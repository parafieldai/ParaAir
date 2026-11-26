#!/bin/bash
# Builds the site's two generated images. Run from anywhere on a Mac with Xcode's command line tools and Google Chrome:
#
#   site/favicon.ico   the app icon at 16, 32 and 48 px (PNG entries), drawn by the same BrandIconGeometry renderer as
#                      scripts/build-icons.sh, so browsers that ask for /favicon.ico get the icon glide.svg shows
#   site/og-card.png   the 1200x630 link preview (og:image, twitter:image), a headless-Chrome screenshot of
#                      scripts/og-card.html
#
# Commit both outputs; CI only checks them (scripts/check-site.py).
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
mkdir -p "$root/.build"
renderer="$root/.build/brand-icon-renderer"
xcrun swiftc -parse-as-library -O \
  -module-cache-path "$root/.build/xcode/ModuleCache.noindex" \
  "$root/macOS/App/BrandIconGeometry.swift" "$root/scripts/render-brand.swift" -o "$renderer"
temporary="$(mktemp -d "$root/.build/site-images.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

for size in 16 32 48; do
  "$renderer" "$size" "$temporary/icon-$size.png"
done
# An ICO file is a 6-byte header, one 16-byte entry per image, then the images; each image here is a whole PNG.
python3 -I - "$root/site/favicon.ico" "$temporary"/icon-16.png "$temporary"/icon-32.png "$temporary"/icon-48.png <<'PY'
import struct, sys
out, paths = sys.argv[1], sys.argv[2:]
images = [open(p, "rb").read() for p in paths]
offset = 6 + 16 * len(images)
blob = struct.pack("<HHH", 0, 1, len(images))
for data in images:
    width, height = struct.unpack(">II", data[16:24])
    blob += struct.pack("<BBBBHHII", width % 256, height % 256, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
open(out, "wb").write(blob + b"".join(images))
PY

"$chrome" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
  --blink-settings=preferredColorScheme=1 --window-size=1200,630 \
  --user-data-dir="$temporary/chrome" --screenshot="$temporary/og-card.png" "file://$root/scripts/og-card.html" >/dev/null 2>&1
python3 -I - "$temporary/og-card.png" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
size = struct.unpack(">II", data[16:24])
if data[:8] != b"\x89PNG\r\n\x1a\n" or size != (1200, 630):
    sys.exit("og-card.png came out %r, expected a 1200x630 PNG" % (size,))
PY
mv "$temporary/og-card.png" "$root/site/og-card.png"
echo "site/favicon.ico ($(wc -c < "$root/site/favicon.ico" | tr -d ' ') bytes), site/og-card.png ($(wc -c < "$root/site/og-card.png" | tr -d ' ') bytes)"
