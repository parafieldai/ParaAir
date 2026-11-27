// The ParaAir paper dart in 3D (the same model as site/logo-mark.svg), re-projected through an
// isometric camera on every frame. Faces are shaded by how squarely they meet the light, so nothing pops as the plane
// banks and turns; outer corners are rounded and outer edges bowed, folds stay straight.

const DART = { nose: [118, 0, 0], spineTail: [-62, 0, 0], leftTip: [-70, 64, 13], rightTip: [-70, -64, 13], keelTail: [-56, 0, -40], keelNose: [82, 0, -3] };
const R = Math.PI / 180;
const AZ = 45 * R, EL = 30 * R;
const sinA = Math.sin(AZ), cosA = Math.cos(AZ), sinE = Math.sin(EL), cosE = Math.cos(EL);
const TO_VIEWER = [cosA * cosE, sinA * cosE, sinE];
const LIGHT = (() => { const v = [cosA * 0.3 - sinA * 0.9, sinA * 0.3 + cosA * 0.9, 0.55]; const l = Math.hypot(...v); return v.map((c) => c / l); })();
const SOFT = { left: [[7, 5, 0], [0.05, -0.035, 0]], right: [[7, 0, 5], [0, -0.035, 0.05]], keel: [[0, 0, 4.5], [0, -0.02, 0.05]] };
const TONES = { wing: [[12, 13, 16], [92, 96, 104]], keel: [[118, 122, 130], [228, 230, 233]] };
export const SIZE = 120;
const K = 0.5, CX = 60, CY = 56;
const NS = "http://www.w3.org/2000/svg";

const rot = ([x, y, z], { yaw, pitch, roll }) => {
  let a = x, b = y * Math.cos(roll * R) - z * Math.sin(roll * R), c = y * Math.sin(roll * R) + z * Math.cos(roll * R);
  [a, c] = [a * Math.cos(pitch * R) + c * Math.sin(pitch * R), -a * Math.sin(pitch * R) + c * Math.cos(pitch * R)];
  [a, b] = [a * Math.cos(yaw * R) - b * Math.sin(yaw * R), a * Math.sin(yaw * R) + b * Math.cos(yaw * R)];
  return [a, b, c];
};
const proj = ([x, y, z]) => [CX + (x * sinA - y * cosA) * K, CY + ((x * cosA + y * sinA) * sinE - z * cosE) * K];
const depth = ([x, y, z]) => (x * cosA + y * sinA) * cosE + z * sinE;
const mix = (a, b, t) => `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * t)).join(",")})`;
const f2 = (p) => p[0].toFixed(2) + " " + p[1].toFixed(2);

function soft(q, [radii, bows]) {
  const n = q.length, cx = (q[0][0] + q[1][0] + q[2][0]) / 3, cy = (q[0][1] + q[1][1] + q[2][1]) / 3;
  const toward = (a, b, dist) => { const l = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1; const u = Math.min(dist / l, 0.45); return [a[0] + (b[0] - a[0]) * u, a[1] + (b[1] - a[1]) * u]; };
  const enter = q.map((p, i) => toward(p, q[(i + n - 1) % n], radii[i]));
  const leave = q.map((p, i) => toward(p, q[(i + 1) % n], radii[i]));
  let d = "M" + f2(leave[0]);
  for (let i = 0; i < n; i++) {
    const k = (i + 1) % n, a = leave[i], b = enter[k];
    if (bows[i]) {
      const mx = (a[0] + b[0]) / 2, my = (a[1] + b[1]) / 2, len = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
      let nx = -(b[1] - a[1]) / len, ny = (b[0] - a[0]) / len;
      if ((mx - cx) * nx + (my - cy) * ny < 0) { nx = -nx; ny = -ny; }
      d += "Q" + f2([mx + nx * len * bows[i] * 2, my + ny * len * bows[i] * 2]) + " " + f2(b);
    } else d += "L" + f2(b);
    if (radii[k]) d += "Q" + f2(q[k]) + " " + f2(leave[k]);
  }
  return d + "Z";
}

// Builds the plane's SVG inside `svg` and returns draw(pose) for each frame.
export function createPlane(svg) {
  // A new layout starts a new engine on the same <svg>: begin from an empty one.
  while (svg.firstChild) svg.removeChild(svg.firstChild);
  svg.setAttribute("viewBox", `0 0 ${SIZE} ${SIZE}`);
  const make = (tag, attrs) => { const e = document.createElementNS(NS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); svg.appendChild(e); return e; };
  const defs = make("defs", {});
  const sheen = document.createElementNS(NS, "linearGradient");
  sheen.setAttribute("id", "hx-sheen"); sheen.setAttribute("x1", "1"); sheen.setAttribute("y1", "0"); sheen.setAttribute("x2", "0"); sheen.setAttribute("y2", "1");
  [["0", ".55"], [".6", "0"]].forEach(([o, a]) => { const s = document.createElementNS(NS, "stop"); s.setAttribute("offset", o); s.setAttribute("stop-color", "#fff"); s.setAttribute("stop-opacity", a); sheen.appendChild(s); });
  defs.appendChild(sheen);
  const faces = [0, 1, 2].map(() => ({
    body: make("path", { stroke: "rgba(14,15,18,.35)", "stroke-width": ".4", "stroke-linejoin": "round" }),
    shine: make("path", { fill: "url(#hx-sheen)" }),
  }));
  const crease = make("path", { fill: "none", stroke: "rgba(255,255,255,.42)", "stroke-width": ".6", "stroke-linecap": "round" });

  return function draw(pose) {
    const p = {};
    for (const key in DART) p[key] = rot(DART[key], pose);
    const list = [
      { pts: [p.keelNose, p.spineTail, p.keelTail], tone: "keel", name: "keel" },
      { pts: [p.nose, p.leftTip, p.spineTail], tone: "wing", name: "left" },
      { pts: [p.nose, p.spineTail, p.rightTip], tone: "wing", name: "right" },
    ].map((f) => {
      const [a, b, c] = f.pts;
      const u = [b[0] - a[0], b[1] - a[1], b[2] - a[2]], v = [c[0] - a[0], c[1] - a[1], c[2] - a[2]];
      let n = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
      const l = Math.hypot(...n) || 1; n = n.map((x) => x / l);
      if (n[0] * TO_VIEWER[0] + n[1] * TO_VIEWER[1] + n[2] * TO_VIEWER[2] < 0) n = n.map((x) => -x);
      const lit = Math.max(0, n[0] * LIGHT[0] + n[1] * LIGHT[1] + n[2] * LIGHT[2]);
      return { ...f, lit, z: (depth(a) + depth(b) + depth(c)) / 3, d: soft(f.pts.map(proj), SOFT[f.name]) };
    }).sort((x, y) => x.z - y.z);
    list.forEach((f, i) => {
      const [lo, hi] = TONES[f.tone];
      faces[i].body.setAttribute("d", f.d);
      faces[i].body.setAttribute("fill", mix(lo, hi, Math.min(1, 0.12 + f.lit * 0.92)));
      faces[i].shine.setAttribute("d", f.d);
      faces[i].shine.setAttribute("opacity", (0.06 + f.lit * 0.22).toFixed(2));
    });
    const n0 = proj(p.nose), n1 = proj(p.spineTail);
    const sl = Math.hypot(n1[0] - n0[0], n1[1] - n0[1]) || 1;
    crease.setAttribute("d", `M${f2([n0[0] + ((n1[0] - n0[0]) * 6.3) / sl, n0[1] + ((n1[1] - n0[1]) * 6.3) / sl])}L${f2(n1)}`);
    // Where the nose points on screen, for steering: the projected nose minus the projected tail.
    return Math.atan2(n0[1] - n1[1], n0[0] - n1[0]);
  };
}

// The screen direction the nose points in the resting pose, so a heading can be turned into an SVG rotation.
export const REST_POSE = { yaw: -104, pitch: -20, roll: 22 };
export function restHeading() {
  const n0 = proj(rot(DART.nose, REST_POSE)), n1 = proj(rot(DART.spineTail, REST_POSE));
  return Math.atan2(n0[1] - n1[1], n0[0] - n1[0]);
}
