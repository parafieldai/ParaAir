#!/bin/bash
# Offscreen UI check: compiles the app's presentation files with a snapshot harness,
# verifies state logic and renders PNGs. Does not launch, sign, mount or touch Keychain.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
products="$root/.build/xcode/Build/Products/Release"
out="${1:-$root/.runtime/ui-snapshots}"
[[ -f "$products/StreamDriveCore.o" ]] || { echo "Build the app once with scripts/build-app.sh first." >&2; exit 1; }
mkdir -p "$root/.build/uiux"
xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" -module-cache-path "$root/.build/uiux/ModuleCache" \
  -I "$products" -I "$root/Sources/CSQLite" \
  "$root/macOS/App/BrandIconGeometry.swift" "$root/macOS/App/GlideStyle.swift" \
  "$root/macOS/App/HomePresentation.swift" "$root/macOS/App/HomeViews.swift" \
  "$root/macOS/App/ConnectionsView.swift" "$root/macOS/Tests/UISnapshots.swift" \
  "$products/StreamDriveCore.o" -lsqlite3 -o "$root/.build/uiux/ui-snapshots"
"$root/.build/uiux/ui-snapshots" "$out"
