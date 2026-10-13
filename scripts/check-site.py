#!/usr/bin/env python3
"""Static checks for the pages in site/ (CI job "site"). Standard library only.

- The deployed files exist: index.html, pricing.html, styles.css, motion.js, _headers.
- Every *.html page in site/ is checked, not only the required ones.
- No em dash in visible copy: page text and user-visible attributes, and anywhere in
  motion.js or styles.css (either can put text on the page).
- The word "unlimited" never appears in visible copy (the transfer allowance has a limit).
- Every local href/src resolves to a file in site/ (a directory resolves to its index.html),
  and every #fragment to an id on the page it points at.
- Nothing the _headers Content-Security-Policy would block: inline <script>,
  <style> elements, style= attributes or on*= event handlers.

Usage: python3 scripts/check-site.py [SITE_DIR]
"""
from html.parser import HTMLParser
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

REQUIRED = ["index.html", "pricing.html", "styles.css", "motion.js", "_headers"]
EM_DASH = "—"  # em dash
BANNED_WORDS = re.compile(r"\bunlimited\b", re.IGNORECASE)
VISIBLE_ATTRIBUTES = {"alt", "title", "aria-label", "aria-description", "placeholder", "value", "content", "label"}


class Page(HTMLParser):
    def __init__(self, name):
        super().__init__(convert_charrefs=True)
        self.name = name
        self.problems, self.ids, self.references = [], set(), []
        self.skip = 0

    def where(self):
        return "%s:%d" % (self.name, self.getpos()[0])

    def check_copy(self, text, what):
        if EM_DASH in text:
            self.problems.append(self.where() + ": em dash in " + what)
        if BANNED_WORDS.search(text):
            self.problems.append(self.where() + ': "unlimited" in ' + what)

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag in ("script", "style"):
            self.skip += 1
        if tag == "script" and not values.get("src"):
            self.problems.append(self.where() + ": inline <script> (blocked by the CSP in _headers)")
        if tag == "style":
            self.problems.append(self.where() + ": <style> element (blocked by the CSP in _headers)")
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
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_endtag(self, tag):
        if tag in ("script", "style") and self.skip:
            self.skip -= 1

    def handle_data(self, data):
        if not self.skip:
            self.check_copy(data, "visible text")


def resolve(site, path):
    """The file a local path serves, the way a static host does: a directory serves its index.html."""
    target = (site / unquote(path).lstrip("/")).resolve()
    if target.is_dir():
        target = target / "index.html"
    return target


def main(argv):
    site = Path(argv[1] if len(argv) > 1 else Path(__file__).resolve().parent.parent / "site")
    problems = ["missing %s" % name for name in REQUIRED if not (site / name).is_file()]
    if problems:
        print("\n".join("site check: " + p for p in problems), file=sys.stderr)
        return 1
    pages = {}
    for path in sorted(site.glob("*.html")):
        page = Page(path.name)
        page.feed(path.read_text(encoding="utf-8"))
        page.close()
        pages[path.resolve()] = page
        problems += page.problems
    for name in ("motion.js", "styles.css"):
        for number, line in enumerate((site / name).read_text(encoding="utf-8").splitlines(), 1):
            if EM_DASH in line:
                problems.append("%s:%d: em dash" % (name, number))
    local = 0
    for source, page in pages.items():
        for where, reference in page.references:
            parts = urlsplit(reference)
            if parts.scheme or parts.netloc:
                continue  # https:, mailto:, data: and other absolute references
            local += 1
            if parts.path:
                target = resolve(site, parts.path)
                if site.resolve() not in target.parents or not target.is_file():
                    problems.append("%s: %s does not resolve to a file in %s" % (where, reference, site))
                    continue
            else:
                target = source
            if parts.fragment:
                ids = pages[target].ids if target in pages else None
                if ids is None:
                    problems.append("%s: #%s points into %s, which is not an HTML page" % (where, parts.fragment, target.name))
                elif parts.fragment not in ids:
                    problems.append("%s: #%s has no matching id in %s" % (where, parts.fragment, target.name))
    if "Content-Security-Policy:" not in (site / "_headers").read_text(encoding="utf-8"):
        problems.append("_headers: no Content-Security-Policy")
    if problems:
        print("\n".join("site check: " + p for p in problems), file=sys.stderr)
        return 1
    print("site check PASS: %d pages (%s), %d required files, %d local references, no em dash or \"unlimited\", "
          "CSP-compatible markup" % (len(pages), ", ".join(p.name for p in pages.values()), len(REQUIRED), local))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
