#!/bin/bash
# Pinned source, project-private module/toolchain caches, bounded parallelism.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REVISION=adcca1cc61bb4d668a945d64b2e176b44ac8e5b5
SHA256=2d1df6b63c23badd6a31845e2b604fe702f7cc49e1352f2f7204d2ecc48e52d9
BUILD="$ROOT/.build-native"
SOURCE="$BUILD/juicefs-$REVISION"
free_kib=$(df -k /System/Volumes/Data | awk 'NR==2 {print $4}')
if (( free_kib < 100 * 1024 * 1024 )); then echo 'Refusing native build: less than 100 GiB free.' >&2; exit 1; fi
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
export GOMODCACHE="$BUILD/gomodcache" GOCACHE="$BUILD/gocache" GOPATH="$BUILD/gopath" GOTOOLCHAIN=auto CGO_ENABLED=1
# Keep Redis/SQLite/PostgreSQL metadata and S3-compatible/local object storage.
TAGS='noazure,nobos,nob2,nocifs,nocos,nodragonfly,noetcd,nogs,nohdfs,noibmcos,noks3,nonfs,noobs,nooss,noqingstor,noqiniu,nosftp,nostorj,noswift,notikv,notos,noufile,nowebdav'
cd "$SOURCE"
go build -p 4 -trimpath -buildvcs=false -tags "$TAGS" -buildmode=c-shared -o "$ROOT/native/lib/libstreamdrive.dylib" ./sdk/streamdrive
if [[ "${1:-}" == '--test' ]]; then go test -p 4 -timeout 120s -count=1 -tags "$TAGS" ./sdk/streamdrive; fi
printf 'Built %s from JuiceFS %s\n' "$ROOT/native/lib/libstreamdrive.dylib" "$REVISION"
