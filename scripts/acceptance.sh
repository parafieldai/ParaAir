#!/bin/bash
# Local fixtures only. This script never mounts, formats remote storage, installs
# an extension, opens Keychain, or changes macOS settings.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
binary=''
native=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --native-library)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { printf '%s\n' '--native-library requires a local dylib path' >&2; exit 2; }
            native=$2
            shift 2
            ;;
        --*) printf 'Usage: %s [path-to-streamdrive] [--native-library PATH]\n' "$0" >&2; exit 2 ;;
        *) [[ -z "$binary" ]] || { printf 'Pass only one CLI executable path.\n' >&2; exit 2; }; binary=$1; shift ;;
    esac
done
if [[ -z "$binary" && -n ${STREAMDRIVE_BIN:-} ]]; then
    binary=$STREAMDRIVE_BIN
elif [[ -z "$binary" ]]; then
    binary="$repo/.build/out/Products/Debug/streamdrive"
    [[ -x "$binary" ]] || binary="$repo/.build/debug/streamdrive"
fi
if [[ ! -x "$binary" ]]; then
    printf 'Build the CLI first, then pass its executable path to this script.\n' >&2
    exit 1
fi

mkdir -p "$repo/.build"
fixture=$(mktemp -d "$repo/.build/acceptance.XXXXXX")
cleanup() {
    case "$fixture" in
        "$repo"/.build/acceptance.*) /bin/rm -rf -- "$fixture" ;;
    esac
}
trap cleanup EXIT
mkdir "$fixture/files" "$fixture/mount"
printf 'range fixture\n' > "$fixture/files/a file.txt"
expected_hash=$(/usr/bin/shasum -a 256 "$fixture/files/a file.txt")
export STREAMDRIVE_HOME="$fixture/state"

"$binary" connect fixture --fixture-root "$fixture/files" --mount-point "$fixture/mount" --cache-mib 8 --journal-mib 8 --min-free-mib 0 > "$fixture/connect.txt"
"$binary" ls fixture --json > "$fixture/list.json"
[[ $(/usr/bin/plutil -extract 0.path raw -o - "$fixture/list.json") == '/a file.txt' ]]
"$binary" status fixture --json > "$fixture/status.json"
[[ $(/usr/bin/plutil -extract drive.cacheBytes raw -o - "$fixture/status.json") == 0 ]]
[[ $(/usr/bin/plutil -extract drive.pendingUploads raw -o - "$fixture/status.json") == 0 ]]

"$binary" pin fixture '/a file.txt' --json > "$fixture/pin.json"
"$binary" status fixture --json > "$fixture/pinned.json"
[[ $(/usr/bin/plutil -extract drive.pins.0.complete raw -o - "$fixture/pinned.json") == true ]]
[[ $(/usr/bin/plutil -extract drive.pinnedBytes raw -o - "$fixture/pinned.json") -gt 0 ]]
"$binary" unpin fixture '/a file.txt' --json > "$fixture/unpin.json"
"$binary" cache fixture --evict --json > "$fixture/cache.json"
[[ $(/usr/bin/plutil -extract drive.cacheBytes raw -o - "$fixture/cache.json") == 0 ]]
"$binary" uploads fixture --json > "$fixture/uploads.json"
[[ $(/usr/bin/plutil -extract 0 raw -o - "$fixture/uploads.json" 2>/dev/null || true) == '' ]]

if "$binary" connect fixture --fixture-root "$fixture/files" > "$fixture/duplicate.out" 2> "$fixture/duplicate.err"; then
    printf 'FAIL: connect silently overwrote a profile\n' >&2
    exit 1
fi
if "$binary" mount > "$fixture/missing.out" 2> "$fixture/missing.err"; then
    printf 'FAIL: mount accepted an implicit profile\n' >&2
    exit 1
fi
[[ $expected_hash == "$(/usr/bin/shasum -a 256 "$fixture/files/a file.txt")" ]]
printf 'PASS: profile, JSON listing, untouched cache, pin/unpin, clean eviction, uploads, and command guards.\n'
printf 'Finder mount/Quick Look and network performance require a signed enabled extension and an explicit storage target.\n'

if [[ -n "$native" ]]; then
    [[ -f "$native" ]] || { printf 'Native library path does not exist.\n' >&2; exit 1; }
    native="$(cd "$(dirname "$native")" && pwd)/$(basename "$native")"
    free_kib=$(/bin/df -k /System/Volumes/Data | /usr/bin/awk 'NR == 2 { print $4 }')
    [[ "$free_kib" -ge 104857600 ]] || { printf 'Under 100 GiB free; native package verification was not started.\n' >&2; exit 1; }
    # These gated tests create only their own SQLite/local-object fixtures.
    env STREAMDRIVE_NATIVE_LIBRARY="$native" \
        CLANG_MODULE_CACHE_PATH="$repo/.build/module-cache" \
        SWIFTPM_MODULECACHE_OVERRIDE="$repo/.build/module-cache" \
        swift test --package-path "$repo" --cache-path "$repo/.build/pm-cache" --disable-sandbox --filter NativeBackendTests
fi
