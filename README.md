# ControlFlow

A personal iPad app for drawing keyframed vector presentations with the Apple Pencil: you draw a scene inside a fixed-aspect viewport, record keyframes, group them into sequences and present them. It is a fork of Character Studio, keeping its vector editor and infinite canvas and replacing the character rigging.

Plan: [docs/plans/animation-app.md](docs/plans/animation-app.md).

## Layout

| Path | What it is |
| --- | --- |
| `ControlFlow.xcodeproj` | The iPad app project (Xcode 26 or later, iPadOS 26 deployment target). |
| `ControlFlow/` | App sources: SwiftUI shell, Metal canvas view, renderer, shaders. |
| `ControlFlow/Document/` | The document type (the `.controlflow` package) and its thumbnail. |
| `Config/Info.plist` | Document type and exported type declarations (merged with Xcode's generated Info.plist). |
| `Packages/ControlFlowCore/` | UI-free Swift package: geometry, camera, curve fitting, Bézier paths, the drawing model, editing tools, undo, keyframes and their interpolation, tessellation, touch routing and palm rejection, the viewport, and the JSON file format. Builds and tests on macOS or Linux. |
| `Schema/` | The file format: JSON Schema, notes, an example and the interpolation test vectors. |

## Running

1. Open `ControlFlow.xcodeproj` in Xcode.
2. Select the **ControlFlow** target, then **Signing & Capabilities**, and pick your personal team.
3. Choose your iPad as the run destination and press Run.

In the iPad Simulator there is no Pencil, so a single finger (the mouse) draws there. Option-drag gives two fingers for pan, zoom and rotate. On a real iPad only the Pencil draws.

## Tests

```sh
cd Packages/ControlFlowCore
swift test
```

Or open the package in Xcode and press Cmd-U. To run everything CI runs (core tests, schema check, iPad Simulator build), use `scripts/check.sh`; see [CLAUDE.md](CLAUDE.md#building-and-testing-on-a-mac).

## Milestones

From [the plan](docs/plans/animation-app.md#11-milestones):

1. **Strip and rename** (done; see the notes below): the character rigging is gone, the app is ControlFlow, and the viewport is in.
2. **Identity and transforms** (done; see the notes below): vertex ids, layer, group and shape transforms, Apply Transform, and Part renamed to Layer.
3. **Keyframe core** (done; see the notes below): sequences, deltas, interpolation and format 1.0, in the core with no UI yet.
4. **Timeline UI** (done; see the notes below): the timeline strip, Set Keyframe, transitions and their curve editor, scrubbing, Play Sequence, onion skin and changed indicators.
5. **Presenting** (done; see the notes below): presentation mode, its keys, taps and pinch, and the external display with the presenter view.
6. **HTML export** (done; see the notes below): Export Web Page writes a folder that GitHub Pages or any web server plays as presentation mode does.

## Milestone 1 notes (strip and rename)

**Using it**

- **Viewport:** every document has a stage, 1920 × 1080 on white by default, with its top-left at the world origin. It draws as a filled rectangle with a thin border on the infinite canvas, and art outside it is dimmed by a veil of the canvas background at 50%, so art can wait off stage. **View > Viewport** sets the aspect (16:9, 4:3, 1:1 or 9:16, keeping the width), a custom width and height, and the background color. Each edit is one undo step, and the viewport never moves the art.
- **Zoom to Fit** (Cmd-0) fits the viewport in the view, at the locked rotation while the rotation lock is on.
- **Export SVG and PNG** cover the viewport. The PNG is filled with its background; the SVG has the art only.
- **Gone:** the Bones tool, Pose mode, weights, IK and limits, the Parameters panel, keyforms, deformers, skins and variants, accessories and behind shapes, the wiggle preview and joint caps, Clean for Rig, and the character frame and its ground line. Symmetry, Duplicate Mirrored and pivot snapping stay.
- **Files:** documents are still `.charstudio` packages until format 1.0 (milestone 3). Older Character Studio files open with each layer's art where its bones put it at rest; the rig is dropped and is not saved back.

**How it works**

- **Model** (ControlFlowCore): `Viewport` (in `Viewport.swift`, replacing `CharacterFrame`) is `width`, `height` and `background` on `Drawing.viewport`. `withAspect` keeps the width, `veilTriangles(covering:)` gives the bands of the view outside the viewport, and `DrawingEditor.updateViewport` and `setViewportAspect` edit it. `Drawing.exportArea` is the viewport. Tests are in `ViewportTests`.
- **Rendering:** after the grid, the renderer fills the viewport with its background; after the art, it draws the veil triangles. The border is part of the overlay's guides.
- **Format:** the writer keeps format 0.3 but writes only the root bone, slots, the default skin, palette, references and a new optional `viewport` key; see [Schema/README.md](Schema/README.md). The reader places each slot's art with its bone's rest transform and ignores the rest of the rig.
- **Renamed:** the app, its target and scheme are ControlFlow, and the core package is `ControlFlowCore`. `Part` became `Layer` in milestone 2.

## Milestone 2 notes (identity and transforms)

**Using it**

- **Layers:** what Character Studio called a part is now a layer everywhere: the Edit menu's Move to New Layer, Move to Layer and Isolate Layer, and new layers are named Layer 1, Layer 2 and so on.
- **Select moves, rotates, scales and flips objects without touching their points.** Dragging a layer changes its transform; each selected shape changes its own transform; a whole group changes the group's. The selection frame turns with a single turned layer, shape or group, so its handles stay on the art. Rotations keep counting past a full turn (three quarter turns read 270, not -90), and a flip shows as a negative scale. Nudges, the flip buttons, rotate and the Inspector's position work the same way.
- **When no transform can hold the edit** (a stretch along the screen's axes across a turned object skews it), Select changes the points instead, as before, so the art still goes where it was dragged.
- **Direct Select, the pen, shapes and strokes work where the art is drawn:** a tap hits an anchor where it shows on screen, and new art in a turned or scaled layer lands under the Pencil.
- **Apply Transform** (Edit menu, and the button beside the flip buttons) bakes the selection's transform into its points and resets it, without moving anything: a layer's whole tree (layer, groups and shapes), a group's into its shapes, or the selected shapes' own. Outlines scale with the art, as they look. It is unavailable when there is nothing to bake. One undo step.
- **Moving art between layers keeps it where it is:** Move to Layer, Move to New Layer, Merge Down and pasting into another layer convert the shapes into their new layer's space. Duplicates and copies keep their transforms.

**How it works**

- **Model** (ControlFlowCore): `Transform` is `position`, `rotation` (degrees, clockwise, unwrapped), `scale` and `pivot`, and its `matrix` turns and scales about the pivot, then moves. `Layer`, `ShapeGroup` and `VectorShape` each have one; a layer's pivot is its transform's pivot. They compose layer, then group, then shape, and a shape's points are in its own space. `Layer.worldShape(_:)` gives a shape as drawn, and `Drawing.world` the whole drawing with every transform baked in, which rendering, caching, the shape index, hit testing and export use. Edits that work on points read and write through `worldShape`/`setWorldShape`, which convert to and from the shape's space.
- **Select** composes its drag into the right transform: `t·L` for a layer, `P⁻¹·t·P·S` for a shape under the parent matrix `P`, and the same for a group under its layer. `Transform(matrix:pivot:near:)` decomposes the result and returns nil for a skew, which is when the edit falls back to the points. `Drawing.apply(_:to:pivot:)` does this; `DrawingEditor.applyTransform()` is Apply Transform. Tests are in `ObjectTransformTests`.
- **Vertex ids:** every `PathPoint` has an `id`. `Drawing.assignVertexIDs()` runs after every commit, on opening a document and in `DrawingEditor.init`: it gives a fresh id from the document's counter to any point with none, or whose id repeats an earlier one in draw order (a copy), so copied points get new ids and every other edit keeps them. Ids are not written to the file yet (format 1.0 will). Tests for each editing operation are in `VertexIDTests`.
- **Format:** an attachment (layer), group and shape may have a `transform` object with any of `position`, `rotation`, `scale` and `pivot`, written only when it isn't the default; the attachment's `pivot` key still holds the layer's pivot. The example robot's antenna is turned 12 degrees. See [Schema/README.md](Schema/README.md#transforms).

## Milestone 3 notes (keyframe core)

**Using it**

- **Files** are now `.controlflow` packages holding `presentation.json` (format 1.0). Character Studio and earlier ControlFlow `.charstudio` files no longer open.
- Until milestone 4's timeline the app edited only the opening state. Files that hold keyframes open, keep them, and save them back; undo covers the whole presentation.

**How it works**

- **Model** (ControlFlowCore): a `Presentation` is the opening `Drawing` plus `KeyframeSequence`s of `Keyframe`s, each holding a `Transition` (duration and `TimingCurve`) and its `SceneChange`s from the state before it: `set` (dotted property keys into the object's JSON), `create`, `delete` and `order`. The opening drawing also holds what isn't keyed: names, editor hints, the palette, references, the viewport's size and global colors' names. The viewport now has an id so keyframes can set its background.
- **Timeline** resolves the state at each keyframe on demand and keeps it until an edit before it. `record(_:at:)` turns an edited state into the keyframe's changes against the one before (`SceneDiff`), so a property set back drops out, later keyframes keep their own changes (edits carry forward until one sets the same property), and changes to objects the edit deleted are dropped. Names and hints edited at any keyframe change everywhere. The commands of the plan's §5.3 are there: insert a keyframe or sequence, split and merge sequences, delete a keyframe or sequence (folding its changes into the next), revert, duplicate as a hold, move (rebuilding every keyframe's changes so each looks as it did), set a transition, rename.
- **Editor:** `DrawingEditor` edits the current keyframe (`selectKeyframe`, nil for the opening state) and commits edits into the timeline; undo stores the whole presentation and the current keyframe (`EditorSnapshot`), one step per gesture or command. The timeline commands, Revert to Previous and `changedObjects()` (for the Layers panel's changed dots) are in `DrawingEditor+Timeline.swift`, ready for milestone 4's UI.
- **Interpolation:** `Timeline.transition(into:elapsed:)` and `playing(sequence:at:)` give the scene partway through a transition: numbers, points and sRGB colors lerp, other values snap at the start, created objects appear at the start and deleted ones leave at the end. `VertexMerge` lines up vertices by id so a point born on a segment starts on the old curve and a dying one rides the healed curve. See [Schema/README.md](Schema/README.md#transitions).
- **Format 1.0:** `PresentationFormat` and `PresentationPackage` replace the Character Studio format. Ids are saved (vertices' included) and checked to be unique, and a change naming an object that isn't there is a load error with its path. The example is now [`Schema/examples/demo.controlflow`](Schema/examples/demo.controlflow), three sequences of the robot; the schema is [`controlflow-1.0.schema.json`](Schema/controlflow-1.0.schema.json).
- **Test vectors:** [`Schema/vectors`](Schema/vectors) records the scenes expected while the example and a set of morphs play, for checking the HTML player against this one (`TestVectorTests`). Tests for the rest are in `KeyframeTests.swift` and `DocumentTests.swift`.

## Milestone 4 notes (timeline UI)

**Using it**

- **Timeline strip:** above the style bar. It starts with the **Opening** chip, then each sequence as a rounded block of keyframe chips; each chip shows a thumbnail of the viewport and the keyframe's number or name. Tap a chip to edit the scene at that keyframe; your edits become that keyframe's changes. The strip scrolls sideways and follows the current chip.
- **Set Keyframe** (the button at the strip's right end, or **K**) adds a keyframe after the current one that looks the same, with the last transition used, and makes it current. **New Sequence** (Shift-Cmd-K) starts a sequence after the current one.
- **Keyframe menu** (touch and hold a chip): Rename, Duplicate Keyframe (a hold), Revert Keyframe, Split Sequence Here and Delete Keyframe. Drag a chip onto another to move it in front of that one, or onto a block's empty space to move it to the block's end; every keyframe still looks as it did. **Sequence menu** (the ellipsis on a block): Play Sequence, Rename, Split at Current Keyframe, Merge with Next and Delete Sequence.
- **Transitions:** the handle before each chip shows the transition's duration ("Cut" for 0) and a tiny curve. Tap it for the popover: the duration (stepper and slider), the CSS presets (Linear, Ease, Ease In, Ease Out, Ease In Out) and a curve editor with two control points to drag; a curve dragged onto a preset's shape becomes that preset, and the control points can leave the square for overshoot and anticipation. Each change plays the transition on the canvas, and **Preview** plays it again. A slider or handle drag is one undo step.
- **Scrubbing:** drag along a transition handle to scrub through it on the canvas. The canvas is view-only while scrubbing (two fingers still pan and zoom), and lifting returns to the current chip.
- **Play Sequence** (the play button, or a block's menu) plays the current chip's sequence from the end of the one before it, in the editor with the viewport veil on, then returns to the current chip. Touching the canvas or pressing Stop ends it.
- **Onion skin** (the strip's layers button, View menu, or Option-Cmd-O) shows the keyframe before the current one as a faint ghost under the art.
- **Changed indicators:** layers and groups the current keyframe changes get an orange dot in the Layers panel. At a keyframe the Inspector lists what it keys on the selection (Transform, Points, Fill, Outline and so on), marks the fields it keys with a dot, and offers **Revert to Previous**, which is also in the Edit menu: the selection goes back to how it was at the keyframe before, so this keyframe no longer changes it.

**How it works**

- **Previews** (ControlFlowCore): `DrawingEditor.preview` is a scene the canvas shows in place of `drawing`, set by `scrubPreview(into:fraction:)` and `playPreview(_:at:)` and cleared by `endPreview()`, any timeline command, undo and changing keyframe. It never touches the document or undo. `displayRevision` changes with what the canvas shows, so the renderer and the overlay rebuild for a preview without the document being handed off for saving. While there is a preview `CanvasSession` ignores the Pencil, hover and tap undo, and the overlay draws only the viewport border (and the outline view's wireframe of the preview). `Timeline.playing(_:at:)` plays any run of keyframes.
- **Playback** runs on the canvas's display link: each frame `CanvasStore.playbackFrame(at:)` asks for the scene at the frame's display time.
- **Onion skin:** `DrawingEditor.onionSkin` is the previous keyframe's state while `showsOnionSkin` is on; the renderer builds it with its own `ArtBuilder`, every shape at the ghost view's opacity, and draws it under the art.
- **Strip model:** `TimelineStrip` (chips, blocks, titles, durations), `Transition.durationLabel`, and `TimingCurve.moving(controlPoint:to:)`, `normalized` and `samples(count:)` for the curve editor and glyphs. `keyedProperties()` gives what the current keyframe keys on the selection, and `TimelineStrip.propertyNames` names it for the Inspector. Thumbnails are drawn off the main thread with `ThumbnailRenderer` once edits go quiet, only for keyframes whose scene changed. Tests are in `TimelineUITests.swift`.

## Milestone 6 notes (HTML export)

**Using it**

- **More > Export Web Page** saves a folder named after the presentation, holding `index.html`, `player.js` and `presentation.json` (the same file the app saves, without reference images), plus `text.json` with the glyph outlines when there is text, so the page doesn't depend on the viewer's fonts. Put the folder on GitHub Pages or any web server and open `index.html`; it needs no build step and uses only relative paths. Opened straight from disk (`file://`), browsers won't let the page read `presentation.json`, so it says to serve the folder instead (`python3 -m http.server` in the folder works).
- It plays as presentation mode does: the opening state, then one sequence per Advance, letterboxed in black. Click or tap the right half, swipe left, or press Space, →, ↓, Page Down or Return to advance; click or tap the left half, swipe right, or press ←, ↑, Page Up or Backspace to go back. Home and End jump to the start and the end, and F toggles full screen.
- The address's hash is the number of sequences played (`index.html#3` opens with three played), and it follows along as you present, so a reload or a shared link opens on the same step.
- Hidden art is left out, as in presentation mode. Translucent gradient stops may blend slightly differently, since browsers mix gradient colors premultiplied.

**How it works**

- **`HTMLExport`** (ControlFlowCore) returns the folder's files; the page and player are the package resources in `Sources/ControlFlowCore/Player/`. Tests are in `HTMLExportTests.swift`.
- **`player.js`** is a dependency-free port of the core: reading the file, applying keyframe changes (`SceneDiff`), timing curves, `Interpolation` and `VertexMerge` for playing, and `SVGWriter` with the `Stroker` for drawing each frame as SVG (variable-width outlines become triangles, inside and outside outlines and clipping become clip paths and masks). `Schema/test_player.js` plays every test vector sample with it and compares the scenes with the app's; CI runs it in the schema job. While porting, its drawing was checked to write the same SVG as `SVGWriter` for every vector scene.

## Milestone 5 notes (presenting)

**Using it**

- **Present** (the play button at the right of the top bar, or Option-Cmd-P) fills the screen with the viewport, letterboxed in black, at the opening state. It presents the document as it is when you start; the editor is untouched underneath.
- **Turned to fill:** with the rotation lock on, a landscape deck presented on a portrait iPad (or a portrait deck on a landscape one) is turned a quarter turn so it fills the screen instead of sitting small between bars, and taps follow the turn: the right half is the deck's right half as you read it. Turning the iPad mid-presentation keeps the deck still on the glass. An external display and the presenter view's pictures are never turned.
- **Advance** plays the next sequence, keyframe after keyframe, and stops on its last keyframe. Advancing while a sequence plays jumps to its end rather than queueing. **Back** jumps, with no animation, to the end of the sequence before (while a sequence plays, to where it started), or to the opening state.
- **Inputs:** tap the right half to advance and the left half to go back, or use a keyboard or clicker: Space, →, ↓, Page Down and Return advance; ←, ↑ and Page Up go back. **Escape** or a two-finger pinch-in exits. The editor's own shortcuts are off while presenting.
- **External display:** with a display connected by cable or AirPlay (Stage Manager off, so the iPad would otherwise mirror), the presentation goes there full-screen and letterboxed, and the iPad shows the **presenter view**: the current state, the next sequence's end state with its name, a counter ("Sequence 3 of 12"), large Back and Advance targets and End Presentation. The keys work there too. While nothing is being presented the external display is black. With Stage Manager on, iPadOS gives the display to Stage Manager instead, so the iPad presents full-screen and the display shows what Stage Manager puts there.
- What shows is the art in the viewport on the viewport's background: no reference images, onion skin, selection or hidden layers.

**How it works**

- **Presenter** (ControlFlowCore, `Presenter.swift`): the state machine. `advance()`, `back()` and `perform(_:)` move between sequence ends; `scene(at:)` gives the scene at a display time, starting a sequence's clock on its first frame and stopping it on its last keyframe. A sequence with no keyframes has nothing to play and is passed in one Advance. `counter`, `nextSequenceTitle`, `nextEndState()` feed the presenter view, `revision` changes only when the scene jumps, and `Presenter.camera(fitting:in:)` letterboxes the viewport. `PresentationKey` maps the keys to `PresentationAction`s, and `PresentationTouches` turns touches into taps on the halves and the pinch-in. Tests are in `PresenterTests.swift`; `PerformanceTests.testPlaybackFrames` times interpolating and tessellating 50 animating shapes per frame.
- **App** (`ControlFlow/Presenting/`): `PresentationController` wraps the `Presenter` for the views, and `PresentationHub` holds the presentation being given and whether an external display is connected. `PresentationCanvasView` is a Metal view with a `CanvasSession` of its own that shows each frame's scene with `DrawingEditor.showScene(_:)`; it renders through `CanvasRenderer.render(..., presenting: true)` (art and an opaque black veil only) on its own screen's display link, every refresh while a sequence plays and otherwise only when the scene jumps. With input on, it takes the keys as `UIKeyCommand`s ahead of the system's and turns touches into actions. The external display gets its own scene (`ExternalDisplaySceneDelegate`, given by `AppDelegate` for the non-interactive external display role), which shows `ExternalDisplayView`. The next state's picture is drawn off the main thread with `ThumbnailRenderer`.

## Text notes

The plan is [docs/plans/text.md](docs/plans/text.md).

**Using it**

- **Text tool** (the "Aa" button after Shapes, or T): tap the canvas to start a text there, or drag for a box that wraps at that width. The keyboard comes up and you type straight onto the canvas, at any zoom or rotation; the software and hardware keyboards, dictation, other languages' input and autocorrect all work. With the Pencil, write into a text (Scribble) while the Text tool is chosen.
- Tap in the text to move the caret. Tapping outside it, pressing Escape, or changing tools ends the edit; a text left empty is deleted. The whole edit is one undo step, and Undo while typing undoes it.
- Tap another text with the Text tool to edit it, or double-tap a text with Select.
- **Select** moves, turns and scales a text like any shape (scaling is a transform, so it animates smoothly). On a text box the side handles change where it wraps instead of stretching it. Direct Select selects the text whole.
- **Context bar** (Text tool, or a text selected with Select): the font (System, or Choose Font for any installed face), size, weight and italic (for the system font), alignment, and More for line height and tracking. They set the style of new text and of the selected texts. The Appearance panel's fill (color, global color, gradient), opacity and clipping work as for shapes; outlines on text come later, so that section is off for a text.
- **Edit > Convert to Outlines** (Shift-Cmd-O) turns a text into ordinary shapes, one per letter with its holes, grouped, so the letters can be reshaped with Direct Select and morph by their points.
- **Keyframes:** a text's words and every style setting can change at a keyframe. Position, rotation, scale, opacity and fill animate as for any shape, and tracking and line height animate too (with lines broken as they are at the end, so words never jump between lines midway). The words, font, weight, italic, size, alignment and box width change at the start of the transition.
- A document naming a font this iPad doesn't have shows it in the system font and says so when it opens; the name is kept, so it comes back on an iPad that has the font.
- Exports draw text as outlines: SVG, PNG, thumbnails and the web page look as the iPad does.

**How it works**

- **Core** (`Text.swift`, `DrawingEditor+Text.swift`): a text is a `VectorShape` with a `TextContent` and an empty path. `TextShaping` lays it out through the `TextShaper` in use (CoreText in the app, `StubTextShaper` in tests and on Linux), and `VectorShape.resolvingText()` puts the glyphs into the path wherever shapes are drawn or hit-tested, so stored text never holds glyphs. `TextEditing` is the string and selection logic and `TextEditState` the session; `Interpolation` lerps tracking and line height with `TextContent.held`. Tests are in `TextTests.swift`.
- **App:** `CoreTextShaper` (`Canvas/`) breaks lines with a `CTTypesetter` and caches glyph outlines from `CTFontCreatePathForGlyph`. `MetalCanvasView` keeps an invisible `UITextView` as the keyboard's target, copying words and selection both ways, and offers texts to Scribble with `UIIndirectScribbleInteraction`.
- **Format 1.1** adds `text` to shapes (`Schema/README.md`, "Text"). The HTML export's `text.json` and `player.js` are checked by the test vectors.

## Arranging and aligning notes

The plan is [docs/plans/arrange-align.md](docs/plans/arrange-align.md). Smart guides, its second part, are described with Snap under the Select tool notes.

**Using it**

- **Arrange button** (Select context bar, the align icon): a popover with **Align** (left, horizontal centers, right, top, vertical centers, bottom), **Align To** (Selection or Viewport), **Distribute** (horizontal and vertical spacing, with horizontal and vertical centers under the `…` menu) and the four draw-order buttons.
- **What moves as one:** each selected layer; each wholly selected group, and each other shape; each shape inside an isolated group or picked with Direct Select; a reference image. Each moves by its transform, so points never change, and at a keyframe the move is keyed and animates like any other.
- **Boxes:** things line up by the box around their art as you see it (a turned shape by the box around it), without outline width, the same box as the Inspector's X, Y, W and H. A text lines up by its text box.
- **Align To Selection** lines each thing up with the edge or middle of them all, so the outermost one stays put. **Viewport** lines each one up with the slide on its own (three things aligned left all touch the left edge). **With one thing selected, Align always uses the viewport**: select a title and tap Horizontal Centers to center it.
- **Distribute** needs three or more things. Spacing makes equal gaps between neighbours (equal overlaps if they overlap); centers makes equal steps between centers. The outer two stay put, or, against the Viewport, move to its edges.
- **Points:** in Direct Select with two or more anchors selected, **Align Points** in the context bar aligns the anchors themselves (Vertical Centers makes them level) and, with three or more, distributes them.
- **Menus:** Arrange > Align and Arrange > Distribute on a keyboard (shortcuts in the keyboard notes; off while typing, where Option-letters type characters), and the Edit menu's Arrange submenu.
- **Nudge** with Shift-arrow moves 10 points. **Rotate Left** and **Rotate Right** sit beside Flip.
- Each command is one undo step; one that would move nothing adds none.

**How it works**

- **Core:** `Alignment.swift` is pure geometry (`Aligner` and `Distributor` return one translation per box or point); `DrawingEditor+Align.swift` splits the selection into units (`alignmentUnits()`), gets their world `geometryBounds`, and applies the translations with `Drawing.apply` in one `commit`. Tests are `AlignmentTests` and `AlignTests`.
- **App:** `CanvasStore.align`, `distribute` and `alignTarget` (kept for the session only, not saved), the `AlignControls` popover in `ContentView.swift`, and the menus in `EditorCommands.swift`.
- No file format change.

## Character Studio foundations

The notes below describe the editor ControlFlow inherits from Character Studio. They still say "part" for a layer and "character" for the document.

## Canvas and ink notes

- **Input routing** lives in `CanvasSession` (ControlFlowCore) so it is unit-tested: the Pencil draws, one finger does nothing, two fingers pan, pinch-zoom and rotate together, fingers are ignored while the Pencil is down, and wide contacts (major radius over 56 pt, above a firmly pressed fingertip) are treated as a palm. Over the canvas the system's own gestures (pinching a document closed, swiping back from the edge, and the three-finger undo, copy and paste gestures) are switched off so they cannot steal a pinch or undo the document behind the editor; use the back button to close the document.
- **Rotation lock** (View > Lock Rotation, Option-Cmd-R; on by default and remembered on this iPad): two fingers pan and pinch-zoom but don't rotate, and the canvas keeps a quarter turn that lays the viewport's long side along the canvas view's long side (Split View and Stage Manager windows count by their own shape). A landscape deck on a landscape view is upright, never upside down; on a portrait view it turns 90° or 270°, whichever keeps the art still on the glass as you turn the iPad (90°, the deck's top on the right, when there is no turn to go by). Square viewports, within 2%, are never turned. The turn is about the middle of the screen and keeps the zoom. Turning the lock on snaps to the nearer allowed rotation over a quarter of a second; turning it off changes nothing. A lock badge sits in the top-right corner while it's on; tap it to turn the lock off. Zoom to Fit and Reset View use the locked rotation. With the lock off or on, resizing the canvas keeps the point in the middle of the view in the middle. The rules are `RotationLock`, `CameraTurn` and `CanvasSession.viewDidResize(from:to:interfaceTurn:)` in ControlFlowCore, tested in `RotationLockTests.swift`.
- **Latency:** each move event feeds all coalesced samples plus predicted samples into the live stroke; a 120 Hz display link draws on the next frame. The Metal layer uses two drawables to save a frame.
- **Rendering:** each stroke segment is a quad whose fragment shader draws an anti-aliased capsule, which gives round caps and joins at any zoom. Finished strokes are tessellated once into a cached buffer; the camera is applied on the GPU, so navigation never re-tessellates.
- **Canvas:** infinite, with a dot grid (larger dot at the world origin) so pan, zoom (5% to 6400%) and rotation (with the rotation lock off) are visible.
- Ink is opaque in v1, because overlapping capsules would double-blend translucent color.

## Vector shapes notes

**Using it**

- **Layout:** the tools, undo and redo, Inspector, Layers and the More menu run down a vertical strip on the left edge. The context bar (the current tool's options) sits at the right of the top bar, beside the document title; when the current tool has more controls than fit, the bar scrolls sideways. The style bar runs along the bottom.
- **Pencil** (pencil tip, formerly Brush): draw freehand with the Pencil. Each stroke is fitted to an editable Bézier path when you lift. A stroke that ends near its start closes into a filled shape; an open stroke is an outline. The smoothing slider (Pencil tool only) trades accuracy for smoother curves.
- **Parts:** a new stroke or pen path starts a new part. Turn on **Auto-join selected part** (Pencil context bar) and a stroke that overlaps the selected part, or a pen path, joins it instead. It is off by default.
- **Pen** (pen nib): tap to place a corner anchor; drag right after placing to pull out a symmetric handle. Tap the first anchor to close the path. Tap the end of an existing open path to continue it, or the end of another open path (while drawing) to join the two. **Done**, or tapping the last anchor again (double-tap), ends an open path. A rubber band previews the next segment when the Pencil hovers (iPad Pencil hover, or a pointer in the Simulator). Each anchor is one undo step.
- **Select** (arrow): tap a shape to select its part, tap again to select just that shape, tap empty canvas to deselect. Drag a selection to move it. Corner handles scale uniformly; **edge handles scale along one axis**. The round handle above the frame rotates, about the **pivot** (a crosshair, defaulting to the part's pivot; drag it to move it, which saves a part's pivot). **Flip** buttons mirror the selection, and **Rotate Left** and **Rotate Right** turn it a quarter turn. The **Arrange** button lines things up (see Arranging and aligning notes). Drag on empty canvas for a **marquee**. Turn on **Add** in the context bar and tap shapes (or marquee) to add to or remove from a multi-selection; move, scale, rotate and flip work on all of it.
- **Direct Select**: tap a shape and its anchors show at once, no extra selection step. Drag an anchor to move it, drag a handle, or drag a segment between anchors to reshape the curve. Tap a segment to insert a point. Marquee on empty canvas picks anchors (of the selected shape) or shapes; **Add** builds up several anchors, which then move, nudge and change type together. The point type control picks **Corner**, **Smooth** or **Symmetric** handles for the selected anchors (this replaces tapping an anchor to toggle); **Break Handles** retracts them. **Delete Point** removes anchors while keeping the shape and the neighbours' handle directions. **Split** cuts a path at the selected anchor; **Join** connects the ends of selected open paths (a single open path is closed). To close an open shape with a straight edge, drag one of its end anchors onto its other end: the anchor stays where it was, a line and a ring preview the new edge, and lifting the Pencil there adds it (one undo step). Drag away again before lifting to move the anchor as usual. Arrow buttons nudge the selected anchors (or the Select tool's selection) by 1 point. With two or more anchors selected, **Align Points** lines them up or spaces them evenly.
- **Snap** (grid menu in the context bar): when on, anchor drags and move/scale drags snap to other anchors and a grid within 8 screen points (so the world radius shrinks as you zoom in). Off by default.
- **Smart Guides** (Snap menu, or View > Smart Guides, Cmd-U; on by default and remembered on this iPad, independent of Snap): while you move, or resize with an edge or corner handle, in Select, the dragged selection's box lines up with the edges and middles of every other shown shape and group (locked ones too) and of the viewport, within 6 screen points, each axis on its own. A thin magenta line runs along what lined up, from the dragged box to the farthest box on that line (across the whole viewport for the viewport's lines), with a small cross at each end when middles line up. Boxes are outline-free, like the Inspector's X, Y, W and H. A Shift-constrained move only lines up along the axis it moves on; a corner resize keeps its uniform scale and lines up the dragged corner on whichever axis is nearer; rotating and resizing a turned frame show no guides. With Snap on too, an anchor hit wins, and on a move the grid takes an axis when it's nearer than the guide. The rules are `SmartGuides` in ControlFlowCore, tested in `SmartGuideTests.swift`.
- **Inspector** (sliders button): numeric X, Y, width and height of the selection, rotate-by degrees, X and Y of the selected points (middle of several), and fill and outline color as hex.
- **Color:** the bottom bar sets fill (with opacity) and outline color and width, and turns either off. Changes apply to the selection and to new strokes; selecting a shape loads its style. The palette keeps colors per character: tap a swatch to fill, long-press for outline or remove.
- **Undo and redo:** the tool strip buttons, a two-finger tap (undo) or a three-finger tap (redo). The last 200 steps within a session; a whole color-picker or slider drag is one step.
- **Reference images** (photo button): import from Photos or Files, or drag an image onto the canvas. They sit locked under the art at 50% opacity; the panel sets opacity, hides, removes, or picks one to move, scale and rotate with the select tool's handles. They are editor-only and will not be exported.

**How it works**

- **Curve fitting** (`CurveFitter`): light [1 2 1] smoothing, corner detection by turning angle, then Schneider's least-squares cubic fitting with Newton reparameterization between corners. Tolerances are in screen points, so fitting feels the same at any zoom.
- **Fills** use stencil-then-cover: a triangle fan writes winding numbers to the stencil and a cover quad paints non-zero pixels, so any freehand outline (even self-intersecting) fills correctly. The canvas is now 4x multisampled into memoryless targets for smooth fill edges.
- **Caching:** each shape's triangles are cached and rebuilt only when that shape changes or zoom crosses a power of two. A new zoom level is refined in the background, shapes on screen first, so a pinch never waits on it: zooming in shows slightly coarser curves for a moment, and zooming out keeps the finer ones until the fingers lift. Opening a document works the same way: the canvas, viewport and references show at once, and the parts appear as they are ready, those on screen first.
- **Model:** `Drawing` holds parts (groups of shapes with a pivot), reference images and the palette. Path points store `in` and `out` handles as offsets, matching the spec's file format. Undo stores `Drawing` snapshots, which share storage thanks to copy-on-write.
- All editing logic (`DrawingEditor`, `EditorOverlay`) lives in ControlFlowCore and is unit-tested on Linux.

## Vector editing notes

- **Tools:** `Tool` is now pencil, pen, select and direct select. Only the Pencil tool captures a freehand stroke in `CanvasSession`; the others send Pencil events to `DrawingEditor`. Pen state (`PenPath`) lives in the editor and survives between taps; switching tools finishes the path.
- **Handle modes:** `PathPoint.mode` is `corner`, `smooth` or `symmetric` (`isSmooth` remains as a computed property). `BezierPath.setHandle` honours the mode. The file format still writes `smooth: false` for corners and now also `symmetric: true` for symmetric points, an optional editor hint, so v0.1 files without it read as before and the example still round-trips byte for byte.
- **Multi-select:** `Selection.shapes(Set<ShapeRef>)` joins part, shape and reference; `selectedAnchors` is a set of indices into the one shape Direct Select is editing.
- **Snapping** lives in `Snapper` (pure functions) and the editor's `SnapSettings`.
- **Tests** cover pen building, closing, continuing and joining, handle modes, delete with heal, split and join, segment dragging, non-uniform scale, flips, pivot, snapping, multi-select and marquee, and the numeric edits.

## Document notes

**Using it**

- **Documents:** the app opens to the Files browser. Tap **+** (Create Document) for a new presentation, or open an existing `.controlflow`. Presentations autosave a moment after each change; tap the back arrow to return to the browser, and tap the title to rename the file. Documents live wherever you browse to (On My iPad, iCloud Drive), and each has its own undo history.
- **Layers** (stacked squares button, replacing the photo button): the document's name, then its layers. Tap a part to select it; long-press or swipe for Rename and Delete. Part names must be unique, so a clash gets a number added. The **Reference Images** section has the import buttons and the per-reference controls from milestone 2.
- **Reference images** now save inside the document, at their imported resolution (JPEG for photos, PNG when they have transparency).
- To look inside a file, copy it to a Mac and choose Show Package Contents; `presentation.json` is plain, readable JSON.

**How it works**

- **Format:** since milestone 3, `presentation.json` in format 1.0; see [Schema/README.md](Schema/README.md) and the [JSON Schema](Schema/controlflow-1.0.schema.json). Until then it was Character Studio's `character.json`.
- **ControlFlowCore** owns the format: a small JSON reader and writer that keeps key order (`JSONValue`), the encoder, decoder and version checks (`PresentationFormat`), and the package as a map of paths to bytes (`PresentationPackage`). Damaged files fail with the JSON path of the problem, for example `opening.layers[1].shapes[0].points[1].p is missing`.
- **App:** a SwiftUI `DocumentGroup` with a `FileDocument` that reads and writes the package folder. The editor keeps its own undo stack and hands the drawing to the document after each finished gesture or command, which marks it edited for autosave. A color picker or slider drag is handed over once, half a second after it stops (`DocumentHandOff`), and before the document closes or the app leaves the foreground.
- Ids are never reused within a session (undo no longer rewinds the id counter), which also fixes a milestone 2 bug where importing a second reference after undoing the first could show the first image.
- **Tests** cover the JSON reader and writer, a byte-for-byte re-save of the example, round trips of editor drawings, draw order, version checks, error paths, and the layer tree. CI also validates the example against the schema.

## Editor completeness notes

The everyday editing gaps from the full-editor plan, with no change to the file format beyond two optional editor hints.

**Using it**

- **Tools:** the left strip now has Pencil, Pen, **Shapes**, Select, Direct Select, **Eraser** and **Scissors**, then undo, redo and a new **Edit** menu. On a short screen the strip scrolls.
- **Shapes:** pick rectangle, ellipse, polygon, star or line in the context bar and drag. Rectangles and ellipses span the drag; polygons and stars grow from where you press with a corner toward the Pencil; lines run from press to lift. The context bar sets the rectangle's corner radius, the polygon's sides, and the star's points and inner radius. Every shape is an ordinary Bézier path, so Direct Select edits it like anything drawn by hand.
- **QuickShape:** draw with the Pencil tool and hold the Pencil still for half a second at the end of the stroke. A rough line, arc, ellipse (a circle when nearly round), rectangle, triangle or polygon of up to six sides snaps to a clean one; a snapped line keeps following the Pencil until you lift. Strokes that match nothing stay as drawn.
- **Eraser:** drag across shapes to delete every shape you touch (one undo step). **Scissors:** tap an outline to cut it there: a closed shape opens at that point, an open path becomes two. Hover shows where the cut will land.
- **Edit menu:** Duplicate (a copy 10 points down and right), Cut, Copy, Paste, Delete; Arrange (bring to front, forward, backward, send to back) for shapes within their part or for a whole part among parts, with Align and Distribute submenus; Move to New Part and Move to Part for selected shapes; Hide, Lock, Show All, Unlock All; Isolate Part.
- **Copy and paste** put the selection on the pasteboard as the character file's own JSON, so it pastes into another character. Copied shapes paste into the selected part; a copied part pastes as a new part. Pasting on top of the original moves the copy 10 points so it is visible.
- **Hide and lock:** per part with the eye and lock in the Layers panel, or per selection from the Edit menu. Hidden art isn't drawn; locked art is drawn but taps, marquees, the eraser and scissors pass through it. Both are saved with the character.
- **Isolation:** double-tap a part with Select (or Isolate in the Edit menu or a layer's menu) to edit just that part. The rest is dimmed and can't be touched, and new strokes, pen paths and shapes join the isolated part. The context bar's Exit button, Escape, or a double tap on empty canvas leaves.
- **Layers:** drag a part to change the draw order; a part's menu adds Isolate and Merge Down.
- **Shift and Option:** a strip on the right edge latches them for when there is no keyboard, and a hardware keyboard's own keys work too. Shift makes squares and circles, 45-degree lines, one-axis moves and 15-degree rotation steps. Option draws shapes from their center and makes a Select drag move a copy (Option-drag to duplicate).
- **Apple Pencil:** double tap follows the setting in Settings > Apple Pencil (switch to the eraser and back, switch to the previous tool, or show the palette). Squeeze (Apple Pencil Pro) opens a palette under the Pencil with every tool, undo and redo, and the colors you used last. Hovering shows the brush size with the Pencil tool, the eraser's reach, and an outline on the shape a touch would select, erase or cut.
- **Keyboard:** V, A, P, N, M, E and C pick Select, Direct Select, Pen, Pencil, Shapes, Eraser and Scissors; Cmd-Z and Shift-Cmd-Z undo and redo; Cmd-X, C, V and D cut, copy, paste and duplicate; Delete deletes; Cmd-] and Cmd-[ (with Shift for front and back) arrange; Cmd-3 and Cmd-2 hide and lock (with Option to show or unlock all); Shift-Cmd-I isolates and Escape exits; arrow keys nudge (1 point, or 10 with Shift); Option-A, H, D, W, V and S align left, horizontal centers, right, top, vertical centers and bottom, and Shift-Option-H and V distribute spacing. Hold Cmd to see the list. Space-drag panning is not in yet.

**How it works**

- All of it lives in ControlFlowCore with tests: `ShapePrimitives` (shape paths and drag modifiers), `ShapeRecognizer` (QuickShape), and `DrawingEditor` with the new tools and `DrawingEditor+Organize` (isolation, hide and lock, arrange, duplicate, clipboard, scissors, tool switching). The app forwards touches, modifier keys, Pencil interactions and the pasteboard.
- **QuickShape** classifies by size-relative tolerances: a closed loop first looks for three corners or four right-angled ones (Douglas-Peucker), then for an ellipse with the same area moments as the stroke that stays within 9% of it all round, then for a polygon. An open stroke is a line when it strays under 6% of its length from the chord, else an arc through its ends and middle. A still Pencil sends no events, so the canvas polls `CanvasSession.checkQuickShape` while a stroke is drawn.
- **Hide and lock** are optional `hidden` and `locked` keys on attachments and shapes, written only when true, so existing files and the example are unchanged byte for byte and the format stays 0.1. `Drawing.hitTest` and every tool skip hidden and locked art.
- **Isolation** is editor state, not saved. The renderer draws the other parts, then a 70% veil of the background color, then the isolated part on top.
- **Duplicate, paste and Option-drag** give every copy fresh ids. An Option-drag records the state before the copy, so one undo removes the copy and the move together.


## Appearance notes

Tier 2 of the full-editor plan, done as one file format bump to **0.2**. Older 0.1 characters open as they are and are saved as 0.2.

**Using it**

- **Appearance** (palette button on the left strip) holds everything below. Changes apply to the selection; outline options also apply to new shapes, like the outline color and width. A slider drag is one undo step.
- **Outlines** now have **ends** (butt, round or square), **corners** (miter with a miter limit, round or bevel), **dashes** (solid, dashed, long dashes or dotted, sized to the outline width) and a **position** for closed shapes (centered on the path, inside it or outside it). Outlines can be translucent now: overlaps no longer darken.
- **Width along the outline:** in Direct Select, select points and drag **Selected Points** to make the outline thicker or thinner there; widths blend smoothly between points. **Make Width Even** resets a shape. **Pencil Pressure Sets Width** (also the line-weight button next to smoothing on the Pencil tool's style bar) makes pressing harder draw a thicker line. It is **off by default**, so outlines stay uniform unless you turn it on; the setting is remembered on the iPad.
- **Unstroked edges:** in Direct Select, select the two anchors at either end of an edge (with **Add**, or a marquee) and tap **Hide Edge Outline**. That edge loses its outline but the fill still covers it, so a head's outline can stop where it overlaps the neck while its fill still hides the neck's top. Select more anchors to change several edges at once; **Show Edge Outline** brings them back. Bare edges show dashed while the shape is selected, and the outline's ends there use the outline's end style. Saved as `stroked: false` on the point the edge leaves from, and kept by SVG export.
- **Opacity** fades a shape's fill and outline.
- **Gradients:** switch a closed shape's fill from Solid to **Linear** or **Radial**. Pick the start and end colors, the angle (linear) and how far it spreads, or swap the colors. The gradient moves, turns and scales with the shape.
- **Clip to Shape Below:** the shape draws only inside the nearest unclipped shape under it in the same part (its fill and its outline). Paint a shadow or highlight loosely over an arm, turn this on, and it stays inside the arm. Several clipped shapes in a row share the same base. Hiding the base hides them too. Taps on the clipped-away area go through to what's beneath.
- **Global colors:** New Global Color from Fill adds a named color (Appearance panel, or the palette's **+** menu). Tap its square swatch in the palette to fill the selection with it (long-press for outline). Change a global color in the Appearance panel and every shape that follows it changes too; renaming or deleting it keeps the shapes' colors. Picking an ordinary color for a shape stops it following.

**How it works**

- **Stroker** (`Stroker`, ControlFlowCore): turns a path into triangles for one quad per segment, a wedge per corner and the caps, with widths blended per point. Dashes cut the flattened path by length first. Triangles are all wound one way.
- **Drawing the art** is planned in ControlFlowCore by `ArtBuilder` as stencil-then-cover steps, so the renderer only replays them. The 8-bit stencil holds a fill's winding (bits 0-5), "outline covers this sample" (bit 6) and the clip (bit 7). Fills mark the winding and paint where it is non-zero; outlines mark their triangles and paint the marked area once, so translucent outlines stay even. Inside and outside outlines are stroked twice as wide and painted only where the path's own winding is non-zero or zero. A clip base sets bit 7 where it paints and clipped shapes paint only there. The tests replay these steps in a stencil simulator to check clipping, alignment and that each shape leaves the stencil clean. Gradients are evaluated per pixel in the cover shader.
- **Pressure:** `CanvasSession` records each sample's force as a fraction of the most the Pencil reports; after fitting, each anchor takes the averaged pressure near where it was drawn (`PressureWidth`). Fingers report no pressure, so the Simulator always draws even outlines.
- **Format 0.2** keeps widths on the centerline (`w` per point) rather than outlining strokes into filled shapes, so line weight stays right when a path is reshaped. Every new key is optional and written only when it differs from its default; see [Schema/README.md](Schema/README.md#appearance-02). `fill` and outline `color` still hold the actual color when a gradient or global color applies, for readers that don't know them.
- The thumbnail uses the same stroker, and Core Graphics for gradients and clipping.

## Workspace and interchange notes

Tier 5 of the full-editor plan: the outline view and ghosting (#23) and SVG import with SVG and PNG export (#25). The character frame (#24) became the viewport in milestone 1.

**Using it**

- **View menu** (the eye button in the toolbar):
  - **Outline View** (Cmd-Y) draws every shape as a thin wire, so you can see paths hidden under fills. Parts outside an isolated part are dimmed.
  - **Ghost Unselected** (Option-Cmd-G) fades everything except the selection to a quarter of its opacity. With nothing selected, nothing fades.
  - **Zoom to Fit** (Cmd-0) fits the viewport in the view. **Reset View** is here too.
- **More menu:**
  - **Import SVG** opens an SVG from Files. Each top-level group becomes a part, named from `data-name`, Inkscape's label or its id; loose shapes become one part named after the file. Paths, rectangles, circles, ellipses, lines and polygons come in with their fills, outlines, linear and radial gradients, opacity and transforms, including CSS in `<style>`. Shapes with holes keep their holes. Text, images, filters, clip paths and masks are skipped, and the toast says how many. The new parts land on top, selected, and the view zooms to them. One undo step. The file is read in the background with "Importing..." showing, so the app stays responsive on a large file; Import SVG is unavailable until it finishes.
  - **Export SVG** and **Export PNG** (1x, 2x or 4x) save to Files. Both cover the viewport. The SVG keeps each part as a group named after it; inside and outside outlines, variable width, clipping and gradients are drawn to look the same. The PNG is filled with the viewport's background. Hidden art is left out of both.

**How it works**

- **Outline view and ghosting** are editor state, not saved. In outline view the renderer skips the art pass and `EditorOverlay` draws the wires. The wires and the selection's outlines and anchors are kept between frames (`OverlayCache`) and rebuilt only when the drawing, zoom bucket (a power of two) or selection changes, so hovering and a pinch within a bucket don't re-flatten them; their line widths are in screen points, scaled by the shader. Ghosting passes `DrawingEditor.ghostFocus` to `ArtBuilder`, which multiplies the paint opacity of shapes outside it.
- **SVG import** lives in ControlFlowCore: `XMLReader` (a small XML parser, since Linux Foundation's is limited), `SVGPathParser` (every path command, with arcs and quadratics turned into cubic Béziers) and `SVGImporter` (styles, transforms, `<use>`, gradients). Compound fills become one fill shape whose rings are joined by hairline bridges, plus an outline-only shape per ring.
- **SVG export** is `SVGWriter` in ControlFlowCore. The app's PNG export draws with Core Graphics, like the thumbnail.

## Groups notes

Phase 1 of the layers plan: groups of shapes inside a part. The file format stays 0.2 with two new optional keys, `groups` on an attachment and `group` on a shape.

**Using it**

- **Group** (Edit menu, Cmd-G): two or more selected shapes of one part become a group, named Group 1, Group 2 and so on. They move to sit together just below the topmost of them, keeping their order. Shapes from different parts can't be grouped; move them into one part first. Groups don't nest: grouping shapes that are in a group takes them out of it. **Ungroup** (Shift-Cmd-G) dissolves the groups of the selected shapes, leaving them where they are. **Add to Group** moves the selected shapes into another group of their part, on top of its shapes.
- **Selecting with Select:** the first tap on a shape still selects its part. The next tap inside that part selects the shape's whole group (one frame round it), or the shape when it has no group. Add mode and marquees take whole groups too. Direct Select still reaches single shapes and anchors inside groups.
- **Going in and out:** double-tap a grouped shape to edit inside its group: only the group's shapes can be tapped (one at a time), the rest is dimmed, and new strokes, pen paths, shapes and pastes join the group. Double-tapping an ungrouped shape isolates its part as before. **Escape**, the context bar's Exit button, or a double tap on empty canvas goes one level out: from a group to its part (with the group selected), from a part to the whole document, and with nothing isolated Escape clears the selection.
- **Renaming:** with a group selected, the Select tool's context bar shows its name; edit it and press Return.
- **Arrange** moves a group as one unit among its part's shapes. Shapes picked inside a group (with Direct Select, or while editing inside it) move among the group's shapes only.
- **Duplicate, Duplicate Mirrored, copy and paste** copy a whole group as a new group (mirrored copies swap `.L` and `.R` in its name); copying part of a group keeps the copies in it. Moving shapes to another part takes a group along when all of it moves.
- **Clipping inside a group:** a clipped shape in a group clips to the nearest unclipped shape below it within the group, never to something outside it. A clipped shape at the bottom of its group draws unclipped.
- **SVG:** export writes each group as a named `<g>` inside its part's group. Import reads a named group inside a part's group as a group of shapes.

**How it works**

- **Model** (ControlFlowCore): `ShapeGroup` (id and name) lives in `Part.groups`, and `VectorShape.group` points a shape at one. A group's shapes are always together in the part's stack. `Drawing.groupsAreValid` checks that, and `Drawing.repairGroups` restores it (dropping empty groups, splitting a group whose shapes got separated into one group per run), which `DrawingEditor.commit` runs after any edit that broke it and the decoder runs on open. Commands are in `DrawingEditor+Layers`, tests in `GroupTests`.
- **Isolation** is now two levels: `isolatedPart` and `isolatedGroup`. Inside a group, `ArtBuilder` draws the rest of the part under the veil and only the group on top.
- **Format:** `groups` on an attachment lists `{ "id", "name" }`, with ids numbered from 1 within the attachment, and a shape's `group` names one. Both are written only when a part has groups, so files without groups are unchanged. The example robot's body and its shadow are now a group. See [Schema/README.md](Schema/README.md#groups).

## Layers panel notes

Phase 3 of the layers plan, simplified in milestone 1 now that accessories and the skeleton are gone. Nothing in the file format changes.

**Using it**

- **Root row:** the first row is the presentation, with its name.
- **Layers** are listed front to back. A layer with groups has a chevron: open it to see its groups. Every layer and group row has its own eye and lock. Drag a layer to change the draw order: it goes just in front of the layer below where you drop it, or to the very back.
- **Active layer:** tapping a layer's name selects it and makes it the **active layer**: new strokes, pen paths, shapes and pasted shapes go into it, wherever on the canvas you draw, until you pick another. A bar on the row's leading edge marks where new art goes. Tap **New Layers** on the root row (or the cross in the context bar) to go back to a new layer for each stroke. Isolation still wins while it lasts, and a hidden or locked active layer takes no art until it is shown or unlocked. While drawing, the context bar shows **Into** and the active layer's name.
- **Groups in the tree:** tap a group's name to select it, use its eye and lock to hide or lock all its shapes, and long-press it to rename it or clip it.
- **Selecting several layers:** tap **Select** in the Layers header and tick layers. The bar under the header hides, locks, brings forward, sends backward or deletes them together; on the canvas they move, scale, rotate and flip together, and Duplicate, Copy and Cut take them all.

**How it works**

- **Model** (ControlFlowCore): the selection `.layer` is one whole layer and `.layers(Set<Int>)` several. `DrawingEditor.targetLayer` is the layer chosen in the panel and `activeLayer` is where new art goes (isolation, then the chosen layer, then with auto-join the selected one); it is editor state, not an undo step, and is forgotten when its layer goes. `LayerTree` has `parts` (each with its `groups`) and `treeRows(expanded:)`, which flattens the tree into the rows the panel lists. `DrawingEditor.moveTreeRow(from:to:in:)` turns a drag of a layer row into a new draw order. Commands are in `DrawingEditor+LayersPanel`, tests in `LayersPanelTests`.

## Selection extras notes

Phase 4 of the layers plan: commands for picking what you mean among layers, groups and shapes. Nothing in the file format changes, and none of these commands is an undo step.

**Using it**

- **Select menu** (in the Edit menu, and on a hardware keyboard): **Select Layer** (Cmd-Up) goes one level out from the selection: from shapes to their group or layer, from a group to its layer. With nothing selected inside an isolated group or layer, it selects that group or layer. **Select All in Layer** (Cmd-A) selects every shape of the isolated layer, else of the layer the selection is in, else of the active layer; inside a group it selects the group's shapes. **Invert Selection** swaps selected and unselected shapes within that same layer or group.
- **Same Fill** and **Same Outline** select every shape whose fill (same global color, gradient or color) or outline (same width and color) matches a selected shape's, across the whole document or only inside the isolated layer or group. Shapes with no fill, or no outline, match each other. Hidden and locked shapes are skipped.
- **Breadcrumbs:** with Select or Direct Select, the context bar shows where the selection sits, such as Hair › Bangs › Shape. Tap an outer level to select it.
- **Keyboard:** Cmd-G and Shift-Cmd-G group and ungroup (from phase 1); Cmd-Up and Cmd-A are new.

**How it works**

- **Model** (ControlFlowCore): `DrawingEditor.selectionCrumbs` lists the levels around the selection as `SelectionCrumb`s (`.layer`, `.group` or `.shapes`, one flagged current), `selectCrumb` selects one, and `selectParent` selects the one outside the current level. `selectionScopeLayer` is the layer Select All in Layer and Invert work in. Commands are in `DrawingEditor+Select`, tests in `SelectMenuTests`.

## Clipped groups notes

The file format stays 0.2 with one new optional key, `clipped` on a group.

**Using it**

- **Clip Group to Shape Below:** select a whole group (tap it with Select, or tap its row in the Layers panel) and turn on **Clip Group to Shape Below** in the Appearance panel, or long-press the group's row and choose **Clip to Shape Below**. The whole group then draws only inside the shape under it, so an iris, pupil and highlight grouped together stay inside the eye white. Clipping inside the group still works (the highlight can clip to the iris), and taps only reach a clipped group where it shows. A clipped shape placed above a clipped group clips to the same shape the group does. The group's row shows a small clip arrow. While you're inside the group (double tap), it draws whole so you can see what you're editing.
- **Exports:** PNG and the thumbnail draw it as the canvas does, and SVG export masks a clipped group as a whole.

**How it works**

- **Model** (ControlFlowCore): `ShapeGroup.isClipped`. `Part.clipBase(ofGroup:)` finds a clipped group's base (the nearest shape below the group that isn't clipped or in a clipped group), `groupClipBase(of:)` gives it for any member, and `clipBase(of:)` skips clipped groups' shapes outside a group. The command is `setGroupClipped` (in `DrawingEditor+Layers`), one undo step.
- **Rendering:** the stencil gives up one winding bit (fills wrap at 32 overlaps instead of 64) for a group mask bit. A clipped group copies its base's clip into the mask bit as it starts, its shapes paint only where that bit is set, and clip bases inside the group mark the clip only where they painted. When the group ends the clip goes back to the group's base for any clipped shapes above it, and the mask is cleared.
- **Format:** the example robot's head has a Visor group clipped to it, with a glint clipped to the visor. See [Schema/README.md](Schema/README.md#groups).
