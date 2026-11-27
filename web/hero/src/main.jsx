// Mounts the hero: one React root for the canvas layer, one for the laptop's screen.
// Without this script the page still reads: the headline, the buttons, and the Mac showing the drive in Finder.
import { createRoot } from "react-dom/client";
import { Hero } from "./Hero.jsx";
import { MacDemo } from "./MacDemo.jsx";

const hero = document.querySelector("[data-hero]");
const layer = document.getElementById("hx-root");
const screen = document.getElementById("hx-screen");
const mac = document.getElementById("hx-mac");

if (hero && layer && screen && mac) {
  hero.classList.add("hx-js");
  // The story plays by scrolling: the hero grows tall and its stage pins. Not under reduced motion.
  if (!window.matchMedia("(prefers-reduced-motion: reduce)").matches) { hero.classList.add("hx-scroll"); mac.classList.add("hx-off"); }
  createRoot(layer).render(<Hero hero={hero} mac={mac} />);
  createRoot(screen).render(<MacDemo />);
}
