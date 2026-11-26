#!/usr/bin/env node
// Runs site/signup.js against a fake page for each answer ParaAir Cloud's /signup/status can give, and checks which
// marked elements end up shown (CI job "site"). No dependencies: the script only reads element.dataset and sets
// element.hidden, so a list of plain objects stands in for the DOM.
//
//   node scripts/check-signup.mjs [path/to/signup.js]
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const source = readFileSync(process.argv[2] ?? join(root, "site", "signup.js"), "utf8");

/// The marked elements of site/pricing.html and get-started.html, as written (hidden or not).
function page() {
  return {
    invite: { dataset: { signup: "invite" }, hidden: false },
    open: { dataset: { signup: "open" }, hidden: true },
    billingOff: { dataset: { billing: "off" }, hidden: true },
  };
}

async function run(answer) {
  const elements = page();
  const fetch = async () => {
    if (answer === "network error") throw new TypeError("offline");
    if (answer === "500") return { ok: false, json: async () => null };
    return { ok: true, json: async () => answer };
  };
  const document = { querySelectorAll: () => Object.values(elements) };
  vm.runInNewContext(source, { document, window: { fetch }, fetch });
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setImmediate(resolve));
  return Object.fromEntries(Object.entries(elements).map(([name, element]) => [name, !element.hidden]));
}

const cases = [
  // Production before billing: a service from before the `billing` field, or one that says it is off.
  [{ open: false }, { invite: true, open: false, billingOff: true }],
  [{ open: false, paused: false, billing: false, checkout: false }, { invite: true, open: false, billingOff: true }],
  // Billing on while sign-up is invite-only (go-live runbook steps 7 to 10): nothing may say nobody is charged.
  [{ open: false, paused: false, billing: true, checkout: true }, { invite: true, open: false, billingOff: false }],
  // Sign-up open: billing is on (the production config check refuses SELF_SIGNUP without it).
  [{ open: true, paused: false, billing: true, checkout: true }, { invite: false, open: true, billingOff: false }],
  // Malformed answers: nothing changes, and nothing says nobody is charged.
  [{}, { invite: true, open: false, billingOff: false }],
  [{ open: false, billing: null }, { invite: true, open: false, billingOff: false }],
  [{ open: "false" }, { invite: true, open: false, billingOff: false }],
  [[], { invite: true, open: false, billingOff: false }],
  // No answer: the page stays as written, which claims nothing about billing.
  ["network error", { invite: true, open: false, billingOff: false }],
  ["500", { invite: true, open: false, billingOff: false }],
];

let failed = 0;
for (const [answer, expected] of cases) {
  const shown = await run(answer);
  const ok = Object.keys(expected).every((name) => shown[name] === expected[name]);
  if (!ok) {
    failed += 1;
    console.error(`signup check: ${JSON.stringify(answer)}: shown ${JSON.stringify(shown)}, expected ${JSON.stringify(expected)}`);
  }
}
if (failed > 0) process.exit(1);
console.log(`signup check PASS: ${cases.length} /signup/status answers`);
