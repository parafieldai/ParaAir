#!/bin/bash
# Build the ParaAir disk image: the app, an Applications link and the branded background, laid out
# by dmgbuild (no Finder scripting, so it works headless and in CI). Optionally Developer ID signs it;
# notarizing and stapling stay with the caller.
#
#   scripts/make-dmg.sh ParaAir.app "ParaAir 0.1.0 alpha 2" out/ParaAir-0.1.0-alpha.2.dmg [SIGNING_IDENTITY]
#
# DMGBUILD may point at a dmgbuild executable (default: dmgbuild on PATH; pip install dmgbuild==1.6.7).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:?usage: make-dmg.sh APP VOLUME_NAME OUT.dmg [SIGNING_IDENTITY]}"
volume="${2:?volume name}"
out="${3:?output .dmg}"
identity="${4:-}"
dmgbuild="${DMGBUILD:-dmgbuild}"
[[ -d "$app" && "$app" == *.app ]] || { echo "Not an app bundle: $app" >&2; exit 1; }
command -v "$dmgbuild" >/dev/null || { echo "dmgbuild is required (pip install dmgbuild==1.6.7)." >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
swift "$root/scripts/dmg-background.swift" "$work/background.png" 1
swift "$root/scripts/dmg-background.swift" "$work/background@2x.png" 2
# One TIFF holding both resolutions, so Retina screens get the sharp version.
tiffutil -cathidpicheck "$work/background.png" "$work/background@2x.png" -out "$work/background.tiff" >/dev/null
rm -f "$out"
"$dmgbuild" -s "$root/scripts/dmg-settings.py" -D app="$app" -D background="$work/background.tiff" "$volume" "$out"
if [[ -n "$identity" ]]; then
  codesign --force --sign "$identity" --timestamp "$out"
  codesign --verify --strict "$out"
fi
echo "Built $out"
