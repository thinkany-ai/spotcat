#!/bin/bash
# 编译并打包成 build/Spotcat.app（ad-hoc 签名，本地开发用）
#
#   ./scripts/bundle.sh                       release，本机架构
#   ./scripts/bundle.sh debug                 debug，本机架构
#   ./scripts/bundle.sh release --universal   arm64 + x86_64 通用二进制（发布用）
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
UNIVERSAL="${2:-}"
APP="build/Spotcat.app"
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
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"
# 内置聊天面板
cp -R Resources/chat "$APP/Contents/Resources/chat"
# 内置扩展（文档、类型声明和许可证不打包）
cp -R extensions "$APP/Contents/Resources/Extensions"
rm -f "$APP"/Contents/Resources/Extensions/*.md "$APP"/Contents/Resources/Extensions/*.d.ts "$APP"/Contents/Resources/Extensions/LICENSE

codesign --force --sign - "$APP" >/dev/null

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/Spotcat"))"
