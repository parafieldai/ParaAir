#!/usr/bin/env python3
"""Builds the site's legal pages from their markdown sources.

    scripts/build-legal-pages.py --source DIR --effective "November 20, 2026" [--out site]

DIR holds terms.md, cloud-terms.md, subscription-policy.md, acceptable-use.md, copyright.md, privacy.md and
law-enforcement.md (docs/legal/ in the private paraair-cloud repository). Each becomes site/<slug>.html, served at /<slug>, plus the
/legal index. `{{EFFECTIVE_DATE}}` in a source becomes --effective. Stdlib only, like the other site scripts.

The markdown subset the documents use: # to #### headings, paragraphs, ``` blocks (kept literally), - and 1. lists (nested by indentation),
pipe tables, > quotes, --- rules, **bold**, *italic*, `code`, [links](url), and bare emails and https URLs.
Numbered clauses get anchors: a heading "## 13. Fees" is #13 and a paragraph "**13.2 Title.** ..." is #13.2, so
emails and other documents can link to a clause.
"""
import argparse
import html
import pathlib
import re
import sys

DOCUMENTS = [
    ("terms", "Terms of Service", "The agreement for the ParaAir app, this website and ParaAir Cloud."),
    ("cloud-terms", "ParaAir Cloud Service Terms", "What the paid storage service includes and how it works."),
    ("subscription-policy", "Subscription, Cancellation and Refund Policy", "Billing, renewal, the free trial, cancelling and refunds."),
    ("privacy", "Privacy Policy", "What we collect, why, who processes it and your choices."),
    ("acceptable-use", "Acceptable Use Policy", "What you may not store or do, and how to report abuse."),
    ("copyright", "Copyright and DMCA Policy", "Copyright notices, counter-notices and our designated agent."),
    ("law-enforcement", "Law Enforcement Guidelines", "How we respond to requests from governments and courts."),
]
FOOTER_LINKS = [("terms", "Terms"), ("privacy", "Privacy"), ("subscription-policy", "Refunds"),
                ("acceptable-use", "Acceptable use"), ("copyright", "Copyright"), ("legal", "All legal")]
COMPANY = ("Parafield Inc.", "18333 Bothell Way NE, Apt 330", "Bothell, WA 98011, United States")
CONTACTS = [("General, legal and privacy", "contact@parafield.ai"), ("Support", "support@parafield.ai"),
            ("Report abuse", "abuse@parafield.ai"), ("Copyright agent", "dmca@parafield.ai")]

GITHUB_PATH = ("M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49"
               "-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52"
               ".28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-"
               ".18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 "
               "3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-"
               "4.42-3.58-8-8-8z")

# ---------------------------------------------------------------------------------------------------------- inline

_TOKEN = "\x00{}\x00"


def inline(text):
    """Markdown inline syntax to HTML. Code spans and links are set aside first so their contents stay literal."""
    stash = []

    def keep(fragment):
        stash.append(fragment)
        return _TOKEN.format(len(stash) - 1)

    text = re.sub(r"`([^`]+)`", lambda m: keep(f"<code>{html.escape(m.group(1))}</code>"), text)

    def link(m):
        label, url = m.group(1), m.group(2).strip()
        url = local(url)
        if not re.match(r"^(https://|mailto:|/[a-z-]*(#|$)|#)", url):
            raise ValueError(f"refusing link target {url!r}")
        external = url.startswith("https://") and "paraair.parafield.ai" not in url
        attrs = ' rel="noopener"' if external else ""
        return keep(f'<a href="{html.escape(url, quote=True)}"{attrs}>{inline(label)}</a>')

    text = re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, text)
    text = re.sub(r"(?<![\w@/.])([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)(?<!\.)",
                  lambda m: keep(f'<a href="mailto:{m.group(1)}">{m.group(1)}</a>'), text)
    text = re.sub(r"(?<![\w/.])(/(?:%s)(?:#\d+(?:\.\d+)*)?)(?![\w-])" % "|".join(SITE_PAGES),
                  lambda m: keep(f'<a href="{local(m.group(1))}">{m.group(1)}</a>'), text)
    text = re.sub(r"(?<![\"'=])(https://[^\s<>()]+[^\s<>().,;:!?'\"])",
                  lambda m: keep(f'<a href="{html.escape(m.group(1), quote=True)}" rel="noopener">{html.escape(m.group(1))}</a>'), text)
    text = html.escape(smart_quotes(text), quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", text)
    text = re.sub(r"(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])", r"<em>\1</em>", text)
    while "\x00" in text:
        text = re.sub(r"\x00(\d+)\x00", lambda m: stash[int(m.group(1))], text)
    return text


def smart_quotes(text):
    """Typographer's quotes for prose (code, links and URLs are already set aside)."""
    text = re.sub(r"(\w)'(\w)", "\\1\u2019\\2", text)                # it's, Parafield's
    text = re.sub(r"(^|[\s(\[\u2014-])'", "\\1\u2018", text)          # opening single
    text = text.replace("'", "\u2019")                                  # closing single, trailing apostrophe
    text = re.sub(r'(^|[\s(\[\u2014-])"', "\\1\u201c", text)          # opening double
    return text.replace('"', "\u201d")


SITE_PAGES = ["cloud-terms", "subscription-policy", "acceptable-use", "law-enforcement", "terms", "privacy", "copyright",
              "legal", "pricing"]


def local(url):
    """Site paths as the site links them, extensionless (/privacy#9.7): the Worker serves /privacy and answers
    /privacy.html with a 307 to it. A page name written as privacy.html becomes /privacy too."""
    m = re.match(r"^/?([a-z-]+)(?:\.html)?(#.*)?$", url)
    known = {s for s, _, _ in DOCUMENTS} | {"legal", "pricing"}
    return f"/{m.group(1)}{m.group(2) or ''}" if m and m.group(1) in known else url


# ----------------------------------------------------------------------------------------------------------- blocks

CLAUSE = re.compile(r"^\*\*(\d+(?:\.\d+)+)\.?\s")      # "**13.2 Title.** ..." or "**13.2. Title**"
PLAIN_CLAUSE = re.compile(r"^(\d+(?:\.\d+)+)\.?\s")    # "13.2. **Title.** ..."
HEADING_NUMBER = re.compile(r"^(\d+(?:\.\d+)*)\.?\s")   # "## 13. Fees", "### 5.1 Account information"
LIST_ITEM = re.compile(r"^( *)([-*]|\d+[.)]) +(.*)$")


def link_number(rendered, number, anchor):
    """Makes a clause's leading number a link to the clause, so it can be copied and shared."""
    return rendered.replace(number, f'<a class="anchor clause-number" href="#{anchor}">{number}</a>', 1)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", re.sub(r"<[^>]+>", "", text).lower()).strip("-") or "section"


class Document:
    def __init__(self, source, effective):
        self.title, self.meta, self.out, self.toc, self.ids = None, None, [], [], set()
        self.lines = source.replace("{{EFFECTIVE_DATE}}", effective).splitlines()
        self.parse()

    def unique(self, base):
        candidate, n = base, 2
        while candidate in self.ids:
            candidate, n = f"{base}-{n}", n + 1
        self.ids.add(candidate)
        return candidate

    def parse(self):
        lines, i = self.lines, 0
        paragraph = []

        def flush():
            if paragraph:
                self.paragraph(" ".join(s.strip() for s in paragraph))
                paragraph.clear()

        while i < len(lines):
            line = lines[i]
            stripped = line.strip()
            if not stripped:
                flush(); i += 1; continue
            if stripped.startswith("```"):
                flush(); i = self.fenced(i); continue
            heading = re.match(r"^(#{1,4})\s+(.*)$", stripped)
            if heading:
                flush(); self.heading(len(heading.group(1)), heading.group(2)); i += 1; continue
            if re.match(r"^(-{3,}|\*{3,})$", stripped):
                flush(); self.out.append("<hr>"); i += 1; continue
            if stripped.startswith("|") and i + 1 < len(lines) and re.match(r"^\|?\s*:?-{3,}", lines[i + 1].strip()):
                flush(); i = self.table(i); continue
            if stripped.startswith(">"):
                flush(); i = self.quote(i); continue
            if LIST_ITEM.match(line) and not paragraph:
                i = self.listing(i); continue
            paragraph.append(line); i += 1
        flush()

    def fenced(self, i):
        """A ``` block (an address to copy, a notice template) is kept as written: escaped, line breaks and all."""
        body, i = [], i + 1
        while i < len(self.lines) and not self.lines[i].strip().startswith("```"):
            body.append(self.lines[i]); i += 1
        self.out.append(f'<pre class="doc-block">{html.escape(chr(10).join(body).strip(chr(10)), quote=False)}</pre>')
        return i + 1

    def heading(self, level, text):
        if level == 1 and self.title is None:
            self.title = text; return
        number = HEADING_NUMBER.match(text)
        anchor = self.unique(number.group(1) if number and level in (2, 3) else slug(text))
        if level == 2:
            self.toc.append((anchor, text))
        tag = f"h{min(level, 4)}"
        self.out.append(f'<{tag} id="{anchor}"><a class="anchor" href="#{anchor}">{inline(text)}</a></{tag}>')

    def paragraph(self, text):
        if self.meta is None and not self.out and re.match(r"^(Effective|Last updated)\b", text):
            self.meta = inline(text); return
        clause = CLAUSE.match(text) or PLAIN_CLAUSE.match(text)
        if clause:
            anchor = self.unique(clause.group(1))
            self.out.append(f'<p class="clause" id="{anchor}">{link_number(inline(text), clause.group(1), anchor)}</p>')
        else:
            self.out.append(f"<p>{inline(text)}</p>")

    def table(self, i):
        rows = []
        while i < len(self.lines) and self.lines[i].strip().startswith("|"):
            rows.append([cell.strip() for cell in self.lines[i].strip().strip("|").split("|")]); i += 1
        head, body = rows[0], rows[2:]
        label = html.escape(re.sub(r"[*`]", "", " / ".join(head)), quote=True)
        parts = [f'<div class="table-scroll" tabindex="0" role="region" aria-label="Table: {label}"><table>', "<thead><tr>"]
        parts += [f'<th scope="col">{inline(c)}</th>' for c in head]
        parts.append("</tr></thead><tbody>")
        for row in body:
            parts.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
        parts.append("</tbody></table></div>")
        self.out.append("".join(parts))
        return i

    def quote(self, i):
        body = []
        while i < len(self.lines) and self.lines[i].strip().startswith(">"):
            body.append(self.lines[i].strip()[1:].strip()); i += 1
        paragraphs = [p for p in "\n".join(body).split("\n\n") if p.strip()]
        self.out.append("<blockquote>" + "".join(f"<p>{inline(' '.join(p.split()))}</p>" for p in paragraphs) + "</blockquote>")
        return i

    def listing(self, i):
        """A list block, nested by indentation; indented non-marker lines continue the previous item."""
        items = []   # (indent, ordered, text)
        while i < len(self.lines):
            line = self.lines[i]
            if not line.strip():
                nxt = self.lines[i + 1] if i + 1 < len(self.lines) else ""
                if LIST_ITEM.match(nxt) or (nxt.startswith("  ") and items):
                    i += 1; continue
                break
            match = LIST_ITEM.match(line)
            if match:
                items.append([len(match.group(1)), match.group(2)[0].isdigit(), match.group(3).strip()])
            elif line.startswith(" ") and items:
                items[-1][2] += " " + line.strip()
            else:
                break
            i += 1
        self.out.append(self.render_items(items))
        return i

    def render_items(self, items):
        out, stack = [], []   # stack of (indent, tag)
        for indent, ordered, text in items:
            tag = "ol" if ordered else "ul"
            if stack and indent > stack[-1][0]:
                out.append(f"<{tag}>"); stack.append((indent, tag))
            else:
                while stack and indent < stack[-1][0]:
                    out.append(f"</li></{stack.pop()[1]}>")
                if stack:
                    out.append("</li>")
                else:
                    out.append(f"<{tag}>"); stack.append((indent, tag))
            clause = CLAUSE.match(text) or PLAIN_CLAUSE.match(text)
            if clause:
                anchor = self.unique(clause.group(1))
                out.append(f'<li id="{anchor}">{link_number(inline(text), clause.group(1), anchor)}')
            else:
                out.append(f"<li>{inline(text)}")
        while stack:
            out.append(f"</li></{stack.pop()[1]}>")
        return "".join(out)


# --------------------------------------------------------------------------------------------------------- template

SITE = "https://paraair.parafield.ai"
CARD = (f"{SITE}/og-card.png", "The ParaAir paper plane and the words: Cloud storage, as a Mac drive.")


def social(url, title, description):
    """The link preview: Open Graph (Facebook, LinkedIn, Slack, iMessage, X's fallback) and X's own card tags.
    Every page shares site/og-card.png (scripts/build-site-images.sh)."""
    title, description = html.escape(title, quote=True), html.escape(description, quote=True)
    return f"""
  <meta property="og:type" content="website">
  <meta property="og:site_name" content="ParaAir">
  <meta property="og:url" content="{url}">
  <meta property="og:title" content="{title}">
  <meta property="og:description" content="{description}">
  <meta property="og:image" content="{CARD[0]}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:alt" content="{html.escape(CARD[1], quote=True)}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{title}">
  <meta name="twitter:description" content="{description}">
  <meta name="twitter:image" content="{CARD[0]}">
  <meta name="twitter:image:alt" content="{html.escape(CARD[1], quote=True)}">"""


def masthead(root=""):
    return f"""  <header class="masthead">
    <a class="brand" href="/" aria-label="ParaAir home">
      <svg class="brand-mark" viewBox="0 0 454 460" aria-hidden="true">
        <polygon class="mark-a" points="0,150 454,0 316,298 244,208"/>
        <polygon class="mark-b" points="244,208 316,298 156,460 168,256"/>
      </svg>
      <span>ParaAir</span>
    </a>
    <nav class="nav" aria-label="Primary">
      <div class="nav-group">
        <a class="nav-link" href="/pricing">Pricing</a>
        <a class="nav-link" href="https://github.com/parafieldai/ParaAir" aria-label="ParaAir source code on GitHub">
          <svg class="nav-icon" viewBox="0 0 16 16" aria-hidden="true"><path d="{GITHUB_PATH}"/></svg>
          <span class="nav-label">GitHub</span>
        </a>
      </div>
      <a class="nav-cta" href="/#access">Download</a>
    </nav>
  </header>"""


def footer(current):
    links = "&nbsp;· ".join(f'<a href="/{s}"{" aria-current=\"page\"" if s == current else ""}>{label}</a>' for s, label in FOOTER_LINKS)
    return f"""  <footer class="colophon">
    <nav class="colophon-legal" aria-label="Legal">{links}</nav>
    <p>ParaAir by Parafield · <a href="https://github.com/parafieldai/ParaAir">Source code</a> (Apache-2.0) · Built on <a href="https://github.com/juicedata/juicefs">JuiceFS</a> · © 2026</p>
  </footer>"""


def page(slug_, title, description, body, current, root="", indexed=True, script="legal.js", body_class="legal-page"):
    """`root` prefixes the page's own assets: "/" for 404.html, which is served at any unknown path. Links between pages
    are root-relative and extensionless everywhere. A page that is not indexed (404.html) gets noindex instead of a
    canonical address and a link preview. `script` and `body_class`: 404.html takes the landing hero, flown by
    motion.js, instead of the legal layout."""
    full_title = f"{title} · ParaAir"
    url = f"{SITE}/{slug_}"
    # The preview's title drops the " · ParaAir" suffix when the title already names ParaAir (og:site_name has it).
    head = (f'\n  <link rel="canonical" href="{url}">' + social(url, title if "ParaAir" in title else full_title, description)
            if indexed
            else '\n  <meta name="robots" content="noindex">')
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{html.escape(full_title)}</title>
  <meta name="description" content="{html.escape(description, quote=True)}">
  <meta name="color-scheme" content="dark light">{head}
  <link rel="icon" href="{root}glide.svg" type="image/svg+xml">
  <link rel="stylesheet" href="{root}styles.css">
</head>
<body{f' class="{body_class}"' if body_class else ''}>
  <a class="skip" href="#main">Skip to content</a>
{masthead(root)}
{body}
{footer(current)}
  <script src="{root}{script}" defer></script>
</body>
</html>
"""


def document_page(slug_, short_title, description, doc):
    toc = "".join(f'<li><a href="#{a}">{inline(t)}</a></li>' for a, t in doc.toc)
    contents = (f'<nav class="toc" aria-label="Contents"><details><summary>Contents</summary><ol role="list">{toc}</ol></details></nav>'
                if len(doc.toc) > 2 else "")
    lead = f"{doc.meta} · " if doc.meta else ""
    meta = f'<p class="doc-meta">{lead}{COMPANY[0]} · <a href="/legal">All legal documents</a></p>'
    body = f"""  <main id="main" class="legal">
    <div class="legal-head">
      <h1{' class="title-long"' if len(doc.title or short_title) > 36 else ''}>{inline(doc.title or short_title)}</h1>
      {meta}
    </div>
    <div class="legal-body">
      {contents}
      <article class="doc">
{chr(10).join("        " + block for block in doc.out)}
      </article>
    </div>
  </main>"""
    return page(slug_, doc.title or short_title, description, body, slug_)


def index_page(effective):
    rows = "".join(f'<li><a href="/{s}"><span class="legal-doc-title">{html.escape(t)}</span>'
                   f' <span class="legal-doc-note">{html.escape(note)}</span></a></li>' for s, t, note in DOCUMENTS)
    contacts = "".join(f"<div><dt>{html.escape(label)}</dt><dd>{inline(email)}</dd></div>" for label, email in CONTACTS)
    body = f"""  <main id="main" class="legal legal-index">
    <div class="legal-head">
      <h1>Legal</h1>
      <p class="doc-meta">Effective {html.escape(effective)} · {COMPANY[0]}</p>
    </div>
    <div class="legal-index-body">
      <ol class="legal-docs" role="list">{rows}</ol>
      <aside class="legal-company" aria-label="Company">
        <p class="legal-company-name">{COMPANY[0]}</p>
        <p>{COMPANY[1]}<br>{COMPANY[2]}</p>
        <dl>{contacts}</dl>
        <p class="legal-note">ParaAir Cloud is offered in the United States. Parafield's other products have their own terms on <a href="https://parafield.ai" rel="noopener">parafield.ai</a>.</p>
      </aside>
    </div>
  </main>"""
    return page("legal", "Legal", "ParaAir's terms, policies and how to reach Parafield Inc.", body, "legal")


def not_found_page():
    """The landing page's hero (site/index.html), so motion.js flies it the same way: the headline at poster size with
    the lead plane flying in under its last words, the grey flock in the open air, the way back at the foot."""
    body = """  <canvas class="sky" data-sky aria-hidden="true"></canvas>
  <main id="main">
    <section class="hero" aria-labelledby="missing-title" data-flight="hero">
      <h1 id="missing-title">There\u2019s no <span class="under" data-under>page&nbsp;here.</span></h1>
      <div class="hero-foot">
        <p class="lede">The link may be old, or the address&nbsp;mistyped.</p>
        <div class="hero-action">
          <a class="cta" href="/">Go to the home page</a>
          <p class="requires">Or try <a href="/pricing">pricing</a> or the <a href="/legal">legal documents</a>.</p>
        </div>
      </div>
    </section>
  </main>"""
    return page("404", "Page not found", "This page does not exist.", body, "", root="/", indexed=False,
                script="motion.js", body_class="")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--source", required=True, type=pathlib.Path)
    parser.add_argument("--effective", required=True, help='for example "November 20, 2026"')
    parser.add_argument("--out", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parent.parent / "site")
    args = parser.parse_args()
    if not re.match(r"^[A-Z][a-z]+ \d{1,2}, \d{4}$", args.effective):
        sys.exit("--effective must look like 'November 20, 2026'")
    problems = []
    for slug_, title, note in DOCUMENTS:
        source = (args.source / f"{slug_}.md").read_text(encoding="utf-8")
        leftovers = sorted(set(re.findall(r"\[(?:counsel|operator|engineering)[^\]]*\]|\[[A-Z][A-Z ,./_-]{2,}\]|\{\{(?!EFFECTIVE_DATE)[^}]*\}\}", source)))
        if leftovers:
            problems.append(f"{slug_}.md: {', '.join(x[:40] for x in leftovers[:5])}")
        doc = Document(source, args.effective)
        (args.out / f"{slug_}.html").write_text(document_page(slug_, title, note, doc), encoding="utf-8")
        print(f"{slug_}.html: {len(doc.toc)} sections, {len(doc.ids)} anchors")
    (args.out / "legal.html").write_text(index_page(args.effective), encoding="utf-8")
    (args.out / "404.html").write_text(not_found_page(), encoding="utf-8")
    print("legal.html, 404.html")
    if problems:
        sys.exit("unfinished placeholders or notes:\n  " + "\n  ".join(problems))


if __name__ == "__main__":
    main()
