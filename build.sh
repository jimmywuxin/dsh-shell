#!/bin/bash
# dsh-shell 构建脚本
#   1) 组装 .app → ~/Applications（launcher.sh + 图标 + Info.plist）
#   2) 渲染并安装 launchd 服务（src/ai.dsh.web.plist → ~/Library/LaunchAgents/）
#   3) 安装 dsh-restart / dsh-kill 到 ~/.npm-global/bin
#
# 2026-09-14 改造要点（原版有三个坑）：
#   - 原版只组装 .app，launchd plist 只在注释里留了骨架（且 label 还是历史命名
#     com.jimmy.dsh-web）——服务实际靠手工装的 ai.dsh.web 在跑，仓库里没有源文件。
#     现已纳入构建流程。
#   - 原版无条件 `cp dsh-* 到 PATH`。若仓库版本落后于线上版本（09-14 就发生过：
#     线上是 launchd 感知版，仓库还是旧的 pkill 版），跑一次 build 就把线上脚本
#     降级了。现改为：内容不同则先备份线上版本再覆盖，并打印提示。
#   - 原版 mktemp -d 的 iconset 从不清理，且 icns 落到 $HOME 根目录永久残留。
#     现用 trap 清理临时目录，icns 改落 build/ 下（.gitignore 已忽略）。
set -euo pipefail
cd "$(dirname "$0")"

# 用法：build.sh [--reload]
#   --reload  允许 bootout + bootstrap 重载服务（**仅限真终端**）。默认不开：
#             本 shell 的 bootstrap 必然失败，bootout 后服务会一直掉到重启电脑。
RELOAD=0
for arg in "$@"; do
  if [ "$arg" = "--reload" ]; then RELOAD=1; fi
done

APP="$HOME/Applications/dsh.app"
PLIST_DST="$HOME/Library/LaunchAgents/ai.dsh.web.plist"
BIN_DIR="$HOME/.npm-global/bin"
LIB_DST="$HOME/.dsh/lib/dsh-lib.sh"
BACKUP_DIR="$HOME/.dsh/backups/build"
BUILD_DIR="$PWD/build"
DOMAIN="gui/$(id -u)"
LABEL="ai.dsh.web"

mkdir -p "$BACKUP_DIR"
# 备份统一放~/.dsh/backups/build/，只留最近 5 份同类文件——旧版把备份直接丢在
# PATH目录（~/.npm-global/bin/*.bak-*）和 LaunchAgents（*.plist.bak-*）里，
# 既污染 bin 目录又会被 launchd 扫到，累积到 6 份也没人清。
prune_backups() { # $1=文件名
  ls -1t "$BACKUP_DIR/$1."* 2>/dev/null | tail -n +6 | while read -r old; do rm -f "$old"; done
}

# ── 1) node / dsh 前置检查（失败即停，不要先把旧产物拆了）─────────
#   node 选择：**只用本机独立安装的node，排除 WorkBuddy 内置的**。
#   ~/.workbuddy/binaries/node/... 随 WorkBuddy 自身升级/清理而变动，且在本 shell 里
#   PATH 前置，`command -v node` 只会命中它 —— 常驻服务不该依赖另一个 App 的内部目录。
#   候选：~/.local/bin、Homebrew、/usr/local，外加 PATH 里非 WorkBuddy 的 node；
#   取版本号最高者。launchd 不读 shell 的 PATH，故必须绝对路径。
# 注：此处不用 `case ... in */x/*)` 也不把整个循环塞进$( )——macOS 自带 bash 3.2
#     解析 `$( )` 内的 case 模式会误判结尾括号（本次实测报 syntax error）。
NODE_CANDS=""
for c in "$HOME/.local/bin/node" /opt/homebrew/bin/node /usr/local/bin/node; do
  if [ -x "$c" ]; then NODE_CANDS="$NODE_CANDS$c"$'\n'; fi
done
PATH_NODE="$(command -v node 2>/dev/null || true)"
if [ -n "$PATH_NODE" ] && [ "${PATH_NODE#*/.workbuddy/}" = "$PATH_NODE" ]; then
  NODE_CANDS="$NODE_CANDS$PATH_NODE"$'\n'
fi

NODE_BIN=""
NODE_VER=""
for c in $NODE_CANDS; do
  v="$("$c" --version 2>/dev/null | sed 's/^v//')"
  if [ -n "$v" ]; then
    if [ -z "$NODE_VER" ] || [ "$(printf '%s\n%s\n' "$NODE_VER" "$v" | sort -V | tail -1)" = "$v" ]; then
      NODE_VER="$v"; NODE_BIN="$c"
    fi
  fi
done
if [ -z "$NODE_BIN" ]; then
  echo "错误：本机没有独立安装的 node（已排除 WorkBuddy 内置的），无法渲染 plist。" >&2
  echo "  请先装 node：brew install node，或从 https://nodejs.org 解压到 ~/.local" >&2
  exit 1
fi
echo "node: $NODE_BIN (v$NODE_VER)"

# dsh 入口从 `command -v dsh` 的软链**反解**真实路径，而不是写死
# $HOME/.npm-global/lib/node_modules/... —— npm prefix 一变（nvm / corepack /
# 换 prefix）写死的路径就指向空文件，而 build.sh 仍会"成功"装出一个起不来的plist。
DSH_LINK="$BIN_DIR/dsh"
if [ ! -e "$DSH_LINK" ]; then
  DSH_LINK="$(command -v dsh 2>/dev/null || true)"
fi
if [ -z "$DSH_LINK" ] || [ ! -e "$DSH_LINK" ]; then
  echo "错误：找不到 dsh 可执行文件（试过 $BIN_DIR/dsh 与 PATH），请先 npm i -g @deepseek-ai/dsh" >&2
  exit 1
fi
DSH_JS="$("$NODE_BIN" -e 'const p=require("path"),fs=require("fs");console.log(fs.realpathSync(process.argv[1]))' "$DSH_LINK")"
if [ ! -f "$DSH_JS" ]; then
  echo "错误：dsh 入口 ${DSH_JS} 不是文件，请重装：npm i -g @deepseek-ai/dsh" >&2
  exit 1
fi
echo "dsh:  $DSH_JS"

# ── 2) 图标：assets/icon_1024.png → AppIcon.icns ───────────
mkdir -p "$BUILD_DIR"
ICONSET="$(mktemp -d)/AppIcon.iconset"
trap 'rm -rf "$(dirname "$ICONSET")"' EXIT
mkdir -p "$ICONSET"
for s in 16 32 64 128 256 512 1024; do
  sips -z $s $s assets/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
done
# @2x 命名规范（16/32/128/256/512 的两倍图）
cp "$ICONSET/icon_32x32.png"     "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"     "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"   "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"   "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png" "$ICONSET/icon_512x512@2x.png"
ICNS="$BUILD_DIR/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICNS"

# ── 3) 组装 .app ───────────────────────────────────────────
#   先在 build/ 里装好，最后才动 ~/Applications里的旧产物：原来是先mv 旧 .app 进废纸篓
#   再组装，中途任何一步失败（set -e 直接退出）就留下一个「已被拆掉、没装回来」的空档，
#   用户双击图标只会得到「已损坏」。
APP_NEW="$BUILD_DIR/dsh.app.new"
rm -rf "$APP_NEW"
mkdir -p "$APP_NEW/Contents/MacOS" "$APP_NEW/Contents/Resources"
cp src/launcher.sh "$APP_NEW/Contents/MacOS/dsh"
chmod +x "$APP_NEW/Contents/MacOS/dsh"
cp "$ICNS" "$APP_NEW/Contents/Resources/AppIcon.icns"
cat > "$APP_NEW/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>dsh</string>
  <key>CFBundleIdentifier</key><string>com.jimmy.dsh-shell</string>
  <key>CFBundleExecutable</key><string>dsh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
</dict>
</plist>
EOF

# 组装成功，现在才换掉旧产物
if [ -d "$APP" ]; then
  TRASH="$HOME/.Trash/dsh.app.$(date +%Y%m%d%H%M%S)"
  mv "$APP" "$TRASH"
  REPLACED="$TRASH"
fi
mv "$APP_NEW" "$APP"

echo "完成：双击 $APP 即用"
if [ -n "${REPLACED:-}" ]; then
  echo "旧产物已移至废纸篓：$REPLACED"
fi

# ── 4) launchd 服务：渲染模板 → 安装 ───────────────────────
PLIST_TMP="$(mktemp)"
# 只替换 <string> 行：模板头注释里也写了占位符名，全局替换会把注释一并改掉
SED_SCRIPT="/^[[:space:]]*<string>/{
s|@NODE@|$NODE_BIN|g
s|@DSH@|$DSH_JS|g
s|@HOME@|$HOME|g
}"
sed -e "$SED_SCRIPT" src/ai.dsh.web.plist > "$PLIST_TMP"

PLIST_CHANGED=0
if [ -f "$PLIST_DST" ] && ! cmp -s "$PLIST_TMP" "$PLIST_DST"; then
  BAK="$BACKUP_DIR/ai.dsh.web.plist.$(date +%Y%m%d%H%M%S)"
  cp "$PLIST_DST" "$BAK"
  prune_backups ai.dsh.web.plist
  PLIST_CHANGED=1
  echo "旧 plist 已备份：$BAK"
fi
mkdir -p "$(dirname "$PLIST_DST")"
cp "$PLIST_TMP" "$PLIST_DST"
rm -f "$PLIST_TMP"

# 重载服务
#   安全默认：**不主动 bootout**。本 shell 环境（WorkBuddy 派生进程）里
#   `launchctl bootstrap` 必然报 5: Input/output error，而 bootout 之后 drop 掉的
#   服务在本会话内无法恢复 → 服务会一直停到重启电脑。2026-09-14 实踩两次。
#   故：plist 变了且服务在跑时，只提示、不卸载；确需重载用 `bash build.sh --reload`
#   （请在真终端里跑），或重启电脑。
#
#   判据顺序（2026-10-05 修）：先看**服务是否装载**，再看 plist 变没变。
#   原顺序是 `if plist 无变化 → 跳过` 在前，于是「plist 没变 + 服务被 bootout 卸载」
#   这个组合直接被吃掉 → 刚跑完 dsh-kill 再跑 build.sh 什么也不会发生、服务永远起不来，
#   而下面那个「未装载就 bootstrap」的分支是**死代码**，从来没被执行过。
if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  # 未装载（含刚跑过 dsh-kill）：不管 plist 变没变，都得把服务装回去
  if launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>/dev/null; then
    echo "launchd 服务已装载：$LABEL"
  else
    echo "警告：服务当前未装载且 bootstrap 失败（本环境限制）。请手动执行：" >&2
    echo "  launchctl bootstrap $DOMAIN $PLIST_DST" >&2
  fi
elif [ "$PLIST_CHANGED" -eq 0 ]; then
  echo "plist 无变化，服务已在运行，跳过重载"
elif [ "$RELOAD" -eq 1 ]; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>/dev/null; then
    echo "launchd 服务已重载：$LABEL"
  else
    echo "错误：bootout 后 bootstrap 失败，服务已掉线！立即恢复：" >&2
    echo "  在真终端跑 launchctl bootstrap $DOMAIN $PLIST_DST  （或重启电脑）" >&2
    exit 1
  fi
else
  echo "⚠ plist 已更新为新版本，但当前服务仍在用旧配置。"
  echo "  已跳过自动重载（避免 bootout 后无法 bootstrap）。生效方式二选一："
  echo "    · 重启电脑（登录时自动加载）"
  echo "    · 真终端跑：launchctl bootout $DOMAIN/$LABEL && launchctl bootstrap $DOMAIN $PLIST_DST"
fi

# ── 5) 安装命令行工具 +共享库（差异比对 + 备份，防降级） ───────────
install_file() {
  local src="$1" name dst
  name="$(basename "$src")"
  dst="$2"
  mkdir -p "$(dirname "$dst")"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    local bak="$BACKUP_DIR/$name.$(date +%Y%m%d%H%M%S)"
    cp "$dst" "$bak"
    prune_backups "$name"
    echo "${name}：线上版本与仓库不同，已备份到 ${bak} 后覆盖（请确认仓库版本确实是想要的版本）"
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "$name 已就位"
}
install_file dsh-restart "$BIN_DIR/dsh-restart"
install_file dsh-kill "$BIN_DIR/dsh-kill"
# 共享库：三个脚本 source 它，必须存在，否则双击图标直接退出（launcher.sh 有前置检查）
install_file src/dsh-lib.sh "$LIB_DST"
echo "共享库：$LIB_DST"
