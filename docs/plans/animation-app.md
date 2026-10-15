# ControlFlow: Animation App Spec

Draft 1, 2026-10-15. Written from a design interview in the project thread.

ControlFlow is a fork of Character Studio (iPad, SwiftUI + Metal, Apple Pencil). It keeps the vector drawing editor and the infinite canvas, and replaces the character and rigging work with **keyframed vector presentations**. You draw a scene inside a fixed-aspect viewport, record keyframes, group them into sequences, and present them. Each interaction plays the next sequence and stops on its last keyframe.

## 1. Concepts

| Term | Meaning |
| --- | --- |
| **Scene** | Everything that is drawn: layers, groups, shapes, vertices, global colors and the viewport background. |
| **Object** | Anything in the scene with an identity (a stable integer id): layer, group, shape, vertex, global color, the viewport. |
| **Opening state** | The scene before any sequence plays. It is the first chip on the timeline and is stored in full. |
| **Keyframe** | A scene state, stored as a **delta** against the keyframe before it, plus the **transition** (duration and timing curve) that leads into it. |
| **Transition** | The animation from the previous keyframe into this one. It has one duration and one curve, which apply to everything that changes. |
| **Sequence** | A run of one or more keyframes that plays as a unit. One interaction plays one sequence. |
| **Chain** | Every keyframe of every sequence, in order, after the opening state. Sequences split the chain into the steps a presentation plays. The first keyframe of a sequence transitions from the last keyframe of the sequence before it (or from the opening state). |

## 2. What changes from Character Studio

### Kept

- The Metal canvas: infinite, with pan, zoom and rotate, the dot grid, palm rejection and low-latency ink.
- Every drawing tool: Pencil (curve fitting, QuickShape), Pen, Shapes, Select, Direct Select, Eraser and Scissors, plus snapping, the Inspector, the Edit menu, copy and paste, hide and lock, isolation, Shift and Option latches, keyboard shortcuts, and Pencil double tap, squeeze and hover.
- Appearance: fills, outlines (ends, corners, dashes, position, width along the outline, unstroked edges), opacity, gradients, clipping, global colors and the palette.
- Layers and groups, reference images, SVG import, bounded undo, and the tessellation cache.
- Project conventions from `CLAUDE.md`: logic lives in the core package with Linux-tested unit tests, the app stays thin, Swift 6 strict concurrency, a byte-stable JSON writer, and y-down points with clockwise degrees and `#RRGGBBAA` colors.

### Removed

Bones and the skeleton, binding and weights, posing and saved poses, IK and limbs, rotation limits, skins, variants, switches, parameters and parameter drivers, keyforms and their topology lock, keyform mirror, deformers, accessories with behind-owner and behind-layer shapes, turnaround aids, Rig Check, the ground line, and the `.charstudio` format.

In code (CharacterCore), these go: `Skeleton`, `Pose`, `Limbs`, `Parameters`, `ParameterDrivers`, `Keyforms`, `KeyformMirror`, `Deformers`, `Switches`, `Variants`, `Turnaround`, `RigCheck`, and `DrawingEditor+{Bones,Pose,Limbs,Parameters,KeyformTopology,Deformers,Switches,Variants,Accessories,Turnaround}`. Their tests go with them. `PathPoint.weight`, `Part.bone`, `Part.secondBone`, `accessoryOf`, `behindLayer`, `variants`, `otherSkinArt` and `VectorShape.keys` / `isBehindOwner` are removed from the model.

In the app, `ParametersPanel` and `RigCheckPanel` go. `FramePanel` becomes the viewport panel.

Renamed or reworked:
- `Part` becomes `Layer`.
- `CharacterFrame` becomes `Viewport`.
- `CharacterFormat` and `CharacterPackage` become the new 1.0 format and its package.
- `LayerTree` loses its bone grouping.

The old `.charstudio` files do not open.

## 3. Viewport

- The viewport is a fixed rectangle in world space, `width` × `height` points, with its top-left at the world origin.
- **Aspect presets:** 16:9 (default, 1920 × 1080), 4:3, 1:1 and 9:16, plus a custom W:H. Changing the aspect keeps the width and the top-left (at the world origin), and it never moves art. (Milestone 1 settled this: keeping the center would move the top-left off the origin.)
- **Background color:** an animatable property of the viewport object (default `#FFFFFFFF`).
- **While editing,** the canvas stays infinite with the dot grid. The viewport draws as a filled rectangle in its background color with a thin border. Art outside it draws dimmed (a veil at 50%, reusing the isolation veil), so off-stage art can wait there and fly in.
- **While presenting,** only the viewport draws, letterboxed to the screen, and anything outside it is cropped.
- The viewport is not animated (no camera moves) in this version; see §12.

## 4. Identity and the object model

Every object has an integer id that is unique in the document and never reused, including after undo (as today).

```
Document
  viewport: Viewport        (id, width, height, background)
  globalColors: [GlobalColor]
  palette, references       (editor-only, not keyed)
  opening: Scene            (full snapshot)
  sequences: [Sequence]

Scene
  layers: [Layer]           back to front
Layer   { id, name, transform, groups: [Group], shapes: [Shape] }
Group   { id, name, transform, isClipped }
Shape   { id, group?, transform, path, fill, gradient, fillGlobal, stroke, opacity, isClipped }
Path    { closed, points: [Vertex] }
Vertex  { id, position, inHandle, outHandle, mode, width, stroked }
```

**Vertices get ids. This is new:** today `PathPoint` is identified only by its index. Every operation that makes points must assign fresh ids. That covers fitting, the pen, shapes, inserting a point and paste or duplicate. Operations that keep points must keep their ids. That covers moving, handle edits, scissors (the split point is a new vertex) and joining paths (the joined points keep their ids). A redrawn stroke is a new shape with new vertices.

**Transforms are new:** layers, groups and shapes each get `transform = { position, rotation, scale(x, y), pivot }`. They compose layer → group → shape → vertices, and vertices are stored in the shape's local space.
- The **Select** tool's move, rotate and scale edit the selected object's transform instead of baking into the points, so a spin animates as a rotation rather than a vertex lerp that shrinks partway through.
- **Direct Select** edits vertices.
- An **Apply Transform** command bakes a transform into the points when wanted.
- The existing part pivot becomes the layer transform's pivot.

**Hidden and locked** remain editor hints and are not keyed. To make something appear or disappear in a presentation, key its opacity or create and delete it.

## 5. Keyframes as deltas

### 5.1 What a keyframe stores

A keyframe stores only what differs from the state before it, as a list of changes:

| Change | Meaning |
| --- | --- |
| `set` | Set animatable or non-animatable properties on an existing object, by id. |
| `create` | Add a new object (stored in full) under a parent at a position. For a vertex, it also records how it was born; see §6.2. |
| `delete` | Remove an object and everything under it. |
| `order` | A new child order for a parent: layers in the scene, or shapes in a layer. |

The state at keyframe *k* is the opening state with the deltas for keyframes 1 through *k* applied. On disk only the opening state and the deltas are stored.

In memory the core keeps a resolved snapshot per keyframe, built lazily. Snapshots are `Drawing`-style copy-on-write values, so unchanged layers and shapes share storage. Editing keyframe *k* invalidates the snapshots from *k* onward. A small move on one shape costs one changed shape, not a rebuilt scene.

### 5.2 Editing a keyframe

There is always a **current keyframe**, the selected chip. You edit the scene as it stands at that keyframe, and the core turns the edit into a change in that keyframe's delta, against the state at *k−1*:
- A property set back to its value at *k−1* is dropped from the delta.
- An edit **carries forward** to later keyframes until one that sets the same property, which keeps its own value.
- Deleting an object at *k* drops later changes that refer to it, in the same undo step. Undo restores them.
- Undo is unchanged in spirit: one gesture or command is one step, and the undoable state is the whole document (opening state and all deltas).

### 5.3 Set Keyframe and the timeline commands

- **Set Keyframe** (a button on the timeline strip, and **K** on the keyboard) inserts a new keyframe after the current one with an empty delta and makes it current. The new keyframe looks identical to the one before it, and your next edits become its changes. Its transition defaults to the last-used duration and curve (initially 0.5 s, ease-in-out).
- **New Sequence** inserts a new sequence after the current one, containing one new keyframe.
- **Split Sequence Here** and **Merge with Next** change sequence boundaries without changing any keyframe.
- **Delete Keyframe** folds its delta into the next keyframe, so later states look the same. The last keyframe's delta is discarded. **Revert Keyframe** empties the delta instead.
- **Duplicate Keyframe** inserts a copy of the keyframe as a hold, with an empty delta.
- Dragging a chip reorders keyframes within or between sequences. Every delta is rebuilt from the resolved states so each keyframe still looks as it did.
- Keyframes and sequences have optional names.

## 6. Interpolation

### 6.1 Values

A transition into keyframe *k* animates from the state at *k−1* to the state at *k* over `duration` seconds:

`p = curve(elapsed / duration)`, then `value = a + (b − a) × p`

Only objects named in delta *k* (and their children) can change during the transition. Everything else is static and stays in its cached GPU buffers.

| Property | How it animates |
| --- | --- |
| Numbers: transform fields, opacity, outline width, miter limit, per-point width, gradient angle, spread and stop offsets | Linear in `p`. Rotation is a plain number, so 0° → 720° spins twice. |
| Points: vertex position, in and out handles | Componentwise. Handles are offsets, as in the file. |
| Colors: fill, outline, gradient stops, global colors, viewport background | Componentwise RGBA in sRGB, not premultiplied. This matches CSS, which keeps the planned HTML export identical. |
| Everything else: closed, handle mode, ends, corners, dash style, outline position, gradient kind, clipping, fill or outline on/off, stroked edges, group membership, draw order | Snaps to the new value at the **start** of the transition. |

A shape that follows a global color animates when the global color animates. Values that overshoot from a curve with y outside [0, 1] are clamped where they must be: alpha and color to [0, 1], widths and scale to ≥ 0.

### 6.2 Vertices that appear or disappear

The two states may have different vertex lists for the same shape. The core matches vertices by id and builds a common vertex list for the transition:

- **Born vertex** (present at *k*, absent at *k−1*): its `create` change records its neighbours `after` / `before` and the curve parameter `t` where it was inserted. At the start of the transition, the shape at *k−1* is split at `t` on the segment between those neighbours, using the existing shape-preserving split (`BezierPath.insertPoint`, de Casteljau). The neighbours' handles take the split values. So the shape looks unchanged at the start and then moves to its *k* geometry. Several vertices born on one segment are split in order.
- **Dying vertex** (present at *k−1*, absent at *k*): mirrored. The healed curve at *k* is split at the vertex's recorded `t`, so the vertex rides along the curve and vanishes when the transition ends. This is smoother than sliding it onto a neighbour; see §12.
- **Fallback:** when neighbours can't be matched (the shape was rebuilt, or `closed` changed), the shape switches to its *k* topology at the start of the transition and only matched vertices animate.

Inserting a point in the editor already preserves the curve (`BezierPath.insertPoint` uses de Casteljau). The new work is recording the birth info, matching by id and building the common list.

### 6.3 Objects created and deleted

- A created object pops in at the **start** of the transition into the keyframe that creates it.
- A deleted object pops out at the **end** of the transition into the keyframe that deletes it.
- Fades are made by keying opacity.

### 6.4 Timing curves

- Each keyframe has `transition = { duration, curve }`. A `duration` of 0 is a cut.
- Presets match CSS: `linear`, `ease`, `ease-in`, `ease-out` and `ease-in-out`.
- **Custom** is a cubic Bézier `[x1, y1, x2, y2]`. The x values are clamped to [0, 1], and the y values may leave [0, 1] for anticipation and overshoot.
- The curve editor shows the curve with two draggable control points and the preset buttons, with a live preview of the transition on the canvas.
- Springs and bounces are not in this version.

## 7. Editor UI

- **Timeline strip:** a strip above the bottom style bar.
  - It starts with an **Opening** chip, followed by each sequence as a rounded block containing its keyframe chips (a thumbnail plus a number or name).
  - Between chips, a **transition handle** shows the duration and a tiny curve glyph. Tap it for the transition popover with the duration field, presets and the curve editor.
  - Tap a chip to make it current.
  - A sequence block's menu offers Play Sequence, Rename, Split, Merge and Delete.
  - **Set Keyframe** and **New Sequence** sit at the right end. The strip scrolls sideways.
- **Scrubbing:** dragging along a transition handle scrubs through it on the canvas. While scrubbing the canvas is view-only, and lifting returns to the current chip.
- **Preview:** **Play Sequence** plays the current chip's sequence from the end of the previous one, in the editor with the viewport veil on.
- **Onion skin:** a toggle shows the previous keyframe as a faint ghost, reusing the existing ghosting.
- **Changed indicator:** objects changed in the current keyframe get a small dot in the Layers panel, and the Inspector marks keyed fields, so you can see what the delta holds. **Revert to Previous** on a selection removes its changes from the current delta.
- **Panels:** the Layers panel shows layers → groups → shapes with no bones. The viewport panel (from the frame panel) sets the aspect and background.

## 8. Presenting

- **Present** (top bar) enters presentation mode at the opening state and fills the screen with the viewport.
- **Advance** plays the next sequence, keyframe after keyframe, and stops on its last keyframe. Advancing while a sequence plays jumps to that sequence's end; it doesn't queue.
- **Back** jumps instantly, with no animation, to the end of the previous sequence, or to the opening state.
- **Inputs:**
  - **Advance:** tap the right half, or press Space, →, ↓, Page Down or Return. Clickers send Page Down or arrows.
  - **Back:** tap the left half, or press ←, ↑ or Page Up.
  - **Exit:** Escape, or a two-finger pinch-in.
- **External display:** when a display is connected (cable, AirPlay or Sidecar), the viewport goes there full-screen and letterboxed. The iPad shows a presenter view with the current state, the next sequence's end state, a counter ("Sequence 3 of 12") and the Advance and Back targets.
- **Playback** runs on the display link at the display's rate (120 Hz ProMotion on the iPad). Transform-only changes are GPU uniforms with no re-tessellation. Shapes whose geometry interpolates are re-tessellated per frame (fills, strokes and dashes), so the performance target is a 60 fps floor for a typical scene of about 50 animating shapes. `PerformanceTests` gains an interpolation-and-tessellation workload.

## 9. File format 1.0

- **Document type:** a new package type, `.controlflow`, with a new UTI. The package contains `presentation.json` and `references/` (images).
- **Writer:** the same `JSONValue` writer, which keeps key order and writes at most 4 decimals, and stays byte-stable.
- **Schema:** `Schema/controlflow-1.0.schema.json`, with `Schema/README.md` rewritten and an example `Schema/examples/demo.controlflow` that `DocumentTests` re-saves byte for byte. `PresentationFormat.migrations` starts fresh at 1.0.
- **Load errors** name the JSON path of the problem, as today. An unknown id in a change is an error.

```json
{
  "formatVersion": "1.0",
  "name": "Demo",
  "viewport": { "id": 1, "width": 1920, "height": 1080, "background": "#FFFFFFFF" },
  "palette": ["#1A1A1AFF"],
  "globalColors": [{ "id": 2, "name": "Ink", "color": "#1A1A1AFF" }],
  "references": [],
  "opening": {
    "layers": [{
      "id": 3, "name": "Ball",
      "transform": { "position": [0, 0], "rotation": 0, "scale": [1, 1], "pivot": [960, 540] },
      "groups": [],
      "shapes": [{
        "id": 4, "closed": true,
        "points": [
          { "id": 5, "p": [900, 540], "in": [0, 33], "out": [0, -33] },
          { "id": 6, "p": [960, 480], "in": [-33, 0], "out": [33, 0] },
          { "id": 7, "p": [1020, 540], "in": [0, -33], "out": [0, 33] },
          { "id": 8, "p": [960, 600], "in": [33, 0], "out": [-33, 0] }
        ],
        "fill": "#E0452BFF"
      }]
    }]
  },
  "sequences": [{
    "id": 9, "name": "Bounce in",
    "keyframes": [
      { "id": 10, "transition": { "duration": 0.6, "curve": "ease-out" },
        "changes": [ { "set": 3, "props": { "transform.position": [0, -300] } } ] },
      { "id": 11, "transition": { "duration": 0.4, "curve": [0.3, 1.6, 0.6, 1] },
        "changes": [
          { "set": 4, "props": { "fill": "#2B7BE0FF", "opacity": 0.8 } },
          { "create": { "id": 12, "p": [990, 488], "in": [-15, -6], "out": [15, 6] },
            "in": 4, "after": 6, "before": 7, "t": 0.5 }
        ] }
    ]
  }]
}
```

Property keys in `set` use the same names as the object's own JSON, with dotted paths into nested values (`transform.rotation`, `stroke.width`, `gradient.stops.1.color`). Only keys that change are written, and optional keys are written only when they differ from their defaults, as today.

## 10. Static HTML export (later)

The planned export is a self-contained directory that GitHub Pages can serve as is: `index.html`, `player.js`, `presentation.json` (the same 1.0 file) and the reference-free assets. It uses relative paths and needs no build step. It has the same inputs as §8, plus swipes and URL hashes (`#3`) for deep-linking to a sequence.

Design choices now that keep this cheap later:
- The interpolation rules in §6 are written to be portable: plain lerps, sRGB colors, CSS-identical curves and documented split rules.
- The core ships **shared test vectors**, JSON fixtures of a document plus the expected interpolated state at chosen times, so a JS player can be checked against the Swift core.
- SVG covers most rendering: paths, gradients and `clipPath` for clipping. Variable-width outlines and inside or outside strokes need outlining to filled paths. The export can bake those per frame in JS or pre-outline static ones; this is decided when the export is built.

## 11. Milestones

1. **Strip and rename** (shipped): remove the character infrastructure (§2), rename the app and package to ControlFlow, add the `Viewport` with the editor veil, and keep CI green. The document format can stay on a temporary internal save until milestone 3.
   - The app, target and scheme are `ControlFlow`, the package is `ControlFlowCore`, and the bundle id is `com.dgcrensh.ControlFlow`.
   - The interim save is still a `.charstudio` package with format 0.3: the writer emits only the root bone, slots, the default skin, palette, references and an optional `viewport` key, and the reader places old files' art with their bones' rest transforms and drops the rest of the rig. Old Character Studio files therefore still open (art only) until format 1.0 replaces this.
   - The pip and tam examples went with the rig; robo stays as the format example.
   - The wiggle preview and joint caps were dropped with the rig. Symmetry, Duplicate Mirrored and pivot snapping stay.
   - Not done here: `Part` → `Layer` (it comes with milestone 2's transforms, which rework the layer model anyway) and `CharacterFormat`/`CharacterPackage` (milestone 3).
   - The viewport background is not written into SVG exports (an SVG importer would read it back as a shape); PNG exports fill it.
2. **Identity and transforms** (shipped): vertex ids everywhere, with tests that each editing operation keeps or assigns ids as §4 says. Add layer, group and shape transforms, make Select edit transforms, and add Apply Transform.
   - `Part` is now `Layer` throughout the code and the UI.
   - Vertex ids are assigned by `Drawing.assignVertexIDs()` after every commit and on open: a point with no id, or one repeating an earlier point's id in draw order, gets a fresh one. They are not saved until format 1.0, so a reopened file numbers its vertices afresh.
   - Points are stored in their shape's space and everything that draws, hit-tests or exports reads the world shapes (`Layer.worldShape`, `Drawing.world`).
   - Select composes its edit into each selected layer's or shape's transform, or a wholly selected group's. When the result would skew (a world-axis stretch across a turned object), it changes the points instead. The selection frame is oriented to a single transformed object.
   - Apply Transform bakes a layer's whole tree, a group into its shapes, or shapes' own transforms, without moving anything.
   - The interim format writes an optional `transform` object on attachments, groups and shapes, only when it isn't the default; the attachment's `pivot` stays the layer pivot.
3. **Keyframe core** (shipped): sequences, deltas, the resolver with lazy snapshots, edit-to-delta, the timeline commands (§5.3), interpolation (§6, including born and dying vertices) and format 1.0 with its schema and example. Everything is in ControlFlowCore with Linux tests and the shared test vectors.
   - `Presentation` (opening `Drawing` + `KeyframeSequence`s) and `SceneChange` are in `Presentation.swift`; `Timeline` resolves and edits states; `SceneDiff` turns two states into changes and applies them; `Interpolation` and `VertexMerge` play transitions. `DrawingEditor` edits a current keyframe and its undo stores `EditorSnapshot`s (presentation + current keyframe); the commands for milestone 4's UI are in `DrawingEditor+Timeline.swift`.
   - Not keyed, so the same at every keyframe and stored once in the opening state: the name, the viewport's size, palette, references, global colors' names, layer and group names, and hidden/locked. Editing any of them at a keyframe changes it everywhere.
   - The file writes optional keys only when they aren't their defaults, as before, so the §9 example is shorter in practice (no empty `groups`, no default transform keys). A `set` back to a default writes the default value; `null` removes keys with none (`fill`, `stroke`, `gradient`, `group`, `fillGlobal`). `closed` can be keyed (it snaps).
   - Ids are unique in the file, with one exception: a keyframe may create an object with the id of one already deleted, which is how a shape moved to another layer keeps its id (and animates as one shape). Sequence and keyframe ids share the numbering.
   - `after`/`before`/`t` on vertex changes are hints for playback only; the states come from the ids and positions. Dash lists and gradient stops that change length snap. Scale overshoot is clamped to the sign both ends share rather than to ≥ 0, so flips still animate.
   - The example is `Schema/examples/demo.controlflow`, the robot in three sequences; `.charstudio` files no longer open. Test vectors are `Schema/vectors/demo.json` and `morph.json`, documented in `Schema/README.md`.
   - The app opens and saves `.controlflow` (UTI `com.dgcrensh.controlflow.presentation`) and still edits only the opening state until the timeline UI.
4. **Timeline UI** (shipped): the strip, Set Keyframe, the transition popover and curve editor, scrubbing, Play Sequence, onion skin and changed indicators.
   - Previews (scrubbing, Play Sequence and the popover's transition preview) are a view-only scene on `DrawingEditor.preview`, separate from the document and undo; any command, undo or change of keyframe ends them, and touching the canvas stops playback. Play Sequence returns to the current chip when it ends.
   - Keyboard: **K** is Set Keyframe and Shift-Cmd-K New Sequence. Option-Cmd-O toggles the onion skin.
   - Chips are reordered by dragging one onto another (it moves in front) or onto a block's empty space (to its end). Split is on the chip's menu (Split Sequence Here) and on the block's menu (at the current keyframe).
   - The onion skin draws the previous keyframe's art with every shape at the ghost view's opacity (0.25), under the current art. It is not shown during a preview.
   - The Inspector's keyed fields: it lists the property groups the current keyframe sets on the selection and puts a dot on the position and size fields (transform or points keyed) and the fill and outline fields.
   - Chip thumbnails are the viewport drawn with `ThumbnailRenderer`, redrawn off the main thread once edits go quiet.
5. **Presenting** (shipped): presentation mode, the inputs, and the external display with the presenter view.
   - `Presenter` (ControlFlowCore) is the state machine: the sequence ends, the scene at a display time, the counter and the next end state. A sequence's clock starts on its first frame. `PresentationKey` and `PresentationTouches` turn keys and touches into Advance, Back and Exit, so the inputs are tested on Linux.
   - Back while a sequence plays returns to where it started (the end of the sequence before it). A sequence with no keyframes is passed in one Advance.
   - Presenting shows the art on the viewport's background only: no references, onion skin or overlay. It presents the document as it is when Present is pressed; Present is in the top bar and on Option-Cmd-P.
   - The external display is a `windowExternalDisplayNonInteractive` scene, which iPadOS gives the app when it would otherwise mirror (Stage Manager off). With Stage Manager on the iPad presents full-screen. The external display is black while nothing is presented.
   - The editor's keyboard shortcuts are off while presenting, since the arrows (nudge) and Escape (exit isolation) mean other things there.
   - `PerformanceTests.testPlaybackFrames` is the interpolation-and-tessellation workload: 50 shapes moving, recoloring and reshaping, one frame per call.
6. **HTML export** (later): §10.

Following `CLAUDE.md`, this file is the plan of record: update it in the same PR when a plan changes or a milestone ships, and rewrite the README milestone notes as each milestone ships.

## 12. Open questions and later ideas

These are defaults I picked without asking. Change any of them.

- **Name and extension:** ControlFlow and `.controlflow`.
- **Dying vertices** ride the healed curve (§6.2) rather than sliding onto a neighbour, which you agreed to in the interview. It is the mirror of the born rule and looks smoother.
- **Advancing mid-sequence** jumps to the end rather than queueing.
- **Hold:** a keyframe with an empty delta and a duration acts as a pause inside a sequence.
- **Later:**
  - Animating the viewport (camera pans and zooms).
  - Auto-continue (a sequence that plays straight into the next).
  - Per-shape timing overrides or stagger.
  - Springs.
  - Presenter notes.
  - Video export.
  - Morphing between unrelated shapes (by resampling).
