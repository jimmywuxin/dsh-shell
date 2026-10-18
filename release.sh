#!/bin/bash
# release.sh：一键发版（commit → push main → tag → push tag → Release → 三者复核）
#
#   用法：bash release.sh <版本号> "<Release标题>" ["<Release notes 文字>"]
#   例：  bash release.sh v1.1.0 "v1.1.0 某某功能"
#
# 存在的理由（2026-10-05）：手动发版时踩过一次坑——先打了 tag 才想起
# CHANGELOG 的 commit 还没 push，导致 tag 指向本地 commit、远端 main 落后一截。
# 「tag / 远端 main / HEAD 三者一致」正是 Jimmy 定的发版纪律，本脚本把顺序固定下来，
# 末尾强制复核，不再靠人记得。
#
# notes 默认从 CHANGELOG.md 里取对应版本段落（与 CHANGELOG 保持同步）；
# 传第三个参数则用它覆盖。CHANGELOG 没有对应段落且没传 notes 时直接报错——
# 宁可不发，也不要发出与 CHANGELOG 不一致的 Release。
set -euo pipefail
cd "$(dirname "$0")"

# gh 装在 /opt/homebrew/bin，而自动化/精简 shell 的 PATH 常常只有 /usr/bin:/bin
# （2026-09-14 实踩：tag 已推完才发现 command -v gh 找不到 → Release 没建 → exit 1，
#  只能手工补发。2026-10-18 复核 PATH 里确实没有 /opt/homebrew/bin）。
# 优先本机实际安装位置，其次回落到原 PATH。
PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin}"
export PATH

VERSION="${1:-}"
TITLE="${2:-}"
NOTES="${3:-}"

[ -n "$VERSION" ] || { echo "用法：bash release.sh <版本号> \"<标题>\" [\"<notes>\"]" >&2; exit 1; }
[ -n "$TITLE" ] || { echo "错误：缺 Release 标题" >&2; exit 1; }
# 单独 if 判 tag 存在：写成 `[ -n "$V" = "$(git tag -l "$V")" ] && ...` 时，
# git tag 匹配到多个会展开成多参数 → `[: too many arguments`（bash 3.2 实测）
if git rev-parse -q --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
  echo "错误：tag $VERSION 已存在" >&2; exit 1
fi

# 1) 工作区必须干净：tag 要落在确定的 commit 上
[ -z "$(git status --short)" ] || {
  echo "错误：工作区不干净，先提交或暂存：" >&2; git status --short >&2; exit 1; }

# 2) CHANGELOG 必须有这段（决定 notes，也顺手挡住「忘了更新 CHANGELOG 就发版」）
if [ -z "$NOTES" ]; then
  [ -f CHANGELOG.md ] || { echo "错误：无 CHANGELOG.md 且未传 notes" >&2; exit 1; }
  NOTES="$(awk -v v="## $VERSION" '
    $0 ~ "^"v { f=1; print; next }
    f && /^## / { exit }
    f { print }' CHANGELOG.md)"
  [ -n "$NOTES" ] || { echo "错误：CHANGELOG.md 里没有 $VERSION 段落，也没传 notes" >&2; exit 1; }
fi

# 3) push main **在打 tag 之前**（反了就又是一次 tag 指向未推送 commit）
git push origin main
echo "✓ main 已推送：$(git rev-parse --short HEAD)"

# 4) 打 tag 并推
git tag -a "$VERSION" -m "$TITLE"
git push origin "$VERSION"
echo "✓ tag 已推送：$VERSION"

# 5) Release
if ! command -v gh >/dev/null 2>&1; then
  echo "警告：没有 gh（GitHub CLI），tag 已推但 Release 未创建。装：brew install gh" >&2
  exit 1
fi
gh release create "$VERSION" --title "$TITLE" --notes "$NOTES"

# 6) 强制复核：远端 main / 远端 tag / 本地 HEAD 必须是同一个 commit
REMOTE_MAIN="$(git ls-remote origin refs/heads/main | cut -f1)"
REMOTE_TAG="$(git ls-remote origin "refs/tags/$VERSION^{}" | cut -f1)"   # ^{} 解 annotated tag
LOCAL="$(git rev-parse HEAD)"
echo "复核：远端 main=${REMOTE_MAIN:0:7}  远端 tag=${REMOTE_TAG:0:7}  HEAD=${LOCAL:0:7}"
if [ "$REMOTE_MAIN" = "$LOCAL" ] && [ "$REMOTE_TAG" = "$LOCAL" ]; then
  echo "✓ $VERSION 发版完成，三者一致"
else
  echo "错误：三者不一致！tag/远端 main/HEAD 没有对齐" >&2; exit 1
fi
