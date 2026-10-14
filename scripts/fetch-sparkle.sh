#!/bin/bash
# Fetches the pinned Sparkle release (updater framework and its signing tools) into
# .build/sparkle/<version>/ and verifies its checksum. Prints that folder.
#
#   dir="$(bash scripts/fetch-sparkle.sh)"   # $dir/Sparkle.framework, $dir/bin/sign_update
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=2.10.0
SHA256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
base="$root/.build/sparkle"
dir="$base/$VERSION"
archive="$base/Sparkle-$VERSION.tar.xz"
if [[ ! -d "$dir/Sparkle.framework" ]]; then
  mkdir -p "$base"
  if [[ ! -f "$archive" ]]; then
    # Resumes a partial download; slow links need the long limit.
    curl --fail --location --retry 3 --continue-at - --max-time 900 --silent --show-error \
      "https://github.com/sparkle-project/Sparkle/releases/download/$VERSION/Sparkle-$VERSION.tar.xz" -o "$archive.partial"
    mv "$archive.partial" "$archive"
  fi
  actual=$(shasum -a 256 "$archive" | awk '{print $1}')
  [[ "$actual" == "$SHA256" ]] || { rm -f "$archive"; echo "Sparkle $VERSION checksum mismatch" >&2; exit 1; }
  rm -rf "$dir.partial" && mkdir -p "$dir.partial"
  tar -xJf "$archive" -C "$dir.partial"
  [[ -d "$dir.partial/Sparkle.framework" && -x "$dir.partial/bin/sign_update" ]] || { echo "Unexpected Sparkle archive layout" >&2; exit 1; }
  mv "$dir.partial" "$dir"
fi
echo "$dir"
