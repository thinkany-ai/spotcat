#!/bin/bash
# 发布新版本：修改 Info.plist 版本号（build 号自动 +1）→ 提交 → 打标签 → 推送。
# 推送标签后由 GitHub Actions（.github/workflows/release.yml）自动打包、签名、公证并发布 Release。
#
#   ./scripts/new-version.sh 0.3.0
#   ./scripts/new-version.sh 0.3.0-beta.1    # 预发布
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: $0 <version>, e.g. 0.3.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "invalid version: $VERSION" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean; commit or stash first" >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "release from main" >&2; exit 1; }
git rev-parse "v$VERSION" >/dev/null 2>&1 && { echo "tag v$VERSION already exists" >&2; exit 1; }

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

git add "$PLIST"
git commit -m "Release $VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"

echo "Pushed v$VERSION (build $BUILD). Follow the release: gh run watch -R thinkany-ai/spotcat"
