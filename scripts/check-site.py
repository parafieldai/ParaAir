#!/usr/bin/env python3
"""Static checks for the pages in site/ (CI job "site"). Standard library only.

- The deployed files exist: index.html, pricing.html, get-started.html, styles.css, motion.js, signup.js, _headers,
  and the site-health files: favicon.ico, og-card.png, robots.txt, sitemap.xml, .well-known/security.txt.
- Every *.html page in site/ and its subfolders is checked, not only the required ones (site/help/export.html
  is served at /help/export).
- No em dash in visible copy: page text and user-visible attributes, and anywhere in
  motion.js or styles.css (either can put text on the page).
- The word "unlimited" never appears in visible copy (the transfer allowance has a limit). The legal pages
  (<body class="legal-page">) are exempt: they use the word to rule it out ("No plan offers \"unlimited\" ...").
- Every local href/src resolves to a file in site/ (a directory resolves to its index.html, and an
  extensionless path to its .html file, as the Worker's html_handling serves it),
  and every #fragment to an id on the page it points at. A path starting with / is taken from site/, any
  other path from the folder of the page it is on. Addresses on https://paraair.parafield.ai count as local
  (the canonical link, og:url, og:image, twitter:image).
- Links to pages are extensionless (/pricing, not pricing.html): the Worker answers /pricing.html with a 307 to /pricing.
- Every page without <meta name="robots" content="noindex"> has a canonical link to its own extensionless address on
  https://paraair.parafield.ai, the same address as og:url, and a link preview: og:title, og:description and
  og:image (a file in site/; a PNG's size must match og:image:width and og:image:height), twitter:card
  summary_large_image, twitter:title, twitter:description and twitter:image.
- sitemap.xml lists exactly those canonical addresses, and robots.txt names sitemap.xml.
- .well-known/security.txt (RFC 9116) has a Contact, one Expires that has not passed and is less than a year away,
  and its own address as Canonical. favicon.ico is an ICO file.
- Nothing the _headers Content-Security-Policy would block: inline <script>,
  <style> elements, style= attributes or on*= event handlers.
- Copy that says ParaAir Cloud charges nobody ("nobody is charged", "billing isn't switched on", "planned prices", ...)
  sits inside an element marked data-billing="off" and written hidden: signup.js shows it only while the service says
  its billing is off, so the page can't say nobody is charged once plans are sold. Never in a meta tag, which no
  script can change.

Usage: python3 scripts/check-site.py [SITE_DIR]
"""
from datetime import datetime, timedelta, timezone
from html.parser import HTMLParser
from pathlib import Path
import re
import struct
import sys
from urllib.parse import unquote, urlsplit
import xml.etree.ElementTree as ET

ORIGIN = "https://paraair.parafield.ai"
HOST = urlsplit(ORIGIN).netloc
REQUIRED = ["index.html", "pricing.html", "get-started.html", "styles.css", "motion.js", "signup.js", "_headers",
            "favicon.ico", "og-card.png", "robots.txt", "sitemap.xml", ".well-known/security.txt"]
EM_DASH = "—"  # em dash
BANNED_WORDS = re.compile(r"\bunlimited\b", re.IGNORECASE)
VISIBLE_ATTRIBUTES = {"alt", "title", "aria-label", "aria-description", "placeholder", "value", "content", "label"}
# Link-preview tags every indexed page carries (og:url and og:image are checked further below).
PREVIEW = ["og:title", "og:description", "og:url", "og:image", "twitter:card", "twitter:title", "twitter:description",
           "twitter:image"]
# Copy that says nobody is charged; true only while ParaAir Cloud's billing is off (see signup.js).
BILLING_OFF = re.compile(r"nobody is charged|isn[\u2019']t switched on|billing opens|planned prices|prices are\s+planned", re.IGNORECASE)
# Elements without an end tag, which open nothing.
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}
# Meta tags whose content is an address on the site, checked like an href.
ADDRESS_META = {"og:url", "og:image", "twitter:image"}


class Page(HTMLParser):
    def __init__(self, name):
        super().__init__(convert_charrefs=True)
        self.name = name
        self.problems, self.ids, self.references = [], set(), []
        self.skip = 0
        self.legal = False
        self.meta, self.canonical, self.noindex = {}, None, False
        # Open elements, each with whether it is written hidden and marked data-billing="off".
        self.stack = []

    def where(self):
        return "%s:%d" % (self.name, self.getpos()[0])

    def check_copy(self, text, what):
        if BILLING_OFF.search(text) and (what != "visible text" or not any(off for _, off in self.stack)):
            self.problems.append(self.where() + ': says nobody is charged in %s outside an element marked data-billing="off" hidden' % what)
        if EM_DASH in text:
            self.problems.append(self.where() + ": em dash in " + what)
        if BANNED_WORDS.search(text) and not self.legal:
            self.problems.append(self.where() + ': "unlimited" in ' + what)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag not in VOID:
            self.stack.append((tag, values.get("data-billing") == "off" and "hidden" in values))
        if tag == "body" and "legal-page" in (values.get("class") or "").split():
            self.legal = True
        if tag in ("script", "style"):
            self.skip += 1
        if tag == "script" and not values.get("src"):
            self.problems.append(self.where() + ": inline <script> (blocked by the CSP in _headers)")
        if tag == "style":
            self.problems.append(self.where() + ": <style> element (blocked by the CSP in _headers)")
        if tag == "meta":
            key, content = values.get("property") or values.get("name"), values.get("content") or ""
            if key == "robots" and "noindex" in content.lower():
                self.noindex = True
            elif key:
                self.meta.setdefault(key, content)
                if key in ADDRESS_META:
                    self.references.append((self.where(), content))
        if tag == "link" and "canonical" in (values.get("rel") or "").split():
            self.canonical = (self.where(), values.get("href") or "")
        for name, value in attrs:
            value = value or ""
            if name == "style":
                self.problems.append(self.where() + ": style= attribute (blocked by the CSP in _headers)")
            if name.startswith("on"):
                self.problems.append(self.where() + ": %s= handler (blocked by the CSP in _headers)" % name)
            if name == "id":
                self.ids.add(value)
            if name in VISIBLE_ATTRIBUTES:
                self.check_copy(value, "%s=" % name)
            if name in ("href", "src"):
                self.references.append((self.where(), value))

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)
        if tag not in VOID:
            self.stack.pop()
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self.skip:
            self.skip -= 1
        # Close up to the matching element (HTML lets some end tags be left out).
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break

    def handle_data(self, data):
        if not self.skip:
            self.check_copy(data, "visible text")


def resolve(site, base, path):
    """The file a local path serves, the way a static host does: a directory serves its index.html.
    A path starting with / is taken from the site root, any other from `base`, the folder of the page it is on."""
    target = ((site if path.startswith("/") else base) / unquote(path).lstrip("/")).resolve()
    if target.is_dir():
        target = target / "index.html"
    elif not target.exists() and not target.suffix and target.with_suffix(".html").is_file():
        target = target.with_suffix(".html")
    return target


def site_path(reference):
    """The path part of a reference served from site/: a relative or root-relative one, or an absolute address on
    https://paraair.parafield.ai ("/" when it has none). None for anything else (other hosts, mailto:, data:)."""
    parts = urlsplit(reference)
    if not parts.scheme and not parts.netloc:
        return parts
    if parts.scheme == "https" and parts.netloc == HOST:
        return parts._replace(path=parts.path or "/")
    return None


def png_size(path):
    data = path.read_bytes()[:24]
    return struct.unpack(">II", data[16:24]) if data[:8] == b"\x89PNG\r\n\x1a\n" else None


def check_preview(site, source, page):
    """The canonical address and the link preview of a page that search engines may index."""
    problems = []
    if not page.canonical:
        return ["%s: no <link rel=\"canonical\"> (or add <meta name=\"robots\" content=\"noindex\">)" % page.name]
    where, href = page.canonical
    parts = urlsplit(href)
    if parts.scheme != "https" or parts.netloc != HOST or parts.query or parts.fragment or parts.path.endswith(".html"):
        problems.append("%s: canonical %s is not an extensionless address on %s" % (where, href, ORIGIN))
    elif resolve(site, source.parent, parts.path or "/") != source:
        problems.append("%s: canonical %s is not this page's own address" % (where, href))
    for key in PREVIEW:
        if not page.meta.get(key, "").strip():
            problems.append("%s: no %s" % (page.name, key))
    if page.meta.get("og:url") and page.meta["og:url"] != href:
        problems.append("%s: og:url %s differs from the canonical %s" % (page.name, page.meta["og:url"], href))
    card = page.meta.get("twitter:card")
    if card and card != "summary_large_image":
        problems.append("%s: twitter:card is %r, expected summary_large_image" % (page.name, card))
    image = site_path(page.meta.get("og:image", ""))
    if image is not None and image.path:
        target = resolve(site, source.parent, image.path)
        size = png_size(target) if target.is_file() else None
        declared = (page.meta.get("og:image:width"), page.meta.get("og:image:height"))
        if size and all(declared) and declared != tuple(str(n) for n in size):
            problems.append("%s: og:image:width/height say %sx%s, %s is %dx%d"
                            % (page.name, declared[0], declared[1], target.name, size[0], size[1]))
    return problems


def check_sitemap(site, canonical):
    """sitemap.xml lists every indexed page's canonical address, and nothing else; robots.txt names it."""
    problems = []
    try:
        root = ET.parse(site / "sitemap.xml").getroot()
    except ET.ParseError as error:
        return ["sitemap.xml: not well-formed XML (%s)" % error]
    ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
    locs = [(loc.text or "").strip() for loc in root.findall("s:url/s:loc", ns)]
    if root.tag != "{%s}urlset" % ns["s"] or not locs:
        problems.append("sitemap.xml: expected a <urlset> of the sitemaps.org 0.9 namespace with <url><loc> entries")
    for loc in sorted({loc for loc in locs if locs.count(loc) > 1}):
        problems.append("sitemap.xml: %s is listed more than once" % loc)
    for loc in sorted(set(locs) - set(canonical)):
        problems.append("sitemap.xml: %s is not the canonical address of an indexed page in site/" % loc)
    for loc in sorted(set(canonical) - set(locs)):
        problems.append("sitemap.xml: missing %s (%s)" % (loc, canonical[loc]))
    robots = (site / "robots.txt").read_text(encoding="utf-8")
    if not re.search(r"^Sitemap:\s*%s/sitemap\.xml\s*$" % re.escape(ORIGIN), robots, re.IGNORECASE | re.MULTILINE):
        problems.append("robots.txt: no \"Sitemap: %s/sitemap.xml\" line" % ORIGIN)
    return problems


def check_security_txt(site, now):
    """RFC 9116: at least one Contact, exactly one Expires (RFC 3339) that has not passed and is less than a year away,
    and, if there is a Canonical, this file's own address."""
    name = ".well-known/security.txt"
    fields = {}
    for line in (site / name).read_text(encoding="utf-8").splitlines():
        match = re.match(r"^([A-Za-z-]+):\s*(\S.*?)\s*$", line)
        if match and not line.startswith("#"):
            fields.setdefault(match.group(1).lower(), []).append(match.group(2))
    problems = []
    if not fields.get("contact"):
        problems.append("%s: no Contact" % name)
    expires = fields.get("expires", [])
    if len(expires) != 1:
        problems.append("%s: needs exactly one Expires, found %d" % (name, len(expires)))
    else:
        try:
            when = datetime.fromisoformat(expires[0].replace("Z", "+00:00"))
            if when.tzinfo is None:
                raise ValueError("no time zone")
        except ValueError:
            problems.append("%s: Expires %r is not an RFC 3339 date and time" % (name, expires[0]))
        else:
            if when <= now:
                problems.append("%s: Expires %s has passed; set a new date less than a year away" % (name, expires[0]))
            elif when - now >= timedelta(days=365):
                problems.append("%s: Expires %s is a year or more away (RFC 9116 asks for less)" % (name, expires[0]))
    for canonical in fields.get("canonical", []):
        if canonical != "%s/%s" % (ORIGIN, name):
            problems.append("%s: Canonical %s is not %s/%s" % (name, canonical, ORIGIN, name))
    return problems


def main(argv):
    site = Path(argv[1] if len(argv) > 1 else Path(__file__).resolve().parent.parent / "site").resolve()
    problems = ["missing %s" % name for name in REQUIRED if not (site / name).is_file()]
    if problems:
        print("\n".join("site check: " + p for p in problems), file=sys.stderr)
        return 1
    pages = {}
    for path in sorted(site.rglob("*.html")):
        page = Page(path.relative_to(site).as_posix())
        page.feed(path.read_text(encoding="utf-8"))
        page.close()
        pages[path.resolve()] = page
        problems += page.problems
    for name in ("motion.js", "signup.js", "styles.css"):
        for number, line in enumerate((site / name).read_text(encoding="utf-8").splitlines(), 1):
            if EM_DASH in line:
                problems.append("%s:%d: em dash" % (name, number))
    local = 0
    for source, page in pages.items():
        for where, reference in page.references:
            parts = site_path(reference)
            if parts is None:
                continue  # other hosts, mailto:, data: and other absolute references
            local += 1
            if parts.path:
                target = resolve(site, source.parent, parts.path)
                if site not in target.parents or not target.is_file():
                    problems.append("%s: %s does not resolve to a file in %s" % (where, reference, site))
                    continue
                if parts.path.endswith(".html"):
                    page_path = "/" + target.relative_to(site).with_suffix("").as_posix()
                    page_path = page_path[:-len("index")] if page_path.endswith("/index") else page_path
                    problems.append("%s: %s answers with a 307; link %s" % (where, reference, page_path))
            else:
                target = source
            if parts.fragment:
                ids = pages[target].ids if target in pages else None
                if ids is None:
                    problems.append("%s: #%s points into %s, which is not an HTML page" % (where, parts.fragment, target.name))
                elif parts.fragment not in ids:
                    problems.append("%s: #%s has no matching id in %s" % (where, parts.fragment, target.name))
    canonical = {}
    for source, page in pages.items():
        if page.noindex:
            continue
        found = check_preview(site, source, page)
        problems += found
        if page.canonical:
            canonical[page.canonical[1]] = page.name
    problems += check_sitemap(site, canonical)
    problems += check_security_txt(site, datetime.now(timezone.utc))
    if (site / "favicon.ico").read_bytes()[:4] != b"\x00\x00\x01\x00":
        problems.append("favicon.ico: not an ICO file")
    if "Content-Security-Policy:" not in (site / "_headers").read_text(encoding="utf-8"):
        problems.append("_headers: no Content-Security-Policy")
    if problems:
        print("\n".join("site check: " + p for p in problems), file=sys.stderr)
        return 1
    print("site check PASS: %d pages (%s), %d required files, %d local references, no em dash or \"unlimited\", "
          "extensionless page links, %d canonical pages with link previews and in sitemap.xml, security.txt current, "
          "CSP-compatible markup" % (len(pages), ", ".join(p.name for p in pages.values()), len(REQUIRED), local,
                                     len(canonical)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
