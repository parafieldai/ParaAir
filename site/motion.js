// ParaAir landing motion. Everything is visible without this script; it only adds
// motion to elements already on screen, pauses off-screen and respects reduced motion.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  // ---------------------------------------------------------------------------
  // The airflow: two twisted ribbons of fine dots, slate and sage, the same field the Mac app draws behind its
  // headers. The ParaAir plane flies along the slate ribbon; the dots it passes are pieces arriving, and light up
  // sage before they cool. The pointer lights them the same way. The ribbons are drawn once to a bitmap; each frame
  // only repaints the lit pieces and the plane.
  // Each [data-airflow] canvas gets its own field; data-plane="off" leaves the plane out (the pointer still lights pieces).
  const airflow = (canvas) => {
    const flies = canvas.dataset.plane !== 'off';
    const ctx = canvas.getContext('2d');
    const MARK = [[[0, 150], [454, 0], [316, 298], [244, 208]], [[244, 208], [316, 298], [156, 460], [168, 256]]];
    const RIBBONS = [
      { base: 0.5, amp: 0.2, phase: 0.35, width: 0.05, swell: 0.3, twist: 1.1, per: 20, tone: '--ribbon-a' },
      { base: 0.56, amp: 0.16, phase: 2.2, width: 0.03, swell: 0.18, twist: 2.7, per: 11, tone: '--ribbon-b' },
    ];
    const CELL = 24;
    let width = 0, height = 0, ratio = 1, count = 0;
    let xs, ys, sizes, energy, buckets = new Map(), active = [];
    let base = document.createElement('canvas');
    let lit = '79 138 115';
    let pointer = null, running = false, last = 0, t = 0, raf = 0, inView = false;

    const random = (seed) => () => {
      seed |= 0; seed = (seed + 0x6D2B79F5) | 0;
      let r = Math.imul(seed ^ (seed >>> 15), 1 | seed);
      r = (r + Math.imul(r ^ (r >>> 7), 61 | r)) ^ r;
      return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
    };
    // Narrow screens flatten the curve, so one wave across a phone doesn't read as a knot.
    const centre = (ribbon, x) =>
      height * (ribbon.base + ribbon.amp * (width < 640 ? 0.6 : 1) * Math.sin((2 * Math.PI * x) / width + ribbon.phase));

    const build = () => {
      ratio = Math.min(window.devicePixelRatio || 1, 2);
      width = canvas.clientWidth; height = canvas.clientHeight;
      canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
      base.width = canvas.width; base.height = canvas.height;
      const scale = width < 640 ? 0.55 : 1;
      count = RIBBONS.reduce((sum, ribbon) => sum + Math.round(width * ribbon.per * scale), 0);
      xs = new Float32Array(count); ys = new Float32Array(count); sizes = new Float32Array(count);
      energy = new Float32Array(count); active = []; buckets = new Map();
      const next = random(flies ? 9 : 23);
      const bctx = base.getContext('2d');
      bctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      bctx.clearRect(0, 0, width, height);
      let index = 0;
      for (const ribbon of RIBBONS) {
        const tone = css(ribbon.tone);
        const n = Math.round(width * ribbon.per * scale);
        for (let k = 0; k < n; k++, index++) {
          const x = next() * width;
          const angle = (2 * Math.PI * x) / width;
          const half = (height * (ribbon.width + ribbon.swell * Math.abs(Math.sin(angle + ribbon.twist)))) / 2;
          const across = next() * 2 - 1;
          const y = centre(ribbon, x) + across * half;
          // Denser and brighter toward a ribbon's edges, as a turned surface catches light.
          const alpha = (0.14 + 0.5 * next()) * (0.45 + 0.55 * across * across);
          const size = 0.7 + 0.7 * next();
          xs[index] = x; ys[index] = y; sizes[index] = size;
          bctx.fillStyle = `rgb(${tone} / ${alpha.toFixed(3)})`;
          bctx.fillRect(x - size / 2, y - size / 2, size, size);
          const key = Math.floor(x / CELL) + ',' + Math.floor(y / CELL);
          if (!buckets.has(key)) buckets.set(key, []);
          buckets.get(key).push(index);
        }
      }
      lit = css('--piece-on-rgb') || lit;
    };

    const light = (x, y, radius, strength) => {
      const c0 = Math.floor((x - radius) / CELL), c1 = Math.floor((x + radius) / CELL);
      const r0 = Math.floor((y - radius) / CELL), r1 = Math.floor((y + radius) / CELL);
      for (let r = r0; r <= r1; r++) {
        for (let c = c0; c <= c1; c++) {
          const list = buckets.get(c + ',' + r);
          if (!list) continue;
          for (const i of list) {
            const d = Math.hypot(xs[i] - x, ys[i] - y);
            if (d >= radius) continue;
            const e = (1 - d / radius) * strength;
            if (e > energy[i]) { if (energy[i] === 0) active.push(i); energy[i] = e; }
          }
        }
      }
    };

    // The plane rides the slate ribbon's centre line from just off the left edge to just off the right.
    const flight = (time) => {
      const x = -0.06 * width + time * width * 1.12;
      return { x, y: centre(RIBBONS[0], x) };
    };

    const draw = (time) => {
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, width, height);
      ctx.drawImage(base, 0, 0, width, height);
      // Lit pieces, in six steps of brightness so each step is one fill.
      const levels = [[], [], [], [], [], []];
      for (const i of active) levels[Math.min(5, Math.floor(energy[i] * 6))].push(i);
      levels.forEach((list, level) => {
        if (!list.length) return;
        ctx.fillStyle = `rgb(${lit} / ${(((level + 1) / 6) * 0.9).toFixed(2)})`;
        for (const i of list) { const s = sizes[i] + 0.6; ctx.fillRect(xs[i] - s / 2, ys[i] - s / 2, s, s); }
      });
      if (time === null || !flies) return;
      const p = flight(time), q = flight(time + 0.003);
      ctx.save();
      ctx.translate(p.x, p.y);
      // The mark's nose points up and to the right (-45 degrees) in its own drawing; turn it to fly nose first.
      ctx.rotate(Math.atan2(q.y - p.y, q.x - p.x) + Math.PI / 4);
      const s = width < 640 ? 0.06 : 0.078;
      ctx.scale(s, s);
      ctx.translate(-227, -230);
      MARK.forEach((poly, index) => {
        ctx.beginPath();
        poly.forEach(([px, py], k) => (k ? ctx.lineTo(px, py) : ctx.moveTo(px, py)));
        ctx.closePath();
        ctx.fillStyle = index === 0 ? css('--ink') : css('--sage');
        ctx.fill();
      });
      ctx.restore();
    };

    const cool = (dt) => {
      const kept = [];
      for (const i of active) { energy[i] = Math.max(0, energy[i] - dt * 0.7); if (energy[i] > 0) kept.push(i); }
      active = kept;
    };

    const step = (now) => {
      if (!running) return;
      if (!xs) { raf = requestAnimationFrame(step); return; }
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      t += dt / 11;
      if (t > 1.04) t = -0.04;
      const p = flight(t);
      if (flies) light(p.x, p.y, width < 640 ? 30 : 38, 1);
      if (pointer) light(pointer.x, pointer.y, width < 640 ? 44 : 60, 0.85);
      cool(dt);
      draw(t);
      // A band without the plane rests once its pieces have cooled and the pointer has left; the pointer wakes it.
      if (!flies && !pointer && active.length === 0) { running = false; return; }
      raf = requestAnimationFrame(step);
    };

    // One calm frame: the plane two thirds across, the pieces behind it lit and cooling with distance.
    const still = () => {
      if (!xs) return;
      energy.fill(0); active = [];
      if (flies) for (let k = 0; k <= 30; k++) { const p = flight(0.39 + k * 0.01); light(p.x, p.y, 36, 0.12 + k / 36); }
      t = 0.69;
      draw(t);
    };

    const start = () => {
      if (running || reduce.matches) return;
      running = true; last = performance.now(); raf = requestAnimationFrame(step);
    };
    const stop = () => { running = false; cancelAnimationFrame(raf); };
    // Run only while the field is on screen, the tab is visible and motion is allowed.
    const sync = () => (inView && !document.hidden && !reduce.matches ? start() : stop());

    // Paint the still frame as soon as the canvas has a size, so the field is never blank even if animation never
    // runs; rebuild whenever its size changes.
    const rebuild = () => {
      if (!canvas.clientWidth || !canvas.clientHeight) return;
      if (canvas.clientWidth === width && canvas.clientHeight === height && xs) return;
      build();
      if (!running) still();
    };
    rebuild();
    let resizeTimer = 0;
    new ResizeObserver(() => { clearTimeout(resizeTimer); resizeTimer = setTimeout(rebuild, 60); }).observe(canvas);
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (width) { build(); if (!running) still(); } });
    reduce.addEventListener('change', () => { if (reduce.matches) { stop(); still(); } else sync(); });
    canvas.parentElement.addEventListener('pointermove', (event) => {
      const rect = canvas.getBoundingClientRect();
      pointer = { x: event.clientX - rect.left, y: event.clientY - rect.top };
      sync();
    });
    canvas.parentElement.addEventListener('pointerleave', () => { pointer = null; });
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; sync(); }).observe(canvas);
    document.addEventListener('visibilitychange', sync);
  };
  document.querySelectorAll('[data-airflow]').forEach(airflow);

  // ---------------------------------------------------------------------------
  // "Big files open in pieces": build the file, and drop the opened pieces each
  // time the scene comes into view.
  const row = document.querySelector('[data-file-row]');
  if (row) {
    const sizeRow = () => {
      const count = window.innerWidth < 560 ? 12 : 18;
      if (row.childElementCount !== count) {
        row.replaceChildren();
        const picks = count === 18 ? [4, 5, 6, 12, 13] : [3, 4, 8];
        for (let i = 0; i < count; i++) {
          const piece = document.createElement('span');
          piece.className = 'piece' + (picks.includes(i) ? ' pick' : '');
          if (picks.includes(i)) piece.style.setProperty('--k', String(picks.indexOf(i)));
          row.append(piece);
        }
        row.style.setProperty('--count', String(count));
      }
      const first = row.firstElementChild;
      if (first) row.style.setProperty('--s', first.getBoundingClientRect().width + 'px');
    };
    sizeRow();
    window.addEventListener('resize', sizeRow);
  }

  const scenes = document.querySelectorAll('[data-scene], .access');
  const access = document.querySelector('.access');
  if (access && !reduce.matches) access.classList.add('is-armed');
  if ('IntersectionObserver' in window) {
    const observer = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) entry.target.classList.add('is-in');
        else if (entry.target.dataset.scene !== undefined) entry.target.classList.remove('is-in');
      }
    }, { threshold: 0.45 });
    scenes.forEach((scene) => observer.observe(scene));
  } else {
    scenes.forEach((scene) => scene.classList.add('is-in'));
  }
})();
