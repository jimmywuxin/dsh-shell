#!/bin/bash
# dsh.app 启动入口
# 职责：等 dsh web 就绪 → 开 Edge --app 独立窗口
#
# 2026-09-14 改造（服务已由 launchd 托管，见 README「进程层」）：
#   - 删除 nohup 自拉段：launchd（ai.dsh.web，KeepAlive=true）是唯一拉起方，
#     .app 再自己 nohup 一个实例会在 kickstart 窗口期抢 3080 → 双实例。
#     服务没跑时改为 launchctl kickstart -k 让 launchd 拉，而不是自己拉。
#
# 2026-09-23 补：**bootout 后的恢复路径**。dsh-kill 走 launchctl bootout 把服务
#   从 launchd 卸载（本会话内 label 不存在），此时 kickstart 无从下手，原版直接
#   报「未找到 launchd 服务 ai.dsh.web」退出 —— 跑过 dsh-kill 后双击图标必失败。
#   现补三级：kickstart（已装载）→ bootstrap plist（已卸载，从文件重新装载）
#   → nohup 兜底（前两者都失败时，保证图标永远能用；此分支 launchd 未托管，
#   不存在抢 3080 的双实例）。同理 dsh-restart 也补了 bootstrap 路径。
#   - 就绪判据从「端口有响应」升级为「HTTP 状态码」：dsh 半启动态会 bind 3080
#     但返 404，旧判据会直接把 404 窗口推给用户。401/2xx 才算就绪。
#   - 401 兜底：cookie 过期时会开出 401 页；此时从 web.log 抓最后一条带 token
#     的 URL 直接开，免去用户手动翻日志。
#   - 补 Edge / dsh 缺失的快速失败提示（原来只有 node 有守护，会傻等 30s）。
set -u

# Finder 双击启动时 PATH 只有 /usr/bin:/bin 等系统路径，找不到 node
# （dsh 是 #!/usr/bin/env node 脚本）——显式补上 node 所在目录
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

URL="http://127.0.0.1:3080"
EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
DSH_BIN="$HOME/.npm-global/bin/dsh"
LOG_DIR="$HOME/.dsh"
LABEL="ai.dsh.web"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

notify() { osascript -e "display notification \"$1\" with title \"DSH\"" >/dev/null 2>&1; }

# 前置保护：缺件直接提示，不傻等 30s
if ! command -v node >/dev/null 2>&1; then
  notify "未找到 node，无法启动 dsh web"
  exit 1
fi
if [ ! -x "$EDGE" ]; then
  notify "未找到 Microsoft Edge，无法打开窗口"
  exit 1
fi
if [ ! -x "$DSH_BIN" ] && [ ! -f "$PLIST" ]; then
  notify "未找到 dsh（${DSH_BIN}），且无 launchd 服务定义 $PLIST"
  exit 1
fi

probe_code() {
  # --noproxy：本机地址不走代理，防止代理 502 被误判为「服务就绪」
  local c
  c=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 2 "$URL" 2>/dev/null)
  printf '%s' "${c:-000}"
}

# token 直开：cookie 过期时 web.log 里最后一条带 token 的 URL 就是当前有效入口
token_url() {
  [ -f "$LOG_DIR/web.log" ] || return 1
  local u
  u=$(grep -o "http://127\.0\.0\.1:3080/?token=[A-Za-z0-9_-]*" "$LOG_DIR/web.log" | tail -1)
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}

open_window() { exec "$EDGE" --app="$1"; }

# 就绪判据：401/2xx 算就绪；000（没起）/404（半启动）/5xx 不算
ready_or_open() {
  local code; code="$(probe_code)"
  case "$code" in
    000|404|5*) return 1 ;;
  esac
  if [ "$code" = "401" ]; then
    # 已就绪但无有效 cookie → 用 token URL 直开，避免 401 白页
    local u
    if u="$(token_url)"; then open_window "$u"; fi
  fi
  open_window "$URL"
}

# 1) 服务已在跑 → 直接开窗口（ready_or_open 成功即已 exec 走）
if ready_or_open; then :; fi

# 2) 服务没跑 → 交给 launchd 拉起（不自己 nohup，防双实例）
#    两级是**顺序兜底**而非 if/elif：bootout 刚结束的一瞬 `launchctl print` 仍可能
#    返回成功（残留状态，2026-09-23 实测），此时 kickstart 会失败 —— 若写成 elif
#    就再也不会尝试 bootstrap，白白掉进 nohup 兜底。
STARTED=""
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  # a) 服务已装载（登录时自动装载）：原子重启
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 && STARTED="kickstart"
fi
if [ -z "$STARTED" ] && [ -f "$PLIST" ]; then
  # b) 服务被卸载（典型：刚跑过 dsh-kill 的 bootout）→ 从 plist 重新装载。
  #    注：这一步在 WorkBuddy 派生的 shell 里必报 5: Input/output error（沙箱限制），
  #    但 .app 由 LaunchServices 拉起、不在该沙箱内，实测可用。
  launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 && STARTED="bootstrap"
fi

if [ -z "$STARTED" ]; then
  # c) 兜底：launchd 两条路都不通 → 手动起一个，保证图标永远能用
  if [ ! -x "$DSH_BIN" ]; then
    notify "launchd 未能拉起服务，且未找到 dsh（${DSH_BIN}）"
    exit 1
  fi
  notify "launchd 未托管，已按手动模式启动 dsh web"
  mkdir -p "$LOG_DIR"
  nohup "$DSH_BIN" web --no-open >> "$LOG_DIR/web.log" 2>> "$LOG_DIR/web.err.log" &
fi

# 3) 等就绪，最多 30s（判据同 dsh-restart）
for i in $(seq 1 60); do
  if ready_or_open; then :; fi
  sleep 0.5
done

# 4) 超时提示（拉起失败时看 ~/.dsh/web.err.log）
notify "dsh web 30 秒未就绪（${STARTED:-手动}），请查看 $LOG_DIR/web.err.log"
exit 1
