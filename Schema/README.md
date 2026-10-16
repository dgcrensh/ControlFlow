# Presentation file format 1.3

A ControlFlow document is a `.controlflow` package (a folder that Files shows as one document):

| File | What it is |
| --- | --- |
| `presentation.json` | The document. Validated by [`controlflow-1.0.schema.json`](controlflow-1.0.schema.json), which covers every 1.x version. |
| `thumbnail.png` | Optional 512 x 512 preview of the opening state. |
| `references/` | Pixels of editor-only reference images, named `reference-1.png`, `reference-2.jpg`, ... |
| `images/` | Pictures that [image](#images) shapes show (PNG, JPEG or HEIC), named by a hash of their bytes. |
| `math.json` | Optional typeset layouts of the [formulas](#math), validated by [`math-1.0.schema.json`](math-1.0.schema.json). |

[`examples/demo.controlflow`](examples/demo.controlflow) is a complete example: a robot in three sequences that turns its head, changes color, pops up a speech bubble, grows a point on it and takes it away, with a title that spreads its letters and then changes its words, a picture that fades, moves and grows, and a formula that changes from `a + b = c` to `a = c - b`. The core tests check that the app re-saves it byte for byte, and CI validates it against the schema (`python Schema/validate.py`, which checks its `math.json` too and needs `pip install "jsonschema>=4.18"`). [`vectors/`](vectors) holds the [test vectors](#test-vectors).

Character Studio's `.charstudio` files (formats 0.1 to 0.3), which ControlFlow saved until milestone 3, don't open.

## Conventions

- Points, y-axis down. Angles in degrees, clockwise on screen. Colors are `#RRGGBBAA` sRGB with straight alpha.
- Numbers are written with at most 4 decimal places. Keys are written in a fixed order, so saving twice gives the same file.
- `formatVersion` is `MAJOR.MINOR`. Readers refuse a newer major version; a newer minor version only adds keys, which older readers ignore. Older files are upgraded on open by the steps in `PresentationFormat.migrations` (none yet). 1.1 added [text](#text), 1.2 [images](#images) and 1.3 [formulas](#math); a 1.0, 1.1 or 1.2 file is a valid 1.3 file.
- Readers should ignore keys they do not know.
- **Ids** are positive whole numbers, each used once in the file: the viewport, global colors, layers, groups, shapes, vertices, sequences and keyframes all share one numbering. The one exception is an object created by a keyframe after an object with its id was deleted: a shape moved to another layer is deleted from one and created in the other with the same id, so it animates as one shape.

## The document

In this order:

- `formatVersion` and `name`, the presentation's name.
- `viewport`: the stage the presentation shows, `{ "id", "width", "height", "background" }`. Its top-left is at the world origin. It is the area the editor exports, and the area outside it is dimmed while editing. Only `background` is keyed.
- `palette`: editor-only reusable colors.
- `globalColors`: `{ "id", "name", "color" }`. A shape's `fillGlobal` and a stroke's `global` hold the id of the global color they follow, and `fill` and `color` hold its current value, so readers that ignore global colors draw the same thing. The colors are keyed, so everything following one animates with it; the names aren't.
- `references`: editor-only reference images, bottom to top, with placement (`x`, `y` center, `rotation`, `scale`), `opacity` and `hidden`. Not keyed.
- `opening`: the scene before the first keyframe, `{ "layers" }`.
- `sequences`: `{ "id", "name", "keyframes" }`, in playing order. One Advance plays one sequence.

### Scene objects

- A **layer** is `{ "id", "name", "transform", "groups", "shapes" }`, back to front. `groups` is written only when there are some.
- A **group** is `{ "id", "name" }`, with `"clipped": true` on a clipped group and an optional `transform`. A shape's `group` holds its group's id; a group's shapes are next to each other in `shapes`, and groups don't nest.
- A **shape** is `{ "id", "group", "closed", "fill", "fillGlobal", "gradient", "stroke", "opacity", "clipped", "transform", "text", "image", "points" }`, with only `id`, `closed` and `points` always written. A shape with `text` is a [text](#text), and one with `image` an [image](#images).
- A **vertex** is `{ "id", "p", "in", "out" }`: the anchor `p` and its handles as offsets from `p`. Optional keys: `w` (the outline width there as a multiple of the stroke width, blended along each segment; default 1), `smooth: false` on corner points, `symmetric: true` on points whose handles are kept equally long, and `stroked: false` to leave the segment to the next point without an outline (the fill still covers it).
- **Editor hints**: layers, groups and shapes may carry `hidden: true` and `locked: true`, written only when set. Like names, they are the same at every keyframe. The app's presentation mode and the HTML export leave hidden art out, as the SVG export does.

### Appearance

Every key here is optional and written only when it differs from its default.

- **Outline** `stroke`: `color`, `global`, `width`, then `cap` (`butt`, `round`, `square`; default `round`), `join` (`miter`, `round`, `bevel`; default `round`), `miterLimit` (in half-widths; default 4), `dash` (dash and gap lengths in points, alternating from a dash; an odd list repeats twice), `dashOffset`, and `align` (`center`, `inside`, `outside`; closed paths only, default `center`). The outline is drawn as separate open runs over the stroked segments, each ending in the stroke's `cap`, and dashes start afresh on each run.
- **Gradients**: `gradient` replaces a shape's solid `fill` with `{ "type", "start", "end", "stops" }`. `linear` runs from `start` to `end`; `radial` runs from `start` (the center) out to the circle through `end`. Stops are `{ "offset", "color" }`, interpolated in straight alpha. The points are in the shape's space. `fill` stays as the color for readers without gradients (the app keeps it equal to the first stop).
- **Opacity**: `opacity` (0 to 1) multiplies the alpha of the fill and of the outline, each on its own.
- **Clipping**: a shape with `clipped: true` draws only where the nearest unclipped shape below it in the same layer draws (its fill and outline). Several clipped shapes in a row share that base, and one with nothing below it draws unclipped. In a group the base is looked for only within the group. A clipped group draws only where the nearest shape below the group that isn't clipped (or in another clipped group) draws, and clipping inside it still works.

### Text

A shape with a `text` key is a text: its words are laid out in the shape's own space and filled with the shape's `fill` (and `fillGlobal`), `opacity`, `transform` and clipping, like any closed shape. A text has `"closed": true` and empty `points`, and a `stroke` on it is not drawn (outlines on text come later). Readers that don't know `text` (1.0 readers) see an empty shape and draw nothing.

`text` is `{ "string", "font", "weight", "italic", "size", "align", "width", "lineHeight", "tracking" }`, with only `string` always written:

- `string`: the words; `\n` breaks a line.
- `font`: a font's PostScript name, or `"system"` (the default) for the platform's system font. A reader without the font uses the system font (the app says so when it opens the file).
- `weight` (100 to 900, default 400) and `italic` (default false).
- `size`: in points, default 72.
- `align`: `left` (default), `center` or `right`.
- `width`: the box's width, which lines wrap to (before the word that would overflow it). Without it the text is one line per `\n` and the box is as wide as the widest line; the other lines align within it.
- `lineHeight`: line spacing as a multiple of `size`, default 1.2. Line n's box starts n × spacing below the origin, and the line's ascent and descent sit centered in it.
- `tracking`: extra points after each character but each line's last, default 0.

The box's top-left is the shape's origin. Where lines break and how the glyphs look depend on the font, so a reader with other fonts can set a text differently. The app hit-tests a text by its box, and its SVG export and HTML export carry the glyphs as outlines (the HTML export in `text.json`, beside `presentation.json`), so they look as the app does.

### Images

A shape with an `image` key is an image: `{ "src" }`, the picture's file in the package, such as `images/58522a450cf10d19.png`. The file is directly in `images/` and named by a 64-bit FNV-1a hash of its bytes (16 hex digits) and its type's extension, so the same picture inserted twice is stored once and a name always means the same pixels. A `src` naming anything else is an error.

An image has `"closed": true` and four straight-edged corner points: top-left, top-right, bottom-right and bottom-left. The picture is stretched over the frame they make, mapping its top-left, top-right and bottom-left corners to points 0, 1 and 3, and drawn with the shape's `opacity`, `transform` and clipping in place of a fill (a `fill` on it is not drawn); a `stroke` draws over it as on any shape. Transforms keep the frame a parallelogram. Since the frame is ordinary points and a transform, an image's place and size animate as any shape's do, and so does its opacity; a new `src` takes effect at the start of a transition. Readers that don't know `image` (1.1 and older) see a closed shape with no fill and draw only its outline, if any.

The HTML export copies each picture the presentation shows to the same path beside `presentation.json`.

### Math

A shape with a `math` key is a formula: LaTeX math typeset in the shape's own space and filled with the shape's `fill` (and `fillGlobal`), `opacity`, `transform` and clipping, like a text. A formula has `"closed": true` and empty `points`, and a `stroke` on it is not drawn. Readers that don't know `math` (1.2 and older) see an empty shape and draw nothing.

- `source`: LaTeX math without `$` or `\[ \]`, as MathJax 4's TeX input reads it (with the AMS, `newcommand`, `html` and `color` packages). Colors inside it are ignored: the shape's fill colors the whole formula.
- `size`: points per em, default 72.
- `display`: display style (`true`, the default) or inline style (`false`, smaller fractions and limits).

The box's top-left is the shape's origin. A formula's look depends on the typesetter, so the app keeps every formula's layout in **`math.json`** beside `presentation.json`, and draws, hit-tests and exports from it: a document opens without typesetting, and a formula looks the same after an app update until it is edited or retypeset. `math.json` is a cache. A formula it leaves out (or a file without it) is typeset when needed, and a `math.json` that doesn't read is ignored.

```
{ "engine": "mathjax-4.1.3/newcm",
  "glyphs": { "NCM-I-1D44E": [[x, y, inX, inY, outX, outY, ...], ...], ... },
  "formulas": [
    { "math": { "source": "a + b = c" }, "box": [w, h], "baseline": b,
      "glyphs": [{ "key", "place": [a, b, c, d, tx, ty], "tags", "source" }],
      "rules": [[x, y, w, h]] } ] }
```

- `glyphs` holds each glyph's closed contours once for the file, keyed by font, variant and code point (`NCM-I-1D44E` is New Computer Modern's italic 𝑎), in glyph units: 1000 per em, y up, each point's position and handle offsets in one flat list.
- `formulas` has one entry per distinct formula a keyframe shows, in draw order with the first keyframe first, keyed by its `math` object exactly as the shape writes it. Its `box` (the top-left at 0, 0), `baseline`, glyph `place`s and `rules` are in thousandths of an em with y down, so multiplying by `size / 1000` gives points in the shape's space. A glyph is its contours mapped by `place` (`x' = a x + c y + tx`, `y' = b x + d y + ty`); `tags` are the `\class` names it sits in, outermost first, and `source` is the LaTeX it came from. `rules` are fraction bars and overlines.
- A formula draws as all its placed contours and its rules filled together (non-zero), each rule wound the same way as the glyphs, so a rule overlapping a glyph adds to it.
- `engine` names the typesetter and font that made the layouts. When formulas in one file come from two engines, each formula has its own `engine` and the top level has none.

The HTML export writes the same `math.json` for the formulas it shows, and its player draws them from it, so the page needs no typesetter or fonts.

### Transforms

- `transform` is `{ "position", "rotation", "scale", "pivot" }`: the object scales by `scale` and turns by `rotation` (degrees, clockwise) about `pivot`, then moves by `position`. As a matrix, `translate(position + pivot) · rotate(rotation) · scale(scale) · translate(-pivot)`.
- They compose layer, then group, then shape, and a shape's `points` (and its gradient) are in the shape's own space. An outline's width scales with the transform as the art does.
- `transform` is written only when it moves something, and each key only when it isn't its default (`[0, 0]`, `0`, `[1, 1]`, `[0, 0]`).
- `rotation` is not wrapped, so `720` is two turns, and a negative `scale` flips.

## Keyframes

A keyframe is `{ "id", "name", "transition", "changes" }`. The scene at a keyframe is the opening scene with the changes of every keyframe up to it applied in order. A keyframe with no changes is a hold.

`transition` is the animation into the keyframe: `{ "duration", "curve" }`, defaulting to 0.5 seconds of `ease-in-out`. A `duration` of 0 is a cut. `curve` is one of CSS's `linear`, `ease`, `ease-in`, `ease-out` and `ease-in-out`, or `[x1, y1, x2, y2]` for CSS's `cubic-bezier`: the x values are in 0 to 1 and the y values may leave it to overshoot.

### Changes

Each change applies to the scene left by the changes before it, and must refer to objects that are there (a file whose change names a missing object doesn't open, and the error names the change's path).

| Change | Meaning |
| --- | --- |
| `{ "set": id, "props": { ... } }` | Sets properties of a layer, group, shape or vertex, the viewport (`background`) or a global color (`color`). |
| `{ "create": object, "in": parent, "after": sibling, "before": vertex, "t": t }` | Adds a layer (no `in`), a group or shape (`in` a layer) or a vertex (`in` a shape), with everything under it. |
| `{ "delete": id, "t": t }` | Removes a layer, group, shape or vertex and everything under it. A group's shapes stay, ungrouped. |
| `{ "order": [ids], "in": parent }` | A new order for the layers (no `in`), a layer's shapes or a shape's points. Children not listed keep their places. |

- **`props`** keys are the object's own keys, with dotted paths into nested values: `transform.rotation`, `stroke.width`, `gradient.stops.1.color`. Setting a nested key creates the objects above it. A key set back to its default is written as the default (`"opacity": 1`); one with no default (`fill`, `stroke`, `gradient`, `group`, `fillGlobal`) is removed with `null`. Ids, names, editor hints and children (`points`, `shapes`, `groups`) can't be set; a shape's `closed` can. The app writes only the keys that change, comparing objects key by key and gradient stops one by one, and writes other arrays (`p`, `dash`) whole.
- **`after`** places a created object after that sibling, or first without it. Groups have no order and ignore it.
- **`before`** and **`t`** on a created vertex say where it was born: on the segment from `after` to `before`, at curve parameter `t`. When several are born on one segment, each `t` is measured on what is left of the segment after the one before. On a deleted vertex, `t` is where it sits on the healed segment. Both are hints for [transitions](#transitions): a reader that ignores them still gets the right scenes.
- The app writes a keyframe's changes in the order removals, additions, property sets, orders.

## Transitions

A transition into a keyframe animates from the scene before it to its own over `duration` seconds. At `elapsed` seconds the progress is `p = curve(elapsed / duration)`, the curve's y where its x is that fraction, and each value is `a + (b - a) × p`:

- **Numbers** (transform fields, opacity, outline width, miter limit, dash lengths and offset, per-point width, gradient points and stop offsets) and **points** (vertex positions and handle offsets) move linearly. Rotation is a plain number, so 0 to 720 turns twice.
- **Colors** (fills, outlines, gradient stops, global colors, the viewport background) move componentwise in sRGB with straight alpha, as CSS does. Shapes following a global color follow it as it moves.
- **Text**: `tracking` and `lineHeight` move like numbers, with lines broken as they will be at the end. Every other text key (`string`, `font`, `weight`, `italic`, `size`, `align`, `width`) takes its new value at the start.
- **Images**: an image's `src` takes its new value at the start; its frame (points and transform) and opacity move like any shape's.
- **Formulas**: a formula whose `source`, `size` or `display` changes **morphs** between its two layouts (from `math.json`). Glyphs are matched in reading order in three passes: glyphs whose innermost `\class` tag is in both formulas match only within that tag, the k-th of a key with the k-th of the same key; then the rest by key; then what is left by font and code point whatever the variant (the key's first and last `-` parts, so `NCM-N-28` matches `NCM-S3-28`). Rules match in order. A matched glyph's `place` (all six numbers) and a matched rule's `x, y, w, h` move like numbers; a matched glyph whose key changes draws its old outline while `p < 0.5` and its new one after. A glyph or rule only in the old formula scales by `1 - p`, and one only in the new by `p` (each kept in 0 to 1), about its center (a glyph's is the middle of its contours' anchors and handles, placed; one at scale 0 is not drawn). The frame is drawn as a static formula is, the glyphs in the new formula's order (new and matched ones), then the old one's leaving glyphs, then the rules likewise; at `p` = 0 and 1 it is exactly the old and the new formula. While either layout is missing, the formula takes its new value at the start.
- **Everything else** takes its new value at the **start**: `closed`, handle modes, ends, corners, outline position, gradient kind, clipping, fill or outline turned on or off, stroked edges, group membership and draw order. Dash lists and gradient stops that change length snap too.
- **Created** objects appear at the start. **Deleted** objects stay, as they were, until the end, in their old place.
- Values a curve carries past its ends are clamped where they must be: colors and opacity to 0 to 1, widths to 0 or more, the miter limit to 1 or more, and a scale to the sign both ends share.

### Vertices born and dying

A shape whose vertices change lines them up by id:

- A vertex **born** on a segment between two vertices present at both ends starts on the old curve: the old segment is split at its `t` (de Casteljau, as inserting a point does), and the neighbours' handles take the split values, so the shape looks unchanged at the start and then moves to its new geometry. Several born on one segment split it in turn.
- A vertex **dying** on a segment is mirrored: the healed segment is split at its `t`, so the vertex rides along the curve and vanishes at the end.
- On an open path, a vertex born or dying past the last vertex present at both ends grows out of (or shrinks into) that end vertex, with no handles.
- When there is no vertex in common, `closed` changes, the common vertices change order, or one segment both gains and loses vertices, the shape takes its new points at the start and only the vertices in common move.

## Test vectors

The files in [`vectors/`](vectors) check another player (such as the HTML export's) against the app. Each holds a `document`, a path to a `presentation.json` relative to the file or the document itself, and `samples`: `{ "sequence", "time", "scene" }`, the scene expected `time` seconds into playing that sequence (by index) from the end of the one before it. Times are each sequence's start, a quarter, half and three quarters into each transition, and each keyframe's end.

A `scene` is `{ "background", "globalColors", "layers" }`, in the file's own JSON for those objects, with numbers rounded to 4 decimals; compare numbers to within 0.0002. Layers include objects that are leaving.

Glyph shapes depend on the font, so the vectors check text against a stand-in font that draws every character as a box with a hole (ControlFlowCore's `StubTextShaper`). A file with text also has `texts`, the `text.json` the HTML export would write for it with that font (each text's lines, and its glyphs' outlines as flat `x, y, inX, inY, outX, outY` lists), and samples where a text's spacing is moving have `outlines`: `[{ "shape", "points" }]`, each text's glyphs as one path in its own space, bridged into one ring as the app does, drawn from `texts`. Samples where a formula is morphing have its frame in `outlines` too, drawn from `math`.

Formulas are checked against real MathJax output: a file with formulas has `math`, the `math.json` the HTML export would write for it, and `mathOutlines`: `[{ "math", "points" }]`, each formula's glyphs and rules as one path in its own space, bridged as the app does, drawn from `math`.

- `demo.json` plays the example.
- `morph.json` exercises each rule: points born and dying on segments and at an open path's end, turns past 360, a flip, an overshooting curve and color, a cut, a shape created and one deleted, a new draw order, a shape that can't be merged, and a wrapping text whose spacing and words change.

`TestVectorTests` checks them; run it with `UPDATE_VECTORS=1` to write them afresh after an intended change to these rules. `test_player.js` (`node Schema/test_player.js`, Node 18 or later) checks the HTML export's player against the same samples, so a change to these rules goes into `Packages/ControlFlowCore/Sources/ControlFlowCore/Player/player.js` too.
