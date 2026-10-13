#!/usr/bin/env python3
"""Point the site's download buttons at one GitHub release.

Rewrites, in every page that offers the download (site/index.html and site/pricing.html by default),
every element marked data-release-download (href), data-release-notes (href), data-release-label (text)
and data-release-size (text). The pages stay static: no script is needed to see the version or download
it. Every page is checked before any is written, and running it twice with the same release changes
nothing the second time.

    python3 scripts/update-site-release.py --tag v0.1.0-alpha.2 --asset dist/ParaAir-0.1.0-alpha.2.dmg
"""

import argparse
import re
import sys
from pathlib import Path

REPO = "https://github.com/parafieldai/ParaAir"
SITE = Path(__file__).resolve().parent.parent / "site"
PAGES = ("index.html", "pricing.html")
TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta|rc)\.(\d+))?$")


def label(tag: str) -> str:
    """v0.1.0-alpha.2 -> 0.1.0 alpha 2, with non-breaking spaces so it never wraps inside."""
    m = TAG.match(tag)
    if not m:
        sys.exit(f"tag must look like v1.2.3 or v1.2.3-alpha.4, got {tag!r}")
    text = ".".join(m.group(1, 2, 3))
    if m.group(4):
        text += f" {m.group(4)} {m.group(5)}"
    return text.replace(" ", "&nbsp;")


def size(path: Path) -> str:
    megabytes = path.stat().st_size / 1_000_000
    return f"{megabytes:.0f}&nbsp;MB" if megabytes >= 10 else f"{megabytes:.1f}&nbsp;MB"


def set_attr(html: str, marker: str, attr: str, value: str) -> tuple[str, int]:
    pattern = re.compile(rf'(<[a-z]+\b[^>]*\b{marker}\b[^>]*\b{attr}=")[^"]*(")')
    return pattern.subn(lambda m: m.group(1) + value + m.group(2), html)


def set_text(html: str, marker: str, value: str) -> tuple[str, int]:
    pattern = re.compile(rf'(<([a-z]+)\b[^>]*\b{marker}\b[^>]*>)[^<]*(</\2>)')
    return pattern.subn(lambda m: m.group(1) + value + m.group(3), html)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", required=True)
    parser.add_argument("--asset", "--zip", dest="asset", required=True, type=Path,
                        help="the file the buttons download (the notarized .dmg)")
    parser.add_argument("--page", dest="pages", action="append", type=Path,
                        help="a page to update; repeat for several (default: %s in site/)" % " and ".join(PAGES))
    args = parser.parse_args()
    if not args.asset.is_file():
        sys.exit(f"no such file: {args.asset}")
    pages = args.pages or [SITE / name for name in PAGES]
    download = f"{REPO}/releases/download/{args.tag}/{args.asset.name}"
    notes = f"{REPO}/releases/tag/{args.tag}"
    release_label, release_size = label(args.tag), size(args.asset)
    updated = []
    for page in pages:
        html = page.read_text(encoding="utf-8")
        html, downloads = set_attr(html, "data-release-download", "href", download)
        html, note_links = set_attr(html, "data-release-notes", "href", notes)
        html, labels = set_text(html, "data-release-label", release_label)
        html, sizes = set_text(html, "data-release-size", release_size)
        if not (downloads and note_links and labels and sizes):
            sys.exit(f"{page} is missing a data-release-download, -notes, -label or -size element; nothing was written")
        updated.append((page, html, downloads))
    for page, html, _ in updated:
        page.write_text(html, encoding="utf-8")
    links = ", ".join(f"{page.name}: {count}" for page, _, count in updated)
    print(f"site now offers {args.tag} (download links in {links})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
