// The hero's camera and the plane's flight, as pure functions of story time (seconds).
// The camera pans across the canvas on its own calm schedule and comes to rest before the Mac appears. The plane's
// route is set by where it should be on screen at a few moments: those become world positions through the camera, a
// smooth curve joins them, and the plane moves along it at a speed that rises gently, cruises and slows to a stop only
// as it touches down on the Mac. Its forward motion never reverses and never pauses, so there are no loops, no circles
// and no stops in mid-air.

export const T = {
  fly: 0, // the plane waits on the canvas from the start and moves only as the reader scrolls
  cam0: 0.8, cam1: 11.4, // the camera's pan
  pick0: 5.8, pick1: 10.0, // files the plane passes lift into its wake
  mac: 10.8, // the Mac fades in
  demo: 11.2, // the drive window opens on its screen
  touch: 13.6, // the plane touches down on the lid
  copy: 15.4, // the headline
};
export const STORY = 17.2;

export const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
export const smooth = (a, b, x) => { const u = clamp((x - a) / (b - a)); return u * u * (3 - 2 * u); };
export const lerp = (a, b, t) => a + (b - a) * t;

// Distance 0..1 over time 0..1: the speed eases up over the first `a`, holds, and eases down over the last `b`.
export function glide(u, a, b) {
  u = clamp(u);
  const v = 1 / (1 - a / 2 - b / 2);
  const ramp = (x) => x * x * x - (x * x * x * x) / 2;
  if (u < a) return v * a * ramp(u / a);
  if (u > 1 - b) return 1 - v * b * ramp((1 - u) / b);
  return v * (a / 2 + (u - a));
}

// A curve through (ts[i], ys[i]) with no overshoot between points (Fritsch-Carlson). `m0`, `m1`: end slopes.
function monotone(ts, ys, m0, m1) {
  const n = ts.length, d = [], m = new Array(n).fill(0);
  for (let i = 0; i < n - 1; i++) d.push((ys[i + 1] - ys[i]) / (ts[i + 1] - ts[i]));
  for (let i = 1; i < n - 1; i++) {
    if (d[i - 1] * d[i] <= 0) continue;
    const h0 = ts[i] - ts[i - 1], h1 = ts[i + 1] - ts[i];
    m[i] = (3 * (h0 + h1)) / ((2 * h1 + h0) / d[i - 1] + (h1 + 2 * h0) / d[i]);
  }
  m[0] = m0 == null ? d[0] : m0;
  m[n - 1] = m1 == null ? d[n - 2] : m1;
  const f = (t) => {
    if (t <= ts[0]) return ys[0] + m[0] * (t - ts[0]);
    if (t >= ts[n - 1]) return ys[n - 1];
    let i = 0;
    while (t > ts[i + 1]) i++;
    const h = ts[i + 1] - ts[i], s = (t - ts[i]) / h, s2 = s * s, s3 = s2 * s;
    return (2 * s3 - 3 * s2 + 1) * ys[i] + (s3 - 2 * s2 + s) * h * m[i] + (-2 * s3 + 3 * s2) * ys[i + 1] + (s3 - s2) * h * m[i + 1];
  };
  f.slopes = m;
  return f;
}

// A smooth curve through points, measured so at(s) is the point s pixels along it.
function route(points) {
  const n = points.length, P = (i) => points[Math.max(0, Math.min(n - 1, i))];
  const raw = [], at = [0];
  for (let i = 0; i < n - 1; i++) {
    const p0 = P(i - 1), p1 = P(i), p2 = P(i + 1), p3 = P(i + 2);
    for (let k = 0; k < 40; k++) {
      const t = k / 40, t2 = t * t, t3 = t2 * t;
      const c = (a0, a1, a2, a3) => 0.5 * (2 * a1 + (-a0 + a2) * t + (2 * a0 - 5 * a1 + 4 * a2 - a3) * t2 + (-a0 + 3 * a1 - 3 * a2 + a3) * t3);
      raw.push([c(p0[0], p1[0], p2[0], p3[0]), c(p0[1], p1[1], p2[1], p3[1])]);
    }
  }
  raw.push(points[n - 1]);
  const len = [0];
  for (let i = 1; i < raw.length; i++) len.push(len[i - 1] + Math.hypot(raw[i][0] - raw[i - 1][0], raw[i][1] - raw[i - 1][1]));
  for (let i = 1; i < n; i++) at.push(len[i * 40]);
  const total = len[len.length - 1];
  const point = (s) => {
    if (s <= 0) { const d = [raw[1][0] - raw[0][0], raw[1][1] - raw[0][1]], l = Math.hypot(...d) || 1; return [raw[0][0] + (d[0] / l) * s, raw[0][1] + (d[1] / l) * s]; }
    if (s >= total) return raw[raw.length - 1];
    let lo = 0, hi = len.length - 1;
    while (hi - lo > 1) { const mid = (lo + hi) >> 1; if (len[mid] < s) lo = mid; else hi = mid; }
    const u = (s - len[lo]) / (len[hi] - len[lo] || 1);
    return [lerp(raw[lo][0], raw[hi][0], u), lerp(raw[lo][1], raw[hi][1], u)];
  };
  return { point, at, total };
}

// `rest`: where the plane comes to rest on the Mac's lid, and `spout`: the point above the middle of the lid where its
// wake turns into a stream falling straight down into the Mac, both in stage pixels once the camera has stopped.
// The plane's forward motion is one speed curve: it enters already gliding, cruises, then slows evenly all the way
// down to the lid, so it never stops in mid-air and never turns back. Its height follows a curve drawn over the
// ground it covers (one height for each step forward), so the flight is a single wave with no loops: level over the
// canvas, then over the Mac through the spout and down onto the lid.
export function makeFlight({ W, VH, rest, spout }) {
  const small = W < 720;
  const camX = W * (small ? 1.0 : 0.75);
  const camAt = (t) => {
    const p = glide((t - T.cam0) / (T.cam1 - T.cam0), 0.14, 0.3);
    return [camX * p, VH * (0.05 * Math.sin(Math.PI * p) - 0.02 * Math.sin(2 * Math.PI * p))];
  };
  const end = camAt(T.touch);
  // Forward: from where it waits on the canvas at the start to the lid at T.touch, cruising at V, then slowing evenly
  // from `slow` (speed V(1 - u^2)) so it settles onto the lid without creeping.
  const x0 = camAt(T.fly)[0] + W * (small ? 0.2 : 0.22), x1 = end[0] + rest[0], slow = 7.4;
  const span = T.touch - slow;
  const V = (x1 - x0) / (slow - T.fly + (span * 2) / 3);
  const ahead = (t) => {
    if (t <= slow) return x0 + V * (t - T.fly);
    if (t >= T.touch) return x1;
    const u = (t - slow) / span;
    return x0 + V * (slow - T.fly) + V * span * (u - (u * u * u) / 3);
  };
  // Height: where the plane should be on screen at a few moments, taken over to the ground it has covered by then.
  // A slow climb in, a long glide that rises a little, level with the spout, then down onto the lid.
  const heights = small
    ? [[T.fly, 0.6], [2.4, 0.57], [4.6, 0.53], [6.8, 0.49], [8.6, (spout[1] / VH) - 0.01]]
    : [[T.fly, 0.56], [2.4, 0.5], [4.6, 0.44], [6.8, 0.37], [8.6, (spout[1] / VH) - 0.01]];
  const xs = end[0] + spout[0];
  const pts = heights.map(([t, y]) => [ahead(t), camAt(t)[1] + y * VH]).filter((q) => q[0] < xs - W * 0.02);
  pts.push([xs, end[1] + spout[1]]);
  pts.push([x1, end[1] + rest[1]]);
  const fy = monotone(pts.map((q) => q[0]), pts.map((q) => q[1]), 0, null);
  // Level out a little just before touching down.
  const n = pts.length, lastSlope = (pts[n - 1][1] - pts[n - 2][1]) / (pts[n - 1][0] - pts[n - 2][0]);
  fy.slopes[n - 1] = lastSlope * 0.35;
  const planeWorld = (t) => { const x = ahead(t); return [x, fy(x)]; };
  // When the plane passes over the spout.
  let lo = T.fly, hi = T.touch;
  for (let i = 0; i < 40; i++) { const mid = (lo + hi) / 2; if (ahead(mid) < xs) lo = mid; else hi = mid; }
  const spoutT = (lo + hi) / 2;
  return { camAt, planeWorld, camEnd: end, small, V, spoutT };
}
