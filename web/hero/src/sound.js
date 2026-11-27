// The hero's sound, off until the reader turns it on with the sound button (Hero.jsx). Nothing else starts it.
// Music: "Dreamer" by Kevin MacLeod (incompetech.com), CC BY 4.0, trimmed to a two-minute loop with fades
// (media/music-dreamer.m4a), fetched only when sound is first turned on. The effects are made here with Web Audio, no files:
//   lift   a print coming apart into particles: a short shimmer of soft high notes over a breath of air
//   pour   the stream reaching the Mac: one low, soft swell you feel more than hear, then grains like fine sand
//   land   the plane touching down on the lid: a small soft tap
//   done   the last files in the drive: two quiet notes
const NOTES = [0, 2, 4, 7, 9]; // a pentatonic scale, so any notes that overlap still sound right
const hz = (semi) => 440 * Math.pow(2, semi / 12);

export function createSound() {
  let ctx = null, master = null, fx = null, music = null, musicGain = null, on = false, lastLift = 0, lastGrain = 0;
  const listeners = new Set();
  // Whether it can actually be heard: on, the audio running and the music playing (a browser may hold both back).
  const audible = () => on && !!ctx && ctx.state === "running" && !!music && !music.paused;
  const tell = () => listeners.forEach((fn) => fn({ on, audible: audible() }));

  const setup = () => {
    if (ctx) return;
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    ctx = new AC();
    master = ctx.createGain();
    master.gain.value = 0;
    master.connect(ctx.destination);
    // A small room: a decaying noise impulse, mixed in quietly, so the effects have air around them.
    const len = Math.floor(ctx.sampleRate * 1.8), ir = ctx.createBuffer(2, len, ctx.sampleRate);
    for (let c = 0; c < 2; c++) { const d = ir.getChannelData(c); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3.2); }
    const verb = ctx.createConvolver(); verb.buffer = ir;
    const wet = ctx.createGain(); wet.gain.value = 0.32;
    fx = ctx.createGain(); fx.gain.value = 0.9;
    fx.connect(master); fx.connect(verb); verb.connect(wet); wet.connect(master);
    music = new Audio("media/music-dreamer.m4a");
    music.loop = true; music.preload = "auto"; music.crossOrigin = "anonymous";
    music.addEventListener("playing", tell); music.addEventListener("pause", tell);
    ctx.addEventListener("statechange", tell);
    musicGain = ctx.createGain(); musicGain.gain.value = 0.36;
    ctx.createMediaElementSource(music).connect(musicGain);
    musicGain.connect(master);
  };

  const noise = (secs) => {
    const b = ctx.createBuffer(1, Math.max(1, Math.floor(ctx.sampleRate * secs)), ctx.sampleRate), d = b.getChannelData(0);
    for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1;
    const s = ctx.createBufferSource(); s.buffer = b; return s;
  };
  const tone = (freq, at, attack, decay, gain, type = "sine", to = null) => {
    const o = ctx.createOscillator(), g = ctx.createGain();
    o.type = type; o.frequency.setValueAtTime(freq, at);
    if (to) o.frequency.exponentialRampToValueAtTime(to, at + attack + decay);
    g.gain.setValueAtTime(0.0001, at);
    g.gain.exponentialRampToValueAtTime(gain, at + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, at + attack + decay);
    o.connect(g); g.connect(fx); o.start(at); o.stop(at + attack + decay + 0.05);
  };
  const air = (at, secs, from, to, gain, q = 0.9) => {
    const s = noise(secs), f = ctx.createBiquadFilter(), g = ctx.createGain();
    f.type = "bandpass"; f.Q.value = q; f.frequency.setValueAtTime(from, at); f.frequency.exponentialRampToValueAtTime(to, at + secs);
    g.gain.setValueAtTime(0.0001, at); g.gain.exponentialRampToValueAtTime(gain, at + secs * 0.35); g.gain.exponentialRampToValueAtTime(0.0001, at + secs);
    s.connect(f); f.connect(g); g.connect(fx); s.start(at); s.stop(at + secs + 0.05);
  };
  const ready = () => on && ctx && ctx.state === "running";

  const api = {
    get on() { return on; },
    get audible() { return audible(); },
    subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); },
    // Start (or carry on) the sound; called from the sound button's click, so the browser allows it.
    kick() {
      if (!on || !ctx) return;
      if (ctx.state !== "running") { const r = ctx.resume(); if (r && r.catch) r.catch(() => {}); }
      if (music.paused) { const p = music.play(); if (p && p.catch) p.catch(() => {}); }
    },
    toggle(next = !on) {
      if (next) {
        setup();
        if (!ctx) return;
        on = true;
        const now = ctx.currentTime;
        master.gain.cancelScheduledValues(now); master.gain.setValueAtTime(master.gain.value, now); master.gain.linearRampToValueAtTime(1, now + 1.2);
        api.kick();
      } else if (ctx) {
        on = false;
        const now = ctx.currentTime;
        master.gain.cancelScheduledValues(now); master.gain.setValueAtTime(master.gain.value, now); master.gain.linearRampToValueAtTime(0, now + 0.5);
        setTimeout(() => { if (!on && music) music.pause(); }, 600);
      } else on = false;
      tell();
    },
    // A print coming apart. `size` 0..1, how big it is.
    lift(size = 0.5) {
      if (!ready()) return;
      const now = ctx.currentTime;
      if (now - lastLift < 0.09) return;
      lastLift = now;
      air(now, 0.55, 900, 3600, 0.035 + size * 0.03);
      const base = 24 + Math.floor(Math.random() * 3) * 2;
      const n = 6 + Math.round(size * 6);
      for (let i = 0; i < n; i++) {
        const semi = base + NOTES[Math.floor(Math.random() * NOTES.length)] + 12 * Math.floor(Math.random() * 2);
        tone(hz(semi), now + i * 0.035 + Math.random() * 0.02, 0.004, 0.16 + Math.random() * 0.12, 0.018 + size * 0.01, "triangle");
      }
    },
    // The stream starting to pour onto the Mac: one low swell.
    pour() {
      if (!ready()) return;
      const now = ctx.currentTime;
      tone(96, now, 0.18, 1.3, 0.16, "sine", 62);
      air(now, 1.2, 420, 160, 0.05, 0.6);
    },
    // Particles landing on the lid, `count` this frame: grains of fine sand, a few at a time.
    grains(count) {
      if (!ready() || count <= 0) return;
      const now = ctx.currentTime;
      if (now - lastGrain < 0.03) return;
      lastGrain = now;
      const n = Math.min(3, 1 + Math.floor(count / 40));
      for (let i = 0; i < n; i++) {
        const at = now + Math.random() * 0.03, s = noise(0.012), f = ctx.createBiquadFilter(), g = ctx.createGain();
        f.type = "highpass"; f.frequency.value = 2600 + Math.random() * 2400;
        g.gain.setValueAtTime(0.012 + Math.random() * 0.012, at); g.gain.exponentialRampToValueAtTime(0.0001, at + 0.012);
        s.connect(f); f.connect(g); g.connect(fx); s.start(at); s.stop(at + 0.03);
      }
    },
    land() {
      if (!ready()) return;
      const now = ctx.currentTime;
      tone(180, now, 0.003, 0.18, 0.09, "sine", 120);
      air(now, 0.12, 2400, 1200, 0.03, 1.4);
    },
    done() {
      if (!ready()) return;
      const now = ctx.currentTime;
      tone(hz(19), now, 0.02, 1.4, 0.05);
      tone(hz(26), now + 0.12, 0.02, 1.6, 0.04);
    },
  };

  // Quiet while the tab is hidden.
  document.addEventListener("visibilitychange", () => {
    if (!ctx || !on) return;
    if (document.hidden) { ctx.suspend(); if (music) music.pause(); }
    else { ctx.resume(); const p = music && music.play(); if (p && p.catch) p.catch(() => {}); }
  });
  return api;
}
