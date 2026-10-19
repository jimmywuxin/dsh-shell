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
set -u

LIB="$HOME/.dsh/lib/dsh-lib.sh"
if [ ! -f "$LIB" ]; then
  osascript -e 'display notification "缺少 dsh-lib.sh，请重新运行 build.sh" with title "DSH"' >/dev/null 2>&1
  exit 1
fi
# shellcheck source=./dsh-lib.sh
. "$LIB"

notify() { osascript -e "display notification \"$1\" with title \"DSH\"" >/dev/null 2>&1; }

# 1) 已在跑且就绪 → 直接成功（常见路径：launchd 常驻，开机即在）
if app_ready; then exit 0; fi

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
