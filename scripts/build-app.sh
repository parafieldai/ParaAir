#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# All builds share this location; no simulators or test clones are created.
free_kib=$(df -Pk /System/Volumes/Data | awk 'NR==2 {print $4}')
if [[ -z "$free_kib" || "$free_kib" -lt 104857600 ]]; then
  echo "At least 100 GiB free on /System/Volumes/Data is required before an Xcode build." >&2
  df -h /System/Volumes/Data >&2
  exit 1
fi
native_library="${STREAMDRIVE_NATIVE_LIBRARY:-$root/native/lib/libstreamdrive.dylib}"
if [[ -n "${STREAMDRIVE_CLOUDFLARE_CLIENT_ID:-}" ]]; then
  if [[ ${#STREAMDRIVE_CLOUDFLARE_CLIENT_ID} -gt 1024 || ! "$STREAMDRIVE_CLOUDFLARE_CLIENT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid public Cloudflare OAuth client ID." >&2; exit 1
  fi
fi
[[ -f "$native_library" ]] || { echo "Build the native engine with scripts/build-juicefs.sh first." >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)." >&2; exit 1; }
signing="$root/.build/signing"
sign_command=(/usr/bin/codesign)
signing_mode="${STREAMDRIVE_SIGNING_MODE:-noninteractive}"
case "$signing_mode" in
  noninteractive|interactive) ;;
  *) echo "STREAMDRIVE_SIGNING_MODE must be noninteractive or interactive." >&2; exit 1 ;;
esac
app_entitlements="$root/macOS/App/StreamDrive.entitlements"
extension_entitlements="$root/macOS/Extension/StreamDriveFS.entitlements"
cli_entitlements=""
if [[ -n "${STREAMDRIVE_SIGN_IDENTITY:-}" ]]; then
  : "${STREAMDRIVE_TEAM_ID:?Set STREAMDRIVE_TEAM_ID for a distribution build}"
  : "${STREAMDRIVE_APP_PROVISIONING_PROFILE:?Set the app Developer ID profile}"
  : "${STREAMDRIVE_EXTENSION_PROVISIONING_PROFILE:?Set the FSKit Developer ID profile}"
  : "${STREAMDRIVE_CLI_PROVISIONING_PROFILE:?Set the packaged CLI Developer ID profile}"
  python3 "$root/scripts/prepare-signing.py" validate \
    --identity-sha1 "$STREAMDRIVE_SIGN_IDENTITY" --team-id "$STREAMDRIVE_TEAM_ID" \
    --app-profile "$STREAMDRIVE_APP_PROVISIONING_PROFILE" \
    --extension-profile "$STREAMDRIVE_EXTENSION_PROVISIONING_PROFILE" \
    --cli-profile "$STREAMDRIVE_CLI_PROVISIONING_PROFILE" --output-dir "$signing"
  if [[ "$signing_mode" == noninteractive ]]; then
    # Default: verified headless signing, with no automatic GUI fallback.
    sign_command=(/usr/bin/python3 -I "$root/scripts/codesign-without-ui.py")
    "${sign_command[@]}" --check-session
  else
    # Explicit developer choice only. App credential operations still forbid UI.
    echo "Interactive developer signing enabled. macOS may request access to the signing key."
  fi
  app_entitlements="$signing/app.entitlements"
  extension_entitlements="$signing/extension.entitlements"
  cli_entitlements="$signing/cli.entitlements"
elif [[ -n "${STREAMDRIVE_TEAM_ID:-}${STREAMDRIVE_APP_PROVISIONING_PROFILE:-}${STREAMDRIVE_EXTENSION_PROVISIONING_PROFILE:-}${STREAMDRIVE_CLI_PROVISIONING_PROFILE:-}${STREAMDRIVE_PROVISIONING_PROFILE:-}" ]]; then
  echo "Incomplete signing configuration. Set an explicit certificate SHA-1 and all three Developer ID profiles, or unset signing variables for an ad-hoc build." >&2
  exit 1
fi
xcodegen generate --spec "$root/macOS/project.yml" --project "$root/macOS"
native_archs="$(/usr/bin/lipo -archs "$native_library")"
# Swift Build documents this process-local flag; it avoids syspolicyd exception bookkeeping.
export DisableExecutionPolicyExceptionRegistration=YES
export CLANG_MODULE_CACHE_PATH="$root/.build/xcode/ModuleCache.noindex"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/xcode/ModuleCache.noindex"
result_bundle="$root/.build/xcode/build-result.xcresult"
[[ ! -e "$result_bundle" ]] || { echo "Previous result bundle exists: $result_bundle" >&2; exit 1; }
trap 'build_status=$?; rm -rf "$result_bundle"; exit "$build_status"' EXIT
# Building an application target runs lsregister automatically. Build only the
# extension with Xcode, then assemble the host without touching registration.
xcodebuild -project "$root/macOS/ParaAir.xcodeproj" -scheme StreamDriveFS \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$root/.build/xcode" -resultBundlePath "$result_bundle" -parallel-testing-enabled NO \
  "ARCHS=$native_archs" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= CODE_SIGNING_ALLOWED=NO build
products="$root/.build/xcode/Build/Products/Release"
app="$products/ParaAir.app"
cli="$app/Contents/Helpers/ParaAirCLI.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Extensions" "$cli/Contents/MacOS" "$cli/Contents/Frameworks"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
# Exercise real FSKit callbacks without registering or mounting a filesystem.
if [[ " $native_archs " == *" $(uname -m) "* ]]; then
  test_binary="$products/volume-callback-tests"
  xcrun swiftc -parse-as-library -target "$(uname -m)-apple-macos26.0" -sdk "$sdk" \
    -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
    -I "$products" -I "$root/Sources/CSQLite" \
    "$root/macOS/Extension/StreamDriveFileSystem.swift" \
    "$root/macOS/Extension/StreamDriveVolume.swift" "$root/macOS/Tests/VolumeCallbacks.swift" \
    "$products/StreamDriveCore.o" -lsqlite3 -o "$test_binary"
  "$test_binary" "$root/.build/xcode"
  bash "$root/scripts/test-native-mount.sh"
  bash "$root/scripts/test-drive-appearance.sh"
else
  echo "Callback tests skipped: native target architecture does not include this build host." >&2
fi
app_binaries=()
cli_binaries=()
launcher_binaries=()
for architecture in $native_archs; do
  binary="$products/ParaAir-app-$architecture"
  xcrun swiftc -parse-as-library -O -target "$architecture-apple-macos26.0" -sdk "$sdk" \
    -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
    -I "$products" -I "$root/Sources/CSQLite" -I "$root/macOS/CFinderSidebar" \
    "$root/macOS/App/"*.swift "$products/StreamDriveCore.o" \
    -lsqlite3 -o "$binary"
  app_binaries+=("$binary")
  cli_binary="$products/ParaAir-cli-$architecture"
  xcrun swiftc -parse-as-library -O -target "$architecture-apple-macos26.0" -sdk "$sdk" \
    -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
    -I "$products" -I "$root/Sources/CSQLite" \
    "$root/Sources/StreamDriveCLI/"*.swift "$products/StreamDriveCore.o" \
    -lsqlite3 -o "$cli_binary"
  cli_binaries+=("$cli_binary")
  launcher_binary="$products/ParaAir-cli-launcher-$architecture"
  xcrun clang -O2 -Wall -Wextra -Werror -target "$architecture-apple-macos26.0" -isysroot "$sdk" \
    "$root/scripts/cli-launcher.c" -o "$launcher_binary"
  launcher_binaries+=("$launcher_binary")
done
/usr/bin/lipo -create "${app_binaries[@]}" -output "$app/Contents/MacOS/ParaAir"
/usr/bin/lipo -create "${cli_binaries[@]}" -output "$cli/Contents/MacOS/paraair"
# A symlink loses Foundation's Bundle.main context when invoked through the old
# helper path. The launcher execs the exact bundled path and carries no secrets.
rm -f "$app/Contents/Helpers/paraair"
/usr/bin/lipo -create "${launcher_binaries[@]}" -output "$app/Contents/Helpers/paraair"
if cmp -s "$app/Contents/MacOS/ParaAir" "$cli/Contents/MacOS/paraair"; then
  echo "App and CLI binaries must be distinct; check intermediate output paths." >&2; exit 1
fi
/usr/bin/plutil -convert xml1 -o "$app/Contents/Info.plist" "$root/macOS/App/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string dev.streamdrive.app "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleExecutable -string ParaAir "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string 0.1.0 "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string 1 "$app/Contents/Info.plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string 26.0 "$app/Contents/Info.plist"
bash "$root/scripts/build-icons.sh"
mkdir -p "$app/Contents/Resources"
/usr/bin/install -m 644 "$root/macOS/Resources/ParaAirIcon.icns" "$app/Contents/Resources/ParaAirIcon.icns"
/usr/bin/install -m 644 "$root/macOS/Resources/ParaAirIcon.png" "$app/Contents/Resources/ParaAirIcon.png"
/usr/bin/install -m 644 "$root/macOS/Resources/ParaAirDriveIcon.png" "$app/Contents/Resources/ParaAirDriveIcon.png"
/usr/bin/plutil -convert xml1 -o "$cli/Contents/Info.plist" "$root/macOS/CLI/Info.plist"
if [[ -n "${STREAMDRIVE_CLOUDFLARE_CLIENT_ID:-}" ]]; then
  /usr/bin/plutil -replace StreamDriveCloudflareClientID -string "$STREAMDRIVE_CLOUDFLARE_CLIENT_ID" "$app/Contents/Info.plist"
  /usr/bin/plutil -replace StreamDriveCloudflareClientID -string "$STREAMDRIVE_CLOUDFLARE_CLIENT_ID" "$cli/Contents/Info.plist"
fi
extension="$app/Contents/Extensions/StreamDriveFS.appex"
/usr/bin/ditto "$products/StreamDriveFS.appex" "$extension"
if [[ -n "${STREAMDRIVE_SIGN_IDENTITY:-}" ]]; then
  python3 "$root/scripts/prepare-signing.py" configure --app "$app" --plan "$signing/plan.json"
else
  python3 "$root/scripts/prepare-signing.py" configure --app "$app"
fi
mkdir -p "$extension/Contents/Frameworks" "$extension/Contents/Resources" "$app/Contents/Frameworks"
/usr/bin/install -m 755 "$native_library" "$app/Contents/Frameworks/libstreamdrive.dylib"
/usr/bin/install -m 644 "$root/native/JUICEFS-LICENSE" "$extension/Contents/Resources/JUICEFS-LICENSE"
/usr/bin/install -m 755 "$native_library" "$extension/Contents/Frameworks/libstreamdrive.dylib"
/usr/bin/install -m 755 "$native_library" "$cli/Contents/Frameworks/libstreamdrive.dylib"
identity="${STREAMDRIVE_SIGN_IDENTITY:--}"
timestamp=(--timestamp=none)
if [[ -n "${STREAMDRIVE_SIGN_IDENTITY:-}" ]]; then timestamp=(--timestamp); fi
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$extension/Contents/Frameworks/libstreamdrive.dylib"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$app/Contents/Frameworks/libstreamdrive.dylib"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$cli/Contents/Frameworks/libstreamdrive.dylib"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$app/Contents/Helpers/paraair"
if [[ -n "$cli_entitlements" ]]; then
  "${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" --entitlements "$cli_entitlements" "$cli"
else
  "${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$cli"
fi
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" \
  --entitlements "$extension_entitlements" "$extension"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" \
  --entitlements "$app_entitlements" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
printf 'Built: %s\n' "$app"
if [[ -z "${STREAMDRIVE_SIGN_IDENTITY:-}" ]]; then
  echo 'Ad-hoc development build. Local extension activation is unverified; distribution requires Developer ID signing and notarization.'
fi
