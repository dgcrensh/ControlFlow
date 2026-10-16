# ControlFlow smoothness profile

Profiled on 2026-10-16 against `main` at `b1e5533` (after image shapes merged). Line numbers are from that commit.

## How this was measured

- **Measured** findings come from release-build benchmarks of ControlFlowCore on the full stress drawing (`STRESS_DRAWING=full`: 40 layers × 60 shapes × 24 anchors, 2,400 shapes). Each number is the median of 9 runs. A few were confirmed with `perf` call graphs.
- **Inferred** findings come from reading the app code: the Metal renderer, the touch path, SwiftUI, and presenting. The app can't be built or run on Linux.
- **The machine is not an iPad.** The cloud container is about **5× slower** than the M-series Mac used in `docs/plans/performance-*.md`. The same "art rebuild after one edit" row takes 8.5 ms here and 1.69 ms there. Each table therefore gives the container number and a rough Mac estimate (÷5). Treat the estimates as order-of-magnitude only.
- **The frame budget** is 8.3 ms at 120 Hz (ProMotion) and 16.7 ms at 60 Hz. The CPU side of a frame should stay well under half of that.
- **The benchmarks** started as a scratch test file. Step 1 of the suggested order below turned the keyframe ones into `Workload`s in `Workloads.swift`, timed by `PerformanceTests` and `ScalingTests`. To re-run them: `STRESS_DRAWING=full swift test -c release --package-path Packages/ControlFlowCore --filter PerformanceTests`.

> **Caveat about the stress drawing (fixed in step 1).** `StressDrawing.make()` used to create vertices with no ids. Real documents always have them (`assignVertexIDs` runs on every commit). Without ids, `Interpolation.shape` treats every shape as reshaped and runs `VertexMerge.fallback`. That made interpolating one moving layer cost 25 ms instead of 0.1 ms, which hid the real costs, and `PerformanceTests.testPlaybackFrames` had the same distortion. Every number below uses a drawing with vertex ids, and `StressDrawing.make` now assigns them.

## Summary

Everything the old audit covered stays in good shape: drawing, hovering, dragging, navigation, undo at the opening state, and committing an edit.

The new keyframe features are where frames drop. Three causes account for nearly all of it:

1. The tessellation cache works in world space and compares whole shapes. So every shape that moves, recolours or fades during a transition is re-flattened and re-stroked on every frame. The cache then forgets the keyframe's own tessellation, so the frame after playback pays again.
2. Rebuilding a keyframe's state builds a lookup table of every object and every vertex in the scene. That happens:
   - for every keyframe replayed after an undo;
   - twice in every `refresh()` while you are at a keyframe (`changedObjects`).
3. Switching keyframes is treated as a document edit, so it triggers a hand-off and an autosave. Transition and rename changes are not treated as edits, so they never trigger one.

## Ranked hotspots

| # | Hotspot | When the user feels it | Evidence | Container | Mac est. | Effort |
|---|---|---|---|---|---|---|
| 1 | Animated shapes re-tessellated every playback or scrub frame | Play, scrub, presenting | Measured | 43 µs per animated shape per frame; whole stage sliding: 104 ms/frame | ~9 µs/shape; ~20 ms/frame | S (paint) / L (transforms) |
| 2 | Frame after playback or scrub re-tessellates everything that animated | The first frame after a transition ends, and editor Play | Measured | 2,400 shapes re-tessellated, ~120 ms | ~25 ms | S |
| 3 | Undo/redo at a keyframe replays the chain from the opening state | Undo at keyframe k | Measured | 238 ms at keyframe 10 of 20 | ~45 ms | M |
| 4 | `changedObjects` builds two whole-scene lookups in every refresh at a keyframe | Every edit, keystroke, slider tick and keyframe switch at a keyframe | Measured + code | 35 ms per call, run twice | ~7 ms | S-M |
| 5 | A keyframe switch counts as a document edit; transition, rename, split and merge don't | Tapping chips (autosave churn); unsaved timeline edits | Measured (revision) + code | — | — | S |
| 6 | Art rebuild after an edit costs more when layers have transforms or text | Every edit in a deck with moved layers | Measured | 8.5 → 13.7 ms (+60%) | 1.7 → 2.7 ms | M (falls out of #1) |
| 7 | Typing and some sliders go through `edit`, not the continuous path | Typing text; anchor-width, gradient and viewport-colour sliders | Code | Full refresh (#4) + hand-off per tick | | S |
| 8 | Presenting: shaders compiled per view, cold first slide, two displays do all the work twice | Pressing Present; external display | Code | | | M |
| 9 | Image decode and texture upload inside a frame, on the main thread | First show of a large image, at Present too | Code | | | M |
| 10 | Text tweens defeat the text caches; the cache wipes itself at 512 entries | Animating tracking or line height; long presentations with text | Code | | | S |
| 11 | A new `MTLBuffer` per changed layer, every playback frame | Play, scrub | Code | | | S |

### 1. Animated shapes are re-tessellated every frame (measured)

**What happens.** `ArtBuilder.build` works on `drawing.world` (`ArtBatch.swift:348`), which bakes every layer, group and shape transform into the points. The cache then matches a shape by id and full `VectorShape ==` (`TessellationCache.swift:47`, `:71`). That has two consequences:

- A transform tween changes the baked points, so it misses the cache.
- A fill, opacity, gradient or outline-colour tween also misses, because paint is part of `VectorShape`. A pure colour fade re-flattens geometry that did not change.

**Measured cost per frame** (interpolation is cheap; nearly all of it is tessellation):

| Transition | Interpolate only | Interpolate + build | Shapes tessellated |
|---|---|---|---|
| All 40 layers slide (2,400 shapes) | 0.11 ms | 104 ms | 2,400 |
| Every shape changes fill | 1.8 ms | 99 ms | 2,400 |
| One layer (60 shapes) fades | 0.15 ms | 11 ms | 60 |

That works out to about 43 µs per animated shape here, or roughly 9 µs on a Mac. At 120 Hz, a Mac-class CPU drops frames once a few hundred shapes animate at once. Text glyph outlines tessellate at the cost of their contours, so a moving title costs much more than its one "shape".

**Fixes, in order:**

1. **(S) Key the cache on geometry only.** Use the path, the outline width, cap, join, dash, alignment and miter, and the text frame. Leave out the fill, gradient, opacity and outline colour. Colour and opacity tweens then cost nothing to tessellate. In the table above, that takes the fill row from 99 ms to roughly the interpolation cost.
2. **(L) Tessellate in local space** and apply layer, group and shape matrices at draw time. `LiveTransform` and the `.moving` steps already do this for drags (`CanvasRenderer.swift:641-643`). Generalising it to a matrix per segment or per shape makes moves, rotations and scales free. Only real path morphs would still re-tessellate. This also fixes #2 and #6 for transforms.

### 2. The frame after playback re-tessellates everything that animated (measured)

**What happens.** `TessellationCache.store` replaces the first tier. The second tier only keeps the same shape at a different tolerance (`TessellationCache.swift:84-97`). So each interpolated frame evicts the keyframe state's tessellation.

When playback or a scrub ends, `endPreview` shows the keyframe again and every animated shape is tessellated cold, in one main-thread frame.

**Measured:** 2,400 shapes re-tessellated in that frame, about 120 ms here (~25 ms on a Mac).

The onion skin has its own builder, so a keyframe switch with onion skin on also builds the ghost cold (code: `CanvasRenderer.swift:149`, `:539`).

**Fix (S):** build preview and playback frames with a separate `ArtBuilder`, or at least a separate cache, so the editing cache stays warm. Or keep the keyframe-state tessellation pinned while a preview runs. #1's local-space change removes most of this anyway.

### 3. Undo and redo at a keyframe replay the whole chain (measured)

**What happens.** `DrawingEditor.restore` makes a fresh `Timeline` (`DrawingEditor.swift:1826`), which drops every resolved state. `timeline.state(at: k)` then re-applies k keyframes' changes from the opening state.

Each `Drawing.apply(_ changes:)` builds a `SceneLookup` (`SceneDiff.swift:257`). That is two dictionaries holding every layer, group, shape and **every vertex** (57,600 here). `perf` puts about 43% of the undo loop in `SceneLookup.add`.

**Measured:**

| Operation | Container | Mac est. |
|---|---|---|
| Undo+redo at keyframe 10 of 20 | 238 ms | ~45 ms |
| Opening keyframe 20 with no states cached | 218 ms | ~45 ms |
| Undo+redo at the opening state | 0.01 ms | |

The cost grows with the keyframe index × the scene size.

**Fixes:**

- **(M)** Keep resolved states across `restore`. Either store the `Timeline` itself in `EditorSnapshot` (it is copy-on-write, so this costs nothing extra), or reuse cached states whose keyframes are unchanged.
- **(S-M)** Make `SceneLookup` index vertices only when a change targets one (most keyframes only set layer or shape properties). Or keep one lookup and update it as each keyframe applies, instead of rebuilding it per keyframe.

### 4. Every refresh at a keyframe builds two whole-scene lookups (measured + code)

**What happens.** `CanvasStore.refresh()` calls `editor.changedObjects()` whenever the revision or the strip changed (`CanvasStore.swift:381-383`). `updateThumbnails` calls it again 300 ms later (`:770`). It builds `SceneLookup(state(at: i-1))` and `SceneLookup(state(at: i))` (`Timeline.swift:326`) to walk parents for the Layers panel's "changed" marks.

**Measured:** 35 ms per call here (~7 ms on a Mac) at keyframe 10. It runs on the main thread after:

- every committed edit at a keyframe;
- every keyframe switch;
- every typed character (#7).

**Fix (S-M):** cache the result per (keyframe, presentation) and recompute only when the keyframe's changes change. Or compute parents from the changes themselves: a shape's layer is a cheap scan, and a vertex target only needs its own shape. Fixing #3's lookup also helps here.

### 5. Keyframe switches autosave; timeline edits don't (measured + code)

**Measured:**

- `revision` goes up on `selectKeyframe`, because `drawing` is reassigned.
- `revision` does not move after `setTransition` or `renameKeyframe`, even though the presentation changed.

**Consequences:**

- **Switching keyframes:** each chip tap hands the document off (`CanvasStore.updateDocument` → `sendDocument` → `editor.presentation`). That marks it edited and starts an autosave: a whole-presentation encode, plus a thumbnail.
- **Transition, rename, split and merge:** `DocumentHandOff.changed` sees no new revision (`DocumentHandOff.swift:25`). These edits reach the document only with a later drawing edit or keyframe switch. **This looks like a data-loss bug** if the app is killed in between.

**Fix (S):** give the editor a document revision that moves on any presentation change, separate from the display revision, and hand off on that one.

### 6. Edits cost more in decks with transforms or text (measured)

**What happens.** `Drawing.world` re-bakes every shape of every layer that has a transform or text on each build (`Drawing.swift:1089-1106`). The baked copies no longer share storage with the cache's copies, so `LayerKey` and `TessellationCache.use` fall back to element-by-element compares.

**Measured:**

| Art rebuild after one fill edit | Container |
|---|---|
| Plain drawing | 8.5 ms |
| Every layer transformed | 13.7 ms (the world bake alone is 1.5 ms) |
| One text per layer | 10.6 ms |

**Fix:** this disappears with #1's local-space tessellation. As a stop-gap, cache each world layer keyed by its source layer.

### 7. Typing and some sliders aren't continuous (code)

These go through `store.edit` rather than the continuous `restyle` path:

- `setEditedText` typing (`DrawingEditor+Text.swift:247`);
- the anchor-width slider (`AppearancePanel.swift:44`);
- the gradient angle and span sliders (`:97`, `:106`);
- the viewport background `ColorPicker` (`ViewportPanel.swift:38`).

So each keystroke or tick runs `Timeline.record` → `SceneDiff.changes`, a full `refresh()` (including #4 at a keyframe), and an immediate hand-off that leads to an autosave.

**Fix (S):** pass `continuous: true`, as the colour picker already does, so hand-offs coalesce.

### 8. Presenting (code)

- `CanvasRenderer.init` compiles `ShaderSource` from source and builds 6 pipelines for each `PresentationCanvasView` (`CanvasRenderer.swift:212-254`). Pressing Present compiles once, or twice with an external display. **Fix:** a shared static `MTLLibrary` and pipelines.
- A new renderer starts cold (`leavingOutUncached`), so the first slide's layers fill in over a few frames. **Fix:** do a synchronous first build for the opening slide.
- With an external display, the presenter view and the external view each interpolate and tessellate every frame, so the CPU work doubles. Sharing `lastFrame` fails when refresh rates differ (`PresentationController.swift:79`). **Fix:** share the interpolated scene and the batch between the displays.

### 9. Images decoded and uploaded on the main thread (code)

`ImageLibrary.image` decodes with `ShouldCacheImmediately` (`ImageLibrary.swift:54-64`). Then `makeTexture` redraws the image into a CGContext and uploads it with mipmaps (`CanvasRenderer.swift:826-886`), all inside a frame. That is tens of ms for a large photo, repeated for each renderer, including at Present. `insertImage` also re-encodes on the main thread (`CanvasStore.swift:1084-1129`).

**Fix:** decode and upload on a background queue, showing the existing placeholder meanwhile.

### 10. Text caches during tweens (code)

A tracking or line-height tween makes a new `TextContent` every frame, so each frame re-runs layout → `adjusted` → `outline`, then tessellates the glyphs. `TextShaping` empties its whole cache at 512 entries (`Text.swift:356`, `:373`). At 120 Hz that happens within seconds, so the static texts' CoreText layouts are lost too, which causes periodic re-layout spikes.

**Fix (S):** don't cache `held` variants (or give them a small LRU of their own), and replace the wipe with an LRU.

### 11. Buffer allocation during playback (code)

`upload(_:keeping:)` calls `device.makeBuffer` for every new segment (`CanvasRenderer.swift:528-533`). During playback that means each changed layer, every frame, including any static art that shares a layer with a moving shape.

**Fix (S):** draw these buffers from `VertexBufferPool` during previews.

## Smaller notes (code)

- Each thumbnail is PNG-encoded off the main thread and then decoded on it. Each one that arrives also re-renders the whole `TimelineBar`. Returning a `CGImage` and assigning the thumbnails in one batch would fix both.
- Each tick of the transition popover's duration slider runs a full `refresh()` and re-renders `TimelineBar`.

## Checked and fine

| Path | Measured cost (container) |
|---|---|
| Interpolating a transition, with vertex ids | 0.1 ms whole stage; 1.8 ms when every shape recolours |
| Committing an edit (nudge) at any keyframe | 0.47 ms |
| `editor.presentation` for hand-off | < 0.01 ms |
| Switching keyframes with warm states and a warm art cache | 0.3 ms |
| `timelineStrip` | < 0.01 ms |
| `keyedProperties` | 0.12 ms |
| Select hover with every layer transformed | 0.07 ms |

From reading the code:

- SwiftUI does not invalidate per playback frame (`isPlaying` is set once; scrubbing is set once per scrub).
- Smart guides build their targets once per drag.
- The presenter doesn't render at rest.
- Undo snapshots are copy-on-write with a limit.

## Suggested order

1. **Fix the measurement (shipped).** Give `StressDrawing` vertex ids. Keep the playback, after-playback, undo-at-keyframe and `changedObjects` workloads from the scratch file as real `PerformanceTests` and `Workloads`.
2. **Quick wins (S, shipped):**
   - #5 (also fixes the data-loss risk);
   - #2 (a separate preview builder);
   - #1's geometry-only cache key;
   - #7;
   - #4's caching.
3. **#3 (shipped):** keep the timeline's states across undo, and make `SceneLookup` lighter.
4. **#1 properly:** local-space tessellation with transforms applied at draw time. This also removes #6.
5. **#8, #9, #10, #11.**

## On-device follow-up

An Instruments pass on a real iPad would add what Linux can't show:

- the GPU side (stencil-and-cover fill rate, 4x MSAA on a 12.9" screen);
- real CoreText glyph costs;
- SwiftUI body re-evaluations;
- true iPad timings for the rows above.

The app already emits the signposts this needs: `Frame`, `Art rebuild`, `GPU frame`, `Missed frame deadline` and `Refresh`. A good script: play a whole-stage transition, undo at a late keyframe, type at a keyframe, and present with an external display.

## Progress

### Step 1: fix the measurement (shipped)

`StressDrawing.make` assigns vertex ids, and `PerformanceTests.testStressDrawingIsValid` checks them. `StressDrawing.presentation(_:keyframes:)` builds a deck of keyframes that each move one layer and recolour one shape, and `StressDrawing.transition(from:to:)` a one-keyframe transition. The new workloads, in `Workload.all` (so `ScalingTests` covers them) and as `PerformanceTests`:

| Workload | Hotspot | Container, per call |
| --- | --- | --- |
| `playbackFrameAllLayersSlide` | #1 | 79 ms |
| `playbackFrameEveryFillChanges` | #1 | 79 ms |
| `playbackFrameOneLayerFades` | #1 | 6.0 ms |
| `frameAfterPlayback` | #2 | 79 ms |
| `undoRedoAtKeyframe` (keyframe 10 of 20) | #3 | 150 ms |
| `changedObjectsAtKeyframe` (keyframe 10 of 20) | #4 | 14 ms |

Full size, `-c release`, the `measure` average divided by the calls per run, on the same kind of cloud container as the profile (this run was faster than the profile's; compare before and after on one machine). With vertex ids, `testPlaybackFrames` dropped to 1.8 ms per frame.

### Step 2: quick wins (shipped)

- **#5:** `DrawingEditor.documentRevision` moves on any change to the document: a drawing edit, a timeline command (transition, rename, split, merge and the rest), undo and redo. Showing another keyframe leaves it alone. `CanvasStore` hands off on it rather than on `revision`, so a chip tap no longer autosaves and a timeline edit is no longer left unsaved until the next drawing edit. Covered by `DocumentHandOffTests`.
- **#2:** `CanvasRenderer` builds scrub and playback frames with `previewBuilder`, a copy of the art builder taken on the preview's first frame (with the art's buffers). The art builder keeps the keyframe's art and cache, and is keyed on `revision` rather than `displayRevision`, so when the preview ends the keyframe shows with no rebuild at all. The copies share storage until the preview writes, and the copy is dropped when the preview ends. A refine merged during a preview is copied into the preview's cache too. Presenting is unchanged: its editor has no drawing of its own, so its scenes stay the art.
- **#1, geometry-only key:** `TessellationCache` reuses a tessellation for any shape with the same id, path and outline geometry (`Tessellation.matches`): width, cap, join, miter limit, dash and alignment. Fill, gradient, opacity, image and outline colour are paint, carried by the steps. Local-space tessellation is still step 4.
- **#7:** typing (`setEditedText`), the anchor-width slider and the viewport background picker go through `edit(continuous: true)`, and the gradient angle and spread sliders through `restyle`, so their hand-offs coalesce like the colour pickers'.
- **#4:** `Timeline.changedObjects(inKeyframe:)` looks up only the ids its changes name (and takes created objects' parents from the changes) instead of indexing every object and vertex of two scenes, and `DrawingEditor.changedObjects()` keeps its last result until the keyframe, `revision` or `documentRevision` changes, so `updateThumbnails`' second read is free.

Before and after, full size, `-c release`, per call, on one cloud container:

| Workload | Before | After |
| --- | --- | --- |
| `playbackFrameEveryFillChanges` | 123 ms | 32 ms |
| `playbackFrameOneLayerFades` | 17 ms | 15 ms |
| `playbackFrameAllLayersSlide` | 123 ms | 123 ms (step 4) |
| `frameAfterPlayback` | 114 ms | 20 ms, and none in the app |
| `changedObjectsAtKeyframe` | 32 ms | < 0.1 ms, uncached |
| `undoRedoAtKeyframe` | 276 ms | 273 ms (step 3) |

`frameAfterPlayback` now times the art builder building the keyframe again after a preview copy played; what is left is the world bake and the layer compares of #6, and the renderer skips even that, since `revision` didn't move. `changedObjectsAtKeyframe` now times the timeline's computation, not the editor's cached copy. What is left of the fill and fade frames is the interpolation, the world bake and rebuilding each changed layer's steps.

### Step 3: undo, redo and resolving keyframes (shipped)

- **Undo and redo keep resolved states.** `DrawingEditor.restore` builds the new `Timeline` and calls `reuseStates(of:)` with the old one. When the opening states match (ignoring `nextID`), it takes every resolved state up to the first keyframe whose changes differ, so undo at keyframe k re-applies only from the keyframe the step changed. Comparing changes is cheap because the snapshot's keyframes share storage with the live timeline's.
- **One lookup per run, without vertices.** `Timeline.state(at:)` and `prune` build one `SceneLookup` and keep it up to date while each keyframe applies (`Drawing.apply(_:lookup:)`), rather than indexing the whole scene per keyframe. The lookup leaves vertices out until a change names an id it doesn't know (`SceneLookup.prepare`); most keyframes only set layer and shape properties, so it never indexes them. Until then a create checks only that its layers, groups and shapes are new, since ids are unique across a scene. Repairing groups (which can make new group ids) rebuilds the lookup. Loading a file still indexes everything, to validate it.
- New workload `resolveLastKeyframeCold`: resolving keyframe 20 of 20 from the opening state, as the first show of a late keyframe after opening a file.

Before and after, full size, `-c release`, per call, on one cloud container:

| Workload | Before | After |
| --- | --- | --- |
| `undoRedoAtKeyframe` (one undo and redo) | 196 ms | 1.3 ms |
| `resolveLastKeyframeCold` | 185 ms | 1.0 ms |
| `changedObjectsAtKeyframe` | < 0.1 ms | < 0.3 ms (noise) |
| `open` | 228 ms | 243 ms (noise; unchanged code) |


### Step 4: local-space tessellation (shipped)

- **Shapes are tessellated in their own space.** `ArtBuilder` no longer builds from `drawing.world`. Each shape is cached as `ArtBuilder.artShape` gives it: its own points (text laid out), with its group and shape transforms as a `place` step (`ArtStep.place`), at the art's tolerance divided by how much its transforms enlarge it, rounded up to a power of two (`ArtBuilder.detail(of:)`). The layer's transform goes on its segment (`ArtSegment.transform`), outside the layer's cache key, so a layer whose transform alone changed reuses its steps, its vertices and (in the renderer) its buffer.
- **The renderer applies the matrices.** `CanvasRenderer.drawArt` draws each segment through `segment.transform · place` (and the drag's transform for `.moving` shapes) before the camera. Gradients and pictures are in the vertices' own space, so they move with the shape.
- **What is still baked.** A stretch or skew of a shape with an outline or a gradient is baked into its points, so outlines keep an even width and gradient bands stay square to their axis, as the file and the exports draw them. A stretched layer with such shapes bakes its transform into all of them.
- **Drags.** A drag changes transforms, not points, so `carry` no longer moves triangles: it keeps each moved shape's tessellation, relabelling a shrunk one at its coarser tolerance and counting an enlarged one as coarse. The carry limit is gone, since nothing is rounded again.
- **#6** goes with it: an edit no longer re-bakes the transformed and text layers. Tests: `LocalSpaceArtTests` paints transformed layers, groups, shapes, clipping, gradients and outlines with `StencilSimulator` (now aware of `place` and segment transforms) and compares them with the world drawing.

Before and after, full size, `-c release`, per call, on one cloud container:

| Workload | Before | After |
| --- | --- | --- |
| `playbackFrameAllLayersSlide` | 88 ms | 7.4 ms |
| `frameAfterPlayback` | 12 ms | 7 ms |
| `testPlaybackFrames` (per frame) | 1.9 ms | 1.3 ms |
| `testDragWithLiveTransform` (one 20-sample drag and lift) | 208 ms | 176 ms |
| `playbackFrameEveryFillChanges` | 19 ms | 22 ms (noise) |
| `artRebuildAfterOneEdit` | 7.6 ms | 7.6 ms |

What is left of the slide frame is interpolating the scene and comparing each layer's shapes for its cache key; nothing is flattened or rebuilt. The app can't be built here, so the renderer change is checked by CI's app build only; an on-device check of a whole-stage slide, a dragged shape with a gradient and a scaled outlined layer is worth doing.
