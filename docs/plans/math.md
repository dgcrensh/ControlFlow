# Math: LaTeX formulas

Formulas typeset from LaTeX with MathJax, drawn as shapes, saved with their layouts, and (later) morphing between keyframes. This file is the design (accepted 2026-10-16) followed by its implementation plan in four PRs.

## Status

| PR | What | State |
| --- | --- | --- |
| 1 | Formulas in the core and the file (format 1.3) | Shipped |
| 2 | MathJax in the app | Shipped; the iPad measurement (More › Time Formulas) is to do |
| 3 | The Math tool | Shipped |
| 4 | The morph | Planned |

Where PR 1 differs from the plan below:

- `MathContent` has no `morph` field yet; PR 4 adds it (and `MathMorphState`) with the morph, and makes the typesetting cache's keys ignore it.
- `math.json` stores each formula's box, baseline, glyph places and rules in thousandths of an em rather than points (the glyph outlines were already in glyph units), so rounding to 4 decimals keeps a small glyph's scale exact; readers multiply by `size / 1000`. The design's `math.source` keyframe key is what the file writes (`set` with dotted `math.*` keys, like text), since `SceneDiff` compares nested objects key by key.
- MathJax cuts a stretched extender (the middle of a tall parenthesis) to length with a nested `<svg>` window. `MathLayout.parse` squeezes such a glyph into its window, which draws the same thing because an extender is the same all along, so a layout stays glyphs and rules with no clipping.
- The fixtures live in `Packages/ControlFlowCore/Tests/ControlFlowCoreTests/Fixtures/math/`, named by an FNV-1a hash of the style and source, and `Schema/typeset_math.mjs` builds the bundle with `MathJax/build.sh` into a temporary folder rather than needing `ControlFlow/Resources/cf-mathjax.js` (which PR 2 adds).
- The test vectors carry `math` (the export's `math.json`) and `mathOutlines` (each formula's outline) once per file, rather than outlines per sample, since a formula's outline doesn't change during a transition until the morph.

Where PR 2 differs from the plan below:

- The canvas asks for missing layouts itself rather than `CanvasStore`: `CanvasRenderer` calls `MathTypesetting.requestMissing(in:)` whenever it builds the art, a preview or the onion skin, so the editor, the presenter view and an external display each ask for what they draw. `CanvasStore` asks for every formula the presentation shows when a document opens or changes, for the chips and playback, and draws the chips with formulas again when layouts arrive.
- A formula's shape doesn't change when its layout arrives, so the core tells the art: `MathTypesetting.generation` is bumped whenever layouts are stored or forgotten, `ArtBuilder` builds a layer with a formula again when it changed (other layers are reused), and the renderer rebuilds its art, preview and onion on the next frame.
- The placeholder is made in the core (`VectorShape.placeholderForMissingLayout`: the box filled with the formula's color at 12% and outlined at 35%), and `ArtBuilder` draws it for a formula without a layout. `ThumbnailRenderer` draws nothing there instead (thumbnails and exports leave such a formula out), and draws the document's thumbnail again once layouts arrive.
- CI's app build also checks that `cf-mathjax.js` is in the built app, since a resource left out would only show on the iPad.

Where PR 3 differs from the plan below:

- `MathEditState` also carries a `session` (one undo step per edit, numbered with the text sessions) and a `revision` the app watches to copy a draft it didn't type into its field (a pasted formula). `mathDraftContent` is the formula the draft would make; the store typesets it 120 ms after it last changed and hands it to `mathDraftTypeset(_:)`, which takes the content rather than a result, since `MathTypesetting` already holds the layout or the error. A draft whose layout or error is already known applies as it is typed.
- A new formula starts with an empty source, drawn as the placeholder box until its first draft typesets, and is deleted if the edit ends with the field empty or before anything typeset. Its box's left middle is where the tap was.
- Pasting plain text with the Math tool starts a new edit with the text as its draft, so a pasted formula that doesn't typeset is never kept. With the source panel open, Cut, Copy and Paste act on its field.
- Retypeset All Formulas is `forgetFormulaLayouts()` (forget and list them), then `formulaLayoutsChanged()` once the app has typeset them, which marks the document changed so `math.json` is written again.
- The context bar's Edit is `editSelectedMath()`. The source panel takes the timeline bar's place while it is open.

## Design

Draft 1, 2026-10-16. Accepted 2026-10-16: every ★ default below was approved. Nothing is built yet; the implementation plan is [below](#implementation-plan). File references are to `main` at perf round 2 step 5 (`eece28a`); `Core/` means `Packages/ControlFlowCore/Sources/ControlFlowCore/`.

A formula is typed as LaTeX math (`e^{i\pi} + 1 = 0`), typeset like TeX, and placed on the canvas as an object that moves, turns, scales, fades and is colored like any shape. Between keyframes, a changed formula morphs: symbols that are in both versions glide to their new places, and the rest shrink away or grow in. That last part is what a presentation of mathematics most wants (a derivation step by step), and it is what Keynote and PowerPoint can't do.

---

### What exists today

Text shipped (`docs/plans/text.md`), and nearly everything a formula needs is already there:

- **A shape that is laid out, not drawn.** A text is a `VectorShape` with a `text` payload and an empty path (`Core/Drawing.swift:7-58`). `resolvingText()` (`Drawing.swift:68-78`) lays the glyphs into the path wherever shapes are drawn or hit-tested, and sets `textFrame`, the box. Selection, transforms, the Layers panel, copy and paste, undo, clipping, fills and gradients all work on it unchanged.
- **Layout behind a protocol with a cache.** `TextShaper` and `TextShaping` (`Core/Text.swift:297-420`): the app plugs in CoreText, tests use `StubTextShaper`, and layouts are cached by content with a separate small cache for mid-transition frames.
- **Glyph outlines draw as one stencil fill** with holes (`Core/ArtBatch.swift`), and a text's tween already moves glyphs mid-transition (`TextLayout.adjusted`, `Text.swift:186`).
- **The HTML export ships layouts, not fonts:** `text.json` holds every text's glyph outlines as flat point lists (`Core/HTMLExport.swift:42-97`), and `player.js` draws them, so the page looks exactly like the iPad.
- **An SVG reader:** `SVGImporter` and `SVGPath` already parse path data, `<use>` with `href`, `<rect>` and nested transforms (`Core/SVGImporter.swift:482-520`).
- **Convert to Outlines** (`DrawingEditor+Text.swift:390`) turns a laid-out shape into ordinary grouped shapes.
- **The package already holds files beside `presentation.json`** (pictures in `images/`, named by hash), and the HTML export copies them.

What's missing is a TeX typesetter. ControlFlowCore can't hold one that depends on Apple frameworks (it is tested on Linux), and there is no TeX anywhere in the repo.

---

### The typesetter

#### Recommendation: MathJax 4 in JavaScriptCore, emitting SVG

The app runs **MathJax 4** (Apache 2.0) in a `JSContext` (no web view), with its TeX input and SVG output and the **New Computer Modern** math font, so formulas look like LaTeX. MathJax's SVG output is exactly the shape the core wants: every glyph is an outline in font units, placed by nested `translate`/`scale` transforms, and fraction bars and radical overbars are `<rect>`s.

I ran it to check (MathJax 4.1.3 in Node, `fontCache: 'local'`):

```
\frac{a}{b}  →
<g data-mml-node="mfrac" data-latex="\frac{a}{b}">
  <g data-mml-node="mi" data-latex="a" transform="translate(220,676)"><use data-c="1D44E" xlink:href="#MJX-1-NCM-I-1D44E"/></g>
  <g data-mml-node="mi" data-latex="b" transform="translate(270,-686)"><use data-c="1D44F" xlink:href="#MJX-1-NCM-I-1D44F"/></g>
  <rect width="729" height="60" x="120" y="220"/>
</g>
```

What that gives us, all verified in the prototype:

- **A stable name for every glyph.** `NCM-I-1D44E` is "New Computer Modern, italic variant, U+1D44E (𝑎)". This is what the morph matches on (below). Stretchy delimiters name their size (`NCM-S6-28` is the sixth-size parenthesis).
- **Structure:** `data-mml-node` (mi, mo, mfrac, msqrt…) and, new in MathJax 4, `data-latex` on each node, the source each piece came from. `\class{name}{…}` puts `class="name"` on a group, which is how a user tags parts for the morph.
- **Coverage people already know** from the web: AMS environments (`aligned`, `cases`, `pmatrix`, `gather`), `\mathbb`, `\mathcal`, `\text`, `\operatorname`, accents, `\left…\right`, and `\newcommand` within a formula. Chemistry (`mhchem`), `cancel`, `braket` and `mathtools` are extensions we can preload.
- **Errors are real errors.** With `formatError` set to throw, `\frac{a}{` fails with "Missing close brace". Undefined macros (`\foo`) render in red by default; we turn that into an error too, so a typo never ends up on a slide.
- **Speed in Node** (with a JIT): 130 ms to start, then about 5 ms per formula. A `JSContext` inside an app runs without a JIT. A one-file bundle run in Node with the JIT off took 250 ms to load and 6.8 ms per formula (see the plan), so the iPad should be in that range; PR 2 of the plan measures it there. That is fine for typing with a short debounce, but too slow to typeset while drawing frames, which shapes the caching below.
- **Size:** the `tex-svg.js` bundle is 1.8 MB including the font's common glyphs; the rest of New Computer Modern's SVG glyph data (accents, arrows, script and fraktur letters, Greek variants and so on, 40 files) is 9.6 MB unminified. Both go in the app bundle; a native module loader hands MathJax its files from the bundle when it asks, so nothing touches the network.

#### Alternatives

- **SwiftMath** (MIT, a Swift port of iosMath, 1.7.3 from August 2025, Swift 6 race-free on Swift Package Index). The runner-up. It typesets natively with CoreText and bundles a dozen OpenType math fonts, including Latin Modern. Against it: less LaTeX (no `\newcommand`, `\middle`, `\dfrac`, `\overset`, `\iint`; `\text` inside `\left…\right` draws twice); the display classes that hold stretchy delimiters, radicals, limits and fraction rules are internal, so getting every outline means vendoring a fork; ordinary runs go through `CTLine`, so a character missing from the math font falls back to a system font that can change between iPadOS versions; and its output has no source mapping, which the `\class` tags of the morph rely on. It is the better choice only if we'd rather not carry JavaScript at all.
- **MathJaxSwift** (MIT) already wraps MathJax in a `JSContext`, but it bundles MathJax 3.2.2, which has no `data-latex` and an older font, and its `MathJax` class isn't `Sendable`. Our own wrapper is about a hundred lines on the same pattern, pinned to MathJax 4; MathJaxSwift is useful as a reference.
- **KaTeX** only outputs HTML and MathML (web fonts placed by CSS), so getting outlines would mean writing a CSS layout engine. No.
- **A full TeX engine** (SwiftLaTeX's WebAssembly pdfTeX or XeTeX, Tectonic) would cover all of LaTeX, TikZ included, but needs a TeX tree of tens of megabytes, runs WebAssembly without a JIT in an app, and produces PDF that we'd still have to parse for paths. Far too heavy for formulas.

One MathJax 4 detail to handle: its larger fonts load glyph ranges on demand, so a formula using a rare symbol needs a second pass. Using `tex2svgPromise` and answering MathJax's module loader from the app bundle handles it (and is what the prototype did).

#### How it fits the core

ControlFlowCore never runs MathJax. The platform piece turns source into SVG text; the core does everything after that, so it is all tested on Linux:

```swift
public protocol MathTypesetter: Sendable {
    /// `math` typeset as MathJax SVG, or a `MathError` with MathJax's message.
    func typeset(_ math: MathContent) async throws -> String
    /// Names the engine and font, e.g. "mathjax-4.1.3/newcm", stored with each layout.
    var engine: String { get }
}

public struct MathLayout: Hashable, Sendable {
    public struct Glyph: Hashable, Sendable {
        var key: String             // "NCM-I-1D44E": font, variant, code point
        var contours: [BezierPath]  // in the glyph's own units, y down
        var place: Affine2D         // font units to the formula's points
        var tags: [String]          // \class names it sits in, outermost first
        var source: String?         // its data-latex, for the editor's hover
    }
    var glyphs: [Glyph]             // in reading (document) order
    var rules: [Rect]               // fraction bars, overlines, in order
    var bounds: Rect                // the box, origin at its top-left
    var baseline: Double
}
```

- `MathLayout.parse(svg:size:)` in the core reads MathJax's output with the existing `XMLReader` and `SVGPath`, flipping MathJax's y-up `scale(1,-1)` and scaling 1000 font units per em to `size` points. It is a small parser of its own rather than `SVGImporter`, because it must keep each glyph's identity instead of flattening everything into paths.
- **On Linux**, tests use `FixtureMathTypesetter`, which returns checked-in SVGs from `Schema/math/` keyed by source. A Node script, `Schema/typeset_math.mjs`, regenerates them with the same pinned MathJax the app bundles (Node is already on CI's schema job and in cloud sessions), so the core is tested against real MathJax output, not a stub.
- **In the app**, `MathJaxTypesetter` is an actor owning one `JSContext` on its own thread (a `JSContext` isn't `Sendable`, and one context serializes calls anyway). It starts when the first formula needs it, not at launch.

#### Caching: typeset once, stored in the file

Drawing can't wait for JavaScript, so a formula's layout must exist before a frame needs it:

- `MathTypesetting.layout(_:)` is synchronous like `TextShaping.layout`, answering from a cache keyed by `MathContent`. On a miss it starts a typeset and returns nil; the canvas draws the shape's previous layout if it has one, else a light placeholder box, and asks for a frame when the layout arrives, as images do while their texture loads.
- **The layouts are saved in the package** as `math.json` beside `presentation.json`: every formula any keyframe shows, with its outlines and the engine that made it. Opening a document then draws every formula at once, with no typesetting at all.
- **That also freezes how a formula looks.** A later app update with a newer MathJax won't nudge the spacing of a talk you've already rehearsed. A formula is retypeset only when you edit it, or when you choose **Retypeset All Formulas** (More menu) after an update.
- `math.json` is a cache: a file without it, or missing an entry, is typeset on open. Its entries are written in a fixed order with the same 4-decimal numbers as everything else, so saving stays byte-stable.

---

### The object

A formula is a **`VectorShape` with a `math` payload and no points**, exactly as a text is a shape with `text`. It reuses everything a shape has: id, layer and group, draw order, transform, fill (color, global color, gradient), opacity, clipping, hide and lock, selection, Layers, copy and paste, undo.

```
MathContent {
  source: String        LaTeX math, without $ or \[ \]
  size: Double          points per em, default 72
  display: Bool         true (default): display style, as in \[ \]
                        false: inline style, as in $ $ (smaller fractions and limits)
}
```

- The origin is the top-left of the formula's box, as for text; the default pivot is the box center. `resolvingText()` becomes `resolvingLayout()`, which fills the path from either payload and sets the box (`textFrame` becomes `layoutFrame`).
- **Color:** the whole formula takes the shape's fill, so a gradient across an equation just works. `\color` inside the source is ignored in this version (the editor says so); to color one term, Convert to Outlines, or make it a second formula. Colored runs inside one formula come later, since they need a shape with more than one fill.
- **Fill only:** like text, a stroke on a formula isn't drawn yet.
- `hasEditablePath` is false, so Direct Select, the scissors and point editing leave it alone.

---

### Editing

- **Math tool** (∑ in the tool strip after Text, key L):
  - **Tap** the canvas: a new formula there, with the editor open.
  - Tap an existing formula with the Math tool, or double-tap it with Select, to edit it.
- **The editor is a source panel docked above the keyboard**, like Keynote's equation editor but without the modal sheet: a monospaced field with the LaTeX, and the formula itself updating **live on the canvas** as you type (after a short pause), at whatever zoom and rotation the camera has.
  - **Errors** show under the field in MathJax's words ("Missing close brace"), with the faulty part underlined when MathJax says where. The canvas keeps the last version that typeset, outlined in red, so the slide never shows a broken formula.
  - **A row of insert buttons** above the keyboard (fraction, root, superscript, subscript, sum, integral, matrix, Greek, and the most used relations) puts in the LaTeX with the caret in the first empty slot, for anyone who doesn't type LaTeX daily.
  - **Scribble** works in the field, since it's an ordinary text view, for writing plain symbols with the Pencil. Recognising handwritten math as LaTeX is a later item: Apple has no API for it (Math Notes has none, and iPadOS 27's `PKStrokeRecognizer` reads words only), so it would need a model of our own.
  - Its string, caret and selection logic reuses `TextEditing` from the text work.
- **The whole edit is one undo step**, ending when you tap outside, press Escape or change tools, as for text. Ending with an empty source deletes the formula.
- **Select:** a formula selects, moves, turns and scales like any shape. All eight handles scale (there's no wrap width). Snapping, Arrange and the Inspector use its box.
- **Context bar** (Math tool, or a formula selected): size, Display or Inline, and Edit. The Appearance panel's Fill section colors it.
- **Convert to Outlines** (Edit menu, Shift-Cmd-O) works on formulas: a group of ordinary shapes, one per glyph and one per rule, holes bridged. One undo step.
- **Copy** puts the LaTeX source on the pasteboard as plain text as well as the shape, so a formula pastes into a LaTeX document or Notes. Pasting plain text while the Math tool is chosen makes a formula from it.

---

### Keyframes

A formula's fields are ordinary dotted properties in `set` changes, with no new kinds of change:

```json
{ "set": 52, "props": { "math.source": "a^2 = c^2 - b^2" } }
```

| Property | How it animates |
| --- | --- |
| Transform, opacity, fill color, gradient | As for any shape: lerped. |
| `size`, `display` | Lerped through the morph below (`size` as a scale; `display` re-lays the formula, and the morph carries it). |
| `source` | **Morphs**: the two layouts are matched glyph by glyph (below). Without the morph (phase 1), it snaps at the start like a text's words. |

#### The morph

Between two keyframes where a formula's source changes, both layouts are known (they're in the cache and the file), so every frame is built from them:

1. **Tagged parts first.** Parts wrapped in `\class{name}{…}` with the same name in both versions are matched to each other, glyph to glyph by key in order. This is how you say "this `x` is that `x`" when the automatic match would pick wrong.
2. **Then the rest by glyph.** Glyphs with the same key (same symbol, same variant) are paired in reading order: the first `b` before with the first `b` after, and so on. `a + b = c` → `a = c - b` keeps `a`, `=`, `b` and `c` and moves them; `+` shrinks away and `−` grows in.
3. **Rules** (fraction bars, radical overbars) pair in order, and their rectangles lerp, so a fraction bar stretches as its numerator grows.
4. **Stretchy delimiters** of different sizes (a `(` that grows as a matrix gets a row) pair by symbol and lerp their box; the outline swaps from the old size to the new halfway.
5. **Matched glyphs** lerp their placement: position and scale, so an exponent that comes down to the baseline (`x^2` → `2x`) also grows to full size on the way.
6. **Unmatched glyphs shrink to nothing** about their own center over the transition, and new ones grow from nothing. That keeps a formula one fill, drawn in one pass: a fade would need each glyph to have its own opacity, which the art pass doesn't do for a single shape.

The transition's timing curve drives all of it, as for everything else. The matching is deterministic and lives in the core (`MathMorph`), with tests, and `player.js` ports it, checked by new vectors in `Schema/vectors`, so the web page morphs exactly as the iPad does.

**Performance:** a morphing formula has a new outline every frame and is re-tessellated, as a text with changing tracking is today. Formulas are a few dozen glyphs, so this should be small, but it's worth a benchmark row in `PerformanceTests` (a slide with ten formulas morphing at once). If it ever shows, matched glyphs that only move could keep their tessellation and be drawn with an offset.

---

### File format 1.3

- A formula is a shape with a `math` object and `"points": []`:

  ```json
  { "id": 52, "points": [],
    "math": { "source": "e^{i\\pi} + 1 = 0", "size": 96 },
    "fill": "#1A1A1AFF",
    "transform": { "position": [960, 540] } }
  ```

  Only keys that differ from the defaults are written (`source` always).
- **`math.json`** in the package (optional, the cache above):

  ```
  { "engine": "mathjax-4.1.3/newcm",
    "formulas": [{ "math": { … }, "box": [w, h], "baseline": b,
                   "glyphs": [{ "key", "place": [a, b, c, d, tx, ty], "tags", "contours" }],
                   "rules": [[x, y, w, h], …] }] }
  ```

  Contours are flat point lists as in `text.json`. The same glyph's contours repeat for each use in this version; a shared glyph table is an easy saving if files grow.
- `formatVersion` goes to **1.3**. A 1.2 reader (an older app, or an old export's player) sees an empty shape and draws nothing, as with text. No migration step, since older files have no formulas.
- The schema gains `math` and a schema for `math.json`; `Schema/README.md` gets a "Math" section; `demo.controlflow` gains a formula that morphs between two keyframes, so `DocumentTests` covers it byte for byte and the vectors cover the morph.

### Exports

- **SVG, PNG and thumbnails** draw formulas as outlines through the same layout.
- **HTML export** copies the formulas from `math.json` that the presentation shows (as it does `text.json` and pictures), and `player.js` draws and morphs them. The page needs no MathJax and no fonts.
- **SVG import** keeps skipping text and formulas.

---

### Phasing

1. **Formulas:** `MathContent`, `MathLayout` and its SVG parser, the typesetter protocol with the fixture typesetter and the Node script, `MathJaxTypesetter` in the app with the bundled MathJax and font, the cache and `math.json`, the Math tool with the source panel, live preview and errors, Select, Convert to Outlines, copy as LaTeX, format 1.3, snapping keyframes, and every export drawing formulas statically.
2. **The morph:** `MathMorph` in the core and `player.js`, `\class` tags, test vectors, the performance row, and the README notes.
3. **Later:** colored runs (`\color`), a document-wide preamble of macros, inline math inside a text (`$…$`), handwriting to LaTeX, outlines on formulas, other math fonts (MathJax 4 has STIX Two, Fira and others), and importing an SVG of MathJax output as a formula.

Each phase updates `README.md`'s milestone notes and gets a plan in `docs/plans/math.md`, as text did.

---

### Decisions

All answered 2026-10-16 with the ★ option, which the design above assumes.


1. **Engine:** MathJax 4 in JavaScriptCore ★ (full LaTeX math, outlines and structure for the morph, about 11 MB) / SwiftMath (native Swift, smaller, less LaTeX, outlines via CoreText)
2. **Morph between keyframes:** in the first release, as phase 2 ★ / later / never (formulas always snap)
3. **Keep typeset layouts in the file** (`math.json`, so a formula never changes look after an app update): Yes ★ / No (retypeset on every open)
4. **Editing:** LaTeX source panel with live preview on the canvas ★ / a visual editor with slots (like Word's equation editor; much more work)
5. **Symbols that appear or disappear in a morph:** shrink and grow ★ / fade (needs per-glyph opacity in the renderer)
6. **`\color` inside a formula:** later ★ / now

## Implementation plan

2026-10-16. Builds the design above, with every ★ default accepted: MathJax 4 in JavaScriptCore, the morph in the first release, typeset layouts kept in the file, a LaTeX source panel with live preview, unmatched symbols that shrink and grow, and `\color` later. File references are to `main` at perf round 2 step 6 (`fa22e9d`); `Core/` means `Packages/ControlFlowCore/Sources/ControlFlowCore/` and `Tests/` means `Packages/ControlFlowCore/Tests/ControlFlowCoreTests/`.

Four PRs, each shipping working on its own. PRs 1 and 4 are core work, fully tested in the cloud (`scripts/check.sh core` and `schema`). PRs 2 and 3 are mostly app work, which only CI's `app-build` job can build, and PR 2 ends with a measurement on the iPad before PR 3 builds the editor on it.

| PR | What you can do after it | Format |
| --- | --- | --- |
| 1. Formulas in the core and the file | Open, play, present and export a file with formulas (made by hand or by tests) | 1.3 |
| 2. MathJax in the app | Formulas typeset on the iPad; typesetting time measured | — |
| 3. The Math tool | Make and edit formulas | — |
| 4. The morph | Formulas morph between keyframes, in the app and on the web page | vectors |

PR 1 adds the design and this plan as `docs/plans/math.md` (per `CLAUDE.md`), and each later PR marks its items shipped there and updates `README.md`'s notes.

#### What I checked before writing this

- **MathJax bundles into one script that typesets synchronously with no DOM, no network, no Node globals and no JIT.** The prototype (now `MathJax/entry.mjs`) was an `esbuild` bundle of MathJax 4.1.3's TeX input, SVG output, lite DOM adaptor and the New Computer Modern font, run in an empty `vm` context under `node --jitless` (the nearest stand-in for a `JSContext` in an app). It loads in 250 ms, typesets its first formula in 28 ms and then takes **6.8 ms per formula** on average over 200. The iPad's JavaScriptCore interpreter isn't V8's, so PR 2 still measures it there, but the design's guess (20 to 80 ms) now looks pessimistic.
- **The catch it solved:** MathJax 4 loads rarer glyph ranges on demand and otherwise throws "retry" (it did for `\mathfrak` and `\mathbb`). Importing every dynamic font file into the bundle, setting `mathjax.asyncLoad` to a no-op with `asyncIsSynchronous = true`, and calling `font.loadDynamicFilesSync()` once makes every formula typeset in one synchronous call.
- **Size:** the bundle is 11.3 MB (3.6 MB gzipped), one file.
- **How text shipped**, since formulas follow it: keyframes store the whole `text` object as one shape property (`Core/SceneDiff.swift:158`), not dotted keys, so formulas use one `math` property the same way (the design's `math.source` example becomes `"math": { … }`). A text partway through a tween has a never-saved `held` field (`Core/Text.swift:73`), which the morph copies.

---

### PR 1: Formulas in the core and the file

Everything here is Foundation-only and tested on Linux. The app gets no new UI, but it opens, draws and exports files with formulas, because the layouts come from `math.json`.

#### 1. Make "laid out" a shape property, not a text one

A mechanical first commit so the formula steps are small:

- `VectorShape.textFrame` → `layoutFrame`, `resolvingText()` → `resolvingLayout()`, `bakedKeepingText` → `bakedKeepingLayout`, and a new `isLaidOut` (`text != nil || math != nil`) replacing `text != nil` where the code means "its path comes from a layout": `Core/Drawing.swift:12-214, 350-379, 1122`, `Core/ArtBatch.swift:604-636, 1227-1236`, `ControlFlow/Canvas/CanvasStore.swift:513-518`, `MetalCanvasView.swift:460-469`. Places that really mean text (editing, the Text tool, fonts) keep `text`.
- No behaviour change; the existing tests are the check.

#### 2. `MathContent` and `MathLayout`: `Core/Math.swift` (new)

```swift
public struct MathContent: Hashable, Sendable, Codable {
    public var source: String
    public var size: Double = 72        // points per em, clamped to TextContent.sizeRange
    public var display: Bool = true
    /// Partway through a transition (PR 4): the formula it comes from and the progress.
    /// Never saved.
    public var morph: MathMorphState?
}

public struct MathLayout: Hashable, Sendable {
    public struct Glyph: Hashable, Sendable {
        public var key: String          // "NCM-I-1D44E"
        public var place: Affine2D      // glyph units (y up, 1000 per em) to the formula's points
        public var tags: [String]       // \class names, outermost first
        public var source: String?      // data-latex
    }
    public var outlines: [String: [BezierPath]]   // each key's contours, once, in glyph units
    public var glyphs: [Glyph]                    // document order
    public var rules: [Rect]                      // in points, document order
    public var bounds: Rect                       // origin at the top-left
    public var baseline: Double
    public var outline: BezierPath                // every glyph and rule, one bridged path
}
```

- Outlines are stored once per glyph key (a refinement of the design, which repeated them per use): a matrix of zeros is one `0` outline, not nine.
- `outline` is built once, with the rings joined by zero-area bridges as `StubTextShaper.bridging` does (`Core/Text.swift:565`), so a formula fills in one stencil pass like a text.

#### 3. Reading MathJax's SVG: `MathLayout.parse(svg:content:)` in `Core/MathLayout.swift` (new)

- Read with `XMLReader`. `<defs>` → each `<path id d>` is parsed with `SVGPath` into contours, keyed by its id with the `MJX-<n>-` prefix dropped.
- Walk the main `<g>` tree with a matrix stack (`transform` attributes: `translate`, `scale`, `matrix`; reuse `SVGImporter`'s transform parsing). `<use href>` → a glyph; `<rect>` → a rule, mapped through the current matrix; `class` → pushes a tag; `data-latex` → the glyph's `source`.
- Units: the root `viewBox` (`minX minY width height`) gives the box. Points = (glyph units × `size` / 1000), with y flipped (MathJax's root is `scale(1,-1)`), and translated so the box's top-left is the origin. `baseline` is `-minY × size / 1000`.
- Ignore `fill`/`stroke` attributes (the shape's fill colors the formula) and anything that isn't `g`, `use`, `rect` or `path`.
- Entities (`&amp;`, `&lt;`) in `data-latex` go through `XMLReader` as usual.

**Tests** (`Tests/MathLayoutTests.swift`, new), on real MathJax output from step 5: `a^2+b^2=c^2` has 7 glyphs in reading order with the expected keys; `\frac{a}{b}` has one rule between its two glyphs; the box and baseline in points for size 72; y is down; `\begin{pmatrix}` uses size-variant delimiter keys; `\class{lhs}{a+b}` tags three glyphs; `outlines` has one entry per distinct key; malformed SVG throws.

#### 4. The typesetter and its cache: `Core/MathTypesetting.swift` (new)

```swift
public struct MathError: Error, Hashable, Sendable { public var message: String }

public protocol MathTypesetter: Sendable {
    var engine: String { get }                                   // "mathjax-4.1.3/newcm"
    func typeset(_ math: MathContent) async throws(MathError) -> String
}

public enum MathTypesetting {
    public static var typesetter: (any MathTypesetter)?           // the app sets it at launch
    /// The layout if it is known; never typesets.
    public static func layout(_ math: MathContent) -> MathLayout?
    /// The error if `math` failed to typeset.
    public static func error(_ math: MathContent) -> MathError?
    /// Typesets `math` if it isn't known or in flight; `done` runs when it is.
    public static func request(_ math: MathContent, done: @Sendable @escaping () -> Void)
    /// Layouts read from a file, kept as they are (the frozen look).
    public static func insert(_ layouts: [MathContent: MathLayout], engine: String)
    /// For Retypeset All (PR 3): forget these, so the next request typesets them anew.
    public static func forget(_ maths: [MathContent])
}
```

- Same shape as `TextShaping` (`Core/Text.swift:318`): a `final class State: @unchecked Sendable` with an `NSLock`. Keys ignore `morph`.
- **No eviction.** A deck has tens to hundreds of formulas, each a few kilobytes, and an evicted layout would be retypeset by whatever MathJax the app has, which would break the frozen look. Layouts stay for the app's lifetime.
- `request` runs the typesetter on a `Task`, parses with step 3, stores the layout or the error, then calls `done`. Two requests for the same content share one typeset.

#### 5. Real MathJax output on Linux: fixtures and the Node script

- `MathJax/` at the repo root (new): `entry.mjs` (the prototype's, exposing `cfTypeset(source, display)`), `package.json` and `package-lock.json` pinning `@mathjax/src` and `@mathjax/mathjax-newcm-font` at 4.1.3, and `build.sh`, which runs `npm ci` and `esbuild` and writes `ControlFlow/Resources/cf-mathjax.js` (PR 2 adds that resource; PR 1 only needs the script).
- `Schema/typeset_math.mjs` (new): runs the same bundle in a Node `vm` context, exactly as the app runs it, and writes `Tests/Fixtures/math/<hash>.svg` for each formula listed in `Tests/Fixtures/math/sources.json`. Run it after changing MathJax or adding a test formula.
- `Tests/Fixtures/math/` is added to the test target's resources in `Packages/ControlFlowCore/Package.swift` (the first fixtures folder there).
- `FixtureMathTypesetter` (in `Tests/`) answers from those files and throws for anything unlisted. Tests set `MathTypesetting.typesetter` to it.
- A test checks that every listed source has its fixture, so a forgotten regeneration fails loudly.

#### 6. The formula shape

- `VectorShape.math: MathContent?` and `init(id:math:fill:transform:)`, beside `text` (`Core/Drawing.swift:11`).
- `resolvingLayout()`: for a formula with a known layout, `path = layout.outline` scaled into place and `layoutFrame = bounds.corners`. **With no layout yet**, the path is empty and the frame is a placeholder box of `size × size` at the origin, so it can be selected, and the renderer draws a light box there (PR 2). The resolved stroke is nil, as for text.
- `hasEditablePath` false; `visibleFill` true; hit-testing by the frame, as for text (`Core/DrawingEditor.swift:878`).
- `ArtBatch`: formulas join text in "no outline" (`Core/ArtBatch.swift:636`) and in the cheap equality checks (lines 1227-1236).
- `Drawing.hasMath` and `Presentation.mathContents` (every distinct `MathContent` any keyframe shows, morph stripped), as `imageSources` does for pictures.

**Tests** (`Tests/MathTests.swift`, new): a formula resolves to its layout's outline and box; without a layout it resolves to the placeholder; move, rotate, scale, Apply Transform and moving between layers keep the formula as a formula (`bakedKeepingLayout`); copy and paste; undo; hit-testing by box; Align uses the box (`AlignTests` pattern); `Drawing.world` keeps `math`.

#### 7. Format 1.3: `presentation.json`

- `SceneJSON`: write `"math": { "source", "size"?, "display"? }` after `text` (`Core/SceneJSON.swift:55`), only non-default keys; `readMath` beside `readText` (line 227), clamping `size` like text.
- `SceneDiff`: `"math"` joins the shape's property list (`Core/SceneDiff.swift:158`), so a changed formula is one `set` of the whole object, as a text is.
- `Interpolation`: `math` snaps at the start of a transition (PR 4 replaces this with the morph).
- `PresentationFormat.version` → 1.3. No migration step.
- `Schema/controlflow-1.0.schema.json`: the `math` object. `Schema/README.md`: a "Math" section after "Images", describing `math` and `math.json`. `Schema/validate.py` also validates `math.json` against a new `math-1.0.schema.json`.
- `demo.controlflow` gains a formula at two keyframes (`a + b = c`, then `a = c - b`) and its `math.json`, so `DocumentTests` checks both files byte for byte and PR 4's vectors have a morph to cover.

#### 8. `math.json` in the package: `Core/PresentationPackage.swift`

```
{ "engine": "mathjax-4.1.3/newcm",
  "glyphs": { "NCM-I-1D44E": [[x, y, inX, inY, outX, outY, …], …], … },
  "formulas": [
    { "math": { "source": "a + b = c" }, "box": [w, h], "baseline": b,
      "glyphs": [{ "key", "place": [a, b, c, d, tx, ty], "tags"?, "source"? }],
      "rules": [[x, y, w, h]] } ] }
```

- One glyph table for the whole file, formulas in the order `Presentation.mathContents` gives (draw order, first keyframe first), numbers to 4 decimals through `JSONValue`, so saving is byte-stable.
- `PresentationPackage.init(files:)` reads it and calls `MathTypesetting.insert`; `files()` writes the layouts of `presentation.mathContents` that are known. A formula without a layout is simply left out; it is typeset on the next open. An unreadable `math.json` is ignored, not an error: it is a cache.
- Entries keep the `engine` they were made with. If formulas in one file come from two engines (after Retypeset of some), each entry carries its own `engine` and the top-level one is omitted.

**Tests** (`Tests/MathPackageTests.swift`, new): round trip byte for byte; a file without `math.json` opens with formulas unlaid out; a damaged `math.json` is ignored; layouts for formulas no longer shown aren't written; a frozen layout survives a typesetter returning something else.

#### 9. Exports

- **SVG, PNG and thumbnails** draw formulas through `resolvingLayout()` already; add a formula to the export tests to prove it (`SVGWriter`, `ThumbnailRenderer`).
- **HTML export:** `HTMLExport` writes `math.json` for the formulas the presentation shows, in the same format as the package's (`Core/HTMLExport.swift`, beside `textFile`).
- **`player.js`:** `readMath` beside `readText` (line 159), `math.json` loaded beside `text.json`, and a formula drawn as a `<path>` from its glyph table, places and rules, with the shape's fill and transform. A formula with no layout draws nothing.
- `Schema/test_player.js` gets a formula, checked against Swift's outline.

---

### PR 2: MathJax in the app

#### 1. The bundle

- Run `MathJax/build.sh` and add `ControlFlow/Resources/cf-mathjax.js` (11.3 MB) to the app target as a resource. It's a generated file committed to the repo, as `Schema/vectors` are; `build.sh` regenerates it. Git stores it compressed (about 3.6 MB).

#### 2. `MathJaxTypesetter`: `ControlFlow/Canvas/MathJaxTypesetter.swift` (new)

```swift
actor MathJaxEngine {
    private var context: JSContext?      // made on first use
    func typeset(_ source: String, display: Bool) throws(MathError) -> String
}
struct MathJaxTypesetter: MathTypesetter {   // Sendable; forwards to one shared MathJaxEngine
    let engine = "mathjax-4.1.3/newcm"
}
```

- The actor owns the one `JSContext` (not `Sendable`, so it never leaves the actor). First use evaluates the bundle (about 250 ms); every call after that is `cfTypeset(source, display)`.
- A JavaScript exception becomes `MathError(message:)` with MathJax's text ("Missing close brace"). `noundefined` is left out of the TeX packages, so an undefined command is an error rather than red text.
- Signposts (`Signposts.swift`): "MathJax load" and "MathJax typeset", for Instruments.
- `ControlFlowApp` sets `MathTypesetting.typesetter = MathJaxTypesetter()` beside the text shaper (`ControlFlowApp.swift:11`). Nothing is loaded until a formula needs typesetting.

#### 3. Drawing formulas whose layout isn't ready

- `CanvasStore`: when a drawn formula has no layout, call `MathTypesetting.request` with a completion that marks it dirty and asks every canvas for a frame, as `ImageLibrary` does for a loaded picture. Same in the presenter view and on an external display.
- `CanvasRenderer` and `ThumbnailRenderer` draw the placeholder box for a formula without a layout (a light fill and hairline, like an image's placeholder).

#### 4. Checkpoint: measure on the iPad

You do this part, since nothing in the cloud runs iPadOS. A debug-only **More › Time Formulas** item typesets the 200-formula benchmark from the prototype and shows the load time and the average in a toast. If formulas average well under 50 ms, PR 3 goes ahead as designed. If they don't, the source panel's live preview waits longer before typesetting (the rest of the design is unaffected, since playback never typesets).

---

### PR 3: The Math tool

#### 1. Core: `Core/DrawingEditor+Math.swift` (new)

- `Tool.math` (`Core/DrawingEditor.swift:4`), added to the lists that mention `.text` where it means "a tool that picks shapes" (`DrawingEditor+ShapeIndex.swift:7`, `EditorOverlay.swift:378, 424`, `CanvasSession.swift:435`).
- `DrawingEditor.mathStyle: MathContent` (size and display for new formulas), like `textStyle`.
- `MathEditState { ref, draft: String, error: MathError?, isNew }` and `mathEdit: MathEditState?`.
- `beginMathEdit(at:)` (new formula at a tap), `beginMathEdit(ref:)` (existing formula), `setMathDraft(_:)`, `mathDraftTypeset(_:)` (the result arrives), `endMathEdit()`.
  - **The shape's `math.source` changes only when a draft typesets.** A broken draft lives in `MathEditState.draft` with its error, and the canvas keeps the last good formula, outlined in red by the overlay. So the model never holds a formula that doesn't typeset.
  - The session is one undo step, built like the text edit session (`DrawingEditor+Text.swift:221-250`): a new formula ended empty is removed without an undo step.
- Taps: with the Math tool, a tap on a formula edits it and a tap elsewhere starts a new one; with Select, a double tap on a formula edits it (`DrawingEditor.swift:761`, beside text).
- `setMathSize`, `setMathDisplay` for the context bar, on the selection and on `mathStyle`, like `setTextStyle`.
- **Convert to Outlines** (`DrawingEditor+Text.swift:390`) handles formulas: one shape per glyph (its contours placed by `place`, holes bridged) and one rectangle per rule, grouped and named after the source (first 24 characters). One undo step.
- **Copy** also puts the source on the pasteboard as plain text (`DrawingEditor+Organize.swift:468`'s clipboard text). **Paste** of plain text with the Math tool makes a formula from it.
- **Retypeset All Formulas:** `MathTypesetting.forget` for the presentation's formulas, then a request for each; the document is marked edited when they arrive so `math.json` is rewritten. Not an undo step (the presentation itself doesn't change).

**Tests** (`Tests/MathEditTests.swift`, new): begin, type a good draft, then a broken one: the shape keeps the good source and the state holds the error; end commits one undo step; a new empty formula leaves no undo step; double tap with Select edits; Convert to Outlines makes glyph and rule shapes in a named group; copy gives the source as text; paste makes a formula.

#### 2. App

- **Tool strip and keys:** a ∑ button after Text (`ContentView.swift:428`) and key L (`EditorCommands.swift:182`).
- **`MathEditorPanel`** (SwiftUI, new), docked above the keyboard while `mathEdit` is set:
  - a monospaced `UITextView` wrapper (so Scribble and the hardware keyboard work), with smart quotes and autocorrect off;
  - a row of insert buttons (fraction, root, superscript, subscript, sum, integral, matrix, Greek letters, ≤ ≥ ≠ → ∈), each inserting LaTeX with the caret in the first empty `{}`;
  - the error line under the field.
- Typing calls `setMathDraft`, and after 120 ms with no typing the store requests a typeset and calls `mathDraftTypeset` with the result. A result for a draft that has since changed is dropped.
- **Context bar** for the Math tool and for selected formulas: size, Display or Inline, Edit.
- **More menu:** Retypeset All Formulas.
- `README.md`: a "Math notes" section, as for text.

---

### PR 4: The morph

#### 1. Matching and frames: `Core/MathMorph.swift` (new)

```swift
public struct MathMorphState: Hashable, Sendable { public var from: MathContent; public var progress: Double }

public enum MathMorph {
    public struct Pairing: Hashable, Sendable {
        var glyphs: [(from: Int?, to: Int?)]   // indices into each layout's glyphs
        var rules: [(from: Int?, to: Int?)]
    }
    public static func pair(_ a: MathLayout, _ b: MathLayout) -> Pairing
    public static func outline(_ a: MathLayout, _ b: MathLayout, _ pairing: Pairing, progress p: Double) -> BezierPath
    public static func bounds(…) -> Rect       // the box lerped, for hit-testing mid-transition
}
```

- `pair` follows the design: tagged groups first (same `\class` name in both, then same key in order inside the group), then the rest by key in reading order (the k-th `b` with the k-th `b`), rules in order, and stretchy delimiters by code point when their size variants differ (a key's last part is the code point, its middle the variant; `S1`…`S6` count as one variant for this).
- `outline`: each matched glyph's `place` lerped componentwise (translation and the 2×2 part, which covers script-size changes); a delimiter whose outline differs draws the old outline until halfway, then the new one, both through the lerped place. Unmatched glyphs scale about their own centers, dying ones from 1 to 0 and born ones from 0 to 1. Rules lerp their rects; an unmatched rule scales with its center. The result is bridged into one path, as a static formula is.
- Pairings are cached by (a, b) since a transition asks for the same pair every frame.

#### 2. Wiring it in

- `Interpolation`: when `a.math != b.math` and both layouts are known, the output's `math` is `b.math` with `morph = MathMorphState(from: a.math, progress: p)`; otherwise it snaps as in PR 1.
- `resolvingLayout()`: a formula with `morph` resolves through `MathMorph.outline`.
- `ArtBatch`: a morphing formula goes down the same per-frame path as a text tween (`Core/ArtBatch.swift:969`), flattened directly and not kept in the big cache.
- `PerformanceTests`: a row with ten formulas morphing at once.

#### 3. The player and the vectors

- `player.js`: `pairMath` and `morphMath`, line for line with the Swift. The vectors make sure they agree.
- Regenerate `Schema/vectors` with `UPDATE_VECTORS=1 swift test --filter TestVectorTests`; the demo's formula morph is the new case (the PR says why, per `CLAUDE.md`).

**Tests** (`Tests/MathMorphTests.swift`, new): `a+b=c` → `a=c-b` pairs a, b, =, c and leaves + dying and − born; repeated symbols pair in order; `\class` tags override reading order; a fraction bar lerps; a growing parenthesis swaps outline at halfway; progress 0 and 1 give exactly the two static outlines; an unknown layout snaps.

---

### Risks

| Risk | How the plan handles it |
| --- | --- |
| JavaScriptCore is slower on the iPad than the prototype suggests | PR 2's checkpoint, before the editor is built. Playback and opening never typeset, so only the live preview's delay depends on it. |
| A MathJax upgrade changes how formulas look | Layouts are frozen in `math.json`; only editing or Retypeset All changes them. The fixtures and the bundle come from the same pinned `package-lock.json`. |
| An 11 MB generated file in the repo | It changes only when MathJax is upgraded on purpose. If it ever matters, Git LFS is a later switch. |
| MathJax's SVG changes shape between versions | The parser accepts only `g`, `use`, `rect` and `path` and ignores the rest; the fixture tests catch a change at upgrade time. |
| `JSContext` and Swift 6 strict concurrency | It never leaves the actor; `MathJaxTypesetter` is a `Sendable` struct forwarding to it. |
| Perf round 2 is still touching `ArtBatch` and `Text.swift` | PR 1's rename (step 1) goes first and is small, so it rebases easily onto whatever lands. |
