// ParaAir site motion. Everything is visible without this script; it only moves what is already on screen, runs
// while the page scrolls (and for the lead plane's one entrance), stops when the page is still, and respects
// reduced motion.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  const root = document.documentElement;
  const css = (name) => getComputedStyle(root).getPropertyValue(name).trim();
  const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
  const MARK = [[[0, 150], [454, 0], [316, 298], [244, 208]], [[244, 208], [316, 298], [156, 460], [168, 256]]];

  // The mark drawn once into a small canvas, nose pointing along +x, so each frame only stamps it.
  const sprite = (size, ink, sage, ratio) => {
    const c = document.createElement('canvas');
    const px = Math.ceil(size * 1.5 * ratio);
    c.width = px; c.height = px;
    const g = c.getContext('2d');
    g.translate(px / 2, px / 2);
    g.rotate(Math.PI / 4);
    const s = (size * ratio) / 454;
    g.scale(s, s);
    g.translate(-227, -230);
    MARK.forEach((poly, i) => {
      g.beginPath();
      poly.forEach(([x, y], k) => (k ? g.lineTo(x, y) : g.moveTo(x, y)));
      g.closePath();
      g.fillStyle = i === 0 ? ink : sage;
      g.fill();
    });
    return c;
  };

  // The bar gains its hairline once the page has scrolled.
  const masthead = document.querySelector('.masthead');
  if (masthead) {
    const mark = () => masthead.classList.toggle('is-scrolled', window.scrollY > 8);
    window.addEventListener('scroll', mark, { passive: true });
    mark();
  }

  // ---------------------------------------------------------------------------
  // The sky. Planes fly only inside airspaces: the hero's open side and the band under its headline, the empty bands
  // between stories, and the closing section's open side. Where a plane is follows how far its airspace has
  // scrolled; when the page stops, they settle within 0.4 s and nothing redraws.
  const sky = document.querySelector('[data-sky]');
  if (sky) {
    const ctx = sky.getContext('2d');
    let W = 0, H = 0, ratio = 1, spaces = [], art = null;
    let shown = window.scrollY, last = 0, raf = 0, entrance = null;

    const seeded = (n) => { let s = n; return () => { s = (s * 16807) % 2147483647; return (s - 1) / 2147483646; }; };
    const rect = (el) => { const r = el.getBoundingClientRect(); return { left: r.left, right: r.right, top: r.top + window.scrollY, bottom: r.bottom + window.scrollY }; };

    const paint = () => {
      const ink = css('--ink'), sage = css('--sage'), grey = css('--plane-grey'), fold = css('--plane-fold');
      // The flock is the mark in two greys, its fold lighter, so a small plane still reads as folded paper.
      art = { lead: sprite(52, ink, sage, ratio), mid: sprite(28, grey, fold, ratio), far: sprite(18, grey, fold, ratio), trail: css('--sage-line'), grey };
    };

    // One plane on a straight glide across the whole width, tilted, sinking a little; `u` runs 0 to 1 across.
    const flight = (p, u) => {
      const x = -0.15 * W + u * 1.3 * W;
      const d = u - p.start;
      const y = p.y + d * 1.3 * W * Math.tan(p.heading) + p.sink * d * Math.abs(d) + p.wobble * (Math.sin(u * 6.28 * p.waves + p.phase) - Math.sin(p.start * 6.28 * p.waves + p.phase));
      return { x, y };
    };

    // How visible a point is: fully inside an airspace, fading to nothing before any of its edges.
    const room = (space, x, y, margin) => {
      let best = 0;
      for (const z of space.zones) best = Math.max(best, clamp((Math.min(x - z.left, z.right - x, y - z.top, z.bottom - y) - margin) / 36));
      return best;
    };

    // The canvas takes its own box (100lvh), so a phone's toolbar showing or hiding never stretches the drawing.
    const fit = () => {
      ratio = Math.min(window.devicePixelRatio || 1, 2);
      const box = sky.getBoundingClientRect();
      W = box.width || window.innerWidth; H = box.height || window.innerHeight;
      sky.width = Math.round(W * ratio); sky.height = Math.round(H * ratio);
    };

    const build = () => {
      fit();
      paint();
      const wide = W >= 1024, phone = W < 640;
      spaces = [...document.querySelectorAll('[data-flight]')].map((el, index) => {
        const kind = el.dataset.flight, box = rect(el), random = seeded(17 + index * 31);
        const zones = [];
        if (kind === 'hero') {
          const h1 = rect(el.querySelector('h1')), foot = rect(el.querySelector('.hero-foot'));
          // The band between the headline and the foot, then (on wider screens) the open side beside both.
          zones.push({ left: 0, right: W, top: h1.bottom + 28, bottom: foot.top - 28 });
          if (!phone) zones.push({ left: Math.max(h1.right, foot.right) + 40, right: W, top: box.top + 88, bottom: box.bottom - 16 });
        } else if (kind === 'close') {
          let right = 0;
          el.querySelectorAll('h2, .cta, .access-notes').forEach((child) => { right = Math.max(right, rect(child).right); });
          if (!phone) zones.push({ left: right + 48, right: W, top: box.top + 32, bottom: box.bottom - 32 });
        } else {
          zones.push({ left: 0, right: W, top: box.top, bottom: box.bottom });
        }
        const usable = zones.filter((z) => z.bottom - z.top > 40 && z.right - z.left > 80);
        const count = kind === 'gap' ? (phone ? 3 : wide ? 6 : 4) : (phone ? 4 : wide ? 9 : 6);
        const planes = [];
        const lead = kind !== 'gap';
        const all = usable.length ? usable : [];
        // The widest zone is where the lead flies; the rest of the flock spreads over every zone.
        const widest = all.slice().sort((a, b) => (b.right - b.left) * (b.bottom - b.top) - (a.right - a.left) * (a.bottom - a.top))[0];
        for (let i = 0; all.length && i < count + (lead ? 1 : 0); i++) {
          const isLead = lead && i === 0;
          const depth = isLead ? 1 : random() < 0.45 ? 0.75 : 0.4;
          const zone = isLead ? (all.find((z) => z.left > 0) || widest) : all[Math.floor(random() * all.length)];
          let x0 = 0, y0 = 0;
          // The flock keeps 60 px clear of the lead, so no plane sits on top of it.
          for (let attempt = 0; attempt < 8; attempt++) {
            x0 = zone.left + (isLead ? 0.42 : 0.08 + 0.84 * random()) * (zone.right - zone.left);
            y0 = zone.top + (isLead ? 0.38 : 0.2 + 0.6 * random()) * (zone.bottom - zone.top);
            const leader = planes[0];
            if (isLead || !leader || !leader.lead || Math.hypot(x0 - leader.x0, y0 - leader.y) >= 60) break;
          }
          planes.push({
            x0,
            lead: isLead,
            depth,
            size: isLead ? 52 : depth > 0.6 ? 24 + 8 * random() : 17 + 4 * random(),
            alpha: isLead ? 1 : depth > 0.6 ? 0.65 + 0.15 * random() : 0.35 + 0.1 * random(),
            y: y0,
            heading: (random() - 0.62) * 0.9,
            sink: 20 + 40 * random(),
            wobble: 6 + 10 * random(),
            waves: 0.5 + random(),
            phase: random() * 6.28,
            start: (x0 + 0.15 * W) / (1.3 * W),
            // Near planes cross further for the same scroll, so the flock peels away front first. The hero's flock
            // lingers through its first screen of scroll; the bands' cross as they pass.
            pace: kind === 'gap' ? (depth > 0.6 ? 0.95 : 0.45) : isLead ? 0.6 : depth > 0.6 ? 0.45 : 0.18,
          });
        }
        return { el, kind, box, zones: all, planes };
      });
    };

    // How far an airspace has scrolled: the hero from the top of the page, the others as they cross the window.
    const progress = (space, scroll) => {
      if (reduce.matches) return 0.35;
      if (space.kind === 'hero') return clamp(scroll / Math.max(1, space.box.bottom - space.box.top), 0, 1.2);
      return clamp((scroll + H - space.box.top) / (H + space.box.bottom - space.box.top), 0, 1) - 0.5;
    };

    const stamp = (image, x, y, angle, bank, alpha, scale = 1) => {
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.translate(x, y);
      ctx.rotate(angle);
      ctx.scale(scale, scale * bank);
      ctx.drawImage(image, -image.width / ratio / 2, -image.height / ratio / 2, image.width / ratio, image.height / ratio);
      ctx.restore();
    };

    // A tapered line behind a plane, along its own path: sage for a lead, faint grey for the near flock.
    const trail = (points, color, width, alpha) => {
      ctx.save();
      ctx.lineCap = 'round';
      ctx.strokeStyle = color;
      for (let k = 1; k < points.length; k++) {
        const f = 1 - k / points.length;
        ctx.globalAlpha = alpha * f * Math.min(points[k - 1].fade, points[k].fade);
        ctx.lineWidth = width * f;
        ctx.beginPath();
        ctx.moveTo(points[k - 1].x, points[k - 1].y);
        ctx.lineTo(points[k].x, points[k].y);
        ctx.stroke();
      }
      ctx.restore();
    };

    const drawPlane = (space, p, u, scroll) => {
      const a = flight(p, u), b = flight(p, u + 0.004), c = flight(p, u + 0.008);
      // At least 16 px of clear paper between any part of a plane and the edge of its airspace.
      const fade = room(space, a.x, a.y, p.size * 0.6 + 16);
      if (fade <= 0) return;
      const angle = Math.atan2(b.y - a.y, b.x - a.x);
      // Bank: a paper plane narrows as it turns.
      const turn = Math.atan2(c.y - b.y, c.x - b.x) - angle;
      const bank = 1 - Math.min(0.3, Math.abs(turn) * 40);
      const y = a.y - scroll;
      if (p.lead || p.depth > 0.6) {
        const points = [];
        const steps = p.lead ? 14 : 6, reach = p.lead ? 200 : 56;
        for (let k = 0; k < steps; k++) { const q = flight(p, u - (k * reach) / (steps * 1.3 * W)); points.push({ x: q.x, y: q.y - scroll, fade: room(space, q.x, q.y, 4) }); }
        trail(points, p.lead ? art.trail : art.grey, p.lead ? 3 : 1.5, p.lead ? 0.9 : 0.25);
      }
      stamp(p.lead ? art.lead : p.depth > 0.6 ? art.mid : art.far, a.x, y, angle, bank, p.alpha * fade, p.size / (p.lead ? 52 : p.depth > 0.6 ? 28 : 18));
    };

    // `flown` (the smoothed scroll) says how far each plane has flown; the real scroll places it on the screen, so a
    // plane never lags the words around its airspace.
    const draw = (flown, now) => {
      const scroll = window.scrollY;
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, W, H);
      for (const space of spaces) {
        if (space.box.bottom < scroll - 40 || space.box.top > scroll + H + 40) continue;
        const p = progress(space, flown);
        for (const plane of space.planes) {
          if (plane.lead && entrance && space.kind === 'hero') continue;
          drawPlane(space, plane, plane.start + p * plane.pace, scroll);
        }
      }
      if (entrance) drawEntrance(scroll, now);
    };

    // The lead plane's one entrance: it flies in under "Mac drive.", leaving the underline, then climbs into its place.
    const under = document.querySelector('[data-under]');
    const hero = document.querySelector('.hero');
    const drawEntrance = (scroll, now) => {
      const t = clamp((now - entrance.start) / 1500);
      const e = 1 - Math.pow(1 - t, 3);
      const r = under.getBoundingClientRect();
      const lead = spaces.find((s) => s.kind === 'hero')?.planes.find((p) => p.lead);
      const home = lead ? flight(lead, lead.start) : { x: W * 0.8, y: H * 0.4 + scroll };
      const p0 = { x: r.left - 90, y: r.bottom + 6 }, p1 = { x: r.right + 30, y: r.bottom + 6 }, p2 = { x: home.x, y: home.y - scroll };
      const at = (k) => {
        const m = 1 - k;
        return { x: m * m * p0.x + 2 * m * k * p1.x + k * k * p2.x, y: m * m * p0.y + 2 * m * k * p1.y + k * k * p2.y };
      };
      const a = at(e), b = at(Math.min(1, e + 0.01));
      stamp(art.lead, a.x, a.y, Math.atan2(b.y - a.y, b.x - a.x), 1, clamp(t * 4));
      if (t >= 1) { entrance = null; under.style.removeProperty('--draw'); }
    };

    const tick = (now) => {
      const dt = Math.min(0.05, (now - last) / 1000 || 0.016);
      last = now;
      const target = window.scrollY;
      shown += (target - shown) * (1 - Math.exp(-dt / 0.11));
      if (Math.abs(target - shown) < 0.5) shown = target;
      // The underline draws as the lead plane passes. Only a frame that actually runs ever shortens it, so if frames
      // never come it simply stays drawn.
      if (entrance && under) {
        const drawn = clamp((now - entrance.start - 200) / 1100);
        under.style.setProperty('--draw', (1 - Math.pow(1 - drawn, 3)).toFixed(3));
      }
      draw(shown, now);
      raf = shown !== target || entrance ? requestAnimationFrame(tick) : 0;
    };
    const wake = () => {
      if (reduce.matches) { shown = window.scrollY; draw(shown, performance.now()); return; }
      if (!raf && !document.hidden) { last = performance.now(); raf = requestAnimationFrame(tick); }
    };

    let width = -1;
    const relayout = () => { if (window.innerWidth === width) return; width = window.innerWidth; build(); shown = window.scrollY; draw(shown, performance.now()); };
    relayout();
    window.addEventListener('resize', () => { if (window.innerWidth !== width) relayout(); else { fit(); paint(); draw(shown, performance.now()); } }, { passive: true });
    window.addEventListener('load', () => {
      // A browser that restores a scroll position after loading skips the entrance: the hero isn't in view.
      if (entrance && window.scrollY > 40) { entrance = null; under.style.removeProperty('--draw'); }
      width = -1; relayout();
    });
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(() => { width = -1; relayout(); });
    window.addEventListener('scroll', wake, { passive: true });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { paint(); draw(shown, performance.now()); });
    // Turning reduced motion on mid-entrance ends the entrance at once: no more frames, the underline fully drawn.
    reduce.addEventListener('change', () => {
      if (reduce.matches) {
        entrance = null;
        if (under) under.style.removeProperty('--draw');
        cancelAnimationFrame(raf); raf = 0;
      }
      width = -1; relayout();
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) wake(); });

    // Only when someone is looking: in a hidden tab the underline simply stays drawn.
    if (under && hero && !reduce.matches && !document.hidden && window.scrollY < 40) {
      entrance = { start: performance.now() + 150 };
      wake();
    }
  }

  // ---------------------------------------------------------------------------
  // "Big files open in pieces": the file's own name, its first letters and its last ones coming down as the story
  // scrolls in, the way a player reads the start of a .mov and its index at the end.
  const file = document.querySelector('[data-file]');
  if (file) {
    const text = file.textContent;
    file.textContent = '';
    const letters = [...text].map((ch) => { const s = document.createElement('span'); s.textContent = ch; file.append(s); return s; });
    const reads = [[0, 2, 0.3], [17, 18, 0.45]];
    let queued = false;
    const show = () => {
      queued = false;
      const r = file.getBoundingClientRect();
      const p = reduce.matches ? 1 : clamp((window.innerHeight - r.top) / (window.innerHeight * 0.8));
      reads.forEach(([from, to, at]) => { for (let i = from; i <= to && i < letters.length; i++) letters[i].classList.toggle('down', p >= at); });
    };
    window.addEventListener('scroll', () => { if (!queued) { queued = true; requestAnimationFrame(show); } }, { passive: true });
    reduce.addEventListener('change', show);
    show();
  }

  // ---------------------------------------------------------------------------
  // "Saves land on your Mac first": the plane waits at the Mac ("Saved"), then flies the save to storage
  // ("Uploading", "Uploaded"). The path is sampled once; drawing happens only while the arc is on screen.
  const arc = document.querySelector('[data-arc]');
  if (arc) {
    const path = arc.querySelector('[data-arc-path]');
    const canvas = arc.querySelector('[data-arc-canvas]');
    const state = arc.querySelector('[data-arc-state]');
    const ctx = canvas.getContext('2d');
    const length = path.getTotalLength();
    const points = Array.from({ length: 121 }, (_, k) => path.getPointAtLength((length * k) / 120));
    let visible = false, queued = false, ratio = 1, plane = null, w = 0, h = 0;
    const size = () => {
      ratio = Math.min(window.devicePixelRatio || 1, 2);
      const r = canvas.getBoundingClientRect();
      w = r.width; h = r.height;
      canvas.width = Math.round(w * ratio); canvas.height = Math.round(h * ratio);
      plane = sprite(44, css('--ink'), css('--sage'), ratio);
    };
    const draw = () => {
      queued = false;
      if (!visible || !w) return;
      const r = arc.getBoundingClientRect();
      const p = reduce.matches ? 0.62 : clamp((window.innerHeight * 0.85 - r.top) / (r.height + window.innerHeight * 0.3));
      const flown = clamp((p - 0.3) / 0.6);
      const label = p < 0.3 ? 'Saved' : flown < 1 ? 'Uploading' : 'Uploaded';
      if (state.textContent !== label) state.textContent = label;
      const sx = w / 1000, sy = h / 220, end = Math.round(flown * 120);
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, w, h);
      if (end > 0) {
        ctx.lineCap = 'round'; ctx.lineWidth = 2.5; ctx.strokeStyle = css('--sage-line');
        ctx.beginPath();
        for (let k = 0; k <= end; k++) { const q = points[k]; k ? ctx.lineTo(q.x * sx, q.y * sy) : ctx.moveTo(q.x * sx, q.y * sy); }
        ctx.stroke();
      }
      const a = points[Math.min(119, end)], b = points[Math.min(120, end + 1)];
      const angle = Math.atan2((b.y - a.y) * sy, (b.x - a.x) * sx);
      ctx.save();
      ctx.translate(a.x * sx, a.y * sy);
      ctx.rotate(angle);
      ctx.drawImage(plane, -plane.width / ratio / 2, -plane.height / ratio / 2, plane.width / ratio, plane.height / ratio);
      ctx.restore();
    };
    const queue = () => { if (!queued) { queued = true; requestAnimationFrame(draw); } };
    size();
    new ResizeObserver(() => { size(); queue(); }).observe(canvas);
    new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; queue(); }).observe(arc);
    window.addEventListener('scroll', queue, { passive: true });
    reduce.addEventListener('change', queue);
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { size(); queue(); });
  }

  // ---------------------------------------------------------------------------
  // Pricing's allowance meter (and any [data-scene]) animates only while it is on screen.
  const scenes = document.querySelectorAll('[data-scene]');
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) entry.target.classList.toggle('is-in', entry.isIntersecting);
    }, { threshold: 0.45 });
    scenes.forEach((scene) => observer.observe(scene));
  } else {
    scenes.forEach((scene) => scene.classList.add('is-in'));
  }
})();
