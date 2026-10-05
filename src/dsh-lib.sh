#!/bin/bash
# dsh-shell 共享库：常量 + 就绪判据 + 启动/锁处理。
#
# 由 build.sh 安装到 ~/.dsh/lib/dsh-lib.sh，供 launcher.sh / dsh-restart /
# dsh-kill 三个脚本 source。**不单独执行**（直接跑它会走自检，见文件末尾）。
#
# 为什么要有这个库（2026-10-05）：label、就绪判据、失效锁处理原本在三个脚本里各抄
# 一份，于是同一个坑只修了两个脚本——「kickstart -k 强杀半启动实例 → 留下
# ~/.dsh/.credentials.yaml.lock → 下一实例 atomic-write 超时 → 崩溃循环」在
# 09-14 实踩（launchd runs 计数到 14），dsh-restart 补了 reap_stale_lock，而
# launcher.sh 至今没有。开机后 launchd 自动拉起服务要加载插件树（实测 10–30s），
# 该窗口内双击图标 → probe 返 000 → 误判「没跑」→ kickstart -k → 正中靶心。
# 一处定义、三处复用，比在每个调用点各补一次 guard 更小也更不容易漏。

# 一个修一处、三处受益：这三个脚本可能由 Finder 双击拉起（launcher.sh），也可能由
# 任何 PATH 残缺的 shell 拉起（dsh-restart / dsh-kill 是命令行工具但常被自动化调用），
# 所以都要自己补 PATH。候选必须与 build.sh 的 node 候选一致 —— 原先三处硬编码只列了
# ~/.local/bin 和 /usr/local/bin，漏了 /opt/homebrew/bin：若机器上唯一的 node 装在
# homebrew，build.sh 能渲染出可用的 plist，但脚本侧的 nohup 兜底会卡在
# `#!/usr/bin/env node` 上找不到解释器。
# 末尾用 ${PATH:-...} 而不是 $PATH：三个脚本都是 set -u，而 PATH 被清空过（env -i
# 只留 HOME 的自动化调用）时 $PATH 是未绑定变量 → 整个脚本崩在 source 这一行。
# 现实场景实测：`env -i HOME=$HOME bash -c '. dsh-lib.sh'` 能正常拿到 curl/pgrep。
# $HOME 本身不兜底：launchd 与 Finder 都必给 HOME，plist 里的 @HOME@ 也依赖它，
# 真没有就当环境坏了、早点崩比静默算错路径好。
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

probe_code() {
  # --noproxy：本机地址不走代理，防止代理 502 被误判为「服务就绪」
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 2 "$URL" 2>/dev/null)
  printf '%s' "${c:-000}"
}

# 就绪判据：401/2xx/3xx 算就绪；000（没起）/404（半启动，插件树没加载完照样
# bind 3080）/5xx 不算。只看端口连通性会误报 —— 2026-09-14 实踩。
app_ready() {
  case "$(probe_code)" in
    000|404|5*) return 1 ;;
    *)          return 0 ;;
  esac
}

pid_of() { launchctl print "$DOMAIN/$LABEL" 2>/dev/null | awk '/pid = /{print $3; exit}'; }

# 失效锁清理。判据是「持锁 PID 是否还活着」（kill -0），因此与调用方无关、
# 幂等、可在任意启动动作前调一次：实例活着时锁有效→保留；持锁进程已死→备份后删除。
# 删的理由：留着锁的唯一后果是下一次启动继续崩在 writer lock 超时上。
reap_stale_lock() {
  [ -f "$LOCK" ] || return 0
  local holder
  holder="$(cat "$LOCK" 2>/dev/null)"
  case "$holder" in
    ''|*[!0-9]*) return 0 ;;   # 空/非 pid：看不懂就不动，交人工
  esac
  kill -0 "$holder" 2>/dev/null && return 0
  mkdir -p "$LOG_DIR/backups"
  cp "$LOCK" "$LOG_DIR/backups/.credentials.yaml.lock.stale-$(date +%Y%m%d%H%M%S)"
  if rm -f "$LOCK"; then
    echo "  ⚠ 清掉失效锁（持锁 pid ${holder} 已死，已备份到 $LOG_DIR/backups/）" >&2
  else
    echo "  ⚠ 失效锁 $LOCK 删不掉（持锁 pid ${holder}），请手动备份后清理" >&2
  fi
}

# 两级启动兜底，成功时输出状态名（kickstart / bootstrap），都不通则返回 1。
# 必须是**顺序 if**而非 if/elif：launchctl bootout 刚返回的一瞬，launchctl print
# 仍可能返回成功（残留态假阳性，09-23 实测），此时 kickstart 会失败——写成 elif
# 就再也不会尝试 bootstrap，白白掉进 nohup 兜底、服务脱离 launchd 托管。
launchd_start() {
  if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 && { echo kickstart; return 0; }
  fi
  if [ -f "$PLIST" ]; then
    launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 && { echo bootstrap; return 0; }
  fi
  return 1
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
# 不测 launchd_start —— 它会真 kickstart/bootout 线上服务。
dsh_lib_selftest() {
  local fail=0 tmp
  tmp="$(mktemp -d)"
  # 在**子 shell** 里覆盖 URL/LOG_DIR/LOCK：这三个是本库的全局量，直接赋值会污染
  # 调用方（万一有人 source 进来跑自检，就会把线上配置改掉，reap_stale_lock 还会
  # 真的去建 $LOG_DIR/backups 目录）。子 shell 退出后改动自动消失。
  (
    LOG_DIR="$tmp"
    LOCK="$tmp/lock"
    URL="http://127.0.0.1:9"   # discard 端口，无人监听 → probe 得 000

    [ "$(probe_code)" = "000" ] || { echo "FAIL: 空响应未兜底为 000"; exit 1; }
    app_ready && { echo "FAIL: 无服务被判为就绪"; exit 1; }

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