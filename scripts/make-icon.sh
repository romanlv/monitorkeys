#!/bin/bash
# Renders Resources/AppIcon.icns from scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swift scripts/make-icon.swift "$work/icon.png" >/dev/null
set=$work/AppIcon.iconset
mkdir "$set"
for s in 16 32 128 256 512; do
    sips -z $s $s "$work/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$work/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$set" -o Resources/AppIcon.icns
cp "$work/icon.png" Resources/AppIcon.png
echo "wrote Resources/AppIcon.icns"
