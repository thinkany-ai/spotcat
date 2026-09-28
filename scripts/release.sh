#!/bin/bash
# 构建可分发的 Spotcat：通用二进制 → Developer ID 签名（hardened runtime）→ 公证 → staple → DMG + ZIP
#
# 需要的环境变量（与 Termany 相同）：
#   APPLE_SIGNING_IDENTITY  如 "Developer ID Application: Name (TEAMID)"，证书需在钥匙串中
#   APPLE_ID                Apple ID 邮箱
#   APPLE_PASSWORD          App 专用密码（appleid.apple.com 生成）
#   APPLE_TEAM_ID           开发者团队 ID
#
# 用法：
#   ./scripts/release.sh             产物输出到 dist/
#   ./scripts/release.sh --publish   另外创建 GitHub Release 草稿 v<版本> 并上传产物（需要 gh 已登录）
#
# 版本号取自 Resources/Info.plist 的 CFBundleShortVersionString。
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APPLE_SIGNING_IDENTITY:?set APPLE_SIGNING_IDENTITY}"
: "${APPLE_ID:?set APPLE_ID}"
: "${APPLE_PASSWORD:?set APPLE_PASSWORD}"
: "${APPLE_TEAM_ID:?set APPLE_TEAM_ID}"

PUBLISH="${1:-}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Resources/Info.plist)
APP="build/Spotcat.app"
DIST="dist"
ZIP="$DIST/Spotcat-$VERSION.zip"
DMG="$DIST/Spotcat-$VERSION.dmg"

notarize() {
  xcrun notarytool submit "$1" \
    --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" --wait
}

echo "==> [1/6] Build universal app (v$VERSION)"
SPOTCAT_CHANNEL=release ./scripts/bundle.sh release --universal

echo "==> [2/6] Sign with Developer ID (hardened runtime)"
codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> [3/6] Notarize and staple the app"
rm -rf "$DIST" && mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/notarize.zip"
notarize "$DIST/notarize.zip"
rm "$DIST/notarize.zip"
xcrun stapler staple "$APP"

echo "==> [4/6] Package ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> [5/6] Package, sign, notarize and staple DMG"
STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Spotcat $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> [6/6] Verify"
spctl --assess --type execute --verbose "$APP"
spctl --assess --type open --context context:primary-signature --verbose "$DMG"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt)
ls -lh "$DIST"

if [ "$PUBLISH" = "--publish" ]; then
  if gh release view "v$VERSION" >/dev/null 2>&1; then
    echo "==> Upload to existing GitHub Release v$VERSION"
    gh release upload "v$VERSION" "$DMG" "$ZIP" "$DIST/SHA256SUMS.txt" --clobber
  else
    echo "==> Create draft GitHub Release v$VERSION"
    gh release create "v$VERSION" "$DMG" "$ZIP" "$DIST/SHA256SUMS.txt" \
      --draft --title "Spotcat v$VERSION" --generate-notes
  fi
fi
