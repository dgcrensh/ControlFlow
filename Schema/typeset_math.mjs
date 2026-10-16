// Typesets the test formulas with the MathJax the app bundles, for the core's tests on
// any platform: each formula in Tests/Fixtures/math/sources.json is written to
// Tests/Fixtures/math/<name>.svg, named as FixtureMathTypesetter looks it up. Fixtures
// no longer listed are removed.
//
//   node Schema/typeset_math.mjs
//
// The bundle is built by MathJax/build.sh (npm ci the first time) and run in an empty
// Node `vm` context, exactly as the app's JavaScriptCore runs it. Run this after
// changing MathJax or adding a test formula. Needs Node 18 or later.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtures = path.join(root, 'Packages', 'ControlFlowCore', 'Tests', 'ControlFlowCoreTests', 'Fixtures', 'math');

/// FNV-1a, 64 bits, as 16 hex digits, over UTF-8: ImageAssets.hash.
function hash(text) {
  let h = 0xcbf29ce484222325n;
  for (const byte of Buffer.from(text, 'utf8')) {
    h ^= BigInt(byte);
    h = (h * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return h.toString(16).padStart(16, '0');
}

/// The fixture's file name: FixtureMathTypesetter.fileName.
function fileName(source, display) {
  return `${hash(`${display ? 'D' : 'I'}${source}`)}.svg`;
}

const bundle = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'cf-mathjax-')), 'cf-mathjax.js');
execFileSync(path.join(root, 'MathJax', 'build.sh'), [bundle], { stdio: 'inherit' });
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(bundle, 'utf8'), context);

const sources = JSON.parse(fs.readFileSync(path.join(fixtures, 'sources.json'), 'utf8'));
const written = new Set(['sources.json']);
for (const { source, display = true } of sources) {
  const name = fileName(source, display);
  fs.writeFileSync(path.join(fixtures, name), context.cfTypeset(source, display) + '\n');
  written.add(name);
}
for (const name of fs.readdirSync(fixtures)) {
  if (!written.has(name)) fs.rmSync(path.join(fixtures, name));
}
console.log(`Wrote ${written.size - 1} formulas to ${path.relative(root, fixtures)}`);
