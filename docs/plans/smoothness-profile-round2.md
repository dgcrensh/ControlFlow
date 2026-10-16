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
4. **#3 (M):** paint-only changes keep their buffers.
5. **#9, #10, #12 (M):** incremental diff, prune and shape index for edits that touch many keyframes or shapes.
6. **#13 and #16 (M).**

## On-device follow-up

Round 1's signposts cover most of this. The new questions for an Instruments pass (Time Profiler plus Metal System Trace) are:

- **How much CPU `drawArt` encoding takes per frame** on the stress drawing while hovering and while drawing a stroke. This decides how far #1 goes.
- **The GPU time** of 8k stencil-and-cover draws at 4× MSAA on a 12.9" screen.
- **The cost of a fade transition's re-uploads (#3)**, and pool fallbacks.
- **CoreText cost of a tracking tween (#13).**
- **Whether typing hands off per keystroke (#14).**
