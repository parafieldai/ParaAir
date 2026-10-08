#!/bin/bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo 'Usage: test-finder-sidebar.sh STATE_ROOT MOUNTED_PARAAIR_PATH' >&2; exit 64; }
root="$(cd "$(dirname "$0")/.." && pwd)"
products="$root/.build/xcode/Build/Products/Release"
[[ -f "$products/StreamDriveCore.o" ]] || { echo 'Build StreamDriveCore first.' >&2; exit 1; }
xcrun swiftc -parse-as-library -O -target "$(uname -m)-apple-macos26.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
  -I "$products" -I "$root/Sources/CSQLite" -I "$root/macOS/CFinderSidebar" \
  "$root/macOS/App/FinderSidebar.swift" "$root/macOS/App/DriveAppearance.swift" \
  "$root/macOS/Tests/FinderSidebarRegistration.swift" \
  "$products/StreamDriveCore.o" -lsqlite3 -o "$products/finder-sidebar-tests"
"$products/finder-sidebar-tests" "$1" "$2"
