#!/bin/bash
# dsh.app 启动检查：确保 dsh web（launchd label ai.dsh.web）就绪。
# 由原生壳（src/DshApp.swift）在开窗前以 `--ensure` 调用；成功 exit 0，失败 exit 1。
# 契约：Swift 把 stdout+stderr 合并进同一 pipe，故诊断一律走 stderr；
#       `refreshed=1` 是给壳的机器可读标记（升级换血后据此全量重连）。
# 认证由壳现场 mint cookie，窗口/浏览器归原生壳；本脚本只管「服务怎么起来」。
# 判据/常量来自 dsh-lib.sh，不在本地重写一份。沿革见 CHANGELOG.md。
set -u

LIB="$HOME/.dsh/lib/dsh-lib.sh"
if [ ! -f "$LIB" ]; then
  osascript -e 'display notification "缺少 dsh-lib.sh，请重新运行 build.sh" with title "DSH"' >/dev/null 2>&1
  exit 1
fi
# shellcheck source=./dsh-lib.sh
. "$LIB"

notify() { osascript -e "display notification \"$1\" with title \"DSH\"" >/dev/null 2>&1; }

# ── 升级自检 ──────────────────────────────────────────────────
# npm -g 升级只换磁盘文件，常驻 node 进程仍跑旧代码。判据在 dsh-lib.sh：
# wrapper 每次启动写入口文件指纹到 .service-fp，磁盘当前指纹 ≠ 记录值 = 该换血。
# 比原来的 ps etime + mtime 短且稳：不怕 touch / 同版重装、不怕 stat 不跟软链、
# 不怕 08、09 被 bash 当八进制。记录缺失 = 旧 wrapper 或野实例，换一次血自愈。
# 返回 0 = 无需换血 / 换血成功 / kickstart 失败但旧版仍可用；1 = 服务确实没起来。
refresh_if_upgraded() {
  launchd_managed || return 0
  service_stale || return 0
  echo "dsh 已升级（入口文件指纹变了），重启服务加载新版本…" >&2
  reap_stale_lock   # kickstart -k 前必修课：强杀会留失效锁 → 崩溃循环（dsh-lib.sh 注）
  if ! launchctl kickstart -k "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "升级换血失败（kickstart），保留旧版本继续打开" >&2
    return 0        # 服务未必被杀，别把能用的旧版一起挡在门外
  fi
  if wait_ready >/dev/null; then
    echo "dsh web 已重启（pid $(pid_of)），新版本生效" >&2
    # 机器可读标记：壳的「隐藏恢复」路径据此决定是否全量重连。
    echo "refreshed=1" >&2
    return 0
  fi
  notify "dsh 升级后重启服务，30 秒未就绪，请查看 $LOG_DIR/web.err.log"
  return 1
}

# 1) 已在跑且就绪 → 升级自检（升级过就重启加载新版本），否则直接成功
if app_ready; then
  refresh_if_upgraded || exit 1
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
  # launchd 是唯一拉起方：手起实例脱离 KeepAlive，还会被 wrapper 的 free_port
  # 当孤儿杀掉。宁可明确报错，也别造一个自己会清理掉的野实例。
  notify "launchd 未能拉起服务，请在真终端跑 dsh-restart，或重启电脑"
  echo "服务未启动：kickstart / bootstrap 均失败。真终端跑 dsh-restart 可恢复托管。" >&2
  exit 1
fi

# 3) 等就绪，最多 30s（判据在 dsh-lib.sh，401/2xx/3xx 才算就绪）
if wait_ready >/dev/null; then exit 0; fi

notify "dsh web 30秒未就绪（${STARTED}），请查看 $LOG_DIR/web.err.log"
exit 1
