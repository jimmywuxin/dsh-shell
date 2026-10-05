#!/bin/bash
# dsh.app 启动入口
# 职责：确保服务在跑 → 等就绪 → 开 Edge --app 独立窗口
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
#
# 2026-10-05 改造：常量/就绪判据/失效锁处理抽到 dsh-lib.sh（三脚本共用）。关键补齐：
#   **启动动作前 reap_stale_lock**。此前只有 dsh-restart 有这道保护，launcher.sh 没有
#   —— 而开机后 launchd 自动拉起服务要加载插件树（实测 10–30s），此窗口内 probe 返
#   000、被本脚本判定「没跑」→ kickstart -k 强杀半启动实例 → 留下 ~/.dsh 的 credentials
#   writer lock → 后续实例崩溃循环（09-14 实踩，launchd runs 计数到 14）。同一个坑只
#   修了两个脚本，现在一处定义、三处复用。
set -u

# Finder 双击启动时 PATH 只有 /usr/bin:/bin 等系统路径，找不到 node
# （dsh 是 #!/usr/bin/env node 脚本）——显式补上 node 所在目录
# PATH 由 dsh-lib.sh 统一补（含 /opt/homebrew/bin，与 build.sh 的 node 候选一致）

LIB="$HOME/.dsh/lib/dsh-lib.sh"
if [ ! -f "$LIB" ]; then
  osascript -e 'display notification "缺少 dsh-lib.sh，请重新运行 build.sh" with title "DSH"' >/dev/null 2>&1
  exit 1
fi
# shellcheck source=../src/dsh-lib.sh
. "$LIB"

EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
# Edge 独立 profile。实测（10-05）dsh 的认证是自持的：GET /?token=xxx → 303
# 种下 Set-Cookie: dsh-auth-*（HttpOnly，Max-Age 30 天）→ 之后裸 URL 返 200。
# 全程与日常 Edge 的任何 cookie/登录态无关，所以拆独立 profile **零代价**。
# 收益有两条实打实的：
#   1) 不再往 Jimmy 日常 2.2GB 的 Edge profile 里塞 dsh 的 cookie 和历史记录；
#   2) 日常 profile 被占用/被锁（Edge 正在更新、profile 目录被别的进程持有）时，
#      --app 可能起不来或抛 profile in use，独立目录躲开这一整类问题。
# ponytail: 首次开窗仍需 token URL 一次（cookie 还没种），这条 401 兜底继续留着。
EDGE_PROFILE="$HOME/.dsh/edge-profile"

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

# token 直开：cookie 过期时 web.log 里最后一条带 token 的 URL 就是当前有效入口。
# 字符集放宽到非空白/引号/&：token 是 base64url 风格，窄集合会匹配出被截断的
# 无效 token，开出来照样 401，白折腾一趟。
token_url() {
  [ -f "$LOG_DIR/web.log" ] || return 1
  local u
  u=$(grep -o 'http://127\.0\.0\.1:3080/?token=[^[:space:]"'"'"'&]*' "$LOG_DIR/web.log" | tail -1)
  [ -n "$u" ] || return 1
  printf '%s' "$u"
}

open_window() {
  mkdir -p "$EDGE_PROFILE"
  # --disable-features=Translate：dsh 的 Web UI 是英文，而本机界面语言是 zh-CN，
  # 独立 profile 每次新建都「从未翻译过」，于是每次开窗都弹「是否翻译此页面」。
  # 走命令行开关而不是写 profile 的 pref：开关跟着进程走，profile 随手删了重建都有效
  #（pref 得重写，Edge 退出时还会拿内存里的值覆盖回去）。
  # 查过 Edge 154 的内核**没有** --no-translate 这个开关（grep 过二进制，对照
  # --no-first-run / --no-default-browser-check 都在），所以只能走 disable-features。
  # 只关翻译，不影响 dsh 本身（dsh 的界面语言是应用内自己的，不靠 Edge 翻译）。
  exec "$EDGE" --user-data-dir="$EDGE_PROFILE" --disable-features=Translate --app="$1"
}

# 就绪则开窗口并 exec（进程替换，函数不返回）；未就绪返回 1。
# 无 token 时 401 页就是当前状态，此时用裸 URL 打开即可。
ready_or_open() {
  local code
  code="$(probe_code)"
  case "$code" in
    000|404|5*) return 1 ;;
  esac
  if [ "$code" = "401" ]; then
    local u
    if u="$(token_url)"; then open_window "$u"; fi
  fi
  open_window "$URL"
}

# 1) 服务已在跑 → 直接开窗口
if ready_or_open; then :; fi

# 2) 服务没跑 → 先清可能存在的失效锁（关键：见文件头2026-10-05），再交给 launchd
#    拉起。不自己 nohup，防双实例。
reap_stale_lock
STARTED="$(launchd_start)" || STARTED=""

if [ -z "$STARTED" ]; then
  # c) 兜底：launchd 两条路都不通 → 手动起一个，保证图标永远能用
  if launchd_managed; then
    # 已装载却 kickstart 失败：再手工拉会和 launchd 的实例抢 3080，宁可不启动
    notify "服务在 launchd 托管下但无法重启，请先跑 dsh-kill 再双击本图标"
    exit 1
  fi
  if [ ! -x "$DSH_BIN" ]; then
    notify "launchd 未能拉起服务，且未找到 dsh（${DSH_BIN}）"
    exit 1
  fi
  notify "launchd 未托管，已按手动模式启动 dsh web"
  mkdir -p "$LOG_DIR"
  nohup "$DSH_BIN" web --no-open >> "$LOG_DIR/web.log" 2>> "$LOG_DIR/web.err.log" &
fi

# 3) 等就绪，最多 30s（判据同 dsh-restart）。就绪那一刻由 ready_or_open exec 开窗。
for _i in $(seq 1 60); do
  if ready_or_open; then :; fi
  sleep 0.5
done

# 4) 超时提示（拉起失败时看 ~/.dsh/web.err.log）
notify "dsh web 30秒未就绪（${STARTED:-手动}），请查看 $LOG_DIR/web.err.log"
exit 1