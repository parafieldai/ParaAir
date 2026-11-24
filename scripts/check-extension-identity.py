#!/usr/bin/env python3
"""Fails when the File System Extension's identity differs from the newest release tag.

macOS keeps ParaAir's file system extension switched on across updates only while the extension looks the same to it:
its Info.plist (bundle identifier, extension point, FSKit personalities and options), its entitlements and its bundle
identifier in the project. Code changes are fine. A changed identity can make macOS switch the extension off on every
Mac that updates, and each person has to turn it on again in System Settings.

  python3 -I scripts/check-extension-identity.py [--against TAG]

Compares the working tree with TAG (default: the newest v* tag). Set ALLOW_EXTENSION_IDENTITY_CHANGE=1 for a change
made on purpose (CI sets it when the pull request body contains "[extension identity change]").
"""
import argparse
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = ["macOS/Extension/Info.plist", "macOS/Extension/StreamDriveFS.entitlements"]


def git(*args):
    return subprocess.run(["git", "-C", str(ROOT), *args], check=True, capture_output=True).stdout


def newest_tag():
    tags = git("tag", "--list", "v*", "--sort=-v:refname").decode().split()
    return tags[0] if tags else None


def extension_bundle_id(project_text):
    """PRODUCT_BUNDLE_IDENTIFIER inside the StreamDriveFS target of macOS/project.yml."""
    match = re.search(r"^  StreamDriveFS:\n(?:    .*\n|\n)*?\s+PRODUCT_BUNDLE_IDENTIFIER:\s*(\S+)", project_text, re.M)
    return match.group(1) if match else None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--against")
    args = parser.parse_args()
    tag = args.against or newest_tag()
    if tag is None:
        print("extension identity: no release tag yet, nothing to compare")
        return 0
    changed = []
    for name in FILES:
        try:
            released = plistlib.loads(git("show", f"{tag}:{name}"))
        except subprocess.CalledProcessError:
            changed.append(f"{name} (absent in {tag})")
            continue
        current = plistlib.loads((ROOT / name).read_bytes())
        if current != released:
            changed.append(name)
    released_id = extension_bundle_id(git("show", f"{tag}:macOS/project.yml").decode())
    current_id = extension_bundle_id((ROOT / "macOS/project.yml").read_text())
    if released_id != current_id:
        changed.append(f"extension bundle identifier {released_id} -> {current_id}")
    if not changed:
        print(f"extension identity: unchanged since {tag}")
        return 0
    message = (f"extension identity changed since {tag}: " + ", ".join(changed) + ". macOS may switch ParaAir's file "
               "system extension off on every Mac that updates. If this is intended, say \"[extension identity change]\" "
               "in the pull request and plan the release note and setup step for it.")
    if os.environ.get("ALLOW_EXTENSION_IDENTITY_CHANGE") == "1":
        print("warning: " + message)
        return 0
    print("error: " + message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
