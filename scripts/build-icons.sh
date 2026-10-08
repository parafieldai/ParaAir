#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/.build"
renderer="$root/.build/brand-icon-renderer"
xcrun swiftc -parse-as-library -O \
  -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
  "$root/macOS/App/BrandIconGeometry.swift" "$root/scripts/render-brand.swift" -o "$renderer"
"$renderer" 1024 "$root/macOS/Resources/ParaAirIcon.png"
"$renderer" 256 "$root/macOS/Resources/ParaAirDriveIcon.png"
temporary="$(mktemp -d "$root/.build/paraair-icon.XXXXXX")"
iconset="$temporary/ParaAir.iconset"
trap 'rm -rf "$temporary"' EXIT
mkdir "$iconset"
for size in 16 32 128 256 512; do
  "$renderer" "$size" "$iconset/icon_${size}x${size}.png"
  doubled=$((size * 2))
  "$renderer" "$doubled" "$iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns "$iconset" -o "$root/macOS/Resources/ParaAirIcon.icns"
