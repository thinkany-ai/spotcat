#!/bin/bash
# 从 Resources/Icon/*.svg 生成 AppIcon.icns 和菜单栏模板图标。修改 SVG 后运行一次，生成结果提交到仓库。
# 依赖：rsvg-convert（brew install librsvg）、iconutil（系统自带）
set -euo pipefail
cd "$(dirname "$0")/.."

SRC=Resources/Icon

# 正式版 AppIcon.icns，开发版 AppIcon-Dev.icns（琥珀色底，便于区分）
for name in AppIcon AppIcon-Dev; do
  ICONSET="$(mktemp -d)/$name.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size "$SRC/$name.svg" -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) "$SRC/$name.svg" -o "$ICONSET/icon_${size}x${size}@2x.png"
  done
  iconutil -c icns "$ICONSET" -o "Resources/$name.icns"
done

# README 用图
rsvg-convert -w 256 -h 256 "$SRC/AppIcon.svg" -o docs/icon.png

rsvg-convert -w 18 -h 18 "$SRC/MenuBarIcon.svg" -o Resources/MenuBarIcon.png
rsvg-convert -w 36 -h 36 "$SRC/MenuBarIcon.svg" -o Resources/MenuBarIcon@2x.png

echo "Generated Resources/AppIcon.icns, AppIcon-Dev.icns, MenuBarIcon(@2x).png, docs/icon.png"
