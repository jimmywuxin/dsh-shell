#!/bin/bash
# dsh.app 启动检查：确保 dsh web（launchd label ai.dsh.web）就绪。
#
# 由原生壳（src/DshApp.swift）在开窗前调用：/bin/bash launcher.sh --ensure
# 成功 exit 0（HTTP 已可应答），失败 exit 1。
#
# 2026-10-19：从 Edge --app 壳迁到原生 WKWebView 壳。原脚本里的浏览器路径
# （--app 窗口、独立 profile、翻译气泡、zombie 清理、401 token 兜底）全部删除：
#   - 窗口归原生壳，浏览器壳那套「进程被 exec 顶替」的坑随之消失；
#   - 认证由壳用 ~/.dsh/.credentials.yaml 的 browser-session 签名密钥现场 mint
#     cookie（已实测），不再依赖 web.log 里的 token URL —— 那批 token 与当前
#     进程不匹配、逐个测全是 401，兜底早已失效。
# 保留的只有「服务怎么起来、怎么等就绪」——这段踩过 kickstart 半启动、
# bootout 后无法恢复、launchctl print 残留假阳性等多次坑，且与 dsh-restart
# 共用 dsh-lib.sh 里的判据，不能在这里重写一份。
#
# 2026-11-04 加「升级自检」：npm -g 升级 dsh 后，常驻的旧 node 进程仍揣着旧代码，
# 而 ensure 一看服务就绪就 exit 0 →「退出 app 重开」永远看到旧版本，必须去终端跑
# dsh-restart（opencode-shell 同款病灶）。现比对 dsh 入口文件 mtime 与服务进程
# 运行时长：文件比进程新 = 升级过 → kickstart -k 重启，重开 app 即等效 dsh-restart。
set -u

LIB="$HOME/.dsh/lib/dsh-lib.sh"
if [ ! -f "$LIB" ]; then
  osascript -e 'display notification "缺少 dsh-lib.sh，请重新运行 build.sh" with title "DSH"' >/dev/null 2>&1
  exit 1
fi
# shellcheck source=./dsh-lib.sh
. "$LIB"

notify() { osascript -e "display notification \"$1\" with title \"DSH\"" >/dev/null 2>&1; }

# ── 升级自检（2026-11-04）────────────────────────────────────
# 服务进程的启动时刻（epoch）：运行时长来自 ps etime（locale 无关，纯时长）。
# 注意：ps 在 WorkBuddy 的沙箱 shell 里会被拒（operation not permitted）——但
# launcher 只由 .app（LaunchServices 拉起，无沙箱）调用，ps 正常。
service_start_epoch() {
  local pid="$1" etime rest d=0 h=0 m=0 s=0 now total
  [ -n "$pid" ] || return 1
  etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [ -n "$etime" ] || return 1
  # etime 形态：MM:SS / HH:MM:SS / D-HH:MM:SS（D 可为多天）
  rest="$etime"
  case "$rest" in *-*) d="${rest%%-*}"; rest="${rest#*-}" ;; esac
  case "$rest" in
    *:*:*) h="${rest%%:*}"; rest="${rest#*:}"; m="${rest%%:*}"; s="${rest##*:}" ;;
    *:*)   m="${rest%%:*}"; s="${rest##*:}" ;;
    *) return 1 ;;
  esac
  case "${d}${h}${m}${s}" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  total=$(( ((d * 24 + h) * 60 + m) * 60 + s ))
  printf '%s' "$(( now - total ))"
}

# 升级过就重启；返回 0 = 已刷新或无需刷新，返回非 0 = 想重启但 kickstart 失败
# （此时保留旧版本继续可用，不打断开 app 流程）。
refresh_if_upgraded() {
  launchd_managed || return 0
  local pid start entry mtime
  pid="$(pid_of)"
  [ -n "$pid" ] || return 0
  start="$(service_start_epoch "$pid")" || return 0
  # 入口文件取进程 argv 里的真实 bin.js 路径（旧进程实际加载的那个）。
  # 不能 stat $DSH_BIN：macOS 的 stat 默认**不跟软链**，拿到的是 npm 软链自己的
  # mtime（链接创建时间），升级后也不会变 —— 2026-11-04 实测踩坑。
  entry="$(ps -o command= -p "$pid" 2>/dev/null | awk '{print $2}')"
  case "$entry" in /*) [ -f "$entry" ] || return 0 ;; *) return 0 ;; esac
  mtime="$(stat -f %m "$entry" 2>/dev/null)" || return 0
  case "$mtime" in ''|*[!0-9]*) return 0 ;; esac
  [ "$mtime" -gt "$start" ] || return 0
  echo "dsh 已升级（入口文件比服务进程新），重启服务加载新版本…" >&2
  reap_stale_lock   # kickstart -k 前必修课：强杀会留失效锁 → 崩溃循环（dsh-lib.sh 注）
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 || return 1
  if wait_ready >/dev/null; then
    echo "dsh web 已重启（pid $(pid_of)），新版本生效"
    return 0
  fi
  notify "dsh 升级后重启服务，30 秒未就绪，请查看 $LOG_DIR/web.err.log"
  exit 1
}

# 1) 已在跑且就绪 → 升级自检（升级过就重启加载新版本），否则直接成功
if app_ready; then
  refresh_if_upgraded
  exit 0
fi

# 2) 未就绪：先清失效锁（开机后半启动窗口内误 kickstart 会留下 credentials
#    writer lock，见 dsh-lib.sh 头注释），再交给 launchd 拉起。
reap_stale_lock

# 两级兜底。必须是**顺序 if** 而非 if/elif：bootout 刚返回的一瞬 launchctl print
# 仍可能返回成功（残留态假阳性），写成 elif 就再也不会试 bootstrap。
STARTED=""
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1 && STARTED=kickstart
fi
if [ -z "$STARTED" ] && [ -f "$PLIST" ]; then
  launchctl bootstrap "$DOMAIN" "$PLIST" >/dev/null 2>&1 && STARTED=bootstrap
fi

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

# 3) 等就绪，最多 30s（判据在 dsh-lib.sh，401/2xx/3xx 才算就绪）
if wait_ready >/dev/null; then exit 0; fi

notify "dsh web 30秒未就绪（${STARTED:-手动}），请查看 $LOG_DIR/web.err.log"
exit 1
