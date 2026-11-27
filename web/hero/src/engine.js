// The hero's story, played by scrolling. The hero is a tall section with a pinned stage; how far it has scrolled sets
// the story's time, eased so a flick of the wheel still glides like video. Scroll back and it plays backwards: every
// frame is worked out from the time alone, nothing piles up. Timings are in flight.js.
//   0 s          the canvas of big prints fades in with the paper plane waiting on it and the clips playing, no
//                words; nothing else moves until the reader scrolls (with a mouse the canvas can be dragged about).
//                The download stays in the header bar, and a key that puts focus in the headline shows it at once.
//   0 - 6 s      the plane flies through the canvas, the camera with it, so the prints stream past
//   6 - 10 s     each print the plane passes lifts off into particles of its own colours and joins the plane's wake
//   10 - 13.6 s  the canvas comes to rest, the Mac fades in, the last prints join the wake; the plane passes over
//                the Mac and its wake falls from there straight down onto the top of the lid in one stream, as the
//                files drop into the drive on its screen (MacDemo.jsx); the plane glides on down to rest on the lid.
//                Nothing enters or covers the screen.
//   15.4 s       only now the headline appears, over the Mac; the screen plays the demo
// The page below never waits for the story: scrolling past the hero is ordinary scrolling, and the story simply stops
// where the reader left it. Reduced motion: no pinning, the end straight away.
import { createPlane, REST_POSE, SIZE } from "./plane.js";
import { store } from "./store.js";
import { T, STORY, clamp, smooth, lerp, makeFlight } from "./flight.js";

export { T, STORY };
const LID = 232 / 2540; // the transparent margin above the laptop's lid in the artwork (site/media/laptop.svg)
const easeInOut = (x) => (x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2);
const wrap = (v, m) => ((v % m) + m) % m;
const TS = 0.02, TR = 140; // the wake: where the plane was every 20 ms over the last 2.8 s
const FALL = 0.75; // seconds a particle takes to fall from the spout onto the lid

export function startHero({ hero, stage, copy, tileEls, layout, canvas, planeWrap, planeSvg, mac, sound }) {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)");
  const ctx = canvas.getContext("2d");
  const drawPlane = createPlane(planeSvg);
  const tiles = layout.tiles.map((t, i) => ({ ...t, el: tileEls[i], sx: 0, sy: 0, loaded: false }));
  tiles.forEach((tl) => { tl.media = tl.el.querySelector("img, video"); });
  // A print's picture is fetched only when it first comes near the screen. A clip plays while its print shows and
  // the hero is in view, from the moment the page opens. Nothing plays under reduced motion.
  const loadMedia = (tl) => {
    tl.loaded = true;
    const m = tl.media;
    if (!m) return;
    if (m.tagName === "VIDEO") { m.poster = tl.poster; m.src = tl.src; } else m.src = tl.src;
  };
  const playMedia = (tl, on) => {
    const v = tl.media;
    if (!v || v.tagName !== "VIDEO") return;
    if (on && v.paused) { const p = v.play(); if (p && p.catch) p.catch(() => {}); }
    else if (!on && !v.paused) v.pause();
  };
  const stopAll = () => tiles.forEach((tl) => playMedia(tl, false));

  // ------------------------------------------------------------------ geometry
  let W = 0, VH = 0, L = [0, 0], rest = [0, 0], spout = [0, 0], macBox = null, F = null, fit = 1, landScale = 0.46, plan = null;
  const measure = () => {
    const sr = stage.getBoundingClientRect();
    W = stage.clientWidth; VH = stage.clientHeight;
    const ratio = Math.min(window.devicePixelRatio || 1, 1.5);
    canvas.width = Math.round(W * ratio); canvas.height = Math.round(VH * ratio);
    ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    const mr = mac.getBoundingClientRect();
    const lidTop = mr.top - sr.top + mr.height * LID;
    macBox = { x: mr.left - sr.left, y: lidTop, w: mr.width, h: mr.height * (1 - LID) };
    L = [mr.left - sr.left + mr.width / 2, lidTop - 3];
    // The plane rests on the right of the lid; its wake pours into the middle from well above it.
    rest = [L[0] + mr.width * 0.2, lidTop - Math.max(20, mr.width * 0.034)];
    spout = [L[0], lidTop - VH * (W < 720 ? 0.16 : 0.2)];
    fit = clamp(W / 1100, 0.62, 1);
    landScale = clamp(mr.width / 1450, 0.3, 0.5);
    F = makeFlight({ W, VH, rest, spout });
    plan = null;
  };

  // ------------------------------------------------------------------ the prints on the canvas
  // `pan` is how far the reader has dragged the canvas; it moves the prints only, never the plane.
  let pan = [0, 0];
  const tileAt = (tile, cam) => {
    const offX = (layout.worldW - W) / 2, offY = (layout.worldH - VH) / 2;
    return [wrap(tile.wx - cam[0] * tile.depth + pan[0] + offX, layout.worldW) - offX, wrap(tile.wy - cam[1] * tile.depth + pan[1] + offY, layout.worldH) - offY];
  };
  // The plane's wake nudges prints aside a little; worked out from where it is now and a moment ago.
  const wakeOf = (cx, cy, size, plane, scale) => {
    const dx = cx - plane[0], dy = cy - plane[1], d = Math.hypot(dx, dy), reach = 120 * scale + size / 2;
    if (d >= reach) return [0, 0];
    const push = Math.pow(1 - d / reach, 2) * 22 * scale;
    return [(dx / (d || 1)) * push, (dy / (d || 1)) * push];
  };

  // ------------------------------------------------------------------ the plan: when each print lifts off, and its particles
  const sampleTile = (tile, cols, rows) => {
    const c = document.createElement("canvas");
    c.width = cols; c.height = rows;
    const g = c.getContext("2d", { willReadFrequently: true });
    let ok = false;
    try {
      const media = tile.el.querySelector("video, img");
      if (media && ((media.tagName === "VIDEO" && media.readyState >= 2) || (media.tagName === "IMG" && media.complete && media.naturalWidth))) {
        // Cover-crop, as the print shows it.
        const mw = media.videoWidth || media.naturalWidth, mh = media.videoHeight || media.naturalHeight;
        const k = Math.max(cols / mw, rows / mh), dw = mw * k, dh = mh * k;
        g.drawImage(media, (cols - dw) / 2, (rows - dh) / 2, dw, dh);
        ok = true;
      }
    } catch (e) { ok = false; }
    if (!ok) {
      const pal = tile.palette || ["#E8E8E6", "#C9CACD", "#141518"];
      for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
        const r = Math.sin(x * 12.9898 + y * 78.233 + tile.id) * 43758.5453, v = r - Math.floor(r);
        g.fillStyle = v < 0.62 ? pal[0] : pal[1 + Math.floor(((v - 0.62) / 0.38) * (pal.length - 1))] || pal[1];
        g.fillRect(x, y, 1, 1);
      }
    }
    return g.getImageData(0, 0, cols, rows).data;
  };
  const planeOnScreen = (t) => { const w = F.planeWorld(t), c = F.camAt(t); return [w[0] - c[0], w[1] - c[1]]; };
  const ensurePlan = () => {
    if (plan) return plan;
    const camEnd = F.camEnd;
    const shows = (tl, cam, m = 0) => { const [x, y] = tileAt(tl, cam); return x + tl.w > m && x < W - m && y + tl.h > m && y < VH - m; };
    const overMac = (tl, cam) => { const [x, y] = tileAt(tl, cam); return x + tl.w > macBox.x - 18 && x < macBox.x + macBox.w + 18 && y + tl.h > macBox.y - 24 && y < macBox.y + macBox.h; };
    const lift = new Map();
    // First, the prints the plane passes close by lift off as it goes past them.
    tiles.forEach((tl) => {
      let best = Infinity, when = 0;
      for (let t = T.pick0; t <= T.pick1; t += 0.05) {
        const cam = F.camAt(t);
        if (!shows(tl, cam, 60)) continue;
        const [x, y] = tileAt(tl, cam), [px, py] = planeOnScreen(t);
        const d = Math.hypot(Math.max(x - px, 0, px - x - tl.w), Math.max(y - py, 0, py - y - tl.h));
        if (d < best) { best = d; when = t; }
      }
      if (best < W * 0.06) lift.set(tl, when - 0.2);
    });
    // Then every print still in view as the canvas comes to rest joins the wake too, nearest the plane first; any
    // where the Mac will appear go before it does, so nothing seems to come from behind it.
    const cams = [F.camAt(T.pick1), F.camAt(T.mac - 0.5), camEnd];
    const rest1 = tiles.filter((tl) => !lift.has(tl) && cams.some((c) => shows(tl, c, 20)));
    const p0 = planeOnScreen(T.pick1);
    const dist = (tl) => { const [x, y] = tileAt(tl, F.camAt(T.pick1)); return Math.hypot(x + tl.w / 2 - p0[0], y + tl.h / 2 - p0[1]); };
    const blocks = (tl) => overMac(tl, cams[1]) || overMac(tl, camEnd);
    const blocking = rest1.filter(blocks).sort((a, b) => dist(a) - dist(b));
    const others = rest1.filter((tl) => !blocks(tl)).sort((a, b) => dist(a) - dist(b));
    blocking.forEach((tl, i) => lift.set(tl, lerp(T.pick1 - 0.5, T.mac - 0.5, blocking.length > 1 ? i / (blocking.length - 1) : 0)));
    others.forEach((tl, i) => lift.set(tl, lerp(T.pick1, T.touch - 2.2, others.length > 1 ? i / (others.length - 1) : 0)));
    tiles.forEach((tl) => { const p = lift.get(tl); if (p !== undefined && p > T.mac - 0.5 && blocks(tl)) lift.set(tl, T.mac - 0.5); });

    const chosen = [...lift].sort((a, b) => a[1] - b[1]);
    const area = chosen.reduce((s, [tl]) => s + tl.w * tl.h, 0);
    const cell = Math.max(6, Math.sqrt(area / (W < 720 ? 1500 : 2800)));
    const list = [];
    chosen.forEach(([tl, p]) => {
      const cols = Math.max(3, Math.round(tl.w / cell)), rows = Math.max(3, Math.round(tl.h / cell));
      const data = sampleTile(tl, cols, rows);
      const cw = tl.w / cols, chh = tl.h / rows;
      // The print comes apart from the corner nearest the plane.
      const [tx, ty] = tileAt(tl, F.camAt(p)), [px, py] = planeOnScreen(p);
      const far = Math.hypot(tl.w, tl.h);
      for (let y = 0; y < rows; y++) for (let x = 0; x < cols; x++) {
        const o = (y * cols + x) * 4;
        let r = data[o], g = data[o + 1], b = data[o + 2];
        const lum = 0.3 * r + 0.59 * g + 0.11 * b;
        if (lum > 232) { const k = 232 / lum; r *= k; g *= k; b *= k; }
        const rnd = (n) => { const v = Math.sin((x + 1) * 91.7 + (y + 1) * 47.3 + tl.id * 13.1 + n * 7.7) * 9999; return v - Math.floor(v); };
        const ox = (x + 0.5) * cw, oy = (y + 0.5) * chh;
        const near = Math.hypot(tx + ox - px, ty + oy - py) / far;
        const go = p + 0.1 + clamp(near, 0, 1.2) * 0.5 + rnd(1) * 0.25;
        const dur = 1.15 + rnd(2) * 0.6;
        // A print that lifts off late still reaches the stream before it has fallen all the way.
        const lag = Math.max(0.22 + Math.pow(rnd(3), 1.7) * 2.3, go + dur - F.spoutT - FALL * 0.45);
        list.push({
          tile: tl, ox, oy, size: Math.min(cw, chh) * 0.92, dot: 1.5 + rnd(4) * 1.3, big: Math.min(1, (tl.w * tl.h) / (W * VH * 0.12)),
          key: ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4),
          p, go, dur, lag, side: rnd(5) + rnd(6) - 1, ph: rnd(7) * 6.283, rise: 18 + rnd(8) * 30,
        });
      }
    });
    const groups = new Map();
    list.forEach((q) => { if (!groups.has(q.key)) groups.set(q.key, []); groups.get(q.key).push(q); });
    const hex = (k) => `rgb(${((k >> 8) & 15) * 17},${((k >> 4) & 15) * 17},${(k & 15) * 17})`;
    const fade = new Map(chosen);
    tiles.forEach((tl) => { if (!fade.has(tl)) fade.set(tl, T.mac - 0.6); });
    plan = { fade, lifted: new Set(chosen.map(([tl]) => tl)), minLag: list.reduce((m, q) => Math.min(m, q.lag), 9), groups: [...groups].map(([k, ps]) => ({ color: hex(k), ps })), total: list.length };
    return plan;
  };

  // ------------------------------------------------------------------ drawing one moment
  const trail = new Float32Array(TR * 2), norm = new Float32Array(TR * 2);
  // The wake is a soft comet: narrow just behind the plane, opening out and thinning away behind it.
  const wideAt = (lag) => (3 + 17 * Math.pow(Math.min(1, lag / 2.2), 0.7)) * fit;
  const wakePoint = (lag, off, out) => {
    const k = clamp(lag / TS, 0, TR - 1.001), i = Math.floor(k), f = k - i;
    const x = lerp(trail[2 * i], trail[2 * i + 2], f), y = lerp(trail[2 * i + 1], trail[2 * i + 3], f);
    out[0] = x + norm[2 * i] * off; out[1] = y + norm[2 * i + 1] * off;
    return out;
  };
  const pt = [0, 0];
  const headingAt = (t) => { const a = F.planeWorld(t - 0.14), b = F.planeWorld(t + 0.14); return Math.atan2(b[1] - a[1], b[0] - a[0]); };

  // Everything on screen is worked out from the story's time `t`, so nothing moves unless the reader scrolls.
  // `shown` 0..1 is the canvas fading in once when the page opens.
  const render = (t, shown) => {
    const cam = F.camAt(t);
    const view = cam;

    // The plane on screen.
    const world = F.planeWorld(t);
    const landed = smooth(T.touch - 0.6, T.touch, t);
    // A little rise and fall in the air as it goes, which settles as it lands.
    const bob = Math.sin(t * 2.1) * 5 * (1 - landed);
    const px = world[0] - view[0], py = world[1] - view[1] + bob;
    const scale = lerp(fit * lerp(0.95, 1.2, smooth(T.fly, T.fly + 2, t)), landScale, smooth(T.cam1 - 1.4, T.touch, t));
    const aim = 1 - smooth(T.touch - 1.3, T.touch - 0.1, t);
    const h0 = headingAt(t - 0.16), h1 = headingAt(t + 0.16);
    const bank = clamp(Math.atan2(Math.sin(h1 - h0), Math.cos(h1 - h0)) * 90, -24, 24) * aim;
    const pose = { yaw: REST_POSE.yaw + 4 * Math.sin(t * 1.3) * (1 - landed), pitch: REST_POSE.pitch + 3 * Math.sin(t * 1.9) * (1 - landed), roll: REST_POSE.roll + bank };
    const nose = drawPlane(pose);
    // In flight the plane points where it is going; coming in to land it eases back to its resting pose, nose up.
    const want = ((headingAt(t) - nose) * 180) / Math.PI;
    const rot = (((want + 540) % 360) - 180) * aim;
    planeWrap.style.opacity = shown.toFixed(3);
    planeWrap.style.transform = `translate3d(${(px - SIZE / 2).toFixed(1)}px,${(py - SIZE / 2).toFixed(1)}px,0) rotate(${rot.toFixed(2)}deg) scale(${scale.toFixed(3)})`;

    // No words to begin with: the headline appears only once the plane has landed. Until then it can't be clicked,
    // but it stays in the page for screen readers, and a key that puts focus in it shows it at once (on a card while
    // it sits over the prints), like a skip link.
    const words = keyFocus ? 1 : smooth(T.copy, T.copy + 0.9, t);
    copy.style.opacity = words.toFixed(3);
    copy.style.transform = `translateY(${((1 - words) * 16).toFixed(1)}px)`;
    copy.style.pointerEvents = words > 0.5 ? "" : "none";
    copy.classList.toggle("hx-card", keyFocus && t < T.mac);

    // The prints.
    const p = t > T.pick0 - 0.4 ? ensurePlan() : null;
    const prevWorld = F.planeWorld(t - 0.14);
    const prevPlane = [prevWorld[0] - view[0], prevWorld[1] - view[1]];
    const flying = t < T.touch - 0.4;
    for (const tile of tiles) {
      const [sx, sy] = tileAt(tile, view);
      tile.sx = sx; tile.sy = sy;
      let ox = 0, oy = 0;
      if (flying) {
        const a = wakeOf(sx + tile.w / 2, sy + tile.h / 2, Math.max(tile.w, tile.h), [px, py], scale);
        const b = wakeOf(sx + tile.w / 2, sy + tile.h / 2, Math.max(tile.w, tile.h), prevPlane, scale);
        ox = (a[0] + b[0]) * 0.6; oy = (a[1] + b[1]) * 0.6;
      }
      const appear = smooth(tile.enter * 0.5, tile.enter * 0.5 + 0.6, shown * 1.0);
      const f = p && p.fade.has(tile) ? p.fade.get(tile) : Infinity;
      const gone = f === Infinity ? 0 : smooth(f, f + 0.4, t);
      const alpha = appear * (1 - gone);
      tile.el.style.opacity = alpha.toFixed(3);
      tile.el.style.visibility = alpha < 0.005 ? "hidden" : "visible";
      const shows = alpha >= 0.005 && sx + tile.w > 0 && sx < W && sy + tile.h > 0 && sy < VH;
      const near = alpha >= 0.005 && sx + tile.w > -160 && sx < W + 160 && sy + tile.h > -160 && sy < VH + 160;
      if (near && !tile.loaded) loadMedia(tile);
      playMedia(tile, shows && visible && !still.matches);
      tile.el.style.transform = `translate3d(${(sx + ox).toFixed(1)}px,${(sy + oy).toFixed(1)}px,0) rotate(${(ox * 0.05).toFixed(2)}deg) scale(${(0.95 + 0.05 * appear - 0.03 * gone).toFixed(3)})`;
    }

    // Where the plane has been, kept in the world so it streams away behind it as the canvas moves.
    for (let k = 0; k < TR; k++) {
      const w = F.planeWorld(t - k * TS);
      trail[2 * k] = w[0] - view[0];
      trail[2 * k + 1] = w[1] - view[1] + (k < 20 ? bob * (1 - k / 20) : 0);
    }
    let nx = 0, ny = -1;
    for (let k = 0; k < TR; k++) {
      const a = Math.max(0, k - 1), b = Math.min(TR - 1, k + 1);
      const dx = trail[2 * a] - trail[2 * b], dy = trail[2 * a + 1] - trail[2 * b + 1], l = Math.hypot(dx, dy);
      if (l > 0.01) { nx = -dy / l; ny = dx / l; }
      norm[2 * k] = nx; norm[2 * k + 1] = ny;
    }

    ctx.clearRect(0, 0, W, VH);
    ctx.lineCap = "round";
    if (t < T.touch + 0.4) {
      const fadeLine = 1 - smooth(T.touch - 0.6, T.touch + 0.3, t);
      for (let k = 1; k < 60; k++) {
        if (t - k * TS < T.fly + 0.05) break;
        const life = 1 - k / 60;
        ctx.strokeStyle = `rgba(20,21,24,${(0.2 * life * life * fadeLine).toFixed(3)})`;
        ctx.lineWidth = 0.6 + 1.6 * life;
        ctx.beginPath(); ctx.moveTo(trail[2 * k - 2], trail[2 * k - 1]); ctx.lineTo(trail[2 * k], trail[2 * k + 1]); ctx.stroke();
      }
    }

    // The particles: off each print, up into the wake, along it behind the plane, and once past the spout, straight
    // down in one stream onto the top of the Mac.
    let arrived = 0;
    if (p) {
      const sw = F.planeWorld(F.spoutT), sx0 = sw[0] - view[0], sy0 = sw[1] - view[1];
      // The stream leaves the spout still moving the way the plane was, and arcs over into its fall, like water
      // poured from something moving: a curve from the spout, out along the plane's heading, down to the lid.
      const sa = F.planeWorld(F.spoutT - 0.06), sb = F.planeWorld(F.spoutT + 0.06), sl = Math.hypot(sb[0] - sa[0], sb[1] - sa[1]) || 1;
      const reach = Math.min(70 * fit, (L[1] - sy0) * 0.45);
      const cx1 = sx0 + ((sb[0] - sa[0]) / sl) * reach, cy1 = sy0 + ((sb[1] - sa[1]) / sl) * reach;
      const lip = 6 * fit;
      for (const group of p.groups) {
        ctx.fillStyle = group.color;
        for (const q of group.ps) {
          if (t < q.p) continue;
          const u = (t - q.go) / q.dur;
          const ox = q.tile.sx + q.ox, oy = q.tile.sy + q.oy;
          if (u <= 0) { const s = q.size; ctx.fillRect(ox - s / 2, oy - s / 2, s, s); continue; }
          const lag = q.lag;
          const tau = t - lag;
          const fall = (tau - F.spoutT) / FALL;
          if (u >= 1 && fall >= 1) { arrived++; continue; }
          // Across the wake: where in its width this particle rides, with a slow wave running back through it.
          const wave = Math.sin(lag * 5.5 - t * 1.6 + q.ph) * 3.5 * fit * Math.min(1, lag / 1.2);
          let rx, ry, alpha = 1 - smooth(1.3, 2.6, lag) * 0.8;
          if (fall <= 0) { wakePoint(lag, q.side * wideAt(lag) + wave, pt); rx = pt[0]; ry = pt[1]; }
          else {
            // Falling, a little faster as it goes. The wake bends over into the stream like a ribbon: each particle
            // keeps its place across it, which narrows from the wake's width to the lid's.
            const f = Math.min(1, fall), g = f * (0.55 + 0.45 * f), h = 1 - g;
            const tx = 2 * h * (cx1 - sx0) + 2 * g * (L[0] - cx1), ty = 2 * h * (cy1 - sy0) + 2 * g * (L[1] - cy1), tl = Math.hypot(tx, ty) || 1;
            const across = q.side * lerp(wideAt(lag), lip, g) + wave * h;
            rx = h * h * sx0 + 2 * h * g * cx1 + g * g * L[0] - (ty / tl) * across;
            ry = h * h * sy0 + 2 * h * g * cy1 + g * g * L[1] + (tx / tl) * across;
            alpha *= 1 - smooth(0.8, 1, f);
          }
          let x = rx, y = ry, s = q.dot;
          if (u < 1) {
            const e = easeInOut(u);
            x = lerp(ox, rx, e); y = lerp(oy, ry, e) - Math.sin(Math.PI * e) * q.rise;
            s = lerp(q.size, q.dot, smooth(0, 0.45, u));
          }
          if (alpha < 0.01) continue;
          if (alpha < 1) ctx.globalAlpha = alpha;
          ctx.fillRect(x - s / 2, y - s / 2, s, s);
          if (alpha < 1) ctx.globalAlpha = 1;
        }
      }
    }

    latestArrived = arrived;
    if (t >= T.mac) mac.classList.remove("hx-off"); else mac.classList.add("hx-off");
    const chapter = t < 1.4 ? 0 : t < 6.2 ? 1 : t < 10.2 ? 2 : t < T.copy ? 3 : 0;
    const grabbable = canGrab();
    if (grabbable !== stage.classList.contains("is-grab")) stage.classList.toggle("is-grab", grabbable);
    store.set({
      phase: t >= T.demo ? "demo" : "canvas",
      arrived: p ? Math.round((arrived / (p.total || 1)) * 24) / 24 : 0,
      chapter, hint: shown > 0.6 && t < 0.35 ? 1 : 0,
    });
  };

  // ------------------------------------------------------------------ time: the scroll, eased
  let t = 0, raf = 0, visible = true, last = 0, latestArrived = 0, keyFocus = false;
  const start = performance.now();
  const progress = () => {
    const r = hero.getBoundingClientRect();
    const span = hero.offsetHeight - window.innerHeight;
    return span > 0 ? clamp(-r.top / span) : 1;
  };
  // The story's time is only ever where the scroll puts it: no part of it plays by itself. It reaches its end at
  // 90% of the hero's scroll; the last stretch holds the finished scene, the headline over the Mac.
  const target = () => Math.min(1, progress() / 0.9) * STORY;
  const frame = (now) => {
    const dt = last ? Math.min((now - last) / 1000, 1 / 20) : 1 / 60;
    last = now;
    // A drag let go keeps gliding, slowing like a print slid across a table.
    if (!grab && (vel[0] || vel[1])) {
      pan = [pan[0] + vel[0] * dt, pan[1] + vel[1] * dt];
      const k = Math.exp(-dt / 0.32);
      vel = [vel[0] * k, vel[1] * k];
      if (Math.hypot(vel[0], vel[1]) < 6) vel = [0, 0];
      plan = null;
    }
    // Ease towards where the scroll says, never faster than the story can look calm: a quick flick of the wheel
    // still plays out as a glide.
    const goal = target();
    const step = (goal - t) * (1 - Math.exp(-dt / 0.5));
    const before = t;
    t += clamp(step, -dt * 1.6, dt * 1.6);
    if (Math.abs(goal - t) < 0.0005) t = goal;
    const shown = smooth(0, 1.1, (now - start) / 1000);
    render(t, shown);
    cue(before, t);
    // Stop drawing once everything has come to rest; a scroll, a drag or a resize starts it again.
    const busy = t !== goal || shown < 1 || grab || vel[0] || vel[1];
    raf = busy && visible && !still.matches ? requestAnimationFrame(frame) : 0;
  };
  // The sound effects follow the story forwards only: a print lifting off, the stream reaching the lid, the plane
  // touching down, the drive filling up. Scrolling back is quiet.
  let poured = false, touched = false, filled = false, lastArrived = 0;
  const cue = (from, to) => {
    if (!sound || !sound.on || !plan) { lastArrived = latestArrived; return; }
    if (to > from) {
      for (const [tl, p] of plan.fade) if (plan.lifted.has(tl) && p > from && p <= to) sound.lift(Math.min(1, (tl.w * tl.h) / (W * VH * 0.12)));
      const first = F.spoutT + plan.minLag;
      if (!poured && from < first && to >= first) { poured = true; sound.pour(); }
      if (!touched && from < T.touch && to >= T.touch) { touched = true; sound.land(); }
      if (latestArrived > lastArrived) sound.grains(latestArrived - lastArrived);
      if (!filled && latestArrived >= plan.total && plan.total > 0) { filled = true; sound.done(); }
    }
    if (to < F.spoutT) poured = false;
    if (to < T.touch) touched = false;
    if (latestArrived < plan.total) filled = false;
    lastArrived = latestArrived;
  };
  const wake = () => { if (!raf && visible && !still.matches) { last = 0; raf = requestAnimationFrame(frame); } };

  const showEnd = () => {
    cancelAnimationFrame(raf); raf = 0;
    stopAll();
    hero.classList.remove("hx-scroll");
    measure();
    tiles.forEach((tl) => { tl.el.style.opacity = "0"; tl.el.style.visibility = "hidden"; });
    mac.classList.remove("hx-off");
    ctx.clearRect(0, 0, W, VH);
    copy.style.opacity = ""; copy.style.transform = ""; copy.style.pointerEvents = ""; copy.inert = false; copy.classList.remove("hx-card");
    drawPlane(REST_POSE);
    planeWrap.style.opacity = "1";
    planeWrap.style.transform = `translate3d(${(rest[0] - SIZE / 2).toFixed(1)}px,${(rest[1] - SIZE / 2).toFixed(1)}px,0) scale(${landScale.toFixed(3)})`;
    store.set({ phase: "demo", arrived: 1, still: true, chapter: 0, hint: 0 });
  };

  // Before the story starts the canvas can be dragged about with a mouse or pen, and it glides on when let go.
  // Touch keeps scrolling the page.
  let grab = null, vel = [0, 0];
  function canGrab() { return t < 0.6 && !still.matches; }
  const onDown = (e) => {
    if (e.pointerType === "touch" || e.button !== 0 || !canGrab() || e.target.closest("a, button, .hero-copy")) return;
    grab = { id: e.pointerId, x: e.clientX, y: e.clientY, at: performance.now() };
    vel = [0, 0];
    stage.setPointerCapture(e.pointerId);
    stage.classList.add("is-grabbing");
    e.preventDefault();
    wake();
  };
  const onMove = (e) => {
    if (!grab || e.pointerId !== grab.id) return;
    const now = performance.now(), dt = Math.max(8, now - grab.at) / 1000;
    const dx = e.clientX - grab.x, dy = e.clientY - grab.y;
    pan = [pan[0] + dx, pan[1] + dy];
    vel = [lerp(vel[0], dx / dt, 0.6), lerp(vel[1], dy / dt, 0.6)];
    grab.x = e.clientX; grab.y = e.clientY; grab.at = now;
    plan = null;
    wake();
  };
  const onUp = (e) => {
    if (!grab || e.pointerId !== grab.id) return;
    if (performance.now() - grab.at > 90) vel = [0, 0];
    const cap = 2600, sp = Math.hypot(vel[0], vel[1]);
    if (sp > cap) vel = [(vel[0] / sp) * cap, (vel[1] / sp) * cap];
    grab = null;
    stage.classList.remove("is-grabbing");
    wake();
  };
  const noDrag = (e) => { if (canGrab()) e.preventDefault(); };
  stage.addEventListener("pointerdown", onDown);
  stage.addEventListener("pointermove", onMove);
  stage.addEventListener("pointerup", onUp);
  stage.addEventListener("pointercancel", onUp);
  stage.addEventListener("dragstart", noDrag);

  let resizeTimer = 0;
  const onResize = () => { clearTimeout(resizeTimer); resizeTimer = setTimeout(() => { measure(); if (still.matches) showEnd(); else wake(); }, 150); };
  window.addEventListener("resize", onResize);
  const io = new IntersectionObserver((entries) => {
    visible = entries[entries.length - 1].isIntersecting;
    store.set({ inView: visible });
    if (visible) wake(); else stopAll();
  }, { threshold: 0 });
  io.observe(hero);
  const onScroll = () => wake();
  window.addEventListener("scroll", onScroll, { passive: true });
  // Focus put in the headline from the keyboard keeps it showing (see render).
  const onFocus = () => {
    const el = document.activeElement;
    const next = !!el && copy.contains(el) && el.matches(":focus-visible");
    if (next !== keyFocus) { keyFocus = next; if (still.matches) return; render(t, 1); wake(); }
  };
  // Focus leaving the headline is read once it has landed wherever it went.
  let focusTimer = 0;
  const onFocusOut = () => { clearTimeout(focusTimer); focusTimer = setTimeout(onFocus, 0); };
  copy.addEventListener("focusin", onFocus);
  copy.addEventListener("focusout", onFocusOut);

  measure();
  // A page opened (or restored) partway down starts the story where the scroll is, rather than playing up to it.
  t = target();
  if (still.matches) showEnd();
  else wake();
  const onMotion = () => { if (still.matches) showEnd(); else { hero.classList.add("hx-scroll"); store.set({ still: false }); measure(); wake(); } };
  still.addEventListener("change", onMotion);

  return {
    destroy() {
      cancelAnimationFrame(raf); io.disconnect();
      window.removeEventListener("resize", onResize); window.removeEventListener("scroll", onScroll); still.removeEventListener("change", onMotion);
      copy.removeEventListener("focusin", onFocus); copy.removeEventListener("focusout", onFocusOut);
      clearTimeout(focusTimer); clearTimeout(resizeTimer); stopAll();
      stage.removeEventListener("pointerdown", onDown); stage.removeEventListener("pointermove", onMove);
      stage.removeEventListener("pointerup", onUp); stage.removeEventListener("pointercancel", onUp); stage.removeEventListener("dragstart", noDrag);
      stage.classList.remove("is-grab", "is-grabbing");
    },
  };
}
