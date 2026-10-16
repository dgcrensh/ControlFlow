# Text

Draft 1, 2026-10-15. The text half of the "rotation lock and text" design; the decisions were answered with the recommended options: editing in place on the canvas, and shipping without letter-by-letter morphing, mixed styles or outlines on text.

## Status

**Shipped** (phases 1 and 2 below):

- `TextContent`, `TextLayout`, the `TextShaper` protocol and `StubTextShaper`, and the `TextShaping` registry and layout cache (`Text.swift`). The app sets its `CoreTextShaper` at launch.
- A text shape stores its words, never its glyphs: everything that draws or hit-tests reads `VectorShape.resolvingText()` (through `Drawing.world` and `Layer.worldShape`), which lays the glyphs into the path and sets `textFrame`, the box. Transforms that would bake into points (Apply Transform, moving a shape between layers) fold into a text's own transform instead. Taps hit a text anywhere in its box.
- The Text tool, in-place editing (`DrawingEditor+Text.swift`: `TextEditing`, `TextEditState`, the edit session as one undo step), the side handles that change a box's wrap width, double tap with Select, Convert to Outlines, and the context bar's style controls with the font picker.
- Format 1.1 (`text` on shapes and `text.*` keyframe properties), the schema, `Schema/README.md`, the example's title, and the test vectors.
- Exports: SVG, PNG and thumbnails draw text as outlines through the same layout. The HTML export writes `text.json` and `player.js` draws from it.

**Changed from the design:**

- `text.json` lists each distinct text with its layout (lines and glyph outlines as flat point lists, not SVG path data), keyed by the text itself rather than a hash, so the player matches them exactly and can redo the tracking and line height adjustment mid-transition. A text partway through a transition is laid out at the end keyframe's spacing (`TextContent.held`) and its glyphs moved for the spacing in between, in Swift (`TextLayout.adjusted`) and in the player alike.
- There is no special tessellation key: a resolved text shape's path changes when its layout does, which the tessellation cache already notices.
- Undo while typing undoes the whole edit session and ends it, since the session is one undo step.
- A font the iPad doesn't have is named in a toast when the document opens.
- Cut, Copy and Paste act on the words while a text is being typed into, and single-key shortcuts (tools, nudge, Delete, K, Escape for isolation) are off so the keys type.

**Shipped later:**

- **Weights within one text** (format 1.4): `TextContent.weights` holds runs of the words in another weight than the text's own, as `{ start, length, weight }` in UTF-16 offsets, written only when there are any. The whole-text `weight` stays the base, so older files and readers are unchanged, and a 1.3 reader draws the text in its base weight.
  - Editing: while typing, the context bar's weight sets the selected words (part of the session's undo step), or with a caret the weight typed next (`TextEditState.typingWeight`, forgotten when the caret moves). Command-B toggles bold the same way. New words take the weight of the character before them. With a text selected but not being typed into, the weight sets the whole text and clears the runs, as before.
  - `TextContent.replaceString` maps the runs through a change the text view reports as a whole new string: the change is taken to start no later than the old selection and the new caret, which settles which of two equal letters was typed or deleted, and characters that stayed the same at the ends of the changed stretch keep their weights (autocorrect).
  - Runs snap at the start of a transition like `weight`. Only the system font has weights, as for `weight`; a named font draws in its own face throughout.

**Later** (phase 3): letter-by-letter morph, outlines on text, other mixed styles within one text (italic, size, font, color), weights for named fonts, SVG `<text>` import, a typewriter-style reveal.

## Design

### What exists today

There is no text anywhere: no CoreText in the app, `<text>` is skipped by SVG import (`Core/SVGImporter.swift:46-47`), and nothing in the plans mentions it. The pieces that help:

- Fills render with **stencil-then-cover, non-zero winding** (`Core/ArtBatch.swift:185-193`), so glyph outlines with holes (o, e, A) draw correctly as they are.
- SVG import already joins a shape's rings into one path with zero-area bridges (`SVGImporter.bridged`, lines 750-790), which is how a glyph can become ordinary shapes.
- The player draws SVG `<path>`s, so text exported as outlines needs nothing new in the browser and doesn't depend on the viewer's fonts.
- Select already edits transforms, and transforms animate smoothly.

### The object

A text object is a **`VectorShape` with a `text` payload and no points**, rather than a new node kind. It reuses everything a shape already has: its id, layer and group membership, draw order, transform, fill (color, global color, gradient), opacity, clipping, hide and lock, selection, the Layers panel, copy and paste, and undo. The only new thing is where its geometry comes from: its glyph outlines are laid out from the text instead of read from `path`.

```
TextContent {
  string: String
  font: String          PostScript name, or "system" (the default)
  weight: Int           400 by default; only for "system"
  italic: Bool          only for "system"
  size: Double          points, default 72
  align: left | center | right
  width: Double?        nil: one line per paragraph, grows as you type
                        a number: wraps at that width (a text box)
  lineHeight: Double    multiple of size, default 1.2
  tracking: Double      extra space between letters, in points, default 0
}
```

- One style per text object in this version (no bold word in the middle of a sentence).
- The origin is the top-left of the first line's box, in the shape's own space, so the transform positions, turns and scales it like any shape. The default pivot is the box center.
- Fill only in this version. Outlines on text (the stroker on glyph contours) come later; the Outline section of the Appearance panel is disabled for text.

### Layout and rendering

ControlFlowCore can't use CoreText (it is tested on Linux), so layout goes through a protocol:

```swift
public protocol TextShaper: Sendable {
    func layout(_ text: TextContent) -> TextLayout
}
public struct TextLayout {
    var glyphs: [Glyph]         // contours (closed BezierPaths) and offset per glyph
    var lines: [LineBox]        // for hit testing, the caret and the selection frame
    var bounds: Rect
    var caretStops: [Point]     // one per character boundary, for editing
}
```

- **The app's shaper** uses CoreText (`CTFramesetter` for line breaking, `CTFontCreatePathForGlyph` for outlines, converting `CGPath` quads and cubics to `BezierPath`). Glyph outlines are cached per font and glyph, so laying out a string again is cheap.
- **The tests' shaper** is a stub in ControlFlowCore: every character is a box with a hole, fixed advance. All the logic above layout (editing, diffing, interpolation, hit testing, the file) is tested on Linux with it.
- **Rendering:** a text shape tessellates its glyph contours into one stencil fill. `TessellationCache` keys text shapes on (id, layout key) as well, so a changed string re-tessellates only that object.
- **Missing fonts:** if a file names a font the iPad doesn't have, it draws in the system font with a toast, and keeps the stored name so it comes back on a device that has it.
- **Font picker:** `UIFontPickerViewController`, which lists the system fonts and any fonts installed on the iPad.

### Editing

- **Text tool** (T on the keyboard, a "T" button in the tool strip after Shapes):
  - **Tap** the canvas: a new auto-width text at that point, already in edit mode with the keyboard up.
  - **Drag**: a text box of that width that wraps.
  - Tap an existing text with the Text tool to edit it.
- **Editing happens in place on the canvas.** A hidden `UITextView` is the input sink, so the software keyboard, a hardware keyboard, dictation, marked text (Japanese, Chinese) and autocorrect all work for free. The canvas draws the text, caret and selection from the core's layout at whatever zoom and rotation the camera has. **Scribble** works through `UIIndirectScribbleInteraction`, so you can write into a text box with the Pencil.
- The string, caret and selection logic (insert, delete, move by character and line, select word) is a small `TextEditing` value in the core, with tests; the app only forwards the text view's changes.
- **The whole editing session is one undo step**, ending when you tap outside, press Escape or change tools. Ending an edit with an empty string deletes the object.
- **Select tool:** a text object selects like a shape. Corner handles scale (transform scale, so it animates smoothly). On a text box, the side handles change its wrap width instead of stretching it, as in Keynote; on an auto-width text they scale along one axis like any shape. Double-tapping a text with Select edits it.
- **Direct Select** doesn't apply to text (taps on it select the whole object).
- **Context bar** for the Text tool and for a selected text: font, size, weight, align, and a "More" popover with line height and tracking. The Appearance panel's Fill section sets its color as for any shape.
- **Convert to Outlines** (Edit menu): turns a text into a group of ordinary shapes, one per glyph, with holes bridged. One undo step. After that the letters can be edited with Direct Select and morph by their vertices like any drawn shape.

### Keyframes

Text fits the delta model with no new kinds of change. Its fields are ordinary dotted properties in `set` changes, alongside the shape's existing ones:

```json
{ "set": 40, "props": { "text.string": "Thank you", "fill": "#2B7BE0FF" } }
```

How each property animates, following §6.1's split:

| Property | How it animates |
| --- | --- |
| Transform (position, rotation, scale, pivot), opacity, fill color, gradient | As for any shape: lerped. **This is how text moves, grows, spins and fades.** |
| `tracking`, `lineHeight` | Lerped, so a text spreading out or tightening up animates smoothly. In a wrapping box, line breaks are taken from the keyframe the transition ends on and held for the whole transition, so more tracking can't make words jump between lines partway through. |
| `string`, `font`, `weight`, `italic`, `size`, `align`, `width` | Snap at the start of the transition, like `closed` or a dash style does. |

Why `size` and `width` snap rather than lerp: either one changes where lines break, so lerping them makes words jump between lines partway through. A text that should grow on screen is scaled with Select (its transform), which lerps cleanly; the `size` field is for setting the type size you design with. I'd rather keep that one clear rule than add a lerp that sometimes looks broken.

Created and deleted text pops in and out (§6.3); fades are made with opacity, as for shapes.

#### Later: text that morphs letter by letter

The vertex-id model extends to text naturally, and the format leaves room for it, but I'd ship text without it first.

- Each character gets an id (from the same counter as everything else) the way vertices do. Typing assigns fresh ids, deleting removes them, and editing elsewhere keeps the others.
- In a transition, characters matched by id **glide from their place in the old layout to their place in the new one** (Keynote's Magic Move by character). Born characters pop in at the start, and dying characters pop out at the end, as created and deleted objects do.
- So changing "Plan" to "Planet" keeps "Plan" still and pops "et" in, changing alignment slides the whole line across, and re-wrapping a box flows words to their new lines.
- On disk this would be an optional `text.ids` array (run-length encoded as `[firstID, count]` pairs, since typed text is mostly consecutive ids), so files without it still read.
- It needs the player to port the layout result per state, so it waits until the export handles text (below).

### File format 1.1

- A text object is a shape with a `text` object and `"points": []`:

  ```json
  { "id": 40, "points": [],
    "text": { "string": "Hello", "font": "AvenirNext-DemiBold", "size": 96, "align": "center", "width": 800 },
    "fill": "#1A1A1AFF",
    "transform": { "position": [560, 400] } }
  ```

- Only keys that differ from the defaults are written, as everywhere else, and the writer stays byte-stable.
- `formatVersion` goes to **1.1**, a minor bump. Writing `"points": []` keeps it forward compatible: a 1.0 reader (an older build of the app, or an old export's player) ignores the `text` key and reads an empty shape that draws nothing, rather than misreading the create as a group. No migration step is needed, since 1.0 files contain no text.
- `controlflow-1.0.schema.json` gains the `text` definition (or the schema is renamed to 1.1; I'd keep one file and note the version in its description), and the shape's `fill` description loses "closed paths only" for text. `Schema/README.md` and `demo.controlflow` gain a title text so `DocumentTests` covers it byte for byte.

### Exports

- **SVG and PNG exports and thumbnails** draw text as outlines (paths), through the same layout. Nothing depends on the viewer's fonts.
- **HTML export:** `presentation.json` stays the same 1.1 file. The export adds `text.json`, the glyph outlines for every distinct text layout that appears in any state (keyed by a hash of the `TextContent`), as SVG path data. `player.js` looks up a text shape's layout there and draws it as a `<path>` with the shape's fill and transform, so the web page looks exactly like the iPad. `test_player.js` gets a vector with stub outlines.
- **SVG import** keeps skipping `<text>` in this version; importing it as text is a later item.
