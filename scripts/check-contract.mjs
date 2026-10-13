#!/usr/bin/env node
// Structural checks for the public ParaAir Cloud API v1 contract (CI job "contract"). Node built-ins only.
// generate-manifests.mjs --check covers manifests.json; this covers errors.json and paths.json:
// unique snake_case codes, 4xx/5xx statuses, boolean fences, Darwin errno names with their Darwin values,
// and path vectors whose expected results are a canonical path or a known errno.
// Usage: node scripts/check-contract.mjs [CONTRACT_DIR]
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const dir = process.argv[2] ?? join(dirname(dirname(fileURLToPath(import.meta.url))), "contract", "paraair-cloud-v1");
// Darwin <sys/errno.h>. Add a name here (with its macOS value) before using it in the contract.
const DARWIN = { EPERM: 1, ENOENT: 2, EIO: 5, ENXIO: 6, EBADF: 9, EACCES: 13, EBUSY: 16, EEXIST: 17, EXDEV: 18,
  ENOTDIR: 20, EISDIR: 21, EINVAL: 22, EFBIG: 27, ENOSPC: 28, EROFS: 30, EAGAIN: 35, ENOTSUP: 45, ETIMEDOUT: 60,
  ENAMETOOLONG: 63, ENOTEMPTY: 66, EDQUOT: 69, ESTALE: 70, ECANCELED: 89, EPROTO: 100 };
const problems = [];
const load = (name) => {
  try { return JSON.parse(readFileSync(join(dir, name), "utf8")); }
  catch (error) { problems.push(`${name}: ${error.message}`); return null; }
};
const checkErrno = (where, entry) => {
  if (!(entry.errno in DARWIN)) problems.push(`${where}: unknown errno name ${entry.errno}`);
  else if (DARWIN[entry.errno] !== entry.errnoValue) problems.push(`${where}: ${entry.errno} is ${DARWIN[entry.errno]} on Darwin, not ${entry.errnoValue}`);
  if (typeof entry.fences !== "boolean") problems.push(`${where}: fences must be a boolean`);
};

const errors = load("errors.json");
if (errors) {
  if (errors.version !== 1) problems.push("errors.json: version must be 1");
  const codes = new Set();
  for (const [index, entry] of (errors.errors ?? []).entries()) {
    const where = `errors.json errors[${index}] ${entry.code}`;
    if (typeof entry.code !== "string" || !/^[a-z][a-z0-9_]*$/.test(entry.code)) problems.push(`${where}: code must be snake_case`);
    if (codes.has(entry.code)) problems.push(`${where}: duplicate code`);
    codes.add(entry.code);
    if (!Number.isInteger(entry.http) || entry.http < 400 || entry.http > 599) problems.push(`${where}: http must be 4xx or 5xx`);
    checkErrno(where, entry);
  }
  if (codes.size === 0) problems.push("errors.json: no error codes");
  const classes = (errors.unknown ?? []).map((entry, index) => { checkErrno(`errors.json unknown[${index}]`, entry); return entry.httpClass; });
  if (classes.sort().join() !== "4xx,5xx") problems.push("errors.json: unknown must map exactly 4xx and 5xx");
}

const paths = load("paths.json");
if (paths) {
  const known = new Set(Object.values(DARWIN));
  for (const [index, entry] of (paths.cases ?? []).entries()) {
    if (typeof entry.input !== "string") problems.push(`paths.json cases[${index}]: input must be a string`);
    for (const side of ["swift", "server"]) {
      const value = entry[side];
      const ok = typeof value === "string" ? value.startsWith("/") : Number.isInteger(value) && known.has(value);
      if (!ok) problems.push(`paths.json cases[${index}].${side}: expected a canonical absolute path or a Darwin errno`);
    }
  }
  if (!paths.cases?.length) problems.push("paths.json: no cases");
}

if (problems.length) {
  for (const problem of problems) console.error(`contract check: ${problem}`);
  process.exit(1);
}
console.log(`contract check PASS: ${errors.errors.length} error codes, ${paths.cases.length} path vectors`);
