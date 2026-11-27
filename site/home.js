// The landing page's motion. Everything is readable without this script.
//   Paintings: every <canvas data-painting> is painted with brush strokes, seeded so it looks the same on every visit.
//     Large ones paint themselves stroke by stroke (underpainting first, details last) the first time they come into
//     view; thumbnails are painted at once. Under reduced motion every canvas is painted in one go.
//   The Finder demo: a cursor selects campfire-night.mov, opens its context menu and opens it; it plays at once,
//     and a jump ahead on the scrub bar plays from there too. It loops only while on screen, and stays still under reduced motion.
//   Reveals: sections below the first screen rise in as they arrive.
(() => {
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');

  // -------------------------------------------------------------------------------------------- paintings
  const rng = (seed) => {
    let a = (seed * 2654435761) >>> 0;
    return () => {
      a = (a + 0x6D2B79F5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  };
  // Smooth value noise and a few octaves of it.
  const noiseOf = (seed) => {
    const hash = (x, y) => {
      let h = (x * 374761393 + y * 668265263 + seed * 1442695041) | 0;
      h = Math.imul(h ^ (h >>> 13), 1274126177);
      return ((h ^ (h >>> 16)) >>> 0) / 4294967296;
    };
    const smooth = (t) => t * t * (3 - 2 * t);
    const n = (x, y) => {
      const xi = Math.floor(x), yi = Math.floor(y), xf = smooth(x - xi), yf = smooth(y - yi);
      const a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1);
      return a + (b - a) * xf + (c - a) * yf + (a - b - c + d) * xf * yf;
    };
    return (x, y, octaves = 3) => {
      let sum = 0, amp = 0.5, f = 1, norm = 0;
      for (let o = 0; o < octaves; o++) { sum += n(x * f, y * f) * amp; norm += amp; amp *= 0.5; f *= 2.03; }
      return sum / norm;
    };
  };
  const hex = (h) => [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)];
  const mixc = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
  const ramp = (stops, t) => {
    t = Math.min(1, Math.max(0, t));
    for (let i = 1; i < stops.length; i++) {
      if (t <= stops[i][0]) { const [t0, c0] = stops[i - 1], [t1, c1] = stops[i]; return mixc(c0, c1, (t - t0) / (t1 - t0 || 1)); }
    }
    return stops[stops.length - 1][1];
  };
  const S = (list) => list.map(([t, h]) => [t, hex(h)]);

  // Each scene: a sky ramp (top to horizon), cloud and hill colours, ground colours by depth, accents, and how the
  // land lies. Colours are the palette of a plein-air sketch: soft, chalky, warm in the light.
  const SCENES = {
    meadow: {
      sky: S([[0, '#8FB6D3'], [0.55, '#BCD3E0'], [1, '#F4E7CF']]), cloud: hex('#FBF6EC'), cloudShade: hex('#C9D2DA'),
      far: S([[0, '#A7B7BC'], [1, '#B9C3AE']]), ground: S([[0, '#A9BC86'], [0.45, '#8FAE72'], [1, '#6F9160']]),
      warm: hex('#D8C58A'), accents: ['#E2735A', '#F1CF66', '#FFFFFF'], horizon: 0.5, hills: 0.09, sun: null,
    },
    dusk: {
      sky: S([[0, '#4E6286'], [0.4, '#B9A0B4'], [0.75, '#EDB08A'], [1, '#F8DDB0']]), cloud: hex('#F6C9A6'), cloudShade: hex('#8E86A3'),
      far: S([[0, '#7D7E9C'], [1, '#9C8E9E']]), ground: S([[0, '#8C8A7C'], [0.5, '#6E7A62'], [1, '#4E5E50']]),
      warm: hex('#E8B27E'), accents: ['#F8D9A0', '#FFE7C2'], horizon: 0.6, hills: 0.07, sun: [0.68, 0.5, '#FFE2B0'],
    },
    river: {
      sky: S([[0, '#A9C9DC'], [0.6, '#CFE0E7'], [1, '#EEEAD9']]), cloud: hex('#FAF8F1'), cloudShade: hex('#BFCCD3'),
      far: S([[0, '#8FA6A0'], [1, '#A6B49C']]), ground: S([[0, '#B3BE84'], [0.5, '#93AA6E'], [1, '#748F5C']]),
      warm: hex('#CDBB7F'), accents: ['#FFFFFF', '#E9DFA8'], horizon: 0.44, hills: 0.12, sun: null, river: true,
    },
    field: {
      sky: S([[0, '#B9CCDB'], [0.7, '#D9E2E4'], [1, '#F2E6D2']]), cloud: hex('#FBF7EF'), cloudShade: hex('#CCD3D8'),
      far: S([[0, '#93A39E'], [1, '#A8B19A']]), ground: S([[0, '#9C91BE'], [0.5, '#8577AE'], [1, '#6E6299']]),
      warm: hex('#B7C38D'), accents: ['#B9A9DD', '#FFFFFF', '#6F8F5E'], horizon: 0.46, hills: 0.06, sun: null, rows: true,
    },
  };

  // The ParaAir mark's faces (the paper plane in logo-mark.svg), far to near, in a 100-unit box.
  const PLANE = [["wingLit", [[93.6, 4], [40.2, 81.1], [6.4, 81.2]]], ["keelLit", [[83.9, 20.7], [40.2, 81.1], [55.1, 96]]], ["wing", [[93.6, 4], [60.8, 76.5], [40.2, 81.1]]]];
  const PAPER_TONES = { wingLit: '#FFFFFF', wing: '#D3D5D9', keelLit: '#5B5F67' };

  // Plan every stroke of a painting, without drawing: a list of [points, width, rgb, alpha] and the extras.
  const plan = (scene, seed, W, H, big) => {
    const R = rng(seed), N = noiseOf(seed), N2 = noiseOf(seed + 7);
    // Each seed lays its own land: the horizon a little higher or lower, the hills taller or flatter.
    const base = SCENES[scene] || SCENES.meadow;
    const sc = { ...base, horizon: base.horizon + (R() - 0.5) * 0.14, hills: base.hills * (0.6 + R() * 0.8) };
    const unit = Math.max(W, H) / 1000;
    const horizonAt = (x) => H * sc.horizon - H * sc.hills * (N(x / W * 2.2 + 3, 0.5, 3) - 0.35) * 2;
    const farAt = (x) => horizonAt(x) - H * 0.05 - H * sc.hills * 1.3 * N2(x / W * 3.4 + 9, 1.5, 4);
    const riverAt = (y) => W * (0.56 + 0.18 * Math.sin(y / H * 5.2 + seed) + 0.06 * (N(1.7, y / H * 3, 2) - 0.5));
    const riverHalf = (y) => W * 0.012 + (y - H * sc.horizon) / H * W * 0.12;
    const region = (x, y) => {
      if (y < farAt(x)) return 'sky';
      if (y < horizonAt(x)) return 'far';
      if (sc.river && Math.abs(x - riverAt(y)) < riverHalf(y)) return 'water';
      return 'ground';
    };
    const cloudiness = (x, y) => Math.max(0, N(x / W * 3.2, y / H * 6.5 + seed * 0.1, 4) - 0.52) * 3.2 * (1 - Math.min(1, y / (H * sc.horizon)) * 0.6);
    const colorAt = (x, y, where) => {
      const j = (N2(x / W * 9, y / H * 9, 2) - 0.5) * 0.28;
      if (where === 'sky') {
        let c = ramp(sc.sky, y / (H * sc.horizon) + j * 0.3);
        if (sc.sun) { const d = Math.hypot(x / W - sc.sun[0], (y / H - sc.sun[1]) * 1.6); c = mixc(c, hex(sc.sun[2]), Math.max(0, 1 - d * 3.2) * 0.85); }
        const cl = Math.min(1, cloudiness(x, y));
        if (cl > 0) {
          const lit = N(x / W * 5 + 2, y / H * 5 - 0.3, 2);
          c = mixc(c, mixc(sc.cloudShade, sc.cloud, Math.min(1, lit * 1.4)), cl);
        }
        return c;
      }
      if (where === 'far') return ramp(sc.far, (y - farAt(x)) / (horizonAt(x) - farAt(x) + 1) + j);
      if (where === 'water') return mixc(ramp(sc.sky, 0.3 + j + (N(x / W * 20, y / H * 4) - 0.5)), [255, 255, 255], 0.12);
      const depth = (y - horizonAt(x)) / (H - horizonAt(x) + 1);
      let c = ramp(sc.ground, depth + j);
      const patch = N(x / W * 4, y / H * 3 + 11, 3);
      if (patch > 0.6) c = mixc(c, sc.warm, Math.min(1, (patch - 0.6) * 3));
      if (sc.rows) { const row = Math.sin((x - W * 0.5) / Math.max(4, y - horizonAt(x) + 4) * 26 * unit + 0.4); c = mixc(c, sc.warm, row > 0.55 ? 0.65 : 0); }
      return c;
    };
    const angleAt = (x, y, where) => {
      if (where === 'sky') return (N(x / W * 2, y / H * 2 + 4, 2) - 0.5) * 1.2 + (cloudiness(x, y) > 0.05 ? (N(x / W * 6, y / H * 6) - 0.5) * 2.2 : 0);
      if (where === 'far') return (N(x / W * 3, y / H * 3) - 0.5) * 0.6 - 0.15;
      if (where === 'water') return Math.PI / 2 + (N(x / W * 8, y / H * 8) - 0.5) * 0.5;
      if (sc.rows) return Math.atan2(y - horizonAt(x), x - W * 0.5) + (N(x / W * 8, y / H * 8) - 0.5) * 0.3;
      return (N(x / W * 3 + 5, y / H * 3, 3) - 0.5) * 1.4 + 0.1;
    };
    const strokes = [];
    const layer = (count, width, length, alpha) => {
      for (let i = 0; i < count; i++) {
        const x = R() * (W + 40) - 20, y = R() * (H + 40) - 20;
        const where = region(Math.max(0, Math.min(W, x)), Math.max(0, Math.min(H, y)));
        const c = colorAt(x, y, where);
        const w = width * (0.7 + R() * 0.6);
        const steps = 5, len = length * (0.7 + R() * 0.6);
        const pts = [[x, y]];
        let px = x, py = y, flip = R() < 0.5 ? -1 : 1;
        for (let s = 0; s < steps; s++) {
          const a = angleAt(px, py, where);
          px += Math.cos(a) * flip * len / steps; py += Math.sin(a) * flip * len / steps;
          pts.push([px, py]);
        }
        const tint = (R() - 0.5) * 18;
        strokes.push([pts, w, [c[0] + tint, c[1] + tint, c[2] + tint * 0.8], alpha * (0.75 + R() * 0.35)]);
      }
    };
    const area = W * H / (unit * unit) / 1000;
    layer(Math.round(area * 1.9), 15 * unit, 70 * unit, 0.55);
    layer(Math.round(area * 4.2), 8 * unit, 34 * unit, 0.62);
    layer(Math.round(area * 7.5), 4 * unit, 17 * unit, 0.7);
    // Accents: flowers in the meadow, glints on water, the last light in the clouds.
    const dots = [];
    const accentCount = Math.round(area * (scene === 'meadow' ? 1.1 : 0.6));
    for (let i = 0; i < accentCount; i++) {
      const x = R() * W, y = R() * H;
      const where = region(x, y);
      if (scene === 'meadow' && where !== 'ground') continue;
      if (scene === 'river' && where !== 'water') continue;
      if (scene === 'dusk' && !(where === 'sky' && cloudiness(x, y) > 0.2)) continue;
      if (scene === 'field' && where !== 'ground') continue;
      const depth = Math.max(0.15, (y - H * sc.horizon) / (H * (1 - sc.horizon)));
      dots.push([x, y, (0.7 + R() * 1.3) * unit * (where === 'sky' ? 1.4 : 0.4 + depth * 1.5), hex(sc.accents[Math.floor(R() * sc.accents.length)]), R() * Math.PI]);
    }
    // The plane flies in the open band of sky above whatever sits on the painting.
    const plane = big ? { x: W * (0.7 + R() * 0.14), y: H * (0.065 + R() * 0.03), size: 28 * unit } : null;
    return { strokes, dots, plane, under: (g) => underpaint(g, W, H, sc, horizonAt) };
  };

  const underpaint = (g, W, H, sc, horizonAt) => {
    const sky = g.createLinearGradient(0, 0, 0, H * sc.horizon);
    sc.sky.forEach(([t, c]) => sky.addColorStop(t, `rgb(${c})`));
    g.fillStyle = sky;
    g.fillRect(0, 0, W, H);
    g.beginPath();
    g.moveTo(0, H);
    for (let x = 0; x <= W; x += W / 40) g.lineTo(x, horizonAt(x));
    g.lineTo(W, H);
    g.closePath();
    const ground = g.createLinearGradient(0, H * sc.horizon, 0, H);
    sc.ground.forEach(([t, c]) => ground.addColorStop(t, `rgb(${c})`));
    g.fillStyle = ground;
    g.fill();
  };

  // One stroke as a loaded brush: a body and three bristle lines, each a touch lighter or darker.
  const brush = (g, [pts, w, c, alpha]) => {
    const line = (dx, dy, width, shade, a) => {
      g.beginPath();
      g.moveTo(pts[0][0] + dx, pts[0][1] + dy);
      for (let i = 1; i < pts.length - 1; i++) {
        const mx = (pts[i][0] + pts[i + 1][0]) / 2, my = (pts[i][1] + pts[i + 1][1]) / 2;
        g.quadraticCurveTo(pts[i][0] + dx, pts[i][1] + dy, mx + dx, my + dy);
      }
      const end = pts[pts.length - 1];
      g.lineTo(end[0] + dx, end[1] + dy);
      g.lineWidth = width;
      g.strokeStyle = `rgba(${Math.round(c[0] + shade)},${Math.round(c[1] + shade)},${Math.round(c[2] + shade)},${a})`;
      g.stroke();
    };
    const [x0, y0] = pts[0], [x1, y1] = pts[pts.length - 1];
    const len = Math.hypot(x1 - x0, y1 - y0) || 1;
    const nx = -(y1 - y0) / len, ny = (x1 - x0) / len;
    line(0, 0, w, 0, alpha);
    line(nx * w * 0.32, ny * w * 0.32, w * 0.28, 14, alpha * 0.55);
    line(-nx * w * 0.3, -ny * w * 0.3, w * 0.24, -16, alpha * 0.5);
    line(nx * w * 0.05, ny * w * 0.05, w * 0.12, 26, alpha * 0.45);
  };

  // The ParaAir plane, folded paper in the painted sky, with a faint trail behind it.
  const drawPlane = (g, { x, y, size }) => {
    g.save();
    g.lineCap = 'round';
    g.setLineDash([size * 0.12, size * 0.22]);
    g.lineWidth = Math.max(1, size * 0.045);
    g.strokeStyle = 'rgba(255,255,255,0.75)';
    g.beginPath();
    g.moveTo(x - size * 4.2, y + size * 1.9);
    g.bezierCurveTo(x - size * 2.8, y + size * 0.4, x - size * 1.8, y + size * 2.1, x - size * 0.5, y + size * 0.7);
    g.stroke();
    g.setLineDash([]);
    g.translate(x, y);
    g.rotate(-0.12);
    const s = size / 100;
    g.scale(s, s);
    g.translate(-50, -50);
    PLANE.forEach(([tone, poly]) => {
      g.beginPath();
      poly.forEach(([px, py], k) => (k ? g.lineTo(px, py) : g.moveTo(px, py)));
      g.closePath();
      g.fillStyle = PAPER_TONES[tone];
      g.shadowColor = 'rgba(40,40,60,0.25)';
      g.shadowBlur = 18;
      g.shadowOffsetY = 10;
      g.fill();
    });
    g.restore();
  };

  // Paper grain: a small tile of specks, laid over the finished painting.
  let grainTile = null;
  const grain = (g, W, H) => {
    if (!grainTile) {
      grainTile = document.createElement('canvas');
      grainTile.width = grainTile.height = 160;
      const t = grainTile.getContext('2d'), R = rng(99);
      for (let i = 0; i < 2600; i++) {
        const light = R() < 0.5;
        t.fillStyle = light ? `rgba(255,255,255,${0.05 + R() * 0.08})` : `rgba(60,50,40,${0.03 + R() * 0.05})`;
        t.fillRect(R() * 160, R() * 160, 1 + R() * 1.2, 1 + R() * 1.2);
      }
    }
    g.save();
    g.fillStyle = g.createPattern(grainTile, 'repeat');
    g.fillRect(0, 0, W, H);
    g.restore();
  };

  const paintCanvas = (canvas, animate) => {
    const box = canvas.getBoundingClientRect();
    const W = Math.max(1, Math.round(box.width)), H = Math.max(1, Math.round(box.height));
    if (W < 4 || H < 4) return null;
    const big = W > 420;
    const ratio = Math.min(window.devicePixelRatio || 1, big ? 1.5 : 2);
    canvas.width = Math.round(W * ratio);
    canvas.height = Math.round(H * ratio);
    canvas.dataset.paintedAt = String(W);
    const g = canvas.getContext('2d');
    g.setTransform(ratio, 0, 0, ratio, 0, 0);
    g.lineCap = 'round';
    g.lineJoin = 'round';
    const job = plan(canvas.dataset.painting, Number(canvas.dataset.seed || 1), W, H, big);
    job.under(g);
    const finish = () => {
      // Accents are dabs, a little wider than tall, laid at a slant like a loaded brush touched once.
      job.dots.forEach(([x, y, r, c, turn]) => { g.fillStyle = `rgba(${c},0.85)`; g.beginPath(); g.ellipse(x, y, r * 1.5, r * 0.75, turn, 0, Math.PI * 2); g.fill(); });
      if (job.plane) drawPlane(g, job.plane);
      grain(g, W, H);
    };
    if (!animate) {
      job.strokes.forEach((s) => brush(g, s));
      finish();
      return null;
    }
    // Coarse to fine over about two and a half seconds.
    let at = 0;
    const per = Math.max(60, Math.ceil(job.strokes.length / 150));
    const frame = () => {
      const end = Math.min(job.strokes.length, at + per);
      for (; at < end; at++) brush(g, job.strokes[at]);
      if (at < job.strokes.length) requestAnimationFrame(frame);
      else finish();
    };
    requestAnimationFrame(frame);
    return null;
  };

  const canvases = [...document.querySelectorAll('canvas[data-painting]')];
  const painted = new WeakSet();
  const io = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting || painted.has(entry.target)) return;
      painted.add(entry.target);
      io.unobserve(entry.target);
      const big = entry.target.getBoundingClientRect().width > 420;
      paintCanvas(entry.target, big && !still.matches);
    });
  }, { rootMargin: '200px 0px' });
  canvases.forEach((c) => io.observe(c));
  // A canvas that changed size a lot is repainted at once, without the brushwork animation.
  let resizeTimer = 0;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(() => {
      canvases.forEach((c) => {
        if (!painted.has(c)) return;
        const w = c.getBoundingClientRect().width, was = Number(c.dataset.paintedAt || 0);
        if (Math.abs(w - was) / (was || 1) > 0.12) paintCanvas(c, false);
      });
    }, 250);
  });

  // -------------------------------------------------------------------------------------------- the archive
  // Years of photos roll slowly past in the window. Now and then one is opened: it is picked, its cloud badge turns
  // into a check as it comes down, and the count of what is on this Mac goes up. Only what was opened takes room.
  const archive = document.querySelector('[data-archive]');
  if (archive) {
    const view = archive.parentElement;
    const local = archive.closest('.win').querySelector('[data-archive-local]');
    const PICS = [['media/snow-peak.webp', 900, 600], ['photos/studio.jpg', 640, 480], ['media/grandma-hug.webp', 900, 602], ['photos/lake.jpg', 640, 480],
      ['media/dad-shoulders.webp', 900, 772], ['photos/podcast.jpg', 640, 480], ['media/banff-lake.webp', 900, 600], ['media/friends-dinner.webp', 900, 600],
      ['media/desert-road.webp', 640, 427], ['photos/interview-b.jpg', 640, 480], ['media/campfire.webp', 640, 360], ['media/red-dress.webp', 640, 434]];
    let built = false, timer = 0, total = 0;
    const build = () => {
      built = true;
      let n = 1312;
      ['2025', '2024', '2022', '2021', '2019'].forEach((year, k) => {
        const label = document.createElement('p'); label.className = 'archive-year'; label.textContent = year;
        const grid = document.createElement('div'); grid.className = 'photo-grid';
        for (let i = 0; i < 8; i++) {
          const [src, w, h] = PICS[(k * 5 + i * 7) % PICS.length];
          const cell = document.createElement('span');
          const img = new Image(w, h); img.src = src; img.alt = ''; img.loading = 'lazy'; img.decoding = 'async';
          const cloud = document.createElement('i'); cloud.className = 'cloud';
          const name = document.createElement('b'); name.textContent = `IMG_${String(n).padStart(4, '0')}.CR3`; n += 3 + ((i * 5) % 7);
          cell.append(img, cloud, name); grid.append(cell);
        }
        archive.append(label, grid);
      });
      // Number every photo, then add a second copy so the roll can loop without a seam; a photo and its copy change together.
      [...archive.querySelectorAll('.photo-grid span')].forEach((cell, i) => { cell.dataset.k = String(i); });
      [...archive.children].forEach((el) => archive.append(el.cloneNode(true)));
      archive.style.setProperty('--roll', `${Math.round(archive.scrollHeight / 2 / 14)}s`);
    };
    const open = () => {
      const v = view.getBoundingClientRect();
      const seen = [...archive.querySelectorAll('.photo-grid span:not(.is-here)')].filter((cell) => { const r = cell.getBoundingClientRect(); return r.top > v.top + 12 && r.bottom < v.bottom - 12; });
      if (!seen.length) return;
      const k = seen[Math.floor(Math.random() * seen.length)].dataset.k;
      const twins = [...archive.querySelectorAll(`[data-k="${k}"]`)];
      twins.forEach((c) => c.classList.add('is-sel'));
      setTimeout(() => {
        twins.forEach((c) => c.classList.add('is-here'));
        total += 41 + Math.floor(Math.random() * 58);
        local.textContent = `${total} MB on this Mac`;
      }, 700);
      setTimeout(() => twins.forEach((c) => c.classList.remove('is-sel')), 1900);
    };
    new IntersectionObserver((entries) => {
      const on = entries[entries.length - 1].isIntersecting && !still.matches;
      if (on && !built) build();
      archive.classList.toggle('is-rolling', on);
      clearInterval(timer);
      if (on) timer = setInterval(open, 2600);
      else if (built) {
        // Off screen it starts over: nothing on this Mac yet.
        archive.querySelectorAll('.is-here, .is-sel').forEach((c) => c.classList.remove('is-here', 'is-sel'));
        total = 0; local.textContent = 'Nothing on this Mac yet';
      }
    }, { threshold: 0.2 }).observe(archive.closest('.card'));
  }

  // -------------------------------------------------------------------------------------------- the terminal
  // Under the project's tree, the real steps type themselves out: clone it, build JuiceFS and the app, and where the
  // app ends up. It plays only while on screen and starts over each time.
  const code = document.querySelector('.art-code .code');
  if (code) {
    const html = code.innerHTML;
    const cut = html.indexOf('<span class="c-p">$</span>');
    const STEPS = [
      ['cmd', 'git clone https://github.com/parafieldai/ParaAir'],
      ['out', "Cloning into 'ParaAir'... done."],
      ['cmd', 'cd ParaAir && scripts/build-juicefs.sh && scripts/build-app.sh'],
      ['out', '▸ JuiceFS: pinned, verified, built'],
      ['out', '▸ ParaAir.app'],
      ['ok', '.build/xcode/Build/Products/Release/ParaAir.app'],
    ];
    let run = 0, live = false;
    const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
    const play = async (me) => {
      while (live && me === run) {
        code.innerHTML = html.slice(0, cut);
        const caret = document.createElement('span'); caret.className = 't-caret';
        for (const [kind, text] of STEPS) {
          if (!live || me !== run) return;
          const line = document.createElement('span');
          if (kind === 'cmd') {
            const sign = document.createElement('span'); sign.className = 'c-p'; sign.textContent = '$ ';
            const typed = document.createElement('span'); typed.className = 't-cmd';
            line.append(sign, typed, caret); code.append(line);
            await sleep(500);
            for (let i = 1; i <= text.length; i++) { if (!live || me !== run) return; typed.textContent = text.slice(0, i); await sleep(26 + Math.random() * 40); }
            await sleep(380);
          } else {
            line.className = kind === 'ok' ? 't-ok' : 'c-dim'; line.textContent = text;
            code.append(line);
            await sleep(kind === 'ok' ? 500 : 650);
          }
          code.append('\n');
        }
        const sign = document.createElement('span'); sign.className = 'c-p'; sign.textContent = '$ ';
        code.append(sign, caret);
        await sleep(4200);
      }
    };
    if (cut > 0) new IntersectionObserver((entries) => {
      const on = entries[entries.length - 1].isIntersecting && !still.matches;
      if (on && !live) { live = true; run++; play(run); }
      else if (!on) { live = false; run++; }
    }, { threshold: 0.3 }).observe(code);
  }

  // -------------------------------------------------------------------------------------------- the edit window
  // A real edit plays in the viewer: interview A, the campfire as cutaway, interview B. The playhead runs along the
  // timeline with it, over the clip that is playing, and the timecode counts in frames. It plays only while on screen.
  const edit = document.querySelector('.win-edit');
  if (edit) {
    const video = edit.querySelector('[data-edit-video]');
    const tc = edit.querySelector('[data-edit-tc]');
    const head = edit.querySelector('.edit-head');
    const box = edit.querySelector('.edit');
    const clips = [...edit.querySelectorAll('.edit-track:not(.edit-audio) .edit-clip')];
    const CUTS = [0, 6, 11, 16]; // where each clip starts and the edit ends, in seconds
    const two = (n) => String(n).padStart(2, '0');
    let raf = 0, shown = false;
    const place = () => {
      const t = Math.min(CUTS[3] - 0.001, video.currentTime || 0);
      const i = t < CUTS[1] ? 0 : t < CUTS[2] ? 1 : 2;
      const b = box.getBoundingClientRect(), c = clips[i].getBoundingClientRect();
      const x = c.left - b.left + ((t - CUTS[i]) / (CUTS[i + 1] - CUTS[i])) * c.width;
      head.style.left = x.toFixed(1) + 'px';
      const s = Math.floor(t);
      tc.textContent = `00:00:${two(s)}:${two(Math.floor((t - s) * 24))}`;
      clips.forEach((el, k) => el.classList.toggle('is-live', k === i));
    };
    const loop = () => { place(); raf = shown && !still.matches ? requestAnimationFrame(loop) : 0; };
    new IntersectionObserver((entries) => {
      shown = entries[entries.length - 1].isIntersecting;
      if (shown && !still.matches) {
        const p = video.play(); if (p && p.catch) p.catch(() => {});
        if (!raf) raf = requestAnimationFrame(loop);
      } else { video.pause(); place(); }
    }, { threshold: 0.2 }).observe(edit);
    place();
  }

  // -------------------------------------------------------------------------------------------- the Finder demo
  const finder = document.querySelector('[data-finder]');
  if (finder) {
    const target = finder.querySelector('[data-target]');
    const menu = finder.querySelector('[data-menu]');
    const open = finder.querySelector('[data-menu-open]');
    const player = finder.querySelector('[data-player]');
    const cursor = finder.querySelector('[data-cursor]');
    const track = finder.querySelector('[data-track]');
    const fill = finder.querySelector('[data-fill]');
    const knob = finder.querySelector('[data-knob]');
    const time = finder.querySelector('[data-time]');
    const badge = finder.querySelector('[data-play-badge]');
    // The clip really plays while the player is open, and jumps when the pointer does.
    const clip = finder.querySelector('[data-clip]');
    const roll = (from) => { if (!clip) return; try { clip.currentTime = from; } catch (e) { /* not loaded yet */ } const p = clip.play(); if (p && p.catch) p.catch(() => {}); };
    const halt = () => { if (clip) clip.pause(); };
    const LENGTH = 28 * 60 + 12;
    let visible = false, wakeUp = null, run = 0;

    const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const whenVisible = () => (visible ? Promise.resolve() : new Promise((resolve) => { wakeUp = resolve; }));
    const local = (el, fx = 0.5, fy = 0.5) => {
      const f = finder.getBoundingClientRect(), r = el.getBoundingClientRect();
      return [r.left - f.left + r.width * fx, r.top - f.top + r.height * fy];
    };
    const point = ([x, y], ms) => {
      cursor.style.transition = ms ? `transform ${ms}ms cubic-bezier(.45,.05,.2,1), opacity .3s` : 'opacity .3s';
      cursor.style.transform = `translate(${x}px, ${y}px)`;
    };
    // The scrub bar: where the clip is, as a share of its 28:12, and the time under it.
    const at = (seconds, jump) => {
      const share = Math.min(1, seconds / LENGTH) * 100;
      fill.classList.toggle('is-jump', !!jump); knob.classList.toggle('is-jump', !!jump);
      fill.style.width = share + '%'; knob.style.left = share + '%';
      const s = Math.floor(seconds);
      time.textContent = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
    };
    const reset = () => {
      target.classList.remove('is-selected');
      menu.classList.remove('is-open');
      open.classList.remove('is-active');
      player.classList.remove('is-open');
      cursor.classList.remove('is-on');
      badge.classList.remove('is-hidden');
      halt();
      at(0);
    };

    const loop = async (me) => {
      const alive = () => me === run;
      while (alive()) {
        await whenVisible();
        if (!alive()) return;
        reset();
        const f = finder.getBoundingClientRect();
        point([f.width * 0.86, f.height * 0.9], 0);
        await sleep(500);
        cursor.classList.add('is-on');
        await sleep(400);
        const thumb = local(target.querySelector('.f-thumb'));
        point(thumb, 1200);
        await sleep(1350);
        if (!alive()) return;
        target.classList.add('is-selected');
        await sleep(420);
        // The context menu opens at the pointer, kept inside the window.
        const mw = menu.offsetWidth, mh = menu.offsetHeight;
        const mx = Math.min(thumb[0] + 6, f.width - mw - 10), my = Math.max(10, Math.min(thumb[1] + 4, f.height - mh - 10));
        menu.style.transform = '';
        menu.style.left = mx + 'px';
        menu.style.top = my + 'px';
        menu.classList.add('is-open');
        await sleep(560);
        point(local(open, 0.3, 0.5), 520);
        await sleep(620);
        open.classList.add('is-active');
        await sleep(380);
        if (!alive()) return;
        menu.classList.remove('is-open');
        open.classList.remove('is-active');
        player.classList.add('is-open');
        // It plays at once; then the cursor jumps ahead on the scrub bar, and it plays from there.
        await sleep(650);
        badge.classList.add('is-hidden');
        roll(0);
        let clock = 0;
        const play = async (from, ms) => { const t0 = performance.now(); while (alive() && performance.now() - t0 < ms) { at(from + (performance.now() - t0) / 1000); await sleep(100); } return from + ms / 1000; };
        clock = await play(0, 1400);
        point(local(track, 0.62, 0.5), 900);
        clock = await play(clock, 1000);
        if (!alive()) return;
        at(LENGTH * 0.62, true);
        roll(clip && clip.duration ? clip.duration * 0.62 : 49);
        clock = await play(LENGTH * 0.62, 2600);
        point([f.width * 0.8, f.height * 0.86], 900);
        await sleep(500);
        if (!alive()) return;
        player.classList.remove('is-open');
        halt();
        cursor.classList.remove('is-on');
        target.classList.remove('is-selected');
        await sleep(1400);
      }
    };
    const start = () => { run++; if (!still.matches) loop(run); else { reset(); target.classList.add('is-selected'); } };
    new IntersectionObserver((entries) => {
      visible = entries[entries.length - 1].isIntersecting;
      if (visible && wakeUp) { const w = wakeUp; wakeUp = null; w(); }
    }, { threshold: 0.35 }).observe(finder);
    still.addEventListener('change', start);
    start();
  }

  // -------------------------------------------------------------------------------------------- posters
  // The clips below the first screen fetch their poster frame only as they come near, so the first load stays light.
  const posters = [...document.querySelectorAll('video[data-poster]')];
  const setPoster = (v) => { if (!v.poster) v.poster = v.dataset.poster; };
  if ('IntersectionObserver' in window) {
    const near = new IntersectionObserver((entries) => entries.forEach((e) => { if (e.isIntersecting) { setPoster(e.target); near.unobserve(e.target); } }), { rootMargin: '600px 0px' });
    posters.forEach((v) => near.observe(v));
  } else posters.forEach(setPoster);

  // -------------------------------------------------------------------------------------------- reveals
  if (!still.matches && 'IntersectionObserver' in window) {
    const fold = window.innerHeight * 0.92;
    const items = [...document.querySelectorAll('.reveal')].filter((el) => el.getBoundingClientRect().top > fold);
    const seen = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-in');
        seen.unobserve(entry.target);
      });
    }, { rootMargin: '0px 0px -8% 0px' });
    items.forEach((el) => {
      const siblings = [...el.parentElement.children].filter((c) => c.classList.contains('reveal'));
      el.style.transitionDelay = `${Math.min(siblings.indexOf(el), 4) * 70}ms`;
      el.classList.add('will-reveal');
      seen.observe(el);
    });
    // Anything that takes focus shows at once, so a key never lands on something still faded out.
    document.addEventListener('focusin', (e) => {
      const el = e.target.closest && e.target.closest('.will-reveal:not(.is-in)');
      if (el) { el.style.transitionDelay = '0ms'; el.classList.add('is-in'); seen.unobserve(el); }
    });
  }
})();
