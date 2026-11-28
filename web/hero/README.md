# The landing page hero

`site/hero.js` is built from here: React 18 and Framer Motion, bundled by esbuild into one self-hosted file, as the
site's Content-Security-Policy (`script-src 'self'`) requires. Nothing here is deployed; only `site/` is.

    npm ci --ignore-scripts
    npm run build        # writes ../../site/hero.js
    npm run watch        # rebuilds on every save

- `src/engine.js` plays the story by scroll: the hero is a tall section (`.hx-scroll`, 820vh) whose stage pins, and how
  far it has scrolled sets the story's time, and the story keeps pace with the scroll (a tenth of a second of
  smoothing, no speed limit), forwards and back: it stops when the scroll stops.
  Every frame is worked out from that time alone. It opens on the canvas with no words; the headline appears only
  once the plane has landed (a key that puts focus in it shows it at once, and the download is always in the header
  bar). Scrolling past the hero is ordinary scrolling: the page never holds the reader until the story has played.
  Prints fetch their picture only when they come near the screen, and clips play only while on screen, never under
  reduced motion.
- `src/flight.js` holds the timings (`T`, `STORY`), the camera's pan and the plane's flight: one speed curve that
  cruises and then slows evenly onto the laptop's lid, over a height-by-distance path, so the plane never loops, turns
  back or stops in mid-air. Prints the plane passes lift off into its wake, and the wake pours onto the lid.
- `src/Hero.jsx` draws the canvas layer and the sound button; `src/MacDemo.jsx` draws what the laptop's screen shows
  (Finder and QuickTime, with icons from the page's sprite).
- `src/sound.js` is off until the reader presses the sound button; nothing else starts it, and the music file is
  fetched only then.
- `src/media.js` lists the files on the canvas. Their sources and licences are in `site/media/CREDITS.md`.

The Mac (`site/media/macbook-pro.webp`) is Apple's MacBook Pro with PROLED XDR Display (14-inch, Space Black) from
Apple's product bezels, with the ParaAir desktop and menu bar composited into its screen; see `site/media/CREDITS.md`.
Its screen is 3024 x 1986 at (418, 277) of the 3860 x 2540 artwork, with the lid 231 from the top; `site/hero.css`,
`src/engine.js` and the How it works diagram in `site/index.html` rely on that geometry.
