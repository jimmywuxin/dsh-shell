#!/bin/bash
# dsh-shell 构建脚本（A 阶段：只组装 .app → ~/Applications）
# B 阶段追加：装 launchd plist + dsh-restart 装进 PATH（见下方注释骨架）
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/dsh.app"
REPLACED=""

# 1) 旧产物进废纸篓（可恢复），再重建
if [ -d "$APP" ]; then
  TRASH="$HOME/.Trash/dsh.app.$(date +%Y%m%d%H%M%S)"
  mv "$APP" "$TRASH"
  REPLACED="$TRASH"
fi

mkdir -p "$APP/Contents/MacOS"
cp src/launcher.sh "$APP/Contents/MacOS/dsh"
chmod +x "$APP/Contents/MacOS/dsh"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>dsh</string>
  <key>CFBundleIdentifier</key><string>com.jimmy.dsh-shell</string>
  <key>CFBundleExecutable</key><string>dsh</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict>
</plist>
EOF

echo "完成：双击 $APP 即用"
if [ -n "$REPLACED" ]; then
  echo "旧产物已移至废纸篓：$REPLACED"
fi

# ── B 阶段骨架（届时取消注释）─────────────────────────────
# PLIST_DST="$HOME/Library/LaunchAgents/com.jimmy.dsh-web.plist"
# # 2) 安装 launchd 服务
# cp src/com.jimmy.dsh-web.plist "$PLIST_DST"
# launchctl bootstrap "gui/$(id -u)" "$PLIST_DST" 2>/dev/null \
#   || launchctl kickstart -k "gui/$(id -u)/com.jimmy.dsh-web"
# # 3) dsh-restart 装进 PATH
# cp dsh-restart "$HOME/.npm-global/bin/" && chmod +x "$HOME/.npm-global/bin/dsh-restart"
