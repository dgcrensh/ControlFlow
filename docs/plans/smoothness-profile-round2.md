# ControlFlow smoothness profile, round 2

Profiled on 2026-10-16 against `main` at `79c32cd`, after all five steps of [round 1](smoothness-profile.md) merged (#14 to #18). Line numbers are from that commit.

## How this was measured

- **Measured** rows are release-build benchmarks of ControlFlowCore on the full stress drawing (`STRESS_DRAWING=full`: 40 layers × 60 shapes × 24 anchors, 2,400 shapes), median of 9 runs unless noted, with `perf` call graphs for the art build.
- **Inferred** rows come from reading the app: the Metal renderer, `CanvasStore`, SwiftUI, and presenting. The app can't be built or run on Linux.
- **This container is about 2.6× slower than the Mac** of `docs/plans/performance-*.md` (the unchanged "art rebuild after one edit" is 4.45 ms here and 1.69 ms there; it was 8.5 ms in round 1's slower container). "Mac est." is container ÷ 2.6, order of magnitude only.
- **Frame budget:** 8.3 ms at 120 Hz, 16.7 ms at 60 Hz. The CPU part of a frame should stay well under half of that.
- **The benchmarks** started as scratch test files. Step 1 of the suggested order below turned the workloads the steps need into `Workload`s in `Workloads.swift`, timed by `PerformanceTests` and `ScalingTests`. To re-run them: `STRESS_DRAWING=full swift test -c release --package-path Packages/ControlFlowCore --filter PerformanceTests`.

> **Caveat about the benchmarks (fixed in step 1).** The renderer builds with `concatenatesVertices = false` (`CanvasRenderer.swift:128`, `:173`, `:616`). Every `Workload` and `PerformanceTests` case used a default `ArtBuilder`, which copies every layer's floats into one array on every build. `perf` put **76 to 80%** of a playback or edit build in that `memmove` (`ArtBatch.append`, `ArtBatch.swift:857`). The real app cost is 5 to 6 times lower than those workloads reported:
>
> | Build | Workloads' old setting | Renderer's setting |
> |---|---|---|
> | Art rebuild after one edit | 4.45 ms | 0.72 ms |
> | Playback frame, every layer slides | 4.0 ms | 0.77 ms |
> | Keyframe switch and build | 4.6 ms | 1.2 ms |
>
> It also hid what is left. Every workload and `PerformanceTests` case now builds with `ArtBuilder.likeRenderer()`, so art rows from tables before step 1 (in `performance-audit.md` and round 1) are not comparable with later ones.

## Summary

Round 1's targets stay fixed. Playback of moves, keyframe switches, undo at a keyframe, typing and committing an edit all cost about a millisecond or less of core work now, with nothing re-tessellated. The work that remains falls into four groups:

1. **Every frame re-encodes the whole art (inferred).** It walks about 8,000 steps of state changes and draws, and re-sends uniforms on nearly every one. On a large drawing this is now probably the biggest per-frame cost on the device, and it hits drawing, hovering, navigating and playback alike.
2. **Paint changes re-upload whole layers (measured).** A fade or recolour re-uploads its layers' triangles on every frame (15 MB per frame when every fill changes), and costs 10 ms of build. Onion skin builds the previous keyframe cold: 76 ms per switch.
3. **Big selections are slow (measured).** With everything selected, each refresh, colour-picker tick, nudge, hover frame and marquee scales with the selection. Most of these are simple: the same work repeated, a selection turned into a string, and an O(n²) loop.
4. **Edits that dirty many keyframes (measured)** cost 10 to 70 ms on the main thread: a keyframe that keys many shapes, reorders in later keyframes, and thumbnails after an early edit.

## Ranked hotspots

| # | Hotspot | When the user feels it | Evidence | Container | Mac est. | Effort |
|---|---|---|---|---|---|---|
| 1 | Whole art re-encoded every frame, with redundant state per step | Every frame: drawing, hover, pan and zoom, drag, playback | Code | 8,010 steps → ~8k draws, ~16k pipeline and uniform binds per frame | GPU encode, likely several ms on iPad | S (binds) / M (culling, cache) |
| 2 | Onion skin builds the previous keyframe cold | Keyframe switch or zoom bucket with onion skin on | Measured | 76 ms per switch (7 ms if seeded) | ~29 ms | S |
| 3 | Paint-only changes re-upload whole layers | Fades, recolour transitions, colour drags, presenting | Measured | Every fill changes: 10 ms build + 15.5 MB upload per frame; one layer fades: 393 KB per frame | ~4 ms + upload | M |
| 4 | `refresh()` selection queries repeat work | Every touch end, command, keystroke, with a big selection | Measured | 13.9 ms with everything selected (19.7 ms at a keyframe); align queries alone 9.6 ms | ~5-8 ms | S |
| 5 | Coalescing keys format the whole selection into a string | Each nudge, colour-picker tick and restyle sample | Measured | 8.4 ms per sample with 2,400 shapes selected | ~3 ms | S |
| 6 | `keyedProperties()` hashes every selected vertex | Every refresh and every style tick at a keyframe | Measured | 5.6 ms with everything selected | ~2 ms | S |
| 7 | Select-tool hover recomputes the selection frame each frame | Hovering with a big selection | Measured | 3.3 ms per frame (4.5 ms transformed) | ~1.3-1.7 ms | S |
| 8 | Marquee is O(n²) when shapes are grouped | Marquee-selecting lots of grouped art | Measured | 168 ms (12 ms ungrouped) | ~65 ms | S |
| 9 | Edits at a keyframe that keys many shapes re-diff all of them | Any commit at a "big build" keyframe | Measured | 15.5 ms per nudge (12.4 ms `SceneDiff`) | ~6 ms | M |
| 10 | Prune re-indexes the whole scene per reordering keyframe | Delete or edit early in a deck whose keyframes reorder | Measured | 73 ms (2.4 ms without reorders) | ~28 ms | M |
| 11 | Thumbnails after an edit: main-thread resolve, N decodes, N strip re-renders | 300 ms after an edit near the start of a deck | Measured + code | 10-13 ms resolve and compare, then 21 PNG decodes and strip updates | ~4-5 ms + SwiftUI | S |
| 12 | Shape index rebuilt from scratch on the first hover after an edit | First hover or tap after any edit or keyframe switch | Measured | 2.1-3.9 ms | ~1-1.5 ms | M |
| 13 | Text tracking and line-height tweens re-lay-out and re-tessellate every frame | Animating text metrics | Measured (stub shaper) | ~17 ms per frame for 40 texts | ~7 ms, more with CoreText | M |
| 14 | Some per-tick controls still hand off on every tick | Transition duration slider and curve drags; text line height and tracking; reference opacity | Code | Hand-off + `ContentView` re-render per tick | | S |
| 15 | Frame-order and per-event waste in the renderer | Edits, hovering, opening with references, presenting | Code | | | S |
| 16 | Copy and paste of big selections on the main thread | Copy or paste of everything | Measured | Copy 298 ms, paste 204 ms, duplicate 29 ms | ~115 / 80 ms | M |

### 1. The whole art is re-encoded every frame (code)

**What happens.** `CanvasRenderer.drawArt` (`CanvasRenderer.swift:692-787`) walks every step of every segment on every frame (8,010 steps on the stress drawing). Stencil and cover steps alternate, and `bind` (`:712-721`) only skips repeats of the same kind. So nearly every step does all of this:

- `setRenderPipelineState`;
- recomputes `toWorld`;
- `setVertexBytes` of the ~176 B `CanvasUniforms`;
- `setVertexBuffer`;
- a `depthStencilState(state)` dictionary lookup (`:790`);
- `setDepthStencilState`, then `setStencilReferenceValue`.

Each cover also builds `PaintUniforms` and calls `setFragmentBytes` (gradients allocate arrays, `:35-39`). Nothing is culled to the view.

That is roughly 8k draws, 40 to 50k encoder calls and about 1.4 MB of byte copies per frame, at rest too whenever anything asks for a frame: drawing a stroke, hovering, navigating or dragging. It is the one per-frame cost that still scales with the drawing, and it is the next thing to look at on a device.

**Fixes:**

1. **(S)** Bind the transform only on `.place`, `.moving` or a new segment. Metal keeps vertex bindings across pipeline switches. Skip unchanged depth-stencil states and references, and resolve each `StencilState` once per batch.
2. **(S-M)** Write each segment's paint uniforms into a buffer at upload and use `setFragmentBufferOffset`.
3. **(M)** Cull shapes outside the view using the cover rectangle the builder already makes. Clip bases and group masks stay whole.
4. **(M-L)** While the camera and the art are unchanged (drawing, hovering, overlay-only frames), draw the art once into a resolved texture and composite it.

**Measure on device:** the `Frame` and `GPU frame` signposts while hovering over the stress drawing.

### 2. Onion skin builds cold (measured)

**What happens.** `updateOnion` (`CanvasRenderer.swift:598-607`) builds with its own `onionBuilder`, whose tessellation cache starts empty and is thrown away by `releaseOnion`. Its key includes `artTolerance`, so every keyframe switch and every zoom bucket with onion skin on flattens the whole previous keyframe inside a frame.

**Measured:** previous keyframe, 20-keyframe deck: **76 ms cold**, 7 ms when the builder is seeded with the art builder's tessellations. The geometry-only key from round 1 means nearly every shape is shared.

**Fix (S):** seed `onionBuilder.tessellations` from `artBuilder.tessellations` before each build, and build with `reusingOtherTolerances: true`.

### 3. Paint-only changes re-upload whole layers (measured)

**What happens.** A rebuilt layer always gets a new segment id (`nextLayerBatchID`, `ArtBatch.swift:527`), because `LayerKey` compares whole shapes, paint included. A fade or recolour rebuilds the layer's steps and re-uploads every float of its triangles, though they haven't changed:

- **The editor:** a new `MTLBuffer` per tick of the colour, opacity and gradient controls, and per anchor-drag sample.
- **Previews and presenting:** a pooled upload on every frame. The pool has 64 slots, so past about 20 changing layers it falls back to `makeBuffer` on every frame (`VertexBufferPool.swift:87-90`).

**Measured** (renderer settings, per frame):

| Transition | Build | Re-uploaded |
|---|---|---|
| Every fill changes | 10.0 ms | 15.5 MB |
| One layer (60 shapes) fades | 0.93 ms | 393 KB |
| Every layer slides | 0.77 ms | 0 |

**Fix (M):** split `LayerKey` into geometry and paint. When only paint differs, keep the segment id and its buffer and patch the cover steps' paint, so the cost is one walk of the changed layers. With #1's paint buffer this becomes a small buffer write. Also pick the smallest pool slot that fits, and add a signpost for pool fallbacks.

### 4. `refresh()` repeats selection work (measured)

**What happens.** `CanvasStore.refresh()` (`CanvasStore.swift:326-406`) reads about 45 editor queries after every touch end (pan and zoom included), command and keystroke:

- **Align queries:** `canAlign`, `canDistribute` and `alignsToViewportOnly` (`:334-336`) each run `alignmentBoxes()` (`DrawingEditor+Align.swift:46-67`), which bakes world bounds for every selected shape. Three passes per refresh.
- **Shape-index scans:** about 25 `shapeIndices(in:)` scans walk every shape for a `.shapes` selection: crumbs, scope layer, has-text, has-image and so on.

**Measured, everything selected:**

| Case | Container |
|---|---|
| Existing `readRefreshQueries` workload | 3.9 ms |
| Everything `refresh()` actually reads | 13.9 ms |
| The same, every layer transformed | 17.1 ms |
| The same, at keyframe 10 of 20 | 19.7 ms |
| The three align queries, 2,400 shapes in one layer | 9.6 ms |

**Fixes (S):**

- Compute the alignment unit count once per refresh, without bounds.
- Skip the selection block when `revision`, `selection`, `tool`, isolation and the selected anchors are all unchanged, so navigation ends are free.
- Extend `readRefreshQueries` to read what `refresh()` reads.

### 5. Coalescing keys stringify the selection (measured)

`nudge` uses `"nudge-\(selection)"` (`DrawingEditor+Commands.swift:331`), and `restyleSelection` uses `"\(key)-\(selection)"` (`DrawingEditor.swift:1811`). That formats the whole selection `Set` as a string on every sample.

**Measured:** 8.4 ms for that string alone with 2,400 shapes selected. It is most of a colour-picker tick on everything (18.8 ms opening, 28.3 ms at a keyframe), and of a whole-selection nudge (20 ms opening, 35 ms at a keyframe).

**Fix (S):** key on a selection generation counter or the selection's hash, not its description.

### 6. `keyedProperties()` walks every selected vertex (measured)

**What happens.** `DrawingEditor+Timeline.swift:269-300` puts every vertex id of every selected shape, in both this state and the previous one, into a `Set` before looking at the keyframe's changes. It runs in `refresh()` (`CanvasStore.swift:386`) and in `refreshStyle()` (`:435`), which runs on every tick of the fill, outline, opacity and gradient controls.

**Measured:** 5.6 ms with everything selected at keyframe 10, against 0.11 ms with one shape.

**Fix (S):** scan the changes first, and resolve only the targets that aren't selected objects to their parent shapes, as `changedObjects(inKeyframe:)` already does. Cache the result per (keyframe, `documentRevision`, selection).

### 7. Select hover recomputes the selection frame (measured)

**What happens.** The select tool's overlay does all of this on every frame:

- calls `drawing.frame(of: selection)` and `editor.pivot` (`EditorOverlay.swift:384`, `:410`), which unions world bounds of the whole selection;
- runs `shapeRefs(in: selection).contains(target)` on every hover (`:319`);
- with ghosting on, `ghostFocus` (`Viewport.swift:112-117`) builds a `Set` per frame (`CanvasRenderer.swift:466`, `:475`).

**Measured:** 3.3 ms per hover frame with everything selected (`frame(of:)` alone is 1.5 ms), 4.5 ms with every layer transformed.

**Fix (S):** cache the frame, the pivot and the selected-ref set in `OverlayCache` and the editor, keyed by `(revision, selection)`.

### 8. Marquee is O(n²) with groups (measured)

`finishMarquee` (`DrawingEditor.swift:800`) calls `tapTarget` (`:750`) per shape. For a grouped shape that walks `shapeRefs(in:)` over the whole drawing.

**Measured:** marquee over everything and lift takes 12 ms on the stress drawing (few groups), and **168 ms** when every shape is in a pair group.

**Fix (S):** resolve each group's target once per marquee.

### 9. Commits at a keyframe that keys many shapes (measured)

`SceneDiff.changes` (`SceneDiff.swift:346`) rebuilds property JSON and `PropertyPath.changes` for every shape that differs from the previous keyframe, on every commit. Once a keyframe keys all 2,400 shapes (a "build everything in" slide), nudging one shape there costs **15.5 ms**, 12.4 ms of it the diff. Moving everything there costs 35 ms.

**Fix (M):** diff only the layers and shapes the commit changed (the layers whose storage differs from `before`), and carry over the keyframe's other changes as they are.

Reshaped shapes are fine: 60 shapes with a merged vertex cost 2.8 ms to diff and 0.7 ms per playback frame.

### 10. Prune with reordering keyframes (measured)

`prune(after:)` (`Timeline.swift:120`) re-applies the later keyframes. Each one with an `order` change builds `state.objectIDs`, a set of every id including about 58k vertices.

**Measured:** delete one shape at keyframe 1 of 20, then undo: **73 ms** in a deck whose keyframes reorder shapes, 2.4 ms in one that doesn't.

**Fix (M):** check order changes against the shared `SceneLookup` (which round 1 made incremental) instead of a fresh id set.

### 11. Thumbnails after an edit (measured + code)

**What happens.** 300 ms after an edit, `updateThumbnails` (`CanvasStore.swift:769-792`) resolves every keyframe and compares it with the cached scene, on the main thread. An edit to the opening state, or one that isn't keyed and so applies everywhere, changes every keyframe, so all N+1 thumbnails then render one by one. Each arrival:

- decodes a PNG on the main thread (`:790`);
- writes `ui.thumbnails`, which every chip reads (`TimelineBar.swift:187`), so the whole strip re-renders each time.

**Measured:** 10 to 13 ms to resolve and compare 21 states, before the decodes and the 21 strip updates.

**Fixes (S):** return a `CGImage` from the detached task and assign the thumbnails in one batch. **(M)** Make the chip its own view that takes its image as a value.

### 12. Shape index rebuilt on the first hover after an edit (measured)

`ShapeIndex.init` (`ShapeIndex.swift:47`) runs from scratch whenever `revision` moves, over `drawing.world`, which re-bakes every transformed layer.

**Measured:** 2.1 ms plain, 3.9 ms with every layer transformed. A nudge followed by the first hover is 4.6 ms, against 0.6 ms for the nudge alone. It lands on the first hover or tap after every edit and every keyframe switch.

**Fix (M):** update the index for the changed layers only, keyed by layer storage, the way `ArtBuilder` reuses layers.

### 13. Text metric tweens (measured with the stub shaper)

Round 1's LRU stops a tween from pushing the static texts out. But 40 texts tweening tracking still re-lay-out, re-outline and re-tessellate every frame: 40 shapes tessellated per frame, about **17 ms** per frame here (the 40 texts sliding cost 0.4 ms). This uses the Linux stub shaper, so CoreText on the iPad will cost more.

**Fix (M):** tween tracking and line height by moving the laid-out glyphs (each glyph's `place`) rather than re-laying-out, when the line breaks don't change. Otherwise, at least cache by quantised metric value.

### 14. Per-tick controls that still hand off every tick (code)

These still hand the document off on every tick. Since `documentRevision`, each hand-off also re-renders `ContentView` and marks the document edited:

- `CanvasStore.setTransition` (`:690-692`) calls `edit` without `continuous`. That covers the duration slider (`TimelineBar.swift:282`) and every curve-handle drag sample (`:400-406`).
- The text line-height and tracking sliders (`ContentView.swift:868`, `:876`).
- The reference opacity slider (`LayersPanel.swift:372`).
- `textViewDidChangeSelection` (`MetalCanvasView.swift:415-419`) runs a non-continuous refresh, which flushes a held hand-off. If UIKit calls it after each change (autocorrect, marked text), typing is back to one hand-off per keystroke. Worth checking with the "Hand off" signpost.

**Fix (S):** pass `continuous: true`, as the anchor-width slider does.

### 15. Renderer frame order and per-event waste (code)

- **(S)** `nextDrawable()` is taken first (`CanvasRenderer.swift:269`), before the art rebuild, upload, onion and overlay work. With two drawables, a slow GPU frame blocks the main thread, touches included. Do the CPU work first, then take the drawable.
- **(S)** Every hover event renders a full frame (`MetalCanvasView.swift:183`) even when the hover target didn't change. With #1, this is the cost of hovering. Have `pencilHovered` return whether anything changed.
- **(S)** Reference images still decode with `UIImage(data:)` and upload inside the frame (`CanvasStore.swift:213-220`, `loadMissingTextures`). Data that fails to decode is retried every frame. Use `CanvasGPU.imageTexture`'s background path and remember failures.
- **(S)** Presenting draws the 4× MSAA grid under a stage that covers it (`:313-315`). Skip it when presenting.
- **(S-M)** The live stroke is copied into a pooled buffer every frame once it's over 4 KB (`:843-855`), so it grows with the stroke. Keep the committed part resident.
- **Known from round 1:** two displays still interpolate and build twice. That is cheap now (about 1 ms per frame) and waits for the device pass.

### 16. Copy and paste of big selections (measured)

Copying everything encodes JSON on the main thread: **298 ms**. Pasting it back takes 204 ms, duplicating 29 ms. These are one-offs, but they freeze the UI.

**Fix (M):** encode the pasteboard lazily, with a promise, or in the background.

## Checked and fine

**Measured (container, renderer settings):**

| Path | Cost |
|---|---|
| Playback frame, one or all 40 layers slide | 0.7-0.8 ms, nothing tessellated or uploaded |
| Keyframe switch and art build, warm | 1.2 ms |
| Art rebuild after one edit | 0.72 ms |
| Commit (nudge) at any keyframe | 0.6-1.1 ms |
| Undo and redo at keyframe 10 of 20 | 1.1 ms (round 1: 238 ms) |
| Resolve keyframe 20 cold | 1.3-1.5 ms (round 1: 218 ms) |
| Typing one character, 40 texts | 0.5 ms opening, 1.1 ms at a keyframe |
| `changedObjects`, `keyedProperties` (one shape), `timelineStrip`, hand-off getter | ≤ 0.12 ms |
| Delete keyframe or Set Keyframe, with undo | < 1 ms |
| Move a keyframe chip | 8.6 ms (one-off) |

**From the code:**

- No SwiftUI writes during gestures, playback or scrubbing.
- The display link pauses when idle.
- Shaders, pipelines and image-shape textures are shared and loaded off the main thread.
- The autosave encode (about 250 ms here for 2,400 shapes, with or without 20 keyframes) and its thumbnail run in `fileWrapper`, off the main thread.

## Suggested order

1. **Fix the measurement (shipped).** Every workload and `PerformanceTests` case builds with `ArtBuilder.likeRenderer()` (`concatenatesVertices = false`), and the playback workloads upload what each frame rebuilt, as the renderer does. New workloads:
   - whole-selection refresh: `readRefreshQueries` reads everything `refresh()` reads, at the opening state and at keyframe 10 ("Refresh queries, everything selected, keyframe 10"); "Color picker tick, everything selected, keyframe 10" (with what `refreshStyle()` reads); "Nudge everything"; "Hover frame, everything selected";
   - "Marquee over everything, shapes grouped in pairs";
   - "Onion skin build, keyframe 10 of 20", a fresh builder as `updateOnion` uses;
   - `testPlaybackUploadPerFrame` prints the floats each played frame uploads, and checks a slide uploads none;
   - "Nudge at a keyframe that keys every shape";
   - "Delete and undo at keyframe 1, keyframes reorder";
   - "Playback frame, a text per layer tweens tracking".
2. **Quick wins (shipped).** Each is a few lines, and together they remove the big-selection stalls and the worst one-frame spikes:
   - #2, seed the onion builder;
   - #5, selection keys;
   - #4, align once per refresh and skip unchanged refreshes;
   - #6, `keyedProperties`;
   - #7, cache the select frame;
   - #8, marquee;
   - #14, continuous hand-offs;
   - #11, batch the thumbnails;
   - #15, frame order, hover, references and the presenting grid.

   What shipped: the onion builder starts from the art's tessellations; coalescing keys use `selectionGeneration`; `alignAvailability` counts the units once without bounds, and `refresh()` reads the selection's queries only when `selectionQueriesKey` changes; `keyedProperties()` looks up only the targets that aren't selected objects and is cached; `OverlayCache` keeps the selected refs, select frame and pivot, and `GhostFocusCache` the ghost focus; the marquee finds groups in one walk; the transition, text metric and reference opacity controls and text selection changes are continuous; thumbnails render and decode in one background batch and reach the strip in one update; the renderer takes the drawable after the CPU work, decodes references off the main thread and remembers failures, skips the grid when presenting, and draws on hover only when `pencilHovered` reports a change.

   Measured in this container against `main` before the change (release, full stress drawing, median per call):

   | Workload | Before | After |
   |---|---|---|
   | Refresh queries, everything selected | 11.3 ms | 4.2 ms |
   | The same at keyframe 10 | 16.5 ms | 4.5 ms |
   | Hover frame, everything selected | 3.3 ms | 0.02 ms |
   | Nudge everything | 20 ms | 11.8 ms |
   | Color picker tick, everything selected, keyframe 10 | 35 ms | 22 ms |
   | Marquee over everything, shapes grouped in pairs | 165 ms | 9.9 ms |
   | Onion skin build, keyframe 10 of 20 | 67 ms | 13.7 ms |

   The refresh rows are what a refresh reads when the selection's key changed; a pan, zoom or tool option now skips them. What is left of a nudge and a colour tick is the commit itself (#9's diff at a keyframe).
3. **#1's encoder diet (shipped):** cut the redundant binds and state, and put paint in buffers. Then check on a device whether culling or an art cache is still needed.

   What shipped: the walk over the art's steps moved into ControlFlowCore as `ArtEncoding.encode`, which sets the pipeline, the transform, the vertex buffer, the depth-stencil state, the stencil reference and the paint buffer only when a step needs a different one. `ArtEncodingTests` replays its commands as a GPU keeps them and checks every draw sees what the old per-step walk set, on the stress drawing, under isolation, ghosting and a live drag, and with image covers whose picture is or isn't ready. The art's vertex shader now takes the 64-byte matrix alone instead of the 176-byte `CanvasUniforms`, and only on a new segment, `place` or `moving`. Each layer's buffer holds its cover steps' paints after its vertices, one 256-byte slot each (`ArtSegment.paintFloats`), written at upload, so a cover binds its paint with `setFragmentBufferOffset` instead of copying it; the paint goes with the vertices, so the buffer's lifetime rules cover it. `StencilState`s still resolve through a dictionary, but only when the state changes.

   Commands per frame for the art of the full stress drawing (`STRESS_DRAWING=full`, 8,010 steps), counted by `ArtEncodingTests`:

   | | Before | After |
   |---|---|---|
   | Encoder calls | 52,030 | 31,322 |
   | Bytes copied into the command buffer | 2.24 MB | 64 B |

   The calls left are a pipeline, a depth-stencil state and usually a reference per step, since stencil and cover steps alternate. **Still to do on a device:** take the `Frame` and `GPU frame` signposts while hovering and while drawing a stroke over the stress drawing, and decide from them whether culling (fix 3) or an art cache (fix 4) is still worth it.
4. **#3, paint-only changes keep their buffers (shipped).**

   What shipped: each layer's paints moved out of its vertex buffer into a paint buffer of their own, named by a new `ArtSegment.paintID` (one 256-byte slot per cover, as before, now from offset 0). When a layer's key differs from its cached one only in its shapes' paint (`VectorShape.hasSameGeometry(as:)`: fill, gradient and outline colors, gradient stops and points, opacity and a picture's `src`, but not whether a fill, gradient, outline or picture is there), `ArtBuilder` keeps the layer's id, vertices and steps, and paints its covers again from a list of which shape and which part each cover paints (`LayerBatch.covers`), taking a new paint id. The renderer then uploads the layer's paints (`ArtBatch.segmentsToRepaint`) and none of its triangles, in the editor and in the pool alike. A change that the art doesn't draw (a global colour link) keeps the paint id too. The pool picks the smallest free buffer that fits, and a `Pool fallback` signpost event marks each buffer it has to make. `ArtRepaintTests` checks that a repainted build equals a cold one for fills, outlines, fades under the ghost view, gradients baked into a stretch, clipping, text and pictures, that adding or removing a fill, gradient or outline still rebuilds, and lists `VectorShape`'s properties so a new one has to be placed on one side. "Art rebuild after one edit" and its two variants now move a shape instead of recolouring it, so they still time a rebuild; "Art repaint after one recolour, with upload" is the new row.

   Measured in this container against `main` before the change (release, full stress drawing, median of 15 runs of 20 calls, with glibc's mmap threshold fixed so its page faults don't swing the rows):

   | Workload | Before | After |
   |---|---|---|
   | Playback frame, every fill changes | 27 ms, 15.5 MB uploaded | 8.3 ms, 1.0 MB |
   | Playback frame, one layer fades | 1.3-1.7 ms, 393 KB | 1.1-1.3 ms, 25 KB |
   | Recolour one shape, with upload | 1.0-1.2 ms, 393 KB | 0.8-0.9 ms, 25 KB |
   | Playback frame, every layer slides (for scale) | 0.9-1.2 ms, 0 | 0.9-1.1 ms, 0 |

   A frame of one layer fading now costs what a slide does: the walk that copies every layer's steps into the batch, which is the floor of any frame that changes something. What is left of "every fill changes" is the scene's interpolation (about a fifth), that walk, and writing 4,000 paints. A layer whose geometry changes now takes two buffers, its vertices and its paints, so a preview that rebuilds many layers per frame (a tracking tween on every layer) takes twice the pool slots; the `Pool fallback` events will show on a device whether the pool needs to grow.
5. **#9, #10, #12, edits that touch many keyframes or shapes (shipped).**

   What shipped:
   - **#9:** `SceneDiff` diffs layer by layer, and `Timeline` keeps the last diff's changes for each layer with the two layers they came from (`SceneDiff.Memo`). A layer's changes depend only on its two states, so the next commit takes them for every layer that is the same on both sides (an `==` that is cheap when the storage is shared) and diffs only the layers the commit changed. The output is the same as a fresh diff, change for change (`testAMemoizedDiffEqualsAFreshOne`, `testRepeatedCommitsAtAKeyframeStoreTheFreshDiff`). The diff also builds its result in one array instead of four, and `record` looks for name and hint changes only in the layers the edit changed, since every state has the same names and hints.
   - **#10:** prune filters each `order` change against the children of its own parent, found through the shared `SceneLookup`, instead of a set of every id in the scene. It also keeps the children the keyframe itself creates: before, prune dropped them from the order, so deleting something before a keyframe that both created a shape and reordered its layer put the new shape in the wrong place (`testPruningKeepsTheOrderOfShapesAKeyframeCreates`).
   - **#12:** `ShapeIndex` keeps each layer's entries with the layer they were made from, and a rebuild from a stale index takes them for every layer that didn't change, so only the changed layers are baked to the world and measured again. An entry's shape, bounds and clip sit in a shared box, so keeping 2,400 entries costs a retain each. `testRebuildKeepingLayersMatchesAColdBuild` checks a kept index against a cold one after moves, hides, transforms, clips, added, deleted and reordered layers, and an erase.

   Measured in this container against `main` before the change (release, full stress drawing, two runs, per call). The container ran slower than when the hotspots were measured (15.5 ms and 73 ms then):

   | Workload | Before | After |
   |---|---|---|
   | Nudge at a keyframe that keys every shape | 19-20 ms | 1.5-2 ms |
   | Delete and undo at keyframe 1, keyframes reorder | 89-98 ms | 3.5-5 ms |
   | First hover after a nudge (new) | 3.4-3.5 ms | 1.1-1.3 ms |
   | The same, every layer transformed (new) | 7.0-7.3 ms | 1.1-1.6 ms |
   | Color picker tick, everything selected, keyframe 10 | 35-39 ms | 30-34 ms |

   A colour tick on everything changes every layer, so it still diffs all of them; that and a whole-selection nudge are the commit's own work now (`assignVertexIDs` and the diff of each changed shape). What is left of the first hover is the nudge itself and the index's grid, which is rebuilt over every entry.
6. **#13 and #16 (shipped).**

   What shipped:
   - **#13:** the profile's guess was off: a held text already moved its laid-out glyphs (`TextLayout.adjusted`), and laying out, outlining and tessellating the 40 texts cost about 3 ms of the frame. The rest was their layers: a text whose points changed rebuilt its whole layer, every frame, and the layer's vertices were uploaded again. Now `LayerKey.change(to:)` sorts a layer's change in one walk into nothing, paint alone (`repaint`, as before) or points too, and for points `ArtBuilder.patch` keeps the layer's steps and writes the reshaped shapes' triangles over their old ones, in place, when each has as many vertices as before (`VectorShape.hasSameSteps(as:)` decides that the steps stay; each shape's vertex ranges are kept in `LayerBatch.shapeVertices`). When the same shapes are reshaped a second time in a row, as on every frame of a transition, the layer is built once more with them in chunks of their own (`LayerBatch.chunks`, one `ArtSegment` each), so later frames copy and upload only those chunks. A clipped shape (whose bounds decide its base's clip clear) or a new vertex count builds the layer, as before. A tweened text's fan comes from each glyph's outlines flattened once at the held metrics and moved where the frame puts the glyph (`TextShaping.flattenedOutline`), so with CoreText a frame flattens no curves. The same patch serves a morph whose flattening keeps its vertex count. `ArtPatchTests` checks that the warm builds draw what cold ones do, frame by frame, under a live drag too, and what each frame uploads.
   - **Segments stand alone:** `ArtBatch.append` used to merge one layer's closing `moving(false)` with the next one's opening `moving(true)`, from before the encoder walked segments; the encoder starts every segment with `moving` off, so a drag of shapes in two neighbouring layers drew the second layer's first moved shapes unmoved. The merge is gone.
   - **#16:** copying keeps the copied art as a `DrawingEditor.Clipboard` (a drawing, about 1 ms for everything) and puts an `NSItemProvider` on the pasteboard that writes its JSON only when something reads it, off the main thread. A paste while the pasteboard still holds the app's own copy (same `changeCount`) pastes the art as it is, with no JSON written or read; another app's copy, or the app's own after a relaunch, is read on a background task and then pasted. Pasting the copy itself and pasting its JSON give the same document (`testPastingACopyEqualsPastingItsText`). Writing and reading the JSON also got faster, which saving and opening share: the writer checks whether a value can go on one line before writing it and stops once the line runs over (it wrote every candidate whole and counted its characters; `testOneLineValuesBreakWhereTheyDid` checks it breaks where it did), and claiming ids builds the error path only for an error.

   Measured in this container against `main` before the change (release, full stress drawing, median per call):

   | Workload | Before | After |
   |---|---|---|
   | Playback frame, a text per layer tweens tracking | 33 ms | 14 ms |
   | Copy everything, on the main thread | 416 ms | 1.1 ms |
   | Paste everything copied in the app, and undo | 386 ms | 19 ms |
   | Copy everything, as file JSON (off the main thread) | 416 ms | 306 ms |
   | Paste everything: read its JSON (off the main thread) | 326 ms | 232 ms |
   | Save: encode and format | 469 ms | 336 ms |
   | Open: parse and decode | 335 ms | 223 ms |

   What is left of a tracking-tween frame is the scene's interpolation (about 3.5 ms: every shape of a layer whose text changed is copied into the frame's drawing), the per-layer key compare and the texts' own layout and outline (about 1 ms). On a device the remaining question is CoreText's cost, below.

## On-device follow-up

Round 1's signposts cover most of this. The new questions for an Instruments pass (Time Profiler plus Metal System Trace) are:

- **How much CPU `drawArt` encoding takes per frame** on the stress drawing while hovering and while drawing a stroke. This decides how far #1 goes.
- **The GPU time** of 8k stencil-and-cover draws at 4× MSAA on a 12.9" screen.
- **Pool fallbacks (#3):** the `Pool fallback` events during a preview that rebuilds many layers per frame. A fade no longer re-uploads its triangles.
- **CoreText cost of a tracking tween (#13):** a frame now lays out and outlines each tweened text (an adjusted layout, no shaping) and flattens nothing; check with the `Frame` signpost that a tween of a few real texts stays well inside the frame.
- **Whether typing hands off per keystroke (#14).**
