#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
# All builds share this location; no simulators or test clones are created.
# Workspace disk policy: 100 GiB free. Hosted CI runners have far less disk, so
# PARAAIR_CI_MIN_FREE_GIB lowers the floor there; it is honoured only when CI=true.
min_free_gib=100
if [[ -n "${PARAAIR_CI_MIN_FREE_GIB:-}" ]]; then
  if [[ "${CI:-}" != true ]]; then
    echo "PARAAIR_CI_MIN_FREE_GIB is ignored outside CI (CI=true)." >&2
  elif [[ "$PARAAIR_CI_MIN_FREE_GIB" =~ ^[0-9]{1,3}$ ]]; then
    min_free_gib=$PARAAIR_CI_MIN_FREE_GIB
  else
    echo "PARAAIR_CI_MIN_FREE_GIB must be a whole number of GiB." >&2; exit 1
  fi
fi
free_kib=$(df -Pk /System/Volumes/Data | awk 'NR==2 {print $4}')
if [[ -z "$free_kib" || "$free_kib" -lt $((min_free_gib * 1024 * 1024)) ]]; then
  echo "At least $min_free_gib GiB free on /System/Volumes/Data is required before an Xcode build." >&2
  df -h /System/Volumes/Data >&2
  exit 1
fi
native_library="${STREAMDRIVE_NATIVE_LIBRARY:-$root/native/lib/libstreamdrive.dylib}"
if [[ -n "${STREAMDRIVE_CLOUDFLARE_CLIENT_ID:-}" ]]; then
  if [[ ${#STREAMDRIVE_CLOUDFLARE_CLIENT_ID} -gt 1024 || ! "$STREAMDRIVE_CLOUDFLARE_CLIENT_ID" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "Invalid public Cloudflare OAuth client ID." >&2; exit 1
  fi
fi
# A signed build without a bundled client ID cannot renew Cloudflare sign-in once
# the access token expires, so Finder never mounts the drive automatically.
if [[ -n "${STREAMDRIVE_SIGN_IDENTITY:-}" && -z "${STREAMDRIVE_CLOUDFLARE_CLIENT_ID:-}" \
      && "${STREAMDRIVE_ALLOW_UNBUNDLED_OAUTH_CLIENT:-}" != 1 ]]; then
  echo "Signed builds need STREAMDRIVE_CLOUDFLARE_CLIENT_ID (the public client ID from cloudflare-oauth-client.json) so R2 sign-in can renew." >&2
  echo "Set STREAMDRIVE_ALLOW_UNBUNDLED_OAUTH_CLIENT=1 to build without it." >&2
  exit 1
fi
# ParaAir Cloud service address: an HTTPS origin, or the loopback dev service.
cloud_loopback=0
# Release version. Apple wants plain numbers in CFBundleShortVersionString, so a pre-release tag
# (v0.1.0-alpha.2) passes 0.1.0 here plus PARAAIR_RELEASE_TAG; PARAAIR_BUILD must only ever increase.
app_version="${PARAAIR_VERSION:-0.1.0}"
app_build="${PARAAIR_BUILD:-1}"
[[ "$app_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "PARAAIR_VERSION must be MAJOR.MINOR.PATCH, got $app_version." >&2; exit 1; }
[[ "$app_build" =~ ^[1-9][0-9]{0,8}$ ]] || { echo "PARAAIR_BUILD must be a positive whole number, got $app_build." >&2; exit 1; }
if [[ -n "${PARAAIR_RELEASE_TAG:-}" && ! "$PARAAIR_RELEASE_TAG" =~ ^v${app_version//./\.}(-(alpha|beta|rc)\.[0-9]+)?$ ]]; then
  echo "PARAAIR_RELEASE_TAG ($PARAAIR_RELEASE_TAG) must be v$app_version or v$app_version-alpha|beta|rc.N." >&2; exit 1
fi
if [[ -n "${PARAAIR_CLOUD_BASE_URL:-}" ]]; then
  if [[ "$PARAAIR_CLOUD_BASE_URL" =~ ^https://[^/?#]+$ ]]; then
    cloud_loopback=0
  elif [[ "$PARAAIR_CLOUD_BASE_URL" =~ ^http://127\.0\.0\.1:[0-9]{2,5}$ ]]; then
    cloud_loopback=1
  else
    echo "PARAAIR_CLOUD_BASE_URL must be https://<host> or http://127.0.0.1:<port>, with no path, query or fragment." >&2; exit 1
  fi
  if (( cloud_loopback )) && [[ -n "${STREAMDRIVE_SIGN_IDENTITY:-}" && "${STREAMDRIVE_ALLOW_DEV_CLOUD:-}" != 1 ]]; then
    echo "Refusing a loopback ParaAir Cloud address in a signed build. Set STREAMDRIVE_ALLOW_DEV_CLOUD=1 for a development build." >&2; exit 1
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
# Sparkle (updates), pinned and checksum-verified by fetch-sparkle.sh.
sparkle_dir="$(bash "$root/scripts/fetch-sparkle.sh")"
app_binaries=()
cli_binaries=()
launcher_binaries=()
for architecture in $native_archs; do
  binary="$products/ParaAir-app-$architecture"
  xcrun swiftc -parse-as-library -O -target "$architecture-apple-macos26.0" -sdk "$sdk" \
    -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
    -I "$products" -I "$root/Sources/CSQLite" -I "$root/macOS/CFinderSidebar" \
    -F "$sparkle_dir" -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
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
/usr/bin/plutil -replace CFBundleShortVersionString -string "$app_version" "$app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleVersion -string "$app_build" "$app/Contents/Info.plist"
[[ -z "${PARAAIR_RELEASE_TAG:-}" ]] || /usr/bin/plutil -replace ParaAirReleaseTag -string "$PARAAIR_RELEASE_TAG" "$app/Contents/Info.plist"
/usr/bin/plutil -replace LSMinimumSystemVersion -string 26.0 "$app/Contents/Info.plist"
bash "$root/scripts/build-icons.sh"
mkdir -p "$app/Contents/Resources"
/usr/bin/install -m 644 "$root/macOS/Resources/ParaAirIcon.icns" "$app/Contents/Resources/ParaAirIcon.icns"
# App icon: the Icon Composer file (macOS 26 rounded square with Liquid Glass), compiled to Assets.car
# (CFBundleIconName) plus a flat ParaAir.icns (CFBundleIconFile). ParaAirIcon.* stay for the drive and disk image.
icon_out="$(mktemp -d)"
xcrun actool "$root/macOS/Resources/ParaAir.icon" --compile "$icon_out" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon ParaAir --output-partial-info-plist "$icon_out/partial.plist" >/dev/null
[[ -f "$icon_out/Assets.car" && -f "$icon_out/ParaAir.icns" ]] || { echo "actool did not produce the app icon" >&2; exit 1; }
/usr/bin/install -m 644 "$icon_out/Assets.car" "$app/Contents/Resources/Assets.car"
/usr/bin/install -m 644 "$icon_out/ParaAir.icns" "$app/Contents/Resources/ParaAir.icns"
rm -rf "$icon_out"
/usr/bin/install -m 644 "$root/macOS/Resources/ParaAirIcon.png" "$app/Contents/Resources/ParaAirIcon.png"
/usr/bin/install -m 644 "$root/macOS/Resources/ParaAirDriveIcon.png" "$app/Contents/Resources/ParaAirDriveIcon.png"
/usr/bin/plutil -convert xml1 -o "$cli/Contents/Info.plist" "$root/macOS/CLI/Info.plist"
if [[ -n "${STREAMDRIVE_CLOUDFLARE_CLIENT_ID:-}" ]]; then
  /usr/bin/plutil -replace StreamDriveCloudflareClientID -string "$STREAMDRIVE_CLOUDFLARE_CLIENT_ID" "$app/Contents/Info.plist"
  /usr/bin/plutil -replace StreamDriveCloudflareClientID -string "$STREAMDRIVE_CLOUDFLARE_CLIENT_ID" "$cli/Contents/Info.plist"
fi
extension="$app/Contents/Extensions/StreamDriveFS.appex"
/usr/bin/ditto "$products/StreamDriveFS.appex" "$extension"
for info in "$cli/Contents/Info.plist" "$extension/Contents/Info.plist"; do
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$app_version" "$info"
  /usr/bin/plutil -replace CFBundleVersion -string "$app_build" "$info"
done
if [[ -n "${PARAAIR_CLOUD_BASE_URL:-}" ]]; then
  for info in "$app/Contents/Info.plist" "$cli/Contents/Info.plist" "$extension/Contents/Info.plist"; do
    /usr/bin/plutil -replace ParaAirCloudBaseURL -string "$PARAAIR_CLOUD_BASE_URL" "$info"
    if (( cloud_loopback )); then
      /usr/bin/plutil -replace ParaAirCloudAllowLoopbackHTTP -bool YES "$info"
      /usr/bin/plutil -replace NSAppTransportSecurity \
        -json '{"NSExceptionDomains":{"127.0.0.1":{"NSExceptionAllowsInsecureHTTPLoads":true}}}' "$info"
    fi
  done
  if (( cloud_loopback )); then
    echo "Warning: this build talks to a development ParaAir Cloud service over plain HTTP at $PARAAIR_CLOUD_BASE_URL. Do not distribute it." >&2
  fi
fi
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
# Sparkle's XPC services exist for sandboxed apps; ParaAir isn't sandboxed, so they are left out.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$sparkle"
/usr/bin/ditto "$sparkle_dir/Sparkle.framework" "$sparkle"
rm -rf "$sparkle/Versions/B/XPCServices" "$sparkle/XPCServices"
identity="${STREAMDRIVE_SIGN_IDENTITY:--}"
timestamp=(--timestamp=none)
if [[ -n "${STREAMDRIVE_SIGN_IDENTITY:-}" ]]; then timestamp=(--timestamp); fi
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$extension/Contents/Frameworks/libstreamdrive.dylib"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$app/Contents/Frameworks/libstreamdrive.dylib"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$cli/Contents/Frameworks/libstreamdrive.dylib"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$app/Contents/Helpers/paraair"
# Sparkle inside out: its installer tool and updater app, then the framework itself.
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$sparkle/Versions/B/Autoupdate"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$sparkle/Versions/B/Updater.app"
"${sign_command[@]}" --force --sign "$identity" --options runtime "${timestamp[@]}" "$sparkle"
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
