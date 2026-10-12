#!/usr/bin/env node
// Computes manifests.json from manifest-cases.json with the API v1 manifest rule
// (README.md, "Chunk manifests"), then checks every chunk against the reference
// semantics: truncate the base to baseVisibleSize, extend with zeros to finalSize,
// apply extents in order.
//
//   node generate-manifests.mjs           rewrite manifests.json
//   node generate-manifests.mjs --check   exit 1 if manifests.json is stale
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const inputPath = join(here, "manifest-cases.json");
const outputPath = join(here, "manifests.json");
const requiredCases = [
  "create-empty", "create-two-chunks", "overwrite-middle", "truncate-then-extend",
  "shrink-last-partial", "extend-partial-last-unchanged", "overlapping-extents-later-wins", "sparse-gap-zeros",
];

function fail(message) {
  console.error(`generate-manifests: ${message}`);
  process.exit(1);
}
const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");
const isSize = (value) => Number.isSafeInteger(value) && value >= 0;

function asciiBytes(value, field) {
  if (typeof value !== "string" || !/^[\x20-\x7e]*$/.test(value)) fail(`${field} must be a printable ASCII string`);
  return Buffer.from(value, "ascii");
}

function chunkList(bytes, chunkSize) {
  const chunks = [];
  for (let start = 0; start < bytes.length; start += chunkSize) {
    const piece = bytes.subarray(start, Math.min(start + chunkSize, bytes.length));
    chunks.push({ index: chunks.length, sha256: sha256(piece), size: piece.length });
  }
  return chunks;
}

function readCase(raw, chunkSize) {
  const { name, baseVisibleSize, finalSize } = raw;
  if (typeof name !== "string" || name.length === 0) fail("every case needs a name");
  if (!isSize(finalSize)) fail(`${name}: finalSize must be a non-negative integer`);
  const base = raw.base === null ? null : asciiBytes(raw.base, `${name}.base`);
  if (!isSize(baseVisibleSize) || baseVisibleSize > finalSize) fail(`${name}: baseVisibleSize must be in [0, finalSize]`);
  if (base === null ? baseVisibleSize !== 0 : baseVisibleSize > base.length) {
    fail(`${name}: baseVisibleSize must be 0 without a base and at most the base length otherwise`);
  }
  if (!Array.isArray(raw.extents)) fail(`${name}: extents must be an array`);
  const extents = raw.extents.map((extent, index) => {
    const data = asciiBytes(extent.data, `${name}.extents[${index}].data`);
    if (!isSize(extent.offset) || data.length === 0 || extent.offset + data.length > finalSize) {
      fail(`${name}.extents[${index}]: needs data and must lie within [0, finalSize)`);
    }
    return { offset: extent.offset, data };
  });
  if (Math.ceil(finalSize / chunkSize) > 65536) fail(`${name}: more than 65536 chunks`);
  return { name, base, baseVisibleSize, finalSize, extents };
}

// The 2.6 rule: reuse a base chunk only when it is complete, still visible and
// untouched; otherwise build each byte from the last covering extent, else the
// visible base, else zero.
function plan({ base, baseVisibleSize, finalSize, extents }, chunkSize) {
  const baseChunks = base === null ? null : chunkList(base, chunkSize);
  const chunks = [];
  for (let index = 0; index < Math.ceil(finalSize / chunkSize); index += 1) {
    const start = index * chunkSize, end = Math.min(start + chunkSize, finalSize);
    const touching = extents.filter((x) => x.offset < end && x.offset + x.data.length > start);
    if (baseChunks !== null && end <= baseVisibleSize && index < baseChunks.length
        && baseChunks[index].size === end - start && touching.length === 0) {
      chunks.push({ index, reuse: true, sha256: baseChunks[index].sha256, size: end - start });
      continue;
    }
    const bytes = Buffer.alloc(end - start);
    if (base !== null && Math.min(end, baseVisibleSize) > start) base.copy(bytes, 0, start, Math.min(end, baseVisibleSize));
    for (const x of touching) {
      const from = Math.max(start, x.offset), to = Math.min(end, x.offset + x.data.length);
      x.data.copy(bytes, from - start, from - x.offset, to - x.offset);
    }
    chunks.push({ index, reuse: false, sha256: sha256(bytes), size: end - start });
  }
  return { baseChunks, chunks };
}

function reference({ base, baseVisibleSize, finalSize, extents }) {
  const bytes = Buffer.alloc(finalSize);
  if (base !== null) base.copy(bytes, 0, 0, baseVisibleSize);
  for (const x of extents) x.data.copy(bytes, x.offset);
  return bytes;
}

const input = JSON.parse(readFileSync(inputPath, "utf8"));
const chunkSize = input.chunkSize;
if (!Number.isSafeInteger(chunkSize) || chunkSize <= 0) fail("chunkSize must be a positive integer");
if (!Array.isArray(input.cases)) fail("cases must be an array");
const names = input.cases.map((testCase) => testCase.name);
if (new Set(names).size !== names.length) fail("case names must be unique");
for (const name of requiredCases) if (!names.includes(name)) fail(`required case ${name} is missing`);

const cases = input.cases.map((raw) => {
  const testCase = readCase(raw, chunkSize);
  const { baseChunks, chunks } = plan(testCase, chunkSize);
  const expected = chunkList(reference(testCase), chunkSize);
  const same = expected.length === chunks.length
    && expected.every((chunk, i) => chunk.sha256 === chunks[i].sha256 && chunk.size === chunks[i].size);
  if (!same) fail(`${testCase.name}: manifest rule disagrees with the reference semantics`);
  return { name: testCase.name, baseChunks, chunks };
});

const text = JSON.stringify({ chunkSize, cases }, null, 2) + "\n";
if (process.argv.includes("--check")) {
  let current = null;
  try { current = readFileSync(outputPath, "utf8"); } catch { /* reported below */ }
  if (current !== text) fail("manifests.json is stale; run `node generate-manifests.mjs`");
  console.log(`manifests.json is current (${cases.length} cases)`);
} else {
  writeFileSync(outputPath, text);
  console.log(`wrote manifests.json (${cases.length} cases)`);
}
