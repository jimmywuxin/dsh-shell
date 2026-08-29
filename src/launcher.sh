#!/bin/bash
# dsh.app 启动入口（A 阶段：.app 内嵌守护）
# 职责：检测 dsh web → 没跑就后台拉起 → 等端口就绪 → 开 Edge --app 独立窗口
# B 阶段升级 launchd 后：删掉「拉起」段即可，等待逻辑原样保留
set -u

# Finder 双击启动时 PATH 只有 /usr/bin:/bin 等系统路径，找不到 node
# （dsh 是 #!/usr/bin/env node 脚本）——显式补上 node 所在目录
export PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

URL="http://127.0.0.1:3080"
EDGE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
DSH_BIN="$HOME/.npm-global/bin/dsh"
LOG_DIR="$HOME/.dsh"

# 前置保护：node 不可用则直接提示，不傻等 30s
if ! command -v node >/dev/null 2>&1; then
  osascript -e 'display notification "未找到 node，无法拉起 dsh web" with title "DSH"'
  exit 1
fi

port_ready() {
  # --noproxy：本机地址不走代理，防止代理 502 被误判为「服务就绪」
  curl -s -o /dev/null --noproxy '*' --max-time 1 "$URL"
}

# 1) 服务已在跑 → 直接开窗口（防双实例：只在确认没跑时才拉起）
if port_ready; then
  exec "$EDGE" --app="$URL"
fi

# 2) 服务没跑 → 后台拉起（日志路径与 B 阶段 plist 约定一致，方便衔接）
mkdir -p "$LOG_DIR"
nohup "$DSH_BIN" web --no-open >> "$LOG_DIR/web.log" 2>> "$LOG_DIR/web.err.log" &

# 3) 等端口就绪，最多 30s
for i in $(seq 1 60); do
  if port_ready; then
    exec "$EDGE" --app="$URL"
  fi
  sleep 0.5
done

# 4) 超时提示（拉起失败时看 ~/.dsh/web.err.log）
osascript -e 'display notification "dsh web 30 秒未就绪，请查看 ~/.dsh/web.err.log" with title "DSH"'
exit 1
