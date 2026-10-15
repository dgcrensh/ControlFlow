// Checks the HTML export's player against the test vectors: each sample's scene, played
// by player.js, must match the one the app recorded (see README.md, "Test vectors").
//
//   node Schema/test_player.js
//
// Needs Node 18 or later and nothing else.
'use strict';
const fs = require('fs');
const path = require('path');

const here = __dirname;
const player = require(path.join(here, '..', 'Packages', 'ControlFlowCore', 'Sources', 'ControlFlowCore', 'Player', 'player.js'));

/// Rounds numbers to 4 decimals, as files are written.
function rounded(v) {
  if (typeof v === 'number') return Math.round(v * 10000) / 10000 || 0;
  if (Array.isArray(v)) return v.map(rounded);
  if (v && typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = rounded(v[k]);
    return out;
  }
  return v;
}

/// Where two values differ beyond 2e-4 per number, or null.
function difference(a, b, at) {
  if (typeof a === 'number' && typeof b === 'number') return Math.abs(a - b) <= 2e-4 ? null : `${at} is ${a}, expected ${b}`;
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return `${at} has ${a.length} items, expected ${b.length}`;
    for (let i = 0; i < a.length; i++) {
      const d = difference(a[i], b[i], `${at}[${i}]`);
      if (d) return d;
    }
    return null;
  }
  if (a && b && typeof a === 'object' && typeof b === 'object' && !Array.isArray(a) && !Array.isArray(b)) {
    const ka = Object.keys(a), kb = Object.keys(b);
    if (ka.join(',') !== kb.join(',')) return `${at} has keys ${ka}, expected ${kb}`;
    for (const k of ka) {
      const d = difference(a[k], b[k], `${at}.${k}`);
      if (d) return d;
    }
    return null;
  }
  return a === b ? null : `${at} is ${JSON.stringify(a)}, expected ${JSON.stringify(b)}`;
}

let failures = 0, checked = 0;
const folder = path.join(here, 'vectors');
for (const name of fs.readdirSync(folder).filter((n) => n.endsWith('.json')).sort()) {
  const vectors = JSON.parse(fs.readFileSync(path.join(folder, name), 'utf8'));
  const document = typeof vectors.document === 'string'
    ? JSON.parse(fs.readFileSync(path.join(folder, vectors.document), 'utf8')) : vectors.document;
  const timeline = new player.Timeline(player.readPresentation(document));
  for (const sample of vectors.samples) {
    const scene = timeline.playing(sample.sequence, sample.time).scene;
    const d = difference(rounded(player.sceneJSON(scene)), sample.scene, 'scene');
    checked++;
    if (d) {
      failures++;
      console.error(`${name}, sequence ${sample.sequence} at ${sample.time}s: ${d}`);
    }
    if (player.renderScene) {
      const svg = player.renderScene(scene);
      if (typeof svg !== 'string' || /NaN|undefined|Infinity/.test(svg)) {
        failures++;
        console.error(`${name}, sequence ${sample.sequence} at ${sample.time}s: the drawing has bad values`);
      }
    }
  }
}
if (failures) {
  console.error(`${failures} of ${checked} samples failed`);
  process.exit(1);
}
console.log(`All ${checked} samples match`);
