// Where the files sit on the canvas: a loose, seeded scatter over a world a little larger than the screen, which
// wraps around as the camera drifts, so the canvas never runs out.
import { MEDIA } from "./media.js";

export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export function layoutTiles(W, VH) {
  const small = W < 720;
  const R = rng(11);
  const H = Math.max(VH, 560);
  // Big prints, a quarter to a third of the screen wide on a desktop (half to two thirds on a phone), with room
  // between them and a few overlapping, like a board of work. The world is wide enough that the camera's pan never
  // shows the same print twice.
  const worldW = Math.round(W * (small ? 2.7 : 2.15));
  const worldH = Math.round(H * (small ? 1.55 : 1.38));
  const cols = Math.max(3, Math.round(worldW / (W * (small ? 0.64 : 0.3))));
  const rows = Math.max(3, Math.round(worldH / (H * (small ? 0.3 : 0.46))));
  const cw = worldW / cols, ch = worldH / rows;
  const cells = [];
  for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) cells.push([c, r]);
  for (let i = cells.length - 1; i > 0; i--) { const j = Math.floor(R() * (i + 1)); [cells[i], cells[j]] = [cells[j], cells[i]]; }
  // A few cells stay empty, so the board breathes.
  const count = Math.min(MEDIA.length, Math.round(cells.length * 0.86));
  const tiles = [];
  for (let i = 0; i < count; i++) {
    const m = MEDIA[i];
    const [c, r] = cells[i];
    const big = R() < 0.22;
    let w = cw * (big ? 1.14 + R() * 0.1 : 0.8 + R() * 0.2);
    if (m.aspect < 1) w *= 0.74;
    let h = w / m.aspect;
    const maxH = ch * (big ? 1.25 : 1.02);
    if (h > maxH) { h = maxH; w = h * m.aspect; }
    const x = c * cw + (R() * 1.2 - 0.1) * (cw - w);
    const y = r * ch + (R() * 1.2 - 0.1) * (ch - h);
    tiles.push({ ...m, id: i, wx: x, wy: y, w: Math.round(w), h: Math.round(h), depth: 0.9 + (w / cw) * 0.16 + R() * 0.05, enter: R() * 0.75 });
  }
  // Nearer prints (they drift a little faster) lie on top of farther ones where they overlap.
  tiles.sort((a, b) => a.depth - b.depth);
  return { tiles, worldW, worldH };
}
