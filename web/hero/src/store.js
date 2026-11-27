// A tiny shared store: the hero's timeline (engine.js) writes it, both React roots (the canvas layer and the Mac's
// screen) read it.
import { useSyncExternalStore } from "react";

const listeners = new Set();
let state = { phase: "idle", arrived: 0, run: 0, still: false, chapter: 0, hint: 1, inView: true };

export const store = {
  get: () => state,
  set(patch) {
    const next = { ...state, ...patch };
    if (Object.keys(patch).every((k) => next[k] === state[k])) return;
    state = next;
    listeners.forEach((l) => l());
  },
  subscribe(listener) {
    listeners.add(listener);
    return () => listeners.delete(listener);
  },
};

export const useHero = (select) => useSyncExternalStore(store.subscribe, () => select(state), () => select(state));
