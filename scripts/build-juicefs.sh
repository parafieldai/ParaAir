#!/bin/bash
# Pinned source, project-private module/toolchain caches, bounded parallelism.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION=adcca1cc61bb4d668a945d64b2e176b44ac8e5b5
SHA256=2d1df6b63c23badd6a31845e2b604fe702f7cc49e1352f2f7204d2ecc48e52d9
BUILD="$ROOT/.build-native"
SOURCE="$BUILD/juicefs-$REVISION"
run_tests=0
run_race=0
for argument in "$@"; do
  case "$argument" in
    --test) run_tests=1 ;;
    --race) run_race=1 ;;
    *) echo "Usage: $0 [--test] [--race]" >&2; exit 2 ;;
  esac
done
# Workspace disk policy: 100 GiB free. Hosted CI runners have far less disk, so
# PARAAIR_CI_MIN_FREE_GIB lowers the floor there; it is honoured only when CI=true.
min_free_gib=100
if [[ -n "${PARAAIR_CI_MIN_FREE_GIB:-}" ]]; then
  if [[ "${CI:-}" != true ]]; then
    echo 'PARAAIR_CI_MIN_FREE_GIB is ignored outside CI (CI=true).' >&2
  elif [[ "$PARAAIR_CI_MIN_FREE_GIB" =~ ^[0-9]{1,3}$ ]]; then
    min_free_gib=$PARAAIR_CI_MIN_FREE_GIB
  else
    echo 'PARAAIR_CI_MIN_FREE_GIB must be a whole number of GiB.' >&2; exit 1
  fi
fi
free_kib=$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')
if (( free_kib < min_free_gib * 1024 * 1024 )); then echo "Refusing native build: less than $min_free_gib GiB free." >&2; exit 1; fi
mkdir -p "$BUILD" "$BUILD/tmp" "$ROOT/native/lib"
export TMPDIR="$BUILD/tmp"
if [[ ! -f "$BUILD/juicefs.tar.gz" ]]; then
 curl --fail --location --retry 2 --max-time 120 --silent --show-error "https://codeload.github.com/juicedata/juicefs/tar.gz/$REVISION" -o "$BUILD/juicefs.tar.gz.partial"
 mv "$BUILD/juicefs.tar.gz.partial" "$BUILD/juicefs.tar.gz"
fi
actual=$(shasum -a 256 "$BUILD/juicefs.tar.gz" | awk '{print $1}')
[[ "$actual" == "$SHA256" ]] || { echo 'JuiceFS archive checksum mismatch' >&2; exit 1; }
if [[ ! -d "$SOURCE" ]]; then tar -xzf "$BUILD/juicefs.tar.gz" -C "$BUILD"; fi
python3 "$ROOT/scripts/patch-juicefs.py" "$SOURCE"
mkdir -p "$SOURCE/sdk/streamdrive"
cp "$ROOT/native/bridge/"*.go "$SOURCE/sdk/streamdrive/"
cp "$ROOT/native/meta_client.go" "$SOURCE/pkg/meta/streamdrive_client.go"
cp "$ROOT/native/vfs_backup.go" "$SOURCE/pkg/vfs/streamdrive_backup.go"
export GOMODCACHE="$BUILD/gomodcache" GOCACHE="$BUILD/gocache" GOPATH="$BUILD/gopath" GOTOOLCHAIN=auto CGO_ENABLED=1
# Keep Redis/SQLite/PostgreSQL metadata and S3-compatible/local object storage.
TAGS='noazure,nobos,nob2,nocifs,nocos,nodragonfly,noetcd,nogs,nohdfs,noibmcos,noks3,nonfs,noobs,nooss,noqingstor,noqiniu,nosftp,nostorj,noswift,notikv,notos,noufile,nowebdav'
cd "$SOURCE"
go build -p 4 -trimpath -buildvcs=false -tags "$TAGS" -buildmode=c-shared -o "$ROOT/native/lib/libstreamdrive.dylib" ./sdk/streamdrive
if (( run_tests )); then go test -p 4 -timeout 120s -count=1 -tags "$TAGS" ./sdk/streamdrive; fi
# The race run skips TestMetadataAndObjectBackupRestore: its intermittent DATA RACE is inside
# JuiceFS pkg/meta.(*dbMeta).dumpDir (pre-existing upstream), not in the bridge.
if (( run_race )); then
  go test -race -p 4 -timeout 300s -count=1 -tags "$TAGS" -skip '^TestMetadataAndObjectBackupRestore$' ./sdk/streamdrive
fi
printf 'Built %s from JuiceFS %s\n' "$ROOT/native/lib/libstreamdrive.dylib" "$REVISION"
