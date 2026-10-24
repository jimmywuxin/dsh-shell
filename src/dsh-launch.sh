#!/bin/bash
# dsh-launch.sh —— launchd 入口 wrapper（ai.dsh.web 的 ProgramArguments 指向它）。
# 由 build.sh 渲染（@NODE@ / @DSH@ / @HOME@）后安装到 ~/.dsh/lib/dsh-launch.sh。
#
# 为什么要有这一层（2026-10-24 实踩复盘）：
#   原来 plist 直接 exec `node bin.js --profile web --no-open`。一旦 :3080 被一个
#   **不受 launchd 托管的孤儿 dsh 实例**占住，KeepAlive 就以 10s 间隔无限重试，
#   每一轮都 `EADDRINUSE`：
#     · ~/.dsh/logs/ 堆到 19188 个 startup 日志、227MB
#     · web.err.log 涨到 19MB
#     · 真正的病因（孤儿进程）埋在 19MB 文件尾，肉眼翻不出来
#   用户侧看到的就是「dsh 打不开」，且重启服务毫无复原迹象。
#
#   这一层在 exec 之前做四件事：
#     1) 清掉占着 :3080 的**孤儿 dsh 实例**（本次故障的直接病因）
#     2) 自轮转超大 web.err.log（copytruncate，不动 inode）
#     3) 清理过期 startup 日志
#     4) 清失效的 credentials writer lock
#   并把「被非 dsh 程序占用」这种**不可自愈**的情况一次性说清楚后退出，
#   配合 plist 的 ThrottleInterval=60 把重试压到 1 分钟一次 —— 日志不再爆，
#   原因一行可读。
#
# 退出码约定：0/正常由 exec 顶替；78(EX_CONFIG) = 环境问题、需人介入。
#
# ⚠ 写法约定：本脚本的日志都是中文，**任何变量插值都必须写成 ${VAR}**，不能在变量
#   名后直接跟中文/全角符号。macOS 自带 bash 3.2 在变量名边界判断上按字节走，全角
#   括号的首字节会被吞进变量名 → set -u 报「<乱码>: unbound variable」直接崩掉。
#   2026-10-24 实测踩了两次（端口号和 pid 两处），且都崩在「孤儿清理」这条最关键
#   的路径上。build.sh 渲染后有 perl 自检拦这种写法（跳过注释行，故本段安全）。
set -u

NODE_BIN="@NODE@"
DSH_JS="@DSH@"
HOME_DIR="@HOME@"

DSH_BIN="$HOME_DIR/.npm-global/bin/dsh"
ERR_LOG="$HOME_DIR/.dsh/web.err.log"
ERR_PREV="$HOME_DIR/.dsh/web.err.log.prev"
LOG_DIR="$HOME_DIR/.dsh/logs"
LOCK="$HOME_DIR/.dsh/.credentials.yaml.lock"
PORT=3080
PROC_PATTERN='bin\.js.*--profile web'
ERR_MAX_BYTES=$((50 * 1024 * 1024))   # 超过 50MB 就轮转
ERR_KEEP_BYTES=200000                 # 轮转时保留尾部 200KB（足够复盘）
STARTUP_KEEP_DAYS=7                   # startup 日志保留天数

# launchd 不读 shell 的 PATH。这里补齐，保证 lsof/ps/date 等系统工具可用。
export PATH="$HOME_DIR/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

log() { echo "[dsh-launch $(date '+%F %T')] $*" >&2; }

# ── 1) 超大 err.log 自轮转（copytruncate）───────────────────────────────
# 用 copytruncate 而不是 shift：err.log 是 launchd 的 StandardErrorPath，
# 换 inode 后 launchd 仍往旧 inode 写，新文件永远接不到内容。截断 + 进程以
# O_APPEND 写是安全的（append 永远从当前 EOF 开始）。
rotate_err_log() {
  [ -f "$ERR_LOG" ] || return 0
  local sz
  sz=$(stat -f%z "$ERR_LOG" 2>/dev/null || echo 0)
  [ "$sz" -gt "$ERR_MAX_BYTES" ] || return 0
  tail -c "$ERR_KEEP_BYTES" "$ERR_LOG" > "$ERR_PREV" 2>/dev/null || true
  : > "$ERR_LOG" 2>/dev/null || return 0
  log "web.err.log 已轮转：${sz} 字节 → 保留尾部 $((ERR_KEEP_BYTES / 1000))KB 至 $(basename "$ERR_PREV")"
}

# ── 2) 过期 startup 日志清理 ─────────────────────────────────────────
prune_startup_logs() {
  [ -d "$LOG_DIR" ] || return 0
  local n
  n=$(find "$LOG_DIR" -name 'startup-*.log' -mtime "+$STARTUP_KEEP_DAYS" 2>/dev/null | wc -l | tr -d ' ')
  [ "${n:-0}" -gt 0 ] || return 0
  find "$LOG_DIR" -name 'startup-*.log' -mtime "+$STARTUP_KEEP_DAYS" -delete 2>/dev/null || true
  log "清理超过 ${STARTUP_KEEP_DAYS} 天的 startup 日志 $n 个"
}

# ── 3) 失效 credentials 锁 ───────────────────────────────────────────
# 判据与 dsh-lib.sh 的 reap_stale_lock 一致：持锁 PID 是否还活着。
# 这里不 source dsh-lib.sh —— wrapper 要尽量不依赖其他文件，少一个失败面。
reap_stale_lock() {
  [ -f "$LOCK" ] || return 0
  local holder
  holder="$(cat "$LOCK" 2>/dev/null)"
  case "$holder" in
    ''|*[!0-9]*) return 0 ;;
  esac
  kill -0 "$holder" 2>/dev/null && return 0
  rm -f "$LOCK" && log "清掉失效锁（持锁 pid $holder 已死）"
}

# ── 4) 端口占用处理 ──────────────────────────────────────────────────
# 分两种情况，都不再让它以「无限 EADDRINUSE 重试」的形式烂下去：
#   a) 占位者是 dsh（认证墙特征）→ 孤儿，杀掉，让本进程接管
#   b) 占位者是别的程序         → 不可自愈，一次说清后 exit 78
#
# 判据为什么以 HTTP 特征为主、ps 为辅（2026-10-24 修）：
#   初版只用 `ps -p PID -o command=` 匹配 bin\.js.*--profile web。在 WorkBuddy
#   派生的 shell 里实测 `ps` 被沙箱拒绝（operation not permitted），输出为空 →
#   所有 dsh 都被判成「非 dsh 进程」→ wrapper 直接 exit 78，服务再也起不来。
#   改以 dsh 的认证墙为特征：不带 cookie 访问 :3080 恒回 401 + 固定文案
#   `dsh web authentication required`，任何非 dsh 程序都不会回这句话。
#   这个判据不依赖任何被沙箱限制的工具。ps 只作兜底（半死进程占端口、握手不响应时）。
free_port() {
  local holder cmd="" body="" is_dsh=0
  holder="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)"
  [ -n "$holder" ] || return 0

  # 判据一（首选）：认证墙文案
  body="$(curl -s --noproxy '*' --max-time 2 "http://127.0.0.1:$PORT/" 2>/dev/null || true)"
  case "$body" in
    *"dsh web authentication required"*) is_dsh=1 ;;
  esac

  # 判据二（兜底）：命令行特征
  if [ "$is_dsh" -eq 0 ]; then
    cmd="$(ps -p "$holder" -o command= 2>/dev/null || true)"
    printf '%s' "$cmd" | grep -qE "$PROC_PATTERN" && is_dsh=1
  fi

  if [ "$is_dsh" -eq 0 ]; then
    log "错误：:${PORT} 被非 dsh 进程占用，服务无法启动。"
    log "  占用者 pid=$holder${cmd:+  cmd=$cmd}"
    log "  处理：结束该进程，或给 dsh 换端口（dsh web --port N）后修改 dsh.app 的 URL。"
    exit 78
  fi

  log "发现孤儿 dsh 实例占用 :${PORT}（pid=${holder}），终止后接管"
  kill -TERM "$holder" 2>/dev/null || true
  local i
  for i in $(seq 1 20); do
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 "$holder" 2>/dev/null; then
    kill -9 "$holder" 2>/dev/null || true
    sleep 1
  fi

  # 端口没退干净就别硬起 —— 硬起又变回 EADDRINUSE，白刷一轮日志。
  if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN -t >/dev/null 2>&1; then
    log "错误：终止 pid=$holder 后 :${PORT} 仍被占用，放弃本轮启动。"
    exit 78
  fi
  log "孤儿实例已清理，:${PORT} 已释放"
}

# ── 前置校验：node / dsh 入口必须存在 ────────────────────────────────
# 缺了就直接说缺什么。原来 plist 里路径失效时，launchd 只往 err.log 丢一行
# 找不到文件的栈，用户看不出是「dsh 升级把路径换了」还是「服务本身坏了」。
if [ ! -x "$NODE_BIN" ]; then
  log "错误：node 不存在或不可执行：${NODE_BIN}（重跑 build.sh 可重新渲染本脚本）"
  exit 78
fi
if [ ! -f "$DSH_JS" ]; then
  log "错误：dsh 入口不存在：${DSH_JS}（重装：npm i -g @deepseek-ai/dsh）"
  exit 78
fi

rotate_err_log
prune_startup_logs
reap_stale_lock
free_port

# 交棒给真正的服务进程。exec 保留本 PID，launchd 的 pid 追踪不中断。
exec "$NODE_BIN" "$DSH_JS" --profile web --no-open
