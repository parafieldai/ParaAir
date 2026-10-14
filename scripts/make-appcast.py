#!/usr/bin/env python3
"""Add a release to the Sparkle update feed (site/appcast.xml) and sign the feed.

  python3 -I scripts/make-appcast.py --app dist/ParaAir.app --archive dist/ParaAir-0.1.0-alpha.2.zip \
      --tag v0.1.0-alpha.2 --notes notes.html [--feed site/appcast.xml] [--url URL]

The version, build and minimum macOS come from the app's Info.plist, and its ParaAirReleaseTag
must equal --tag. The archive is the zip of that same signed, notarized and stapled app.
sign_update signs the archive and then the whole feed with the EdDSA key in this Mac's
Keychain (account "paraair"); the app requires both (SURequireSignedFeed). Re-running for the
same build replaces its entry, so the script is idempotent. --check only validates a feed.
"""
import argparse
import email.utils
import html
import pathlib
import plistlib
import re
import subprocess
import sys
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ACCOUNT = "paraair"
TAG = re.compile(r"^v(\d+\.\d+\.\d+)(?:-(alpha|beta|rc)\.(\d+))?$")
# sign_update embeds the feed signature as a trailing comment; it is replaced on every run.
SIGNATURE_BLOCK = re.compile(r"\s*<!--\s*sparkle-signatures:.*?-->\s*", re.S)


def sign_update():
    from subprocess import run
    folder = run(["bash", str(ROOT / "scripts/fetch-sparkle.sh")], capture_output=True, text=True, check=True).stdout.strip()
    return pathlib.Path(folder) / "bin/sign_update"


def title(version, tag):
    stage = TAG.match(tag)
    if stage and stage.group(2):
        name = "release candidate" if stage.group(2) == "rc" else stage.group(2)
        return f"ParaAir {version} {name} {stage.group(3)}"
    return f"ParaAir {version}"


def item_xml(info, tag, url, length, signature, notes, date):
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    minimum = info.get("LSMinimumSystemVersion", "26.0")
    return (
        "    <item>\n"
        f"      <title>{html.escape(title(version, tag))}</title>\n"
        f"      <pubDate>{date}</pubDate>\n"
        f"      <sparkle:version>{html.escape(build)}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>\n"
        f"      <sparkle:minimumSystemVersion>{html.escape(minimum)}</sparkle:minimumSystemVersion>\n"
        f"      <sparkle:fullReleaseNotesLink>https://github.com/parafieldai/ParaAir/releases/tag/{html.escape(tag)}</sparkle:fullReleaseNotesLink>\n"
        f"      <description><![CDATA[{notes}]]></description>\n"
        f"      <enclosure url=\"{html.escape(url)}\" length=\"{length}\" type=\"application/octet-stream\" "
        f"sparkle:edSignature=\"{html.escape(signature)}\"/>\n"
        "    </item>\n"
    )


def empty_feed():
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<rss version="2.0" xmlns:sparkle="{SPARKLE}">\n'
            "  <channel>\n"
            "    <title>ParaAir</title>\n"
            "    <link>https://paraair.pages.dev/appcast.xml</link>\n"
            "    <description>ParaAir updates</description>\n"
            "    <language>en</language>\n"
            "  </channel>\n"
            "</rss>\n")


def check(text):
    """Parse the feed and return its builds, newest first; raise on anything malformed."""
    body = SIGNATURE_BLOCK.sub("\n", text)
    channel = ET.fromstring(body.encode()).find("channel")
    if channel is None:
        raise ValueError("feed has no channel")
    builds = []
    for item in channel.findall("item"):
        build = item.findtext(f"{{{SPARKLE}}}version")
        enclosure = item.find("enclosure")
        if not build or not build.isdigit():
            raise ValueError("item without a numeric sparkle:version")
        if enclosure is None or not enclosure.get(f"{{{SPARKLE}}}edSignature") or not (enclosure.get("length") or "").isdigit():
            raise ValueError(f"build {build}: enclosure needs a length and an EdDSA signature")
        if not enclosure.get("url", "").startswith("https://"):
            raise ValueError(f"build {build}: enclosure must be served over HTTPS")
        builds.append(int(build))
    if builds != sorted(builds, reverse=True) or len(builds) != len(set(builds)):
        raise ValueError("items must be unique and newest first")
    return builds


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--feed", default=str(ROOT / "site/appcast.xml"))
    parser.add_argument("--check", action="store_true", help="only validate the feed")
    parser.add_argument("--app")
    parser.add_argument("--archive")
    parser.add_argument("--tag")
    parser.add_argument("--notes", help="HTML file with the release notes shown in the update window")
    parser.add_argument("--url", help="archive URL (default: the GitHub release asset for --tag)")
    parser.add_argument("--allow-http-url", action="store_true", help="local update tests only; never for the published feed")
    arguments = parser.parse_args()
    feed = pathlib.Path(arguments.feed)

    if arguments.check:
        builds = check(feed.read_text())
        print(f"appcast OK: {len(builds)} item(s), newest build {builds[0] if builds else 'none'}")
        return
    for name in ("app", "archive", "tag", "notes"):
        if not getattr(arguments, name):
            parser.error(f"--{name} is required")
    if not TAG.match(arguments.tag):
        parser.error("--tag must look like v0.1.0 or v0.1.0-alpha.2")
    info = plistlib.loads((pathlib.Path(arguments.app) / "Contents/Info.plist").read_bytes())
    if info.get("ParaAirReleaseTag") != arguments.tag or TAG.match(arguments.tag).group(1) != info.get("CFBundleShortVersionString"):
        sys.exit(f"{arguments.app} is not the {arguments.tag} build (ParaAirReleaseTag {info.get('ParaAirReleaseTag')!r})")
    archive = pathlib.Path(arguments.archive)
    url = arguments.url or f"https://github.com/parafieldai/ParaAir/releases/download/{arguments.tag}/{archive.name}"
    if not url.startswith("https://") and not arguments.allow_http_url:
        parser.error("--url must be HTTPS")

    tool = sign_update()
    signature = subprocess.run([str(tool), "--account", ACCOUNT, "-p", str(archive)],
                               capture_output=True, text=True, check=True).stdout.strip()
    if not re.fullmatch(r"[A-Za-z0-9+/]{86}==", signature):
        sys.exit("sign_update did not return an EdDSA signature")
    notes = pathlib.Path(arguments.notes).read_text().replace("]]>", "]]&gt;")
    item = item_xml(info, arguments.tag, url, archive.stat().st_size, signature, notes,
                    email.utils.formatdate(usegmt=True))

    text = SIGNATURE_BLOCK.sub("\n", feed.read_text()) if feed.exists() else empty_feed()
    build = info["CFBundleVersion"]
    # Drop an earlier entry for this build, then put the new one first.
    text = re.sub(r"    <item>\n(?:(?!    </item>).)*?<sparkle:version>" + re.escape(build) + r"</sparkle:version>.*?    </item>\n",
                  "", text, flags=re.S)
    marker = "    <language>en</language>\n"
    if marker not in text:
        sys.exit("unexpected feed layout")
    text = text.replace(marker, marker + item, 1).rstrip() + "\n"
    if not arguments.allow_http_url:
        check(text)
    feed.write_text(text)
    subprocess.run([str(tool), "--account", ACCOUNT, str(feed)], capture_output=True, text=True, check=True)
    verified = subprocess.run([str(tool), "--account", ACCOUNT, "--verify", str(feed)], capture_output=True, text=True)
    if verified.returncode:
        sys.exit("the signed feed failed verification: " + (verified.stderr or verified.stdout).strip())
    print(f"appcast: {title(info['CFBundleShortVersionString'], arguments.tag)} (build {build}) added to {feed} and signed")


if __name__ == "__main__":
    main()
