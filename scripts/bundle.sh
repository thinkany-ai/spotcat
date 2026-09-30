#!/bin/bash
# 编译并打包成 build/Spotcat.app（ad-hoc 签名）
#
#   ./scripts/bundle.sh                       release 配置，本机架构
#   ./scripts/bundle.sh debug                 debug 配置，本机架构
#   ./scripts/bundle.sh release --universal   arm64 + x86_64 通用二进制
#
# 默认打出「开发版」build/Spotcat Dev.app（Bundle ID ai.thinkany.spotcat.dev、数据目录 Spotcat Dev、琥珀色图标），
# 与已安装的正式版互不影响；SPOTCAT_CHANNEL=release 时打正式版 build/Spotcat.app（scripts/release.sh 使用）。
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
UNIVERSAL="${2:-}"
CHANNEL="${SPOTCAT_CHANNEL:-dev}"
# 两个版本输出到不同路径，互不覆盖
if [ "$CHANNEL" = "release" ]; then APP="build/Spotcat.app"; else APP="build/Spotcat Dev.app"; fi
BINARY="build/Spotcat"
mkdir -p build

if [ "$UNIVERSAL" = "--universal" ]; then
  # 指定 --arch 时两种架构输出到同一目录，逐个编译后先复制出来再合并
  for arch in arm64 x86_64; do
    swift build -c "$CONFIG" --arch "$arch"
    cp "$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/Spotcat" "build/Spotcat-$arch"
  done
  lipo -create build/Spotcat-arm64 build/Spotcat-x86_64 -output "$BINARY"
  rm build/Spotcat-arm64 build/Spotcat-x86_64
else
  swift build -c "$CONFIG"
  cp "$(swift build -c "$CONFIG" --show-bin-path)/Spotcat" "$BINARY"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BINARY" "$APP/Contents/MacOS/Spotcat"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 图标（由 scripts/make-icons.sh 从 Resources/Icon/*.svg 生成）
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
if [ "$CHANNEL" = "release" ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  # 开发版：独立的 Bundle ID / 名称 / 图标，数据目录由 SpotcatChannel 决定（AppEnvironment.swift）
  PLIST="$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ai.thinkany.spotcat.dev" \
    -c "Set :CFBundleName Spotcat Dev" -c "Set :CFBundleDisplayName Spotcat Dev" \
    -c "Set :SpotcatChannel dev" "$PLIST"
  cp Resources/AppIcon-Dev.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# 内置聊天面板
cp -R Resources/chat "$APP/Contents/Resources/chat"
# 扩展不再内置，由插件市场按需安装（仓库 thinkany-ai/spotcat-extensions）

codesign --force --sign - "$APP" >/dev/null

echo "Built $APP [$CHANNEL] ($(lipo -archs "$APP/Contents/MacOS/Spotcat"))"
