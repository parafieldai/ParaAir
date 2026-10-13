#!/usr/bin/env python3
"""Point the landing page's download buttons at one GitHub release.

Rewrites, in site/index.html, every element marked data-release-download (href), data-release-notes
(href), data-release-label (text) and data-release-size (text). The page stays static: no script is
needed to see the version or download it.

    python3 scripts/update-site-release.py --tag v0.1.0-alpha.2 --zip dist/ParaAir-0.1.0-alpha.2.zip
"""

import argparse
import re
import sys
from pathlib import Path

REPO = "https://github.com/parafieldai/ParaAir"
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
    parser.add_argument("--zip", required=True, type=Path)
    parser.add_argument("--page", type=Path, default=Path(__file__).resolve().parent.parent / "site" / "index.html")
    args = parser.parse_args()
    if not args.zip.is_file():
        sys.exit(f"no such file: {args.zip}")
    html = args.page.read_text(encoding="utf-8")
    download = f"{REPO}/releases/download/{args.tag}/{args.zip.name}"
    notes = f"{REPO}/releases/tag/{args.tag}"
    html, downloads = set_attr(html, "data-release-download", "href", download)
    html, note_links = set_attr(html, "data-release-notes", "href", notes)
    html, labels = set_text(html, "data-release-label", label(args.tag))
    html, sizes = set_text(html, "data-release-size", size(args.zip))
    if not (downloads and note_links and labels and sizes):
        sys.exit("site/index.html is missing a data-release-download, -notes, -label or -size element")
    args.page.write_text(html, encoding="utf-8")
    print(f"site now offers {args.tag} ({downloads} download links)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
