#!/usr/bin/env python3
"""Static checks for the landing page in site/ (CI job "site"). Standard library only.

- The deployed files exist: index.html, styles.css, motion.js, _headers.
- No em dash in visible copy: index.html text and user-visible attributes, and
  anywhere in motion.js or styles.css (either can put text on the page).
- Every local href/src resolves to a file in site/, and every #fragment to an id.
- Nothing the _headers Content-Security-Policy would block: inline <script>,
  <style> elements, style= attributes or on*= event handlers.

Usage: python3 scripts/check-site.py [SITE_DIR]
"""
from html.parser import HTMLParser
from pathlib import Path
import sys
from urllib.parse import unquote, urlsplit

REQUIRED = ["index.html", "styles.css", "motion.js", "_headers"]
EM_DASH = "\u2014"  # em dash
VISIBLE_ATTRIBUTES = {"alt", "title", "aria-label", "aria-description", "placeholder", "value", "content", "label"}


class Page(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.problems, self.ids, self.references, self.fragments = [], set(), [], []
        self.skip = 0

    def where(self):
        return "index.html:%d" % self.getpos()[0]

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
            if name in VISIBLE_ATTRIBUTES and EM_DASH in value:
                self.problems.append(self.where() + ": em dash in %s=" % name)
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
        if not self.skip and EM_DASH in data:
            self.problems.append(self.where() + ": em dash in visible text")


def main(argv):
    site = Path(argv[1] if len(argv) > 1 else Path(__file__).resolve().parent.parent / "site")
    problems = ["missing %s" % name for name in REQUIRED if not (site / name).is_file()]
    if problems:
        print("\n".join("site check: " + p for p in problems), file=sys.stderr)
        return 1
    page = Page()
    page.feed((site / "index.html").read_text(encoding="utf-8"))
    page.close()
    problems += page.problems
    for name in ("motion.js", "styles.css"):
        for number, line in enumerate((site / name).read_text(encoding="utf-8").splitlines(), 1):
            if EM_DASH in line:
                problems.append("%s:%d: em dash" % (name, number))
    for where, reference in page.references:
        parts = urlsplit(reference)
        if parts.scheme or parts.netloc:
            continue  # https:, mailto:, data: and other absolute references
        if not parts.path:
            if parts.fragment and parts.fragment not in page.ids:
                problems.append("%s: #%s has no matching id" % (where, parts.fragment))
            continue
        target = (site / unquote(parts.path).lstrip("/")).resolve()
        if site.resolve() not in target.parents or not target.is_file():
            problems.append("%s: %s does not resolve to a file in %s" % (where, reference, site))
    if "Content-Security-Policy:" not in (site / "_headers").read_text(encoding="utf-8"):
        problems.append("_headers: no Content-Security-Policy")
    if problems:
        print("\n".join("site check: " + p for p in problems), file=sys.stderr)
        return 1
    print("site check PASS: %d files, %d local references, no em dash, CSP-compatible markup"
          % (len(REQUIRED), sum(1 for _, r in page.references if not urlsplit(r).scheme)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
