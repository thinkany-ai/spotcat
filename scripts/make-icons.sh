#!/bin/bash
# 从 Resources/Icon/*.svg 生成 AppIcon.icns 和菜单栏模板图标。修改 SVG 后运行一次，生成结果提交到仓库。
# 依赖：rsvg-convert（brew install librsvg）、iconutil（系统自带）
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Resources/Icon
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
  rsvg-convert -w $size -h $size "$SRC/AppIcon.svg" -o "$ICONSET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$SRC/AppIcon.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

rsvg-convert -w 18 -h 18 "$SRC/MenuBarIcon.svg" -o Resources/MenuBarIcon.png
rsvg-convert -w 36 -h 36 "$SRC/MenuBarIcon.svg" -o Resources/MenuBarIcon@2x.png

echo "Generated Resources/AppIcon.icns, Resources/MenuBarIcon.png, Resources/MenuBarIcon@2x.png"
