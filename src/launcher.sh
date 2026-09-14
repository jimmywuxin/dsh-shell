#!/bin/bash
# dsh.app 启动入口
# 职责：等 dsh web 就绪 → 开 Edge --app 独立窗口
#
# 2026-09-14 改造（服务已由 launchd 托管，见 README「进程层」）：
#   - 删除 nohup 自拉段：launchd（ai.dsh.web，KeepAlive=true）是唯一拉起方，
#     .app 再自己 nohup 一个实例会在 kickstart 窗口期抢 3080 → 双实例。
#     服务没跑时改为 launchctl kickstart -k 让 launchd 拉，而不是自己拉。
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
if [ ! -x "$DSH_BIN" ] && ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  notify "未找到 dsh（${DSH_BIN}），且无 launchd 服务 $LABEL"
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
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 \
    || notify "launchd 服务 $LABEL 拉起失败，请查看 $LOG_DIR/web.err.log"
else
  notify "服务未运行，且未找到 launchd 服务 $LABEL"
  exit 1
fi

# 3) 等就绪，最多 30s（判据同 dsh-restart）
for i in $(seq 1 60); do
  if ready_or_open; then :; fi
  sleep 0.5
done

# 4) 超时提示（拉起失败时看 ~/.dsh/web.err.log）
notify "dsh web 30 秒未就绪，请查看 $LOG_DIR/web.err.log"
exit 1
