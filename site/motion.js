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
    let shown = window.scrollY, last = 0, raf = 0, nap = 0, entrance = null, painted = 0;

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
          // The flock keeps 60 px clear of the lead and 36 px from each other, so no plane sits on top of another;
          // planes of one depth glide at one speed, so they keep that spacing while they drift.
          for (let attempt = 0; attempt < 12; attempt++) {
            x0 = zone.left + (isLead ? 0.42 : 0.08 + 0.84 * random()) * (zone.right - zone.left);
            y0 = zone.top + (isLead ? 0.38 : 0.2 + 0.6 * random()) * (zone.bottom - zone.top);
            if (isLead || planes.every((q) => Math.hypot(x0 - q.x0, y0 - q.y) >= (q.lead ? 60 : 36))) break;
          }
          planes.push({
            x0,
            zone,
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
            // Near planes cross further for the same scroll than far ones, so the flock spreads out in depth as the
            // page moves. The hero's flock lingers through its first screen of scroll; the bands' cross as they pass.
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
        // A plane that has just come round to the start of its airspace leaves no line across it.
        if (Math.abs(points[k].x - points[k - 1].x) > 80) break;
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

    // At rest the sky still flies: the flock glides on slowly, near planes faster, coming round past the window's
    // edges (where every airspace has already faded it out) to fly in again from the other side, and every plane
    // rides the air a little. The lead plane only drifts a few pixels, on two slow unrelated swells so it never reads
    // as a loop, easing in once its entrance is over. Nothing moves under reduced motion.
    let leadSince = 0;
    const idle = (p, now) => {
      if (reduce.matches) return { dx: 0, dy: 0, tilt: 0 };
      const s = now / 1000, period = 5 + 3 * ((p.phase * 7.3) % 1), w = (6.283 / period) * s + p.phase;
      if (p.lead) {
        const k = clamp((now - leadSince) / 1600);
        const rise = Math.sin(s * 0.53 + p.phase) + 0.6 * Math.sin(s * 0.19 + 1.7);
        return { dx: 2 * k * Math.sin(s * 0.31 + 0.4), dy: 1.6 * k * rise, tilt: 0.025 * k * Math.cos(s * 0.53 + p.phase) };
      }
      return { dx: s * (p.depth > 0.6 ? 9 : 4.5), dy: (p.depth > 0.6 ? 5 : 3) * Math.sin(w), tilt: 0.06 * Math.cos(w) };
    };
    // The flock comes round across the whole window, 80 px past either edge, so it always reappears out of sight.
    const shift = (p, q, drift) => {
      let x = q.x + drift.dx;
      if (!p.lead) { const span = W + 160; x = ((((x + 80) % span) + span) % span) - 80; }
      return { x, y: q.y + drift.dy };
    };

    const drawPlane = (space, p, u, scroll, now, lead) => {
      const drift = idle(p, now);
      const a = shift(p, flight(p, u), drift), b = shift(p, flight(p, u + 0.004), drift), c = shift(p, flight(p, u + 0.008), drift);
      // At least 16 px of clear paper between any part of a plane and the edge of its airspace; a flock plane
      // gliding past the lead fades as it nears it rather than crossing it.
      const near = lead && !p.lead ? clamp((Math.hypot(a.x - lead.x, a.y - lead.y) - 44) / 40) : 1;
      const fade = room(space, a.x, a.y, p.size * 0.6 + 16) * near;
      if (fade <= 0) return a;
      const angle = Math.atan2(b.y - a.y, b.x - a.x);
      // Bank: a paper plane narrows as it turns.
      const turn = Math.atan2(c.y - b.y, c.x - b.x) - angle;
      const bank = 1 - Math.min(0.3, Math.abs(turn) * 40);
      const y = a.y - scroll;
      if (p.lead || p.depth > 0.6) {
        const points = [];
        const steps = p.lead ? 14 : 6, reach = p.lead ? 200 : 56;
        for (let k = 0; k < steps; k++) { const q = shift(p, flight(p, u - (k * reach) / (steps * 1.3 * W)), drift); points.push({ x: q.x, y: q.y - scroll, fade: room(space, q.x, q.y, 4) }); }
        trail(points, p.lead ? art.trail : art.grey, p.lead ? 3 : 1.5, p.lead ? 0.9 : 0.25);
      }
      stamp(p.lead ? art.lead : p.depth > 0.6 ? art.mid : art.far, a.x, y, angle + drift.tilt, bank, p.alpha * fade, p.size / (p.lead ? 52 : p.depth > 0.6 ? 28 : 18));
      return a;
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
        // The lead first (it is the first plane when there is one), so the flock knows where to give way.
        let lead = null;
        for (const plane of space.planes) {
          if (plane.lead && entrance && space.kind === 'hero') continue;
          const at = drawPlane(space, plane, plane.start + p * plane.pace, scroll, now, lead);
          if (plane.lead) lead = at;
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
      if (t >= 1) { entrance = null; leadSince = now; under.style.removeProperty('--draw'); }
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
      // Scrolling and the entrance draw every frame. The idle drift needs only about 30 a second, so between its
      // frames the loop sleeps on a timer instead of waking at every refresh.
      const busy = shown !== target || entrance;
      if (busy || now - painted >= 30) { draw(shown, now); painted = now; }
      if (busy) raf = requestAnimationFrame(tick);
      else if (flying()) { raf = -1; nap = setTimeout(() => { nap = 0; raf = requestAnimationFrame(tick); }, 30); }
      else raf = 0;
    };
    // Frames run only while some airspace with planes is on screen in a visible tab.
    const flying = () => !reduce.matches && !document.hidden
      && spaces.some((s) => s.planes.length && s.box.bottom > window.scrollY - 40 && s.box.top < window.scrollY + H + 40);
    const sleep = () => { cancelAnimationFrame(raf); clearTimeout(nap); raf = 0; nap = 0; };
    const wake = () => {
      if (reduce.matches) { shown = window.scrollY; draw(shown, performance.now()); return; }
      if (document.hidden) return;
      // Scrolling cuts a nap short: the planes follow the page at full rate.
      if (nap) sleep();
      if (!raf) { last = performance.now(); raf = requestAnimationFrame(tick); }
    };

    let width = -1;
    const relayout = () => { if (window.innerWidth === width) return; width = window.innerWidth; build(); shown = window.scrollY; draw(shown, performance.now()); };
    relayout();
    // A resize can bring an airspace into view, so the loop wakes for it too.
    window.addEventListener('resize', () => { if (window.innerWidth !== width) relayout(); else { fit(); paint(); draw(shown, performance.now()); } wake(); }, { passive: true });
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
        sleep();
      }
      width = -1; relayout(); wake();
    });
    document.addEventListener('visibilitychange', () => { if (!document.hidden) wake(); });

    // Only when someone is looking: in a hidden tab the underline simply stays drawn.
    if (under && hero && !reduce.matches && !document.hidden && window.scrollY < 40) {
      entrance = { start: performance.now() + 150 };
    }
    wake();
  }

  // ---------------------------------------------------------------------------
  // "Big files open in pieces": when the name comes into view, a plane reads it the way a player opens a .mov: it
  // skims the first letters, hops over the middle to the index at the end, and drops those pieces as it passes. They
  // rain into their letters, which fill from the bottom as the pieces land. The letters are solid in the page; only a
  // frame that runs ever empties one, and anything that stops a run (a hidden tab, reduced motion) fills them at once.
  const file = document.querySelector('[data-file]');
  const fileCanvas = document.querySelector('[data-file-canvas]');
  if (file && fileCanvas) {
    const fctx = fileCanvas.getContext('2d');
    const demo = file.parentElement;
    const letters = [...file.querySelectorAll('.down')];
    let run = null, armed = true, primed = false, waiting = 0, fraf = 0, fratio = 1, fplane = null, geo = null;

    // Everything in the canvas's own coordinates, measured once per run. The canvas spans the whole window across,
    // and from just under the words above (the demo's top margin is the air) to the foot of the name.
    const measure = () => {
      // Every read first, then every write, so measuring costs one layout.
      fratio = Math.min(window.devicePixelRatio || 1, 2);
      const em = parseFloat(getComputedStyle(file).fontSize) || 48;
      const across = document.documentElement.clientWidth;
      const d = demo.getBoundingClientRect(), f = file.getBoundingClientRect();
      const say = demo.parentElement.querySelector('.say');
      const ceiling = say ? say.getBoundingClientRect().bottom + 14 : f.top - em;
      const above = Math.max(em * 0.6, f.top - ceiling);
      const cells = letters.map((el) => {
        const r = el.getBoundingClientRect(), style = getComputedStyle(el);
        // Where the letter's ink starts and ends in its box, as the clip in styles.css uses them.
        const base = parseFloat(style.getPropertyValue('--base')) || 0.95, cap = parseFloat(style.getPropertyValue('--cap')) || 0.26;
        return { el, left: r.left, right: r.right, top: r.top - (f.top - above), h: r.height, base, cap };
      });
      const colours = { ink: css('--ink'), sage: css('--sage'), on: css('--on'), line: css('--sage-line') };
      fileCanvas.style.left = `${-d.left}px`;
      fileCanvas.style.top = `${f.top - d.top - above}px`;
      fileCanvas.style.width = `${across}px`;
      fileCanvas.style.height = `${f.height + above}px`;
      fileCanvas.width = Math.round(across * fratio);
      fileCanvas.height = Math.round((f.height + above) * fratio);
      const size = Math.max(22, Math.min(56, em * 0.42));
      fplane = sprite(size, colours.ink, colours.sage, fratio);
      // Runs of neighbouring letters: the start of the file, then its end.
      const groups = [];
      // Only whitespace between two letters keeps them in one run.
      const joined = (a, b) => a.nextElementSibling === b && (a.nextSibling === b || !a.nextSibling.textContent.trim());
      cells.forEach((c, i) => { if (i && joined(letters[i - 1], letters[i])) groups[groups.length - 1].push(c); else groups.push([c]); });
      // The plane cruises well above the letters, so the pieces have air to fall through, and climbs to the top of
      // the air between runs of letters; its wings stay clear of the words above.
      const high = size * 0.55 + 2;
      const cruise = Math.max(high, above - Math.max(size * 0.6, Math.min(above * 0.5, em * 0.7)));
      geo = { em, size, cells, groups, w: across, h: f.height + above, high, cruise, colours };
    };

    // The plane's flight: in from the window's left edge, down to cruise over each run of letters, up over the gaps
    // between them, and out past the right edge. Each waypoint's time follows the distance flown at one speed, so the
    // plane never surges or stalls between them.
    const waypoints = () => {
      const { em, size, groups, w, high, cruise } = geo;
      const pts = [{ x: -size, y: high + (cruise - high) * 0.3 }];
      groups.forEach((g, i) => {
        const left = g[0].left, right = g[g.length - 1].right;
        // The climb between runs is no steeper than the gap is wide, so a short hop on a phone stays smooth.
        if (i) { const end = groups[i - 1][groups[i - 1].length - 1].right; pts.push({ x: (end + left) / 2, y: Math.max(high, cruise - (left - end) * 0.4) }); }
        pts.push({ x: left, y: cruise }, { x: right, y: cruise });
      });
      pts.push({ x: w + size, y: high });
      const speed = Math.max(em * 5, w / 2.4);
      let t = 0;
      pts.forEach((p, i) => { if (i) t += Math.hypot(p.x - pts[i - 1].x, p.y - pts[i - 1].y) / speed; p.t = t; });
      return pts;
    };

    // A smooth curve through the waypoints, by time: each waypoint's velocity is the slope between its neighbours, so
    // the plane keeps an even speed however unevenly the waypoints are spaced.
    const along = (pts, t) => {
      let i = 0;
      while (i < pts.length - 2 && t > pts[i + 1].t) i++;
      const p1 = pts[i], p2 = pts[i + 1], dt = p2.t - p1.t;
      const slope = (k) => {
        const a = pts[Math.max(0, k - 1)], b = pts[Math.min(pts.length - 1, k + 1)];
        return { x: (b.x - a.x) / (b.t - a.t), y: (b.y - a.y) / (b.t - a.t) };
      };
      const m1 = slope(i), m2 = slope(i + 1);
      const u = clamp((t - p1.t) / dt), u2 = u * u, u3 = u2 * u;
      const h00 = 2 * u3 - 3 * u2 + 1, h10 = u3 - 2 * u2 + u, h01 = -2 * u3 + 3 * u2, h11 = u3 - u2;
      return { x: h00 * p1.x + h10 * dt * m1.x + h01 * p2.x + h11 * dt * m2.x, y: h00 * p1.y + h10 * dt * m1.y + h01 * p2.y + h11 * dt * m2.y };
    };

    // A letter starts to fill when its first piece lands, and is full 0.8 s later, easing in and out.
    const fillOf = (cell, t) => {
      if (cell.at === undefined) return 0;
      const x = clamp((t - cell.at - cell.lag) / 0.8);
      return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
    };
    // The top of a letter's fill in the canvas, matching the clip in styles.css: from the letter's foot to its top.
    const level = (cell, f) => cell.top + (cell.base - f * (cell.base - cell.cap)) * cell.h;

    // Everything back as the page has it: letters solid, and the canvas empty and 0 by 0, so a narrower window
    // later never inherits a wide one.
    const finish = () => {
      run = null; primed = false;
      cancelAnimationFrame(fraf); fraf = 0; clearTimeout(waiting);
      letters.forEach((el) => el.style.removeProperty('--fill'));
      fileCanvas.width = 0; fileCanvas.height = 0;
      ['left', 'top', 'width', 'height'].forEach((k) => fileCanvas.style.removeProperty(k));
    };

    const frame = (now) => {
      if (!run) return;
      if (!run.start) {
        run.start = now;
        // The first frame that runs empties the letters; nothing else ever does.
        geo.cells.forEach((c) => { c.at = undefined; c.el.style.setProperty('--fill', '0'); });
      }
      const t = (now - run.start) / 1000;
      const { em, size, cells } = geo;
      const g = 24 * em, piece = Math.max(5, em * 0.07);
      const at = along(run.pts, t), ahead = along(run.pts, t + 0.02);
      fctx.setTransform(fratio, 0, 0, fratio, 0, 0);
      fctx.clearRect(0, 0, geo.w, geo.h);

      // Each letter's pieces leave the plane as it passes over it.
      for (const c of cells) {
        if (c.at === undefined && at.x >= (c.left + c.right) / 2 && t < run.end) {
          c.at = t;
          c.lag = Math.sqrt((2 * Math.max(0, c.top + c.base * c.h - at.y)) / g);
          for (let k = 0; k < 9; k++) run.pieces.push({ c, x: c.left + (0.15 + 0.7 * Math.random()) * (c.right - c.left), y: at.y + size * 0.15, born: t + k * 0.045, spin: Math.random() * 6.28 });
        }
        c.el.style.setProperty('--fill', fillOf(c, t).toFixed(3));
      }

      // Falling pieces, with a short streak above each; a piece is absorbed where the fill has risen to.
      fctx.fillStyle = geo.colours.on;
      fctx.strokeStyle = geo.colours.line;
      run.pieces = run.pieces.filter((p) => {
        const age = t - p.born;
        if (age < 0) return true;
        const y = p.y + 0.5 * g * age * age, v = g * age;
        const floor = level(p.c, fillOf(p.c, t));
        if (y >= floor) return false;
        fctx.globalAlpha = Math.min(1, age * 12);
        fctx.lineWidth = piece * 0.35; fctx.lineCap = 'round';
        fctx.beginPath(); fctx.moveTo(p.x, y - Math.min(v * 0.06, em * 0.25)); fctx.lineTo(p.x, y - piece); fctx.stroke();
        fctx.save(); fctx.translate(p.x, y); fctx.rotate(p.spin + age * 5); fctx.fillRect(-piece / 2, -piece / 2, piece, piece); fctx.restore();
        return true;
      });
      fctx.globalAlpha = 1;

      // The plane, with its sage trail along the way it came.
      if (t < run.end) {
        const alpha = Math.min(clamp(t / 0.15), clamp((run.end - t) / 0.2));
        fctx.lineCap = 'round';
        for (let k = 1; k < 16; k++) {
          const a = along(run.pts, Math.max(0, t - (k - 1) * 0.03)), b = along(run.pts, Math.max(0, t - k * 0.03));
          const fade = 1 - k / 16;
          fctx.globalAlpha = alpha * 0.85 * fade; fctx.lineWidth = Math.max(0.5, size * 0.09 * fade);
          fctx.beginPath(); fctx.moveTo(a.x, a.y); fctx.lineTo(b.x, b.y); fctx.stroke();
        }
        fctx.globalAlpha = alpha;
        fctx.save();
        fctx.translate(at.x, at.y);
        fctx.rotate(Math.atan2(ahead.y - at.y, ahead.x - at.x));
        fctx.drawImage(fplane, -fplane.width / fratio / 2, -fplane.height / fratio / 2, fplane.width / fratio, fplane.height / fratio);
        fctx.restore();
        fctx.globalAlpha = 1;
      }

      const settled = cells.every((c) => c.at !== undefined && t - c.at > c.lag + 0.85) && !run.pieces.length;
      if (t >= run.end && settled) { finish(); return; }
      // A plane that can't finish (it lost its letters, say) doesn't keep the name empty.
      if (t > run.end + 2) { finish(); return; }
      fraf = requestAnimationFrame(frame);
    };

    // Puts emptied letters back, if no plane is filling them.
    const refill = () => { if (run) return; primed = false; clearTimeout(waiting); waiting = 0; letters.forEach((el) => el.style.removeProperty('--fill')); };
    const shown = () => { const r = demo.getBoundingClientRect(); return r.bottom > 0 && r.top < window.innerHeight; };

    // Flies only from emptied letters, so the plane always brings back what was taken.
    const fly = () => {
      if (run) return;
      if (!primed || reduce.matches || document.hidden) { refill(); return; }
      measure();
      if (!geo.groups.length) { finish(); return; }
      armed = false; clearTimeout(waiting); waiting = 0;
      const pts = waypoints();
      run = { pts, end: pts[pts.length - 1].t, pieces: [], start: 0 };
      fraf = requestAnimationFrame(frame);
    };

    // The letters empty while the name is still a third of a window away, out of sight, so nobody sees the pieces
    // leave; if it is already on screen by then, they stay solid and nothing flies this time. The plane flies once
    // most of the name shows, or after a moment once any of it does (someone stopped scrolling at its edge). Out of
    // sight again, the letters wait emptied; once the whole section is well away, they fill again. It flies again only
    // after that.
    const prime = () => requestAnimationFrame(() => {
      if (run || primed || !armed || reduce.matches || document.hidden || shown()) return;
      primed = true;
      letters.forEach((el) => el.style.setProperty('--fill', '0'));
    });
    new IntersectionObserver(([entry]) => { if (entry.isIntersecting) prime(); }, { rootMargin: '35% 0px 35% 0px' }).observe(demo);
    // Re-armed (and refilled) only once the whole section, heading and all, is a third of a window away.
    new IntersectionObserver(([entry]) => { if (!entry.isIntersecting) { armed = true; refill(); } }, { rootMargin: '35% 0px 35% 0px' })
      .observe(demo.closest('section') || demo);
    new IntersectionObserver(([entry]) => {
      if (!primed || run) return;
      if (entry.intersectionRatio >= 0.6) { fly(); return; }
      if (entry.isIntersecting) { if (!waiting) waiting = setTimeout(() => { waiting = 0; if (primed && !run && shown()) fly(); }, 2500); }
      else { clearTimeout(waiting); waiting = 0; }
    }, { threshold: [0, 0.6] }).observe(demo);
    // A hidden tab or reduced motion ends a run at once and never leaves the letters empty.
    document.addEventListener('visibilitychange', () => { if (document.hidden) { if (run) finish(); else refill(); } });
    reduce.addEventListener('change', () => { if (reduce.matches) { if (run) finish(); else refill(); } });
    // A new width moves the letters; a phone's toolbar showing or hiding (a height change) doesn't.
    let across = window.innerWidth;
    window.addEventListener('resize', () => { if (window.innerWidth !== across) { across = window.innerWidth; if (run) finish(); } }, { passive: true });
  }

  // ---------------------------------------------------------------------------
  // "Saves land on your Mac first": once most of the section shows, the save lands on the Mac as a row of pieces
  // ("Saving…", then "Saved" at once), then the plane takes off and the pieces stream after it along the arc into
  // storage, each filling its slot as it lands ("7 of 12 pieces", then "Uploaded"). The page itself shows the finished
  // scene: both rows full, the trail flown and the plane landed. A run empties it only while it is out of sight, like
  // the file name above, and anything that stops a run (a hidden tab, Reduce Motion, a new width) puts it back.
  const arc = document.querySelector('[data-arc]');
  if (arc) {
    const path = arc.querySelector('[data-arc-path]');
    const svg = path.ownerSVGElement;
    const canvas = arc.querySelector('[data-arc-canvas]');
    const state = arc.querySelector('[data-arc-state]');
    const count = arc.querySelector('[data-arc-count]');
    const mac = Array.from(arc.querySelectorAll('[data-arc-mac] i'));
    const cloud = Array.from(arc.querySelectorAll('[data-arc-cloud] i'));
    const N = cloud.length;
    const done = { state: state.textContent, count: count.textContent };
    mac.forEach((el, k) => el.style.setProperty('--k', k));
    const ctx = canvas.getContext('2d');
    let points = [];
    // The timeline, in seconds: the save lands, the plane flies, and piece k leaves the Mac at LEAVE + k * GAP. Pieces
    // cross the arc more slowly than the plane (0.68 of TRAVEL, at an even pace), so they always follow it.
    const SAVED = 0.55, TAKEOFF = 0.8, FLIGHT = 1.5, LEAVE = 0.9, GAP = 0.09, TRAVEL = 2.3;
    const END = LEAVE + (N - 1) * GAP + TRAVEL + 0.35;
    let run = null, raf = 0, primed = false, armed = true, waiting = 0, ratio = 1, plane = null, geo = null;
    const ease = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
    const lerp = (a, b, u) => a + (b - a) * u;

    const measure = () => {
      ratio = Math.min(window.devicePixelRatio || 1, 2);
      const box = arc.getBoundingClientRect(), s = svg.getBoundingClientRect();
      canvas.width = Math.round(box.width * ratio); canvas.height = Math.round(box.height * ratio);
      plane = sprite(40, css('--ink'), css('--sage'), ratio);
      // From layout, not the drawn box: while primed the Mac's pieces are shifted up to land, and the copies must
      // still leave from their slots.
      const centre = (el) => {
        const end = el.closest('.arc-end');
        return { x: end.offsetLeft + el.offsetLeft + el.offsetWidth / 2, y: end.offsetTop + el.offsetTop + el.offsetHeight / 2, size: el.offsetWidth };
      };
      geo = { w: box.width, h: box.height, sx: s.width / 1000, sy: s.height / 220, ox: s.left - box.left, oy: s.top - box.top,
        mac: mac.map(centre), cloud: cloud.map(centre), on: css('--piece-on'), trail: css('--sage-line') };
      // The path leaves from above the middle of the Mac's row and lands above the middle of storage's, so pieces rise
      // straight up into it and settle left to right, in file order, at the other end.
      if (geo.sx > 0 && mac.length && cloud.length) {
        const mid = (row) => (row[0].x + row[row.length - 1].x) / 2;
        const a = (mid(geo.mac) - geo.ox) / geo.sx, b = (mid(geo.cloud) - geo.ox) / geo.sx, pull = (b - a) * 0.258;
        path.setAttribute('d', `M ${a.toFixed(1)} 196 C ${(a + pull).toFixed(1)} 12, ${(b - pull).toFixed(1)} 12, ${b.toFixed(1)} 196`);
      }
      const length = path.getTotalLength();
      points = Array.from({ length: 121 }, (_, k) => path.getPointAtLength((length * k) / 120));
    };
    // A point on the flight path, u from 0 (the Mac) to 1 (storage), in the canvas's coordinates.
    const onArc = (u) => {
      const f = clamp(u) * 120, i = Math.min(119, Math.floor(f)), r = f - i, a = points[i], b = points[i + 1];
      return { x: geo.ox + lerp(a.x, b.x, r) * geo.sx, y: geo.oy + lerp(a.y, b.y, r) * geo.sy };
    };
    const heading = (u) => { const a = onArc(Math.max(0, u - 0.01)), b = onArc(Math.min(1, u + 0.01)); return Math.atan2(b.y - a.y, b.x - a.x); };
    // Piece k on its way: up from its slot on the Mac to the path, along it, and down into its slot in storage.
    const piece = (k, u) => {
      const from = geo.mac[k], to = geo.cloud[k], start = onArc(0), finish = onArc(1);
      if (u < 0.16) { const e = ease(u / 0.16); return { x: lerp(from.x, start.x, e), y: lerp(from.y, start.y, e) - Math.sin(Math.PI * e) * 8, s: lerp(from.size, 8, e) }; }
      if (u > 0.84) { const e = ease((u - 0.84) / 0.16); return { x: lerp(finish.x, to.x, e), y: lerp(finish.y, to.y, e) - Math.sin(Math.PI * e) * 8, s: lerp(8, to.size, e) }; }
      const q = onArc((u - 0.16) / 0.68); return { x: q.x, y: q.y, s: 8 };
    };
    const trail = (upto) => {
      if (upto <= 0) return;
      ctx.lineCap = 'round'; ctx.lineWidth = 2.5; ctx.strokeStyle = geo.trail;
      ctx.beginPath();
      const steps = Math.max(2, Math.round(upto * 120));
      for (let k = 0; k <= steps; k++) { const q = onArc((upto * k) / steps); k ? ctx.lineTo(q.x, q.y) : ctx.moveTo(q.x, q.y); }
      ctx.stroke();
    };
    const stamp = (u) => {
      const q = onArc(u);
      ctx.save(); ctx.translate(q.x, q.y); ctx.rotate(heading(u));
      ctx.drawImage(plane, -plane.width / ratio / 2, -plane.height / ratio / 2, plane.width / ratio, plane.height / ratio);
      ctx.restore();
    };
    // The scene at rest: the whole trail flown and the plane landed at storage (or, primed, waiting at the Mac). Without
    // the script the page shows the trail as the path itself; data-live hands it to the canvas.
    const rest = () => {
      if (!geo) return;
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, geo.w, geo.h);
      if (primed) { stamp(0); return; }
      trail(1); stamp(1);
    };

    const finish = () => {
      run = null; primed = false;
      cancelAnimationFrame(raf); raf = 0; clearTimeout(waiting); waiting = 0;
      delete arc.dataset.phase;
      cloud.forEach((el) => el.classList.remove('on'));
      state.textContent = done.state; count.textContent = done.count;
      rest();
    };

    const frame = (now) => {
      if (!run) return;
      if (!run.start) { run.start = now; arc.dataset.phase = 'run'; }
      const t = (now - run.start) / 1000;
      if (t >= SAVED && state.textContent !== done.state) state.textContent = done.state;
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, geo.w, geo.h);
      const flown = ease(clamp((t - TAKEOFF) / FLIGHT));
      trail(flown);
      ctx.fillStyle = geo.on;
      for (let k = 0; k < N; k++) {
        const u = (t - (LEAVE + k * GAP)) / TRAVEL;
        if (u <= 0) continue;
        if (u >= 1) {
          if (!cloud[k].classList.contains('on')) { cloud[k].classList.add('on'); run.landed++; count.textContent = `${run.landed} of ${N} pieces`; }
          continue;
        }
        const p = piece(k, u);
        ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(u * 5.5 + k);
        ctx.fillRect(-p.s / 2, -p.s / 2, p.s, p.s);
        ctx.restore();
      }
      stamp(flown);
      if (run.landed === N && count.textContent !== done.count && t > END - 0.3) count.textContent = done.count;
      if (t >= END) { finish(); return; }
      raf = requestAnimationFrame(frame);
    };

    const shown = () => { const r = arc.getBoundingClientRect(); return r.bottom > 0 && r.top < window.innerHeight; };
    const fly = () => {
      if (run) return;
      if (!primed || reduce.matches || document.hidden) { finish(); return; }
      armed = false; clearTimeout(waiting); waiting = 0;
      measure();
      run = { start: 0, landed: 0 };
      raf = requestAnimationFrame(frame);
    };
    // Emptied only while out of sight (a third of a window away), so nobody sees the save leave.
    const prime = () => requestAnimationFrame(() => {
      if (run || primed || !armed || reduce.matches || document.hidden || shown()) return;
      primed = true;
      arc.dataset.phase = 'primed';
      state.textContent = 'Saving…'; count.textContent = `0 of ${N} pieces`;
      rest();
    });

    arc.dataset.live = '';
    measure(); rest();
    // A new size puts the finished scene back, whether a run was flying or the scene was primed out of sight.
    new ResizeObserver(() => { if (run || primed) finish(); measure(); rest(); }).observe(arc);
    new IntersectionObserver(([entry]) => { if (entry.isIntersecting) prime(); }, { rootMargin: '35% 0px 35% 0px' }).observe(arc);
    // Re-armed (and put back) only once the whole section is a third of a window away.
    new IntersectionObserver(([entry]) => { if (!entry.isIntersecting) { armed = true; if (!run) finish(); } }, { rootMargin: '35% 0px 35% 0px' })
      .observe(arc.closest('section') || arc);
    new IntersectionObserver(([entry]) => {
      if (!primed || run) return;
      if (entry.intersectionRatio >= 0.6) { fly(); return; }
      if (entry.isIntersecting) { if (!waiting) waiting = setTimeout(() => { waiting = 0; if (primed && !run && shown()) fly(); }, 2500); }
      else { clearTimeout(waiting); waiting = 0; }
    }, { threshold: [0, 0.6] }).observe(arc);
    document.addEventListener('visibilitychange', () => { if (document.hidden && (run || primed)) finish(); });
    reduce.addEventListener('change', () => { if (reduce.matches) finish(); });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { measure(); rest(); });
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
