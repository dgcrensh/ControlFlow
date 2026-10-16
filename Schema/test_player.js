// Checks the HTML export's player against the test vectors: each sample's scene, played
// by player.js, must match the one the app recorded, and so must its text and morphing
// formula outlines where the sample has them, and each formula's outline drawn from the
// vectors' math.json (see README.md, "Test vectors").
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

/// Each text shape's glyph outline in its own space, drawn from the file's `texts` (the
/// HTML export's text.json), and each morphing formula's, drawn from its `math`, as the
/// vectors write it: `[{ shape, points }]`, each point's x, y, inX, inY, outX, outY in
/// one flat list.
function outlines(scene, texts, math) {
  const out = [];
  for (const layer of scene.layers) {
    for (const shape of layer.shapes) {
      let outline;
      if (shape.text) outline = player.textOutline(shape.text, texts);
      else if (shape.math && shape.math.morph) outline = player.formulaOutline(shape.math, math);
      else continue;
      const points = [];
      for (const p of outline) points.push(p.p[0], p.p[1], p.in[0], p.in[1], p.out[0], p.out[1]);
      out.push({ shape: shape.id, points });
    }
  }
  return out;
}

let failures = 0, checked = 0;
const folder = path.join(here, 'vectors');
for (const name of fs.readdirSync(folder).filter((n) => n.endsWith('.json')).sort()) {
  const vectors = JSON.parse(fs.readFileSync(path.join(folder, name), 'utf8'));
  const document = typeof vectors.document === 'string'
    ? JSON.parse(fs.readFileSync(path.join(folder, vectors.document), 'utf8')) : vectors.document;
  const timeline = new player.Timeline(player.readPresentation(document));
  const texts = vectors.texts ? player.readTextLayouts(vectors.texts) : null;
  const math = vectors.math ? player.readMathLayouts(vectors.math) : null;
  for (const expected of vectors.mathOutlines || []) {
    const points = [];
    for (const p of player.mathOutline(expected.math, math)) points.push(p.p[0], p.p[1], p.in[0], p.in[1], p.out[0], p.out[1]);
    const d = difference(rounded(points), expected.points, `mathOutlines ${expected.math.source}`);
    checked++;
    if (d) {
      failures++;
      console.error(`${name}: ${d}`);
    }
  }
  for (const sample of vectors.samples) {
    const scene = timeline.playing(sample.sequence, sample.time).scene;
    let d = difference(rounded(player.sceneJSON(scene)), sample.scene, 'scene');
    if (!d && sample.outlines) d = difference(rounded(outlines(scene, texts, math)), sample.outlines, 'outlines');
    checked++;
    if (d) {
      failures++;
      console.error(`${name}, sequence ${sample.sequence} at ${sample.time}s: ${d}`);
    }
    if (player.renderScene) {
      const svg = player.renderScene(scene, { texts, math });
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
