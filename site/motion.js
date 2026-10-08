// ParaAir landing motion. Everything is visible without this script; it only adds
// motion to elements already on screen, pauses off-screen and respects reduced motion.
(() => {
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');
  const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

  // ---------------------------------------------------------------------------
  // Hero field: a grid of file pieces. A Glide mark flies through and the pieces
  // it passes light up, then cool down. The pointer lights pieces the same way.
  const canvas = document.querySelector('[data-field]');
  if (canvas) {
    const ctx = canvas.getContext('2d');
    const MARK = [[[0, 150], [454, 0], [316, 298], [244, 208]], [[244, 208], [316, 298], [156, 460], [168, 256]]];
    let cols = 0, rows = 0, pitch = 18, size = 11, energy = new Float32Array(0);
    let width = 0, height = 0, ratio = 1;
    let pointer = null, running = false, last = 0, t = 0.08, phase = 0.6, raf = 0, inView = false;
    let colors = {};

    const measure = () => {
      ratio = window.devicePixelRatio || 1;
      width = canvas.clientWidth; height = canvas.clientHeight;
      canvas.width = Math.round(width * ratio); canvas.height = Math.round(height * ratio);
      pitch = width < 600 ? 17 : 22;
      size = pitch - 8;
      cols = Math.ceil(width / pitch) + 1; rows = Math.ceil(height / pitch) + 1;
      energy = new Float32Array(cols * rows);
      colors = { off: css('--field-off'), on: css('--sage'), ink: css('--ink') };
    };

    const glider = (time) => {
      // A gentle S-curve across the upper part of the hero.
      const x = -0.08 * width + time * width * 1.16;
      const y = height * (0.3 + 0.13 * Math.sin(time * Math.PI * 2 * 0.9 + phase) + 0.05 * Math.sin(time * 9 + phase * 2));
      return { x, y };
    };

    const light = (x, y, radius, strength) => {
      const c0 = Math.max(0, Math.floor((x - radius) / pitch)), c1 = Math.min(cols - 1, Math.ceil((x + radius) / pitch));
      const r0 = Math.max(0, Math.floor((y - radius) / pitch)), r1 = Math.min(rows - 1, Math.ceil((y + radius) / pitch));
      for (let r = r0; r <= r1; r++) {
        for (let c = c0; c <= c1; c++) {
          const dx = c * pitch + size / 2 - x, dy = r * pitch + size / 2 - y;
          const d = Math.sqrt(dx * dx + dy * dy);
          if (d < radius) {
            const i = r * cols + c;
            energy[i] = Math.max(energy[i], (1 - d / radius) * strength);
          }
        }
      }
    };

    const draw = (pos, angle) => {
      ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
      ctx.clearRect(0, 0, width, height);
      for (let r = 0; r < rows; r++) {
        for (let c = 0; c < cols; c++) {
          const e = energy[r * cols + c];
          ctx.globalAlpha = 1;
          ctx.fillStyle = colors.off;
          ctx.fillRect(c * pitch, r * pitch, size, size);
          if (e > 0.02) {
            ctx.globalAlpha = Math.min(1, e);
            ctx.fillStyle = colors.on;
            ctx.fillRect(c * pitch, r * pitch, size, size);
          }
        }
      }
      if (pos) {
        ctx.globalAlpha = 1;
        ctx.save();
        ctx.translate(pos.x, pos.y);
        ctx.rotate(angle);
        const s = width < 600 ? 0.07 : 0.09;
        ctx.scale(s, s);
        ctx.translate(-227, -230);
        MARK.forEach((poly, index) => {
          ctx.beginPath();
          poly.forEach(([px, py], k) => (k ? ctx.lineTo(px, py) : ctx.moveTo(px, py)));
          ctx.closePath();
          ctx.fillStyle = index === 0 ? colors.ink : colors.on;
          ctx.fill();
        });
        ctx.restore();
      }
    };

    const step = (now) => {
      if (!running) return;
      const dt = Math.min(0.05, (now - last) / 1000);
      last = now;
      t += dt / 9.5;
      if (t > 1.05) { t = -0.02; phase = Math.random() * Math.PI * 2; }
      const p = glider(t), q = glider(t + 0.004);
      light(p.x, p.y, width < 600 ? 44 : 62, 1);
      if (pointer) light(pointer.x, pointer.y, width < 600 ? 50 : 72, 0.9);
      for (let i = 0; i < energy.length; i++) if (energy[i] > 0) energy[i] = Math.max(0, energy[i] - dt * 0.42);
      // The mark's nose points up-right (-45°) in its own drawing, so add 45° to fly nose-first.
      draw(p, Math.atan2(q.y - p.y, q.x - p.x) + Math.PI / 4);
      raf = requestAnimationFrame(step);
    };

    const still = () => {
      // Reduced motion: one calm frame showing a finished trail.
      energy.fill(0);
      for (let k = 0; k <= 60; k++) { const p = glider(0.1 + k * 0.011); light(p.x, p.y, 58, 0.25 + k / 80); }
      const p = glider(0.76), q = glider(0.764);
      draw(p, Math.atan2(q.y - p.y, q.x - p.x) + Math.PI / 4);
    };

    const start = () => {
      if (running || reduce.matches) return;
      running = true; last = performance.now(); raf = requestAnimationFrame(step);
    };
    const stop = () => { running = false; cancelAnimationFrame(raf); };
    // Run only while the hero is on screen, the tab is visible and motion is allowed.
    const sync = () => (inView && !document.hidden && !reduce.matches ? start() : stop());

    // Paint a finished trail immediately so the field is never blank, even if animation never runs.
    measure();
    still();
    window.addEventListener('resize', () => { measure(); if (!running) still(); });
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
      colors = { off: css('--field-off'), on: css('--sage'), ink: css('--ink') };
      if (!running) still();
    });
    reduce.addEventListener('change', () => { if (reduce.matches) { stop(); still(); } else sync(); });
    const hero = canvas.parentElement;
    hero.addEventListener('pointermove', (event) => {
      const rect = canvas.getBoundingClientRect();
      pointer = { x: event.clientX - rect.left, y: event.clientY - rect.top };
    });
    hero.addEventListener('pointerleave', () => { pointer = null; });
    new IntersectionObserver(([entry]) => { inView = entry.isIntersecting; sync(); }).observe(hero);
    document.addEventListener('visibilitychange', sync);
  }

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
