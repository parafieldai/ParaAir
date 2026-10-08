#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
products="$root/.build/xcode/Build/Products/Release"
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos26.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
  -I "$products" -I "$root/Sources/CSQLite" -I "$root/macOS/CFinderSidebar" \
  "$root/macOS/App/DriveAppearance.swift" "$root/macOS/Tests/DriveAppearanceTests.swift" \
  "$products/StreamDriveCore.o" -lsqlite3 -o "$products/drive-appearance-tests"
"$products/drive-appearance-tests" "$root/.build/xcode"
