// Bundles the landing page hero (src/) into one self-hosted file, site/hero.js, which the site's
// Content-Security-Policy (script-src 'self') allows. `npm run build` once, or `npm run watch` while editing.
import * as esbuild from "esbuild";

const options = {
  entryPoints: ["src/main.jsx"],
  bundle: true,
  minify: true,
  format: "iife",
  target: ["es2020", "safari15"],
  outfile: "../../site/hero.js",
  jsx: "automatic",
  define: { "process.env.NODE_ENV": '"production"' },
  legalComments: "eof",
  banner: { js: "// ParaAir landing hero, built from web/hero by esbuild (npm run build). Do not edit by hand." },
  logLevel: "info",
};

if (process.argv.includes("--watch")) {
  const context = await esbuild.context(options);
  await context.watch();
} else {
  await esbuild.build(options);
}
