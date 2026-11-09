#!/bin/bash
# dsh-shell 共享库：常量 + 就绪判据 + 启动/锁处理。
#
# 由 build.sh 安装到 ~/.dsh/lib/dsh-lib.sh，供 launcher.sh / dsh-restart /
# dsh-kill 三个脚本 source。**不单独执行**（直接跑它会走自检，见文件末尾）。
#
# 一处定义、三处复用：label / 就绪判据 / 失效锁处理曾在三个脚本里各抄一份，
# 修一个漏两个 → kickstart -k 强杀半启动实例留下失效锁 → 崩溃循环。
# 开机后 launchd 加载插件树要 10–30s，该窗口内误判「没跑」再 kickstart 正中靶心。
#
# 三个脚本都可能由 PATH 残缺的 Finder / 自动化调用，故统一补 PATH；
# 候选必须与 build.sh 的 node 候选一致。${PATH:-...} 不能写成 $PATH：
# `env -i HOME=...` 下 set -u 会崩在 source 这一行。
# $HOME 不兜底：launchd 与 Finder 必给，plist 的 @HOME@ 也依赖它。
# 沿革见 CHANGELOG.md。
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

LABEL="ai.dsh.web"
DOMAIN="gui/$(id -u)"
URL="http://127.0.0.1:3080"
LOG_DIR="$HOME/.dsh"
LOCK="$LOG_DIR/.credentials.yaml.lock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DSH_BIN="$HOME/.npm-global/bin/dsh"
# 真实 argv：node .../@deepseek-ai/dsh/lib/bin.js --profile web --no-open。
# 旧的 `pkill -f "dsh web"` 一个都匹配不到（命令行里没有连续的 "dsh web"）。
PROC_PATTERN='bin\.js.*--profile web'
# launchd wrapper 每次启动把入口文件指纹写这里，launcher 据此判断是否跑旧代码。
SERVICE_FP="$LOG_DIR/.service-fp"

# 服务是否跑着旧代码。stat -L 必须跟随软链：npm 升级换的是目标文件，
# 软链自身的 inode 不变。无记录/空记录 = 旧 wrapper 或野实例 → 换一次血自愈；
# 拿不到磁盘指纹（dsh 未安装）→ 放行，重启也起不来。
service_stale() {
  local disk recorded
  disk="$(stat -L -f '%z|%i' "$DSH_BIN" 2>/dev/null)" || return 1
  [ -n "$disk" ] || return 1
  [ -f "$SERVICE_FP" ] || return 0
  recorded="$(cat "$SERVICE_FP" 2>/dev/null)"
  [ -n "$recorded" ] || return 0
  [ "$disk" != "$recorded" ]
}

probe_code() {
  # --noproxy：本机地址不走代理，防止代理 502 被误判为「服务就绪」
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 2 "$URL" 2>/dev/null)
  printf '%s' "${c:-000}"
}

# 就绪判据：401/2xx/3xx 算就绪；000（没起）/404（半启动，插件树没加载完照样
# bind 3080）/5xx 不算。只看端口连通性会误报 —— 2026-09-14 实踩。
# $1 可选：调用方已经 probe 过就把它传进来，省一次请求。
# 判据只此一处 —— launcher.sh 的 ready_or_open 曾把它抄了一份（2026-10-06 收回）。
app_ready() {
  case "${1:-$(probe_code)}" in
    000|404|5*) return 1 ;;
    *)          return 0 ;;
  esac
}

pid_of() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/pid = /{print $3; exit}'; }

# 失效锁清理。判据是「持锁 PID 是否还活着」（kill -0），因此与调用方无关、
# 幂等、可在任意启动动作前调一次：实例活着时锁有效→保留；持锁进程已死→删除。
# 删的理由：留着锁的唯一后果是下一次启动继续崩在 writer lock 超时上。
reap_stale_lock() {
  [ -f "$LOCK" ] || return 0
  local holder
  holder="$(cat "$LOCK" 2>/dev/null)"
  case "$holder" in
    ''|*[!0-9]*) return 0 ;;   # 空/非 pid：看不懂就不动，交人工
  esac
  kill -0 "$holder" 2>/dev/null && return 0
  # 锁里只有一个 pid，没什么可备份的（曾经每次都往 backups/ 拷一份，纯堆积）。
  rm -f "$LOCK" \
    && echo "  ⚠ 清掉失效锁（持锁 pid ${holder} 已死）" >&2 \
    || echo "  ⚠ 失效锁 $LOCK 删不掉（持锁 pid ${holder}），请手动清理" >&2
}

# label 是否仍受launchd 托管（kickstart/bootstrap 都失败后的关键判据）。
launchd_managed() { launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; }

# 等应用真就绪，最多 30s；成功输出 HTTP 状态码。
wait_ready() {
  local i
  for i in $(seq 1 60); do
    if app_ready; then probe_code; return 0; fi
    sleep 0.5
  done
  return 1
}

# 自检：`bash ~/.dsh/lib/dsh-lib.sh`。只断言最易回归的三处判据。
dsh_lib_selftest() {
  local fail=0 tmp
  tmp="$(mktemp -d)"
  # 在**子 shell** 里覆盖 URL/LOG_DIR/LOCK：这三个是本库的全局量，直接赋值会污染
  # 调用方（万一有人 source 进来跑自检，就会把线上配置改掉）。子 shell 退出后改动
  # 自动消失。
  (
    LOG_DIR="$tmp"
    LOCK="$tmp/lock"
    URL="http://127.0.0.1:9"   # discard 端口，无人监听 → probe 得 000

    [ "$(probe_code)" = "000" ] || { echo "FAIL: 空响应未兜底为 000"; exit 1; }
    app_ready && { echo "FAIL: 无服务被判为就绪"; exit 1; }

    # 版本指纹：无记录判陈旧、同指纹判新鲜、软链目标变了判陈旧
    DSH_BIN="$tmp/bin"; SERVICE_FP="$tmp/fp"
    printf 'v1' > "$DSH_BIN"
    service_stale || { echo "FAIL: 无指纹记录未判陈旧"; exit 1; }
    stat -L -f '%z|%i' "$DSH_BIN" > "$SERVICE_FP"
    service_stale && { echo "FAIL: 同指纹被判陈旧"; exit 1; }
    ln -s "$DSH_BIN" "$tmp/link"; DSH_BIN="$tmp/link"
    printf 'v2-longer' > "$DSH_BIN"
    service_stale || { echo "FAIL: 软链目标变了未判陈旧"; exit 1; }

    : > "$LOCK"; reap_stale_lock >/dev/null 2>&1
    [ -f "$LOCK" ] || { echo "FAIL: 空锁被误删"; exit 1; }

    echo 999999 > "$LOCK"; reap_stale_lock >/dev/null 2>&1
    [ -f "$LOCK" ] && { echo "FAIL: 死 pid 的锁未清理"; exit 1; }

    echo $$ > "$LOCK"; reap_stale_lock >/dev/null 2>&1
    [ -f "$LOCK" ] || { echo "FAIL: 活 pid 的锁被误删"; exit 1; }

    exit 0
  ) || fail=1
  rm -rf "$tmp"
  [ "$fail" = 0 ] && echo "dsh-lib selftest OK"
  return "$fail"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  dsh_lib_selftest
fi