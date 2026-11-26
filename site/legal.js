// Legal pages: the masthead's hairline once the page has scrolled, as on the rest of the site (motion.js), and on wide
// screens the contents list open with the section being read marked. No planes here: long documents stay calm.
// Everything is visible without this script; it only toggles a class, `open` and aria-current on what is already there.
(() => {
  const masthead = document.querySelector('.masthead');
  if (masthead) {
    const rule = () => masthead.classList.toggle('is-scrolled', window.scrollY > 8);
    window.addEventListener('scroll', rule, { passive: true });
    rule();
  }

  const toc = document.querySelector('.toc');
  const details = toc && toc.querySelector('details');
  if (!details) return;
  const wide = window.matchMedia('(min-width: 1024px)');
  const sync = () => { if (wide.matches) details.open = true; };
  sync();
  wide.addEventListener('change', sync);

  const links = new Map([...details.querySelectorAll('a[href^="#"]')].map((a) => [decodeURIComponent(a.hash.slice(1)), a]));
  const headings = [...links.keys()].map((id) => document.getElementById(id)).filter(Boolean);
  if (!headings.length) return;

  let current = null;
  const mark = (id) => {
    if (id === current) return;
    if (current) links.get(current)?.removeAttribute('aria-current');
    current = id;
    const link = links.get(id);
    if (!link) return;
    link.setAttribute('aria-current', 'true');
    // Keep the marked entry in view inside the sticky list (scrolling the list, not the page).
    if (wide.matches && toc.scrollHeight > toc.clientHeight) {
      const box = toc.getBoundingClientRect(), item = link.getBoundingClientRect();
      if (item.top < box.top + 24) toc.scrollTop -= box.top + 24 - item.top;
      else if (item.bottom > box.bottom - 24) toc.scrollTop += item.bottom - box.bottom + 24;
    }
  };

  // The last heading above the top third of the viewport is the section being read; at the very bottom of the
  // page it is the last one, which may be too short to reach that line.
  const update = () => {
    const doc = document.documentElement;
    if (window.innerHeight + window.scrollY >= doc.scrollHeight - 2) { mark(headings[headings.length - 1].id); return; }
    const line = window.innerHeight / 3;
    let id = headings[0].id;
    for (const h of headings) { if (h.getBoundingClientRect().top <= line) id = h.id; else break; }
    mark(id);
  };
  // At most one update per 80 ms while scrolling, plus one when it stops (a timer, so it also runs in a tab the
  // browser treats as hidden, where animation frames pause).
  let timer = 0, last = 0;
  window.addEventListener('scroll', () => {
    const now = performance.now();
    if (now - last > 80) { last = now; update(); }
    clearTimeout(timer);
    timer = setTimeout(update, 100);
  }, { passive: true });
  window.addEventListener('resize', update, { passive: true });
  update();
})();
