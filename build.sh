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

APP="$HOME/Applications/dsh.app"
PLIST_DST="$HOME/Library/LaunchAgents/ai.dsh.web.plist"
BIN_DIR="$HOME/.npm-global/bin"
BUILD_DIR="$PWD/build"
DOMAIN="gui/$(id -u)"
LABEL="ai.dsh.web"

# ── 1) 旧产物进废纸篓（可恢复），再重建 ─────────────────────
REPLACED=""
if [ -d "$APP" ]; then
  TRASH="$HOME/.Trash/dsh.app.$(date +%Y%m%d%H%M%S)"
  mv "$APP" "$TRASH"
  REPLACED="$TRASH"
fi

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp src/launcher.sh "$APP/Contents/MacOS/dsh"
chmod +x "$APP/Contents/MacOS/dsh"
cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
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

echo "完成：双击 $APP 即用"
if [ -n "$REPLACED" ]; then
  echo "旧产物已移至废纸篓：$REPLACED"
fi

# ── 4) launchd 服务：渲染模板 → 安装 ───────────────────────
NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ]; then
  # PATH 干净时（launchd / cron 等非登录 shell 环境）按已知位置兜底：
  # launchd 不读 shell 的 PATH，而这些环境跑 build.sh 是常态（如修复作业）
  NODE_LATEST="$(ls -1 "$HOME"/.workbuddy/binaries/node/versions/*/bin/node 2>/dev/null | sort -V | tail -1)"
  for c in /opt/homebrew/bin/node /usr/local/bin/node "$NODE_LATEST"; do
    if [ -x "$c" ]; then NODE_BIN="$c"; break; fi
  done
fi
if [ -z "$NODE_BIN" ]; then
  echo "错误：找不到 node（PATH 与已知位置都没有），无法渲染 plist（launchd 需要绝对路径）" >&2
  exit 1
fi
echo "node: $NODE_BIN"
DSH_JS="$HOME/.npm-global/lib/node_modules/@deepseek-ai/dsh/lib/bin.js"
if [ ! -f "$DSH_JS" ]; then
  echo "错误：找不到 dsh 入口 $DSH_JS，请先 npm i -g @deepseek-ai/dsh" >&2
  exit 1
fi

PLIST_TMP="$(mktemp)"
# 只替换 <string> 行：模板头注释里也写了占位符名，全局替换会把注释一并改掉
SED_SCRIPT="/^[[:space:]]*<string>/{
s|@NODE@|$NODE_BIN|g
s|@DSH@|$DSH_JS|g
s|@HOME@|$HOME|g
}"
sed -e "$SED_SCRIPT" src/ai.dsh.web.plist > "$PLIST_TMP"

if [ -f "$PLIST_DST" ] && ! cmp -s "$PLIST_TMP" "$PLIST_DST"; then
  BAK="$PLIST_DST.bak-$(date +%Y%m%d%H%M%S)"
  cp "$PLIST_DST" "$BAK"
  echo "旧 plist 已备份：$BAK"
fi
mkdir -p "$(dirname "$PLIST_DST")"
cp "$PLIST_TMP" "$PLIST_DST"
rm -f "$PLIST_TMP"

# 重载服务（bootstrap 在部分环境下不可用，失败则退回 kickstart 重载）
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
fi
if launchctl bootstrap "$DOMAIN" "$PLIST_DST" 2>/dev/null; then
  echo "launchd 服务已装载：$LABEL"
else
  echo "launchctl bootstrap 不可用，退回 kickstart 重载…"
  launchctl kickstart -k "$DOMAIN/$LABEL" 2>/dev/null \
    || echo "警告：服务未能重载，请手动 launchctl bootstrap $DOMAIN $PLIST_DST" >&2
fi

# ── 5) 安装命令行工具（差异比对 + 备份，防降级） ───────────
install_cmd() {
  local src="$1" name dst bak
  name="$(basename "$src")"
  dst="$BIN_DIR/$name"
  mkdir -p "$BIN_DIR"
  if [ -f "$dst" ] && ! cmp -s "$src" "$dst"; then
    bak="$dst.bak-$(date +%Y%m%d%H%M%S)"
    cp "$dst" "$bak"
    echo "$name：线上版本与仓库不同，已备份到 $bak 后覆盖（请确认仓库版本确实是想要的版本）"
  fi
  cp "$src" "$dst"
  chmod +x "$dst"
  echo "$name 已就位：\$ $name"
}
install_cmd dsh-restart
install_cmd dsh-kill
