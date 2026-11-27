// What the laptop's screen shows: the ParaAir drive open in Finder, filling with the files as the plane's wake pours
// onto the Mac, then a loop: the pointer opens a 27 GB clip and it plays at once in QuickTime; the ParaAir menu bar
// panel drops down (the app's real panel); and back. Everything stays inside the screen. Sizes are in container
// units (cqw, a hundredth of the screen's width), so it scales with the Mac. The icons are the page's own sprite.
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import { AnimatePresence, LazyMotion, domAnimation, m } from "framer-motion";
import { MEDIA, FINDER_FILES } from "./media.js";
import { useHero } from "./store.js";

const byName = Object.fromEntries(MEDIA.map((f) => [f.name, f]));
const FILES = FINDER_FILES.map((n) => byName[n]);
const OPEN = 1; // dance-take4.mov
const spring = { type: "spring", stiffness: 260, damping: 28 };
const EXT = { pdf: "PDF", sheet: "XLSX", wav: "WAV", md: "MD", blend: "BLEND" };
const FAVORITES = [["AirDrop", "#i-airdrop"], ["Recents", "#i-clock"], ["Applications", "#i-apps"], ["Desktop", "#i-desktop"], ["Documents", "#i-docs"], ["Downloads", "#i-down"]];

const Icon = ({ id, className, box = "0 0 20 20" }) => <svg className={className} viewBox={box} aria-hidden="true"><use href={id} /></svg>;

function Thumb({ file }) {
  if (file.kind === "doc") return <span className={`hxd-doc hxd-doc-${file.doc}`}><Icon id="#i-doc" box="0 0 48 60" /><b>{EXT[file.doc]}</b></span>;
  return <img src={file.kind === "video" ? file.poster : file.src} alt="" loading="lazy" decoding="async" draggable={false} />;
}

export function MacDemo() {
  const phase = useHero((s) => s.phase);
  const arrived = useHero((s) => s.arrived);
  const still = useHero((s) => s.still);
  const run = useHero((s) => s.run);
  const inView = useHero((s) => s.inView);
  const [step, setStep] = useState("browse");
  const shown = Math.min(FILES.length, Math.round(arrived * FILES.length));
  const ready = phase === "demo";
  const full = shown >= FILES.length;

  // The loop, once every file is in: point at the clip, open it, it plays, the menu bar panel, close.
  useEffect(() => {
    setStep("browse");
    if (!ready || !full || still || !inView) return undefined;
    const timers = [];
    const at = (s, fn) => timers.push(setTimeout(fn, s * 1000));
    const cycle = () => {
      at(0.5, () => setStep("point"));
      at(1.5, () => setStep("open"));
      at(1.9, () => setStep("play"));
      at(6.2, () => setStep("panel"));
      at(9.2, () => setStep("browse"));
      at(11.4, cycle);
    };
    cycle();
    return () => timers.forEach(clearTimeout);
  }, [ready, full, still, run, inView]);

  // The pointer goes to what it acts on, measured, so it lands on the clip whatever the Mac's size.
  const root = useRef(null), clip = useRef(null), hud = useRef(null);
  const [cursor, setCursor] = useState({ left: "88%", top: "90%" });
  useLayoutEffect(() => {
    const box = root.current && root.current.getBoundingClientRect();
    if (!box || !box.width) return;
    const at = (el, fx, fy) => {
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return { left: `${(((r.left + r.width * fx - box.left) / box.width) * 100).toFixed(2)}%`, top: `${(((r.top + r.height * fy - box.top) / box.height) * 100).toFixed(2)}%` };
    };
    const spot = step === "point" || step === "open" ? at(clip.current, 0.56, 0.58) : step === "play" ? at(hud.current, 0.66, 0.5) : step === "panel" ? { left: "79.6%", top: "2.4%" } : null;
    setCursor(spot || { left: "88%", top: "90%" });
  }, [step]);

  const playing = step === "play" || step === "panel";
  const picked = step !== "browse";

  return (
    <LazyMotion features={domAnimation}>
    <div className="hxd" ref={root}>
      <AnimatePresence>
        {ready && (
          <m.div key={`f${run}`} className="hxd-finder" initial={still ? false : { opacity: 0, y: "2%", scale: 0.98 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0 }} transition={still ? { duration: 0 } : spring}>
            <aside className="hxd-side">
              <p>Favorites</p>
              {FAVORITES.map(([label, id]) => <span key={label}><Icon id={id} />{label}</span>)}
              <p>Locations</p>
              <span className="is-here"><Icon id="#i-drive" />Client Footage<Icon id="#i-eject" className="hxd-eject" /></span>
            </aside>
            <div className="hxd-main">
              <div className="hxd-tools">
                <span className="hxd-nav"><Icon id="#t-back" /><Icon id="#t-fwd" /></span>
                <b>Client Footage</b>
                <span className="hxd-acts"><Icon id="#t-grid" /><Icon id="#t-group" /><Icon id="#t-share" /><Icon id="#t-tag" /><Icon id="#t-more" /><Icon id="#t-search" /></span>
              </div>
              <div className="hxd-grid">
                {FILES.map((file, i) => (
                  <m.div key={file.name} className={`hxd-item${i === OPEN && picked ? " is-sel" : ""}`} initial={false}
                    animate={{ opacity: i < shown ? 1 : 0, y: i < shown ? "0%" : "-40%", scale: i < shown ? 1 : 0.9 }} transition={still ? { duration: 0 } : { type: "spring", stiffness: 200, damping: 24 }}>
                    <span className="hxd-thumb" ref={i === OPEN ? clip : undefined}><Thumb file={file} /></span>
                    <b>{file.file}</b>
                    <em>{file.size}</em>
                  </m.div>
                ))}
              </div>
              <div className="hxd-status">{shown} {shown === 1 ? "item" : "items"} on Client Footage</div>
            </div>
          </m.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {playing && (
          <m.div key="player" className="hxd-player" initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.96 }} transition={spring}>
            <div className="hxd-bar">dance-take4.mov</div>
            <div className="hxd-view">
              <video src="media/dancer.mp4" poster="media/dancer.webp" muted loop playsInline preload="none" ref={(v) => { if (v) { v.muted = true; const p = v.play(); if (p && p.catch) p.catch(() => {}); } }} />
              <div className="hxd-hud" ref={hud}>
                <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M9.5 5 3 10l6.5 5zM17.5 5 11 10l6.5 5z" /></svg>
                <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M5 4h3.4v12H5zM11.6 4H15v12h-3.4z" /></svg>
                <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M2.5 5 9 10l-6.5 5zM10.5 5l6.5 5-6.5 5z" /></svg>
                <em>17:28</em>
                <span><m.b initial={{ width: "62%" }} animate={{ width: "70%" }} transition={{ duration: 7, ease: "linear" }} /></span>
                <em>28:12</em>
              </div>
            </div>
          </m.div>
        )}
      </AnimatePresence>

      <AnimatePresence>
        {step === "panel" && (
          <m.img key="panel" className="hxd-panel" src="app-panel-light.png" alt="" initial={{ opacity: 0, y: "-4%", scale: 0.97 }} animate={{ opacity: 1, y: 0, scale: 1 }} exit={{ opacity: 0, y: "-3%" }} transition={spring} />
        )}
      </AnimatePresence>

      {ready && full && !still && inView && (
        <m.svg className="hxd-cursor" viewBox="0 0 24 24" initial={{ left: "88%", top: "90%", opacity: 0 }} animate={{ ...cursor, opacity: 1, scale: step === "open" ? 0.86 : 1 }} transition={{ type: "spring", stiffness: 70, damping: 18 }}>
          <path d="M5 2.5v17.2l4.6-4.4 2.9 6.5 2.6-1.2-2.8-6.3h6.4z" />
        </m.svg>
      )}
    </div>
    </LazyMotion>
  );
}
