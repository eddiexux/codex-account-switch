#!/bin/zsh
# 由 Resources/AppIcon.svg 生成 Resources/AppIcon.icns（改图标后运行一次并提交产物，打包时不再依赖 rsvg-convert）。
# 依赖：rsvg-convert（brew install librsvg）、iconutil（macOS 自带）。
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "缺少 rsvg-convert：brew install librsvg" >&2; exit 1; }

SRC="Resources/AppIcon.svg"
OUT="Resources/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"

for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" -h "$size" "$SRC" -o "$SET/icon_${size}x${size}.png"
  rsvg-convert -w $((size * 2)) -h $((size * 2)) "$SRC" -o "$SET/icon_${size}x${size}@2x.png"
done

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "已生成：$OUT ($(du -h "$OUT" | cut -f1))"
