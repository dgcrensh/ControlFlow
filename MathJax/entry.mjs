// MathJax 4 as one script for a bare JavaScript context (JavaScriptCore in the app, a
// Node `vm` context in Schema/typeset_math.mjs): TeX in, SVG out, synchronously, with
// no DOM, no network and no Node globals. build.sh bundles it.
//
// Every dynamic font file of New Computer Modern is imported here, and `asyncLoad` is a
// no-op with `asyncIsSynchronous`, so `loadDynamicFilesSync()` marks them all loaded
// and a formula never needs a second pass for a rarer glyph. Errors throw, with
// MathJax's message ("Missing close brace", "Undefined control sequence \foo").
import { mathjax } from '@mathjax/src/mjs/mathjax.js';
import { TeX } from '@mathjax/src/mjs/input/tex.js';
import { SVG } from '@mathjax/src/mjs/output/svg.js';
import { liteAdaptor } from '@mathjax/src/mjs/adaptors/liteAdaptor.js';
import { RegisterHTMLHandler } from '@mathjax/src/mjs/handlers/html.js';
import '@mathjax/src/mjs/input/tex/base/BaseConfiguration.js';
import '@mathjax/src/mjs/input/tex/ams/AmsConfiguration.js';
import '@mathjax/src/mjs/input/tex/newcommand/NewcommandConfiguration.js';
import '@mathjax/src/mjs/input/tex/html/HtmlConfiguration.js';
import '@mathjax/src/mjs/input/tex/color/ColorConfiguration.js';
import { MathJaxNewcmFont } from '@mathjax/mathjax-newcm-font/mjs/svg.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/PUA.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/accents-b-i.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/accents.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/arabic.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/arrows.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/braille-d.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/braille.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/calligraphic.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/cherokee.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/cyrillic-ss.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/cyrillic.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/devanagari.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/double-struck.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/fraktur.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/greek-ss.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/greek.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/hebrew.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/latin-b.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/latin-bi.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/latin-i.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/latin.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/marrows.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/math.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/monospace-ex.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/monospace-l.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/monospace.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/mshapes.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/phonetics-ss.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/phonetics.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/sans-serif-b.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/sans-serif-bi.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/sans-serif-ex.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/sans-serif-i.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/sans-serif-r.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/sans-serif.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/script.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/shapes.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/symbols-b-i.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/symbols.js';
import '@mathjax/mathjax-newcm-font/mjs/svg/dynamic/variants.js';
const adaptor = liteAdaptor();
RegisterHTMLHandler(adaptor);
const tex = new TeX({ packages: ['base', 'ams', 'newcommand', 'html', 'color'], formatError: (jax, err) => { throw err; } });
const svg = new SVG({ fontCache: 'local', fontData: MathJaxNewcmFont });
mathjax.asyncLoad = () => null;
mathjax.asyncIsSynchronous = true;
const doc = mathjax.document('', { InputJax: tex, OutputJax: svg });
svg.font.loadDynamicFilesSync();
// Macros a formula defines (\newcommand, \def, \let) are forgotten before the next one,
// so a formula's layout never depends on what was typeset before it.
const definitions = ['new-Command', 'new-Delimiter', 'new-Environment'].map((name) => tex.parseOptions.handlers.retrieve(name));
/// `source` typeset as MathJax's SVG, in display style or inline.
globalThis.cfTypeset = function (source, display) {
  for (const map of definitions) map.map.clear();
  return adaptor.outerHTML(doc.convert(source, { display: !!display }));
};
