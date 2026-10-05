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
#   - 补浏览器 / dsh 缺失的快速失败提示（原来只有 node 有守护，会傻等 30s）。
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

# 浏览器壳 = Microsoft Edge。
# 曾试过换 Chrome（2026-10-05，commit 4147ae1），**结论是换不回来**：
# Chrome 154跑dsh web 页面时 renderer 会崩（Aw Snap 错误码 10/15，Chrome 弹
# 「上次打开时意外退出」），重启电脑无效。Edge 154 跑同一页面一直正常。
# Safari 更早也试过，实测否掉：无 --app（窗口带地址栏）、无 --user-data-dir
# （cookie 直接进日常 profile）、AppleScript 控制报 -10084 要自动化授权。
BROWSER="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
# Edge 独立 profile。dsh 的认证是自持的（10-05 实测）：GET /?token=xxx → 303 种下
# Set-Cookie: dsh-auth-*（HttpOnly，Max-Age 30 天）→ 之后裸 URL 返 200，不碰任何
# 外部 cookie，所以拆独立目录零代价。收益：不往日常 profile（2.2G）塞 dsh 的
# cookie 与历史，且躲开「日常 profile 被占用/被锁导致 --app 起不来」整类问题。
BROWSER_PROFILE="$HOME/.dsh/edge-profile"

notify() { osascript -e "display notification \"$1\" with title \"DSH\"" >/dev/null 2>&1; }

# 前置保护：缺件直接提示，不傻等 30s
if ! command -v node >/dev/null 2>&1; then
  notify "未找到 node，无法启动 dsh web"
  exit 1
fi
if [ ! -x "$BROWSER" ]; then
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
  mkdir -p "$BROWSER_PROFILE"
  reap_zombie_browser
  disable_browser_translate
  # 启动方式：**回到 exec**（2026-10-06 改，nohup+disown 版是错的）。
  #
  # 改回 exec 的原因（实测）：`nohup ... &` + disown 让浏览器活过了 launcher 的
  # 退出，但代价是**它成了孤儿子进程**（ppid = /sbin/launchd，Jimmy 双击后实测）。
  # macOS 上 Chromium 对孤儿子进程的 `--app` 窗口有约束 —— 进程活着、命令行带着
  # --app，但**一个窗口都不开**（renderer=0、无 Crashpad 记录 = 不是崩，是不开窗）。
  # exec 出的进程 ppid 是 LaunchServices，窗口正常。
  #
  # exec 曾被认为会导致「第二次点 app 不重跑 launcher」（因为进程被顶替、
  # LaunchServices 认为 app 还在运行）—— 这条观察本身没错，但解法不该是换启动方式，
  # 而是在**下次启动前把上次的残留清掉**（上面 reap_zombie_browser 无条件清）。
  # 两者结合 = 窗口能开+ 每次点 app 都重跑 launcher。
  exec "$BROWSER" --user-data-dir="$BROWSER_PROFILE" --app="$1"
}

# 清掉上一次的 dsh 浏览器实例 —— **无论有没有窗口，都清**。
#
# 为什么必须无条件清（2026-10-06 修正）：
#   open_window 用 `exec`，所以 dsh.app 的进程会被浏览器进程顶替，ppid 是
#   LaunchServices。这带来两个连锁问题：
#     ① 进程被顶替后 LaunchServices 认为「dsh.app 还在运行」→ 第二次点 app 只
#        activate 已有进程、**launcher 不重跑** → 用户看到「浏览器默认界面」；
#     ② 单实例机制下新进程只送 URL 不执行 --app。
#   既然「不清残留 → launcher 不重跑」，那就**每次点 app 都在 exec 前清干净**，
#   让每一次点击都是「从零起一个带 --app 的新实例」。这与用户预期一致：
#   点 app = 开一个新窗口。代价：连着点两次会有两个窗口（旧的不保留），可接受。
#
# 判据与坑（都实测过）：
#   - pgrep -f 而不是 `ps | grep`：后者在这台机器上匹配不到（多次实测返 0）。
#   - pkill 后要轮询等一下：SingletonLock 软链与 socket 的清理有延迟，
#     立刻重启会被旧锁判成「已有实例」→ 又变成不开窗。
reap_zombie_browser() {
  pgrep -f "user-data-dir=$BROWSER_PROFILE" >/dev/null 2>&1 || return 0
  pkill -f "user-data-dir=$BROWSER_PROFILE" 2>/dev/null
  local i
  for i in $(seq 1 10); do
    pgrep -f "user-data-dir=$BROWSER_PROFILE" >/dev/null 2>&1 || return 0
    sleep 0.3
  done
  return 0
}

# 关掉浏览器的「是否翻译此页面」气泡。
# 起因：dsh 的 Web UI 是英文、本机界面语言 zh-CN，而独立 profile 每次新建都「从未
# 翻译过」，于是每次开窗都弹这个框。
# 走过两段弯路，别再试：
#   ① `--disable-features=Translate` —— 无效。`Translate` 不是 Edge 154 的有效
#      feature 名（grep 内核二进制 .../Frameworks/.../Microsoft Edge Framework 找不到），
#      renderer 进程也没拿到这个 flag。
#   ② 无脑 `plutil -replace translate.enabled` —— **pref 里 translate 块还不存在时
#      plutil 报 "Key path not found" 直接失败**（实测0.004s），&& 短路 → 翻译块
#      从来没被创建过。所以必须先判块在不在，不在就 -insert 建出来。
# 现在走 profile 的 pref：Chromium 里翻译气泡由 `translate.enabled` 控制，
# 「永不翻译此语言」写进 `translate.blocked_languages`。两者都写，双保险。
# 用 plutil 改 JSON（macOS 自带，不用 python）；Edge 退出时会拿内存里的值覆盖，所以
# 每次开窗前重写一遍——幂等。
# 兜底：prefs 写坏了不能让它挡住开窗，失败就继续开（顶多多弹一次框）。
disable_browser_translate() {
  local prefs="$BROWSER_PROFILE/Default/Preferences" want='{"enabled":false,"blocked_languages":["en"]}'
  [ -f "$prefs" ] || return 0
  cp "$prefs" "$prefs.dsh-bak" 2>/dev/null
  # 判块在不在用 grep 而不是 plutil -extract：plutil 对嵌套 dict 的 extract 也会报
  # "No value at that key path"（实测{"translate":{...}} 也判不出来），不可用。
  if grep -q '"translate"' "$prefs" 2>/dev/null; then
    # 块已存在 → 逐键改（-insert 在已存在时会失败）
    plutil -replace translate.enabled -bool NO "$prefs" \
      && plutil -replace translate.blocked_languages -json '["en"]' "$prefs"
  else
    # 块不存在 → 一次 insert 建出来
    plutil -insert translate -json "$want" "$prefs"
  fi || cp "$prefs.dsh-bak" "$prefs" 2>/dev/null
  return 0
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