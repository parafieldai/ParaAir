#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
products="$root/.build/xcode/Build/Products/Release"
[[ -f "$products/StreamDriveCore.o" ]] || { echo 'Build the current Core with scripts/build-app.sh first.' >&2; exit 1; }
free_kib=$(df -Pk /System/Volumes/Data | awk 'NR==2 {print $4}')
[[ -n "$free_kib" && "$free_kib" -ge 104857600 ]] || { echo 'At least 100 GiB free disk space is required.' >&2; exit 1; }
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos26.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
  -I "$products" -I "$root/Sources/CSQLite" "$root/scripts/connected-smoke.swift" \
  "$products/StreamDriveCore.o" -lsqlite3 -o "$products/connected-smoke"
printf 'Built without running: %s\n' "$products/connected-smoke"
