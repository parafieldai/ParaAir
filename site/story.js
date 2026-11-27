// How it works: a cloud (your bucket) holds a 48 GB video, drawn as 48 squares (the app's pieces are really 1 MB
// each, so the squares stand for many); a laptop (your Mac) plays it. Three steps play in turn and loop, and the step
// buttons jump to one:
//   1 Open  the player's first reads come down, the start and the index at the end, and the video is ready.
//   2 Play  the playhead moves on; the next pieces arrive just ahead of it into a small cache, and when the cache is
//           full the piece used longest ago makes room (the app keeps about 1 GB).
//   3 Save  the piece under the playhead is changed and saved on the Mac at once, then only it goes back up.
// One colour code throughout: dark grey is on your Mac, in the bucket and on the Mac's bar alike.
// The steps take turns only while the reader lets them: choosing a step plays just that one and rests on its end, the
// pause button stops time where it is, and no step changes while focus is on a step. Play starts the turns again.
// Everything drawn comes from stateAt(step, t), so any moment can be shown; under reduced motion each step is shown
// at its end, without movement. It runs only while on screen.
(() => {
  const root = document.querySelector('[data-story]');
  if (!root) return;
  const svg = root.querySelector('.story-svg');
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');
  const tiles = [...svg.querySelectorAll('[data-tile]')];
  const segs = [...svg.querySelectorAll('[data-seg]')];
  const part = (name) => root.querySelector(`[data-st="${name}"]`);
  const opening = part('opening'), play = part('play'), head = part('head'), pill = part('pill'), pillText = part('pill-text'), flightsLayer = part('flights');
  const count = root.querySelector('[data-story-count]');
  const buttons = [...root.querySelectorAll('[data-step]')];
  const captions = [...root.querySelectorAll('[data-caption]')];
  const controls = root.querySelector('[data-story-controls]');
  const tablist = root.querySelector('[role="tablist"]');
  const pauseButton = root.querySelector('[data-story-pause]');
  const bars = buttons.map((b) => b.querySelector('.story-bar span'));
  // The screen plays a real interview. It plays in Play, rests in Open and Save, and picks up where it left off on
  // the next round, so each round shows the next part of it.
  const film = root.querySelector('[data-st-film]');
  let filmStep = -1;
  const syncFilm = (step, moving) => {
    if (!film) return;
    if (step === 1 && moving && visible && !still.matches) {
      if (film.paused) { const p = film.play(); if (p && p.catch) p.catch(() => {}); }
    } else if (!film.paused) film.pause();
    if (step !== filmStep && step === 1 && film.duration && film.currentTime > film.duration - 9) { try { film.currentTime = 0; } catch (e) { /* not loaded yet */ } }
    filmStep = step;
  };

  const COUNT = 48;
  const LAST = COUNT - 1;
  const DUR = [5.2, 8.2, 6.2];
  const tileAt = (i) => [148 + (i % 12) * 19.5 + 7.5, 212 + Math.floor(i / 12) * 19.5 + 7.5];
  const segAt = (i) => [620 + i * (268 / 48) + 2.15, 284];
  // Pieces stop just above the MacBook's lid and never cross into its screen; the player on the screen lights up instead.
  const LID = [754, 94];

  // The cache holds this many squares; when one more arrives, the one used longest ago leaves.
  const CAP = 6;
  // What the scene shows at time t of a step.
  const stateAt = (step, t) => {
    const arrived = [], flights = [];
    let playhead = 0, ready = true, edit = -1, sent = -1, pillState = '';
    const fly = (seg, start, dur, dir) => {
      if (t >= start + dur) return true;
      if (t >= start) flights.push({ seg, dir, u: (t - start) / dur });
      return false;
    };
    if (step === 0) {
      if (fly(0, 0.5, 1.2, 'down')) arrived.push(0);
      if (fly(LAST, 1.1, 1.2, 'down')) arrived.push(LAST);
      ready = t >= 2.5;
    } else if (step === 1) {
      arrived.push(0, LAST);
      // The playhead moves on slowly; each piece is fetched a little before the playhead reaches it.
      playhead = Math.min(5, t * 0.62);
      for (let k = 1; k <= 7; k++) if (fly(k, Math.max(0.15 + (k - 1) * 0.3, (k - 2.6) / 0.62 - 1), 1.0, 'down')) arrived.push(k);
    } else {
      arrived.push(0, LAST);
      for (let k = 1; k <= 7; k++) arrived.push(k);
      playhead = 5;
      if (t >= 0.4 && t < 2.8) edit = 5;
      if (t >= 0.4) pillState = 'saved';
      fly(5, 1.4, 1.4, 'up');
      if (t >= 2.8) pillState = 'uploaded';
      if (t >= 2.8 && t < 3.7) sent = 5;
    }
    // Pieces arrive in the order they are used, so the cache keeps the last few that came.
    const on = new Set(arrived.slice(-CAP));
    return { on, flights, playhead, ready, edit, sent, pillState, full: arrived.length >= CAP, playing: step === 1 };
  };

  // Flying pieces: a small pool of squares moved along a curve from tile to screen (or back).
  const NS = 'http://www.w3.org/2000/svg';
  const pool = Array.from({ length: 6 }, () => {
    const r = document.createElementNS(NS, 'rect');
    r.setAttribute('x', '-7.5'); r.setAttribute('y', '-7.5'); r.setAttribute('width', '15'); r.setAttribute('height', '15'); r.setAttribute('rx', '3.5');
    r.setAttribute('class', 'st-fly');
    flightsLayer.appendChild(r);
    return r;
  });
  const ease = (u) => (u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2);
  const along = ({ seg, dir, u }) => {
    const e = ease(Math.min(1, Math.max(0, u)));
    const [a, b] = dir === 'down' ? [tileAt(seg), LID] : [LID, tileAt(seg)];
    const c = [(a[0] + b[0]) / 2, Math.min(a[1], b[1]) - (dir === 'down' ? 110 : 150)];
    const x = (1 - e) * (1 - e) * a[0] + 2 * (1 - e) * e * c[0] + e * e * b[0];
    const y = (1 - e) * (1 - e) * a[1] + 2 * (1 - e) * e * c[1] + e * e * b[1];
    // Full size over the cloud, smaller as it reaches the lid, where it fades (and the other way up).
    const s = dir === 'down' ? 1 - 0.5 * e * e : 0.5 + 0.5 * Math.sqrt(e);
    const fade = dir === 'down' ? (e > 0.85 ? (1 - e) / 0.15 : 1) : (e < 0.12 ? e / 0.12 : 1);
    return { x, y, s, fade };
  };

  let shownStep = -1;
  const render = (step, t) => {
    const st = stateAt(step, t);
    tiles.forEach((el, i) => { el.classList.toggle('is-copied', st.on.has(i)); el.classList.toggle('is-sent', st.sent === i); });
    segs.forEach((el, i) => { el.classList.toggle('is-on', st.on.has(i)); el.classList.toggle('is-edit', st.edit === i); });
    pool.forEach((el, i) => {
      const f = st.flights[i];
      if (!f) { el.setAttribute('opacity', '0'); return; }
      const { x, y, s, fade } = along(f);
      el.setAttribute('transform', `translate(${x.toFixed(1)} ${y.toFixed(1)}) scale(${s.toFixed(3)})`);
      el.setAttribute('opacity', fade.toFixed(2));
      el.classList.toggle('is-up', f.dir === 'up');
    });
    const [hx] = segAt(Math.floor(st.playhead) + (st.playhead % 1));
    head.setAttribute('transform', `translate(${hx.toFixed(1)} 0)`);
    opening.classList.toggle('is-hidden', st.ready);
    play.classList.toggle('is-hidden', !st.ready || st.playing || step === 2);
    pill.classList.toggle('is-hidden', !st.pillState);
    const words = st.pillState === 'uploaded' ? 'Uploaded to your bucket' : 'Saved on your Mac';
    if (pillText.textContent !== words) pillText.textContent = words;
    const here = st.full ? `${st.on.size} pieces: the cache is full` : `${st.on.size} piece${st.on.size === 1 ? '' : 's'} in a small cache`;
    if (count.textContent !== here) count.textContent = here;
    if (shownStep !== step) {
      shownStep = step;
      buttons.forEach((b, i) => { b.setAttribute('aria-selected', String(i === step)); b.classList.toggle('is-on', i === step); });
      captions.forEach((c, i) => { c.classList.toggle('is-on', i === step); c.setAttribute('aria-hidden', String(i !== step)); });
    }
    bars.forEach((bar, i) => { bar.style.transform = `scaleX(${i === step ? Math.min(1, t / DUR[step]) : i < step ? 1 : 0})`; });
    syncFilm(step, moving());
  };

  // auto: the steps take turns; paused: time stands still. A chosen step plays once (auto off) and rests on its end.
  let step = 0, t = 0, last = 0, frame = 0, visible = false, auto = true, paused = false;
  // Focus on a step holds the turns; focus on the pause button doesn't, so Play keeps playing.
  const holding = () => !!tablist && tablist.matches(':focus-within');
  const atRest = () => t >= DUR[step] && (!auto || holding());
  const moving = () => !paused && !atRest();
  const showPause = () => {
    if (!pauseButton) return;
    const running = auto && !paused;
    pauseButton.classList.toggle('is-paused', !running);
    pauseButton.setAttribute('aria-label', running ? 'Pause the steps' : 'Play the steps');
    pauseButton.hidden = still.matches;
  };
  const tick = (now) => {
    const dt = last ? Math.min((now - last) / 1000, 1 / 20) : 0;
    last = now;
    if (!paused) t += dt;
    if (t >= DUR[step]) {
      if (auto && !holding()) { step = (step + 1) % 3; t = 0; } else t = DUR[step];
    }
    render(step, t);
    frame = visible && !still.matches && moving() ? requestAnimationFrame(tick) : 0;
  };
  const wake = () => { if (!frame && visible && !still.matches && moving()) { last = 0; frame = requestAnimationFrame(tick); } };
  const go = (i) => { step = i; t = still.matches ? DUR[i] - 0.001 : 0; render(step, t); wake(); };
  // Choosing a step stops the turns, so its caption stays for as long as the reader wants it.
  const choose = (i) => { auto = false; paused = false; showPause(); go(i); };
  buttons.forEach((b, i) => {
    b.addEventListener('click', () => choose(i));
    b.addEventListener('keydown', (e) => {
      if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') return;
      e.preventDefault();
      const next = (i + (e.key === 'ArrowRight' ? 1 : 2)) % 3;
      buttons[next].focus();
      choose(next);
    });
  });
  if (pauseButton) {
    pauseButton.addEventListener('click', () => {
      if (auto && !paused) paused = true;
      else {
        const rested = t >= DUR[step];
        auto = true; paused = false;
        if (rested) { step = (step + 1) % 3; t = 0; }
      }
      showPause();
      render(step, t);
      wake();
    });
  }
  // Focus leaving the controls lets the turns go on.
  if (controls) controls.addEventListener('focusout', () => setTimeout(() => { render(step, t); wake(); }, 0));
  // It runs only while on screen and while the page's tab is showing.
  let onScreen = false;
  const syncView = () => { visible = onScreen && document.visibilityState !== 'hidden'; if (!visible && film) film.pause(); wake(); };
  new IntersectionObserver((entries) => { onScreen = entries[entries.length - 1].isIntersecting; syncView(); }, { threshold: 0.25 }).observe(root);
  document.addEventListener('visibilitychange', syncView);
  // A pending frame would carry the step on past its end, so it goes before the step is shown at rest.
  still.addEventListener('change', () => { cancelAnimationFrame(frame); frame = 0; showPause(); go(step); });
  showPause();
  go(0);
  if (still.matches) render(0, DUR[0]);
})();
