# Performance audit

Reviewed from the code on 2026-10-11: `main` (`37780ec`) with the open PRs #15 (layers panel tree and
stack), #16 (Select menu and breadcrumbs) and #17 (clipped groups, behind-owner shapes) stacked on it,
which is commit `67b05b8` on `claude/project-thread-fzun4v`. Line numbers below are from that tree.
Nothing was profiled on a device or in the Simulator; every cost here is reasoned from the code, and the
first recommendation is to measure before fixing. Findings-and-recommendations only, no changes made.

Effort: S small (hours), M medium (a day or two), L large.

## Summary

The architecture is sound: the Metal canvas renders only when something changed, the display link pauses
when idle, the art is tessellated once per shape and cached, navigation never re-tessellates, the live
stroke is a cheap capsule strip, and SwiftUI is kept out of the per-touch path. For a character of a few
hundred shapes everything below is probably invisible on an M-series iPad. The problems show up as the
drawing grows (an SVG import of a few thousand shapes, or long sessions) and all share one cause: **most
geometry queries are recomputed from the Bézier paths on every call, and several of them run on every
frame or every touch sample.**

| # | Finding | Where | When it hurts | Effort |
| --- | --- | --- | --- | --- |
| 1 | Hit-testing flattens every path twice, on every hover frame, tap and eraser sample (partly shipped) | `Drawing.swift:71-85`, `444-452` | Hovering, erasing, select taps on large drawings | S |
| 2 | A drag rebuilds the whole drawing and re-uploads every vertex per sample (shipped) | `DrawingEditor.swift:437-441`, `ArtBatch.swift:155-179`, `CanvasRenderer.swift:282-302` | Moving a part with many shapes | M |
| 3 | Clip-base lookups are O(n) per shape, so a part's art pass is O(n²) (shipped; smaller than estimated) | `Drawing.swift:168-193`, `ArtBatch.swift:189-219` | Parts with hundreds of shapes, worse with clipping (#17) | S |
| 4 | `refresh()` recomputes ~90 derived values, several O(all shapes), after every edit and every color-picker tick (shipped) | `CanvasStore.swift:221-331` | Picker drags, layers panel open | M |
| 5 | Overlay re-flattens the selection, hover target and (in outline view) every shape each frame (shipped) | `EditorOverlay.swift:62-64`, `114-128`, `206-208`, `262-283` | Outline view, large selections | S-M |
| 6 | Three fresh `MTLBuffer`s per frame and a full vertex re-upload per art rebuild (shipped) | `CanvasRenderer.swift:301`, `397-406` | Every frame while drawing or editing | S |
| 7 | Undo history is unbounded and holds whole-drawing snapshots (shipped) | `UndoStack.swift:6`, `DrawingEditor.swift:1541` | Long sessions, memory | S |
| 8 | Full-screen stencil passes per clip base and group; 4x MSAA everywhere (clip clears shipped; MSAA unmeasured) | `ArtBatch.swift:199-203`, `243`; `CanvasRenderer.swift:75` | Many clipped shapes, fill-rate on 12.9" at 2x | M |
| 9 | Document hand-off and thumbnail re-render on every finished change, including picker ticks (shipped) | `CanvasStore.swift:187-197`, `CharacterDocument.swift:28-31` | Autosave churn, I/O | S |
| 10 | No benchmarks or signposts, so none of this is measured (shipped: see below) | `Packages/ControlFlowCore/Tests` | Now | S |

Suggested order: 10 first (so the rest can be checked), then 1, 3, 6, 7 as quick wins, then 2 and 4,
then 5, 8, 9. 10 shipped first; the quick wins 1 (its cheap half), 3, 6 and 7 shipped next, on top of
it, with before and after numbers under "Measuring performance". 2 and 4 followed, and found what
really dominated art rebuilds and the outline view: a `reserveCapacity` call that made appending
vertices quadratic (see finding 2). 5, 8 and 9 came last; the biggest find there was direct select
looking up the whole selection once per selected shape (see finding 5).

## What already works well

Worth keeping in mind so fixes don't undo it.

- `MetalCanvasView` only renders when `needsRender` is set and pauses the `CADisplayLink` when idle
  (`MetalCanvasView.swift:97-118`). Touch moves, hovers and store changes set the flag; nothing polls.
- The art pass is rebuilt only when `revision`, the zoom bucket, isolation or ghost focus changed
  (`CanvasRenderer.swift:288-290`). Pan and zoom within a power-of-two bucket are free.
- `ArtBuilder` caches each shape's fan and outline triangles by id and compares the stored shape with
  the current one (`ArtBatch.swift:223-239`); unchanged shapes share array storage with the previous
  drawing, so that comparison takes the identical-buffer fast path and costs nothing.
- Coalesced and predicted touches go into the live stroke, which is a capsule strip with
  anti-aliasing in the fragment shader (`CapsuleTessellator.swift`, `ShaderSource.swift:38-75`), so
  the ink under the nib never waits on curve fitting.
- `CanvasSession` and `DrawingEditor` are value types mutated in place; SwiftUI sees only
  `EditorUIState`, and only after a gesture ends (`CanvasStore.swift:131-134`).
- `Drawing` snapshots for undo are copy-on-write, so an undo step costs only the parts it touched.
- Reference images are decoded once, uploaded once with mipmaps, and cached by id.

## Findings

### 1. Hit-testing flattens every path twice, on every hover frame, tap and eraser sample (S)

`VectorShape.contains` (`Drawing.swift:71-85`) starts with `bounds.outset(by:).contains(p)`, but
`bounds` is `path.bounds()`, which flattens the whole path at 0.25 pt (`BezierPath.swift:253-255`).
So the "cheap" bounds reject is itself a full flatten of every shape in the drawing, and shapes that
pass are flattened again at 0.5 pt for the winding test. `Part.bounds` and `visibleArtBounds` do the
same for every shape they touch.

Callers on hot paths:

- `Drawing.hitTest` (`Drawing.swift:444-452`) runs for `hoverTarget` inside `EditorOverlay.vertices`
  (`EditorOverlay.swift:206`), which the renderer builds **every frame** while the Pencil hovers in
  the select, direct-select or eraser tool (`CanvasRenderer.swift:243`). Hover events arrive at up to
  120 Hz and each one sets `needsRender`.
- `eraseAlong` (`DrawingEditor.swift:1247-1263`) calls `contains` `steps + 1` times for every editable
  shape per move event; `steps` grows with the distance moved, so a fast swipe over a 2,000-shape
  drawing is tens of thousands of flattens per event.
- `marqueeTouches`, `cutTarget` (24 samples plus 20 golden-section steps per segment, for every
  segment of every shape, also every hover frame via `scissorsPreview`), `openEndpoint`, and
  `snapAnchors`.
- `Drawing.frame(of:)` for the selection is computed in `beginSelect`, in `pivot`, in the overlay each
  frame in the select tool (`EditorOverlay.swift:263`), and in `refresh()`.

Recommendations:

- Cache each shape's bounds. `VectorShape` is a value type with a `path`; either store `bounds` as a
  field kept up to date by the few mutators (`apply`, the direct-select edits go through
  `drawing.parts[p].shapes[s].path = ...`, so a `didSet` on `path` works), or compute bounds from the
  control polygon (anchors plus handles) for the reject test, which needs no flattening and is
  conservative. The control-polygon hull is the right bounds for the reject; keep the tight flattened
  bounds only for the selection frame.
- Give `Drawing` a cheap spatial index for hit-testing: even a flat array of `(ShapeRef, bounds)` in
  draw order, rebuilt when `revision` changes, turns a hover frame into a bounds scan with no path
  work. A uniform grid or a simple BVH is the next step if the scan itself shows up.
- Hit-test against the renderer's cached flattened polygon rather than re-flattening: `ArtBuilder`
  already holds `fan` and `outline` for every drawn shape at the current tolerance. Moving the
  tessellation cache into ControlFlowCore as a `DrawingGeometryCache` keyed by shape id, shared by the
  renderer, hit-testing, the overlay and the thumbnail, is the single change that removes the most
  repeated work. `recommendations.md` #3 (flatten at 0.5/zoom) folds into this.
- For the eraser, sample along the segment against bounds first, then test only the candidates, and
  stop at the first hit per shape (it already breaks, but after flattening).

Shipped (2026-10-11), the cheap half: `BezierPath.controlBounds` (the anchors and handle control
points, which contain the curve) and `VectorShape.hitBounds` (that plus the outline's reach) reject
points without flattening, so `contains` flattens only shapes the point is near, once.
`VectorShape.containsAny(of:tolerance:)` flattens once for all of an eraser move's samples, and
`eraseAlong` first drops shapes whose `hitBounds` miss the swept segment. `cutTarget` and the
marquee reject by the same bounds. The tight `bounds` is unchanged for selection frames. Still open:
the shared geometry cache and spatial index, and `Drawing.frame(of:)` and `visibleArtBounds`, which
still flatten.

### 2. A drag rebuilds the whole drawing and re-uploads every vertex per sample (M)

`pencilMoved` for a transform does `drawing = before.applying(transform, to: target)`
(`DrawingEditor.swift:437-441`) on every move sample. That:

- Copies the selection's parts (copy-on-write makes the rest free) and applies the affine to every
  anchor and handle of every selected shape, and to gradients and stroke widths.
- Bumps `revision`, so the next frame runs `ArtBuilder.build` over **every** part
  (`ArtBatch.swift:155-179`): the moved shapes are flattened and stroked again (`Stroker.triangles` is
  the expensive part: joins, caps, dashes), and the unchanged shapes' cached triangles are copied into
  a brand-new `[Float]` vertex array (`ArtBatch.add`, `ArtBatch.swift:346-354`) and re-uploaded in a
  new `MTLBuffer` (`CanvasRenderer.swift:301`).
- `cache.filter { live.contains($0.key) }` rebuilds the cache dictionary every build
  (`ArtBatch.swift:177`).

Dragging a whole character (`Cmd-A`, then move) therefore re-tessellates the entire drawing at 120 Hz.
This is `recommendations.md` #14 and it is still open.

Recommendations:

- Keep the drawing untouched during a transform drag and carry the in-progress affine separately
  (`DrawingEditor.liveTransform: (Selection, Affine2D)?`). The renderer applies it in the vertex
  shader for the moved shapes (a per-draw `float3x3` uniform, or a second `worldToClip`) and the
  overlay transforms the frame corners. Commit the transform into the drawing once at lift, which is
  one rebuild. Hit-testing during the drag is not needed. Snapping still works off `before`.
  Direct-select anchor and handle drags change the path itself and keep re-tessellating, but only the
  one shape, which is fine.
- Make `ArtBatch` incremental: give each cached tessellation a stable slot in a persistent vertex
  buffer and only copy ranges for shapes whose geometry changed. Simpler first step: when
  `build` finds every shape cached, reuse the previous `vertices` array and only rebuild `steps`.
- Keep the dictionary and remove dead ids with `cache.removeValue` for `cache.keys` not in `live`
  rather than filtering into a new dictionary.
- The wiggle preview (`CanvasRenderer.swift:297`, `DrawingEditor+Bones.swift:473-486`) rotates the
  wiggling parts' shapes on the CPU every frame and re-tessellates them. The same live-transform
  uniform makes the wiggle free.

Shipped (2026-10-11):

- The cause of slow rebuilds was none of the above. `ArtBatch.add` called
  `vertices.reserveCapacity(vertices.count + n)` before each shape's triangles, and `reserveCapacity`
  allocates exactly what it is asked for, so every shape copied the whole vertex array built so far:
  about 4 M floats, copied 8,000 times per build. `CapsuleTessellator.append` did the same into the
  overlay's array, which is the "unexplained" 12 s outline view. Both now grow geometrically
  (`Array.reserveAdditional`), and a warm rebuild of the full stress drawing went from 0.83 s to
  0.011 s, a cold one from 0.91 s to 0.07 s, and the outline-view overlay from 12 s to 0.02 s
  (finding 5's re-flattening remains, but is now small).
- `DrawingEditor.liveTransform` (`LiveTransform`) describes a select-tool drag that moves shapes: the
  drawing as the drag began, the ids of the shapes it moves (a part brings its accessories) and the
  affine from there to now. `ArtBuilder.build(_:...moving:)` brackets those shapes' steps with
  `ArtStep.moving(true/false)`, and the renderer builds the starting drawing once per drag and then
  draws the bracketed steps with `worldToClip × transform`, so a drag re-tessellates and re-uploads
  nothing until the Pencil lifts, which is one rebuild. The fragment shader still sees the untransformed
  point, which is what the untransformed gradient expects. `movesTessellation` limits this to
  similarities (move, rotate, uniform scale, mirror) that enlarge by at most 2x, where it is exact
  because outline widths and dashes scale by the same factor (`VectorShape.apply`); stretches, and
  bigger enlargements whose flattening would show, rebuild per sample as before, now cheaply. The
  editor still applies the transform to `drawing` on every sample, so the overlay, snapping and
  everything else that reads the drawing are unchanged. A test plays the bracketed batch through the
  stencil simulator and checks it paints what the transformed drawing does, clipping included.
- The cache drops dead ids in place instead of filtering into a new dictionary.

Still open: the wiggle preview still re-tessellates the wiggling parts every frame (the same
`.moving` steps could carry it, with one transform per part), and an incremental vertex buffer
is no longer worth it at these costs.

### 3. Clip-base lookups are O(n) per shape, so a part's art pass is O(n²) (S)

For every shape it appends, `ArtBuilder.appendShapes` (`ArtBatch.swift:189-219`) calls
`part.groupClipBase(of:)`, `part.clipBase(of:)` and `part.isClipBase(index)`, and `isClipBase` calls
both again for the next index. Each is a linear scan down the shape array (`Drawing.swift:168-193`),
and `clipBase(ofGroup:)` adds a `firstIndex` scan for the group's first member. For a part of n
shapes that is on the order of 5n² index checks per rebuild, so 500 shapes in one part is roughly a
million `isClipping` calls per frame during a drag, before any tessellation. `Part.shape(_:contains:)`
(`Drawing.swift:223-229`) does the same two lookups per hit-test candidate, and `ThumbnailRenderer`
(`ThumbnailRenderer.swift:57`) per shape per save. PR #17 added the group variants and doubled the
constant.

Correction after measuring: the cost is smaller than this says. `clipBase(of:)` returns at once for
an unclipped shape, and `lastIndex` searches backwards from the shape, so it stops at the nearest
unclipped shape below; only the group variant's `firstIndex` scans from the bottom of the part. The
one-pass plan below shipped anyway (it is simpler to reason about and #17's group variants build on
it), but `testArtBuildWarmOnePart` (the whole stress drawing in one part, every third shape clipped)
measures the same before and after, 0.857 s and 0.854 s.

Recommendation: compute clip bases for a whole part in one forward pass. Walk the shapes once,
tracking "last unclipped index" (and, inside a group, "last unclipped index since the group started"),
and emit `[Int?]` arrays `clipBase` and `groupClipBase` plus a `isClipBase` bit set. Expose it as
`Part.clipPlan()` and have `appendShapes`, `hitTest` and the thumbnail ask the plan. This also makes
the clip rules easier to test in one place.

Shipped (2026-10-11): `Part.clipPlan()` returns a `ClipPlan` (`base(of:)`, `isBase(_:)`) built in one
pass; `ArtBuilder.appendShapes`, `ThumbnailRenderer` and `SVGWriter` use it, and a test checks it
against `clipBase(of:)` for every clipping combination of a part with a group. `Part.shape(_:contains:)`
keeps the single lookup, since hit-testing asks only about the shapes under the point. PR #17's
`groupClipBase` should join the plan when it lands.

### 4. `refresh()` recomputes ~90 derived values after every edit (M)

`CanvasStore.refresh()` (`CanvasStore.swift:221-331`) runs after every `edit {}` and every touch end.
Most of it is cheap flag copying, but several lines walk the whole drawing:

- `LayerTree(drawing:)` (line 309) rebuilds the entire panel model: per part, `groupRuns` is O(shapes
  × groups) (`Drawing.swift:203-207` calls `members(ofGroup:)` per group), plus `adjoins`, the
  accessory grouping (`layers.filter` per owner, O(parts²)) and the bone tree. The panel then
  recomputes `treeRows(expanded:)` in `body` on every state change (`LayersPanel.swift:215`).
- `exportArea()` (line 308) → `visibleArtBounds` flattens every shown shape (finding 1).
- `selectionGeometry`, `selectionCrumbs`, `groupsToAddSelectionTo`, `canGroupSelection`,
  `canUngroupSelection`, `canArrange`, `selectedGroup`, `accessoryOwnerForSelection` each call
  `shapeIndices(in:)` or `shapeRefs(in:)`, which for `.shapes` is a full walk of all parts and shapes
  building a `Set` membership test per shape (`Drawing.swift:508-516`). That is maybe ten full walks
  per refresh.
- `hasHiddenArt`, `hasLockedArt`, `possibleParents` are also whole-drawing scans.

This runs on every tick of a color-picker drag (`setFill(continuous:)` goes through `edit`,
`CanvasStore.swift:602`), every reference-opacity slider step, every nudge key repeat, and every touch
end. With the layers panel open each refresh also diffs and re-renders a `List`.

Recommendations:

- Compute `shapeIndices(in: selection)` once per refresh and derive the selection-dependent flags
  from it, or memoize it inside `DrawingEditor` keyed on `(revision, selection)`.
- Split `refresh()` into tiers: what changes per command (undo flags, style, selection) versus what
  changes only when the drawing's structure changes (layers tree, bones, hidden/locked, export area),
  gated on `editor.revision` and the selection, so a picker drag updates the swatch and nothing else.
- `LayerTree` should be built lazily, only while the panel is shown, or at least only when `revision`
  changed since the last build. Inside it, build `groupRuns` in one pass over the shapes (group id →
  indices) instead of one `members(ofGroup:)` scan per group.
- The continuous-color path (`setFill`, `setOutline`, `setGlobalColor`) could skip the document
  hand-off and the layers rebuild until the picker ends (see finding 9).

Shipped (2026-10-11), measured with `testRefreshQueries` (the editor queries one refresh reads, with
the whole stress drawing selected):

- What the queries cost was mostly flattening: `selectionGeometry`, `Drawing.frame(of:)` and
  `exportArea()` all took `BezierPath.bounds()`, which flattened every path. `bounds()` is now exact
  and analytic (each segment's ends plus the roots of its derivative, skipping segments whose handles
  are already inside the box), so it needs no flattening and is tighter than before by up to the old
  0.25 pt tolerance. `bounds(tolerance:)` keeps the flattened version. One refresh's queries went from
  20 ms to 3.5 ms with everything selected; with one part selected they are well under 1 ms.
- `refresh()` reads the drawing-wide values (layers tree, bones, hidden and locked art, export area,
  palette, global colors, name, frame) only when `editor.revision` changed since it last read them,
  so selection, tool and view changes skip them.
- Fill and outline colors, outline width, opacity, gradient stops and global colors go through
  `CanvasStore.restyle`, whose `refreshStyle()` copies only what a style change can alter (undo flags,
  style, appearance, recent colors, palette, global colors), so a color-picker drag no longer reads
  the selection's flags or rebuilds the layers tree per tick.

Still open: the document hand-off per tick (finding 9), and `shapeIndices(in:)` is still walked about
fifteen times per full refresh for a multi-shape selection (about 0.08 ms each at full size, so not
worth a memo yet). The layers panel's own per-render work belongs to PR #15's tree.

### 5. Overlay re-flattens the selection and hover target every frame (S-M)

`EditorOverlay.vertices` (`EditorOverlay.swift`) is rebuilt and re-uploaded every frame
(`CanvasRenderer.swift:232-245`), which is right for handles and the marquee but not for the heavy
parts:

- Direct select flattens every selected shape at 0.5 px (`drawAnchors`, line 62-64), and the scissors
  tool outlines every selected shape (line 236). Select-all in direct select on a big part is a full
  re-flatten per frame.
- Outline view flattens **every** shown shape in the drawing every frame (lines 114-128), so in
  outline view every hover event re-tessellates the whole drawing on the CPU. It also skips the art
  cache entirely.
- `hoverTarget` (line 206, finding 1) and `scissorsPreview` (line 218, which runs `cutTarget` over
  every segment of every editable shape) run per frame while hovering.
- The bone layer calls `BoneMetrics.outline(of:zoom:)` per bone per frame; fine for a skeleton, listed
  for completeness.

Recommendations:

- Split the overlay into a slow layer (selection outlines, outline-view wireframe, bones) rebuilt
  when `(revision, selection, selectedAnchors, zoom bucket, tool, view options)` change, and a fast
  layer (handles, hover ring, marquee, pen rubber band) rebuilt per frame. Keep the slow layer's
  vertex buffer between frames.
- Draw the outline-view wireframe from the art cache's flattened polygons (the shared geometry cache
  from finding 1) instead of re-flattening.
- Compute `hoverTarget` and `scissorsPreview` once per hover event in `pencilHovered` and store the
  result on the editor, rather than per rendered frame; hover events are the only thing that changes
  them.

Shipped (2026-10-11), measured with new hover tests (20 hover frames over the middle of the full
stress drawing, overlay built for each):

- The worst case was not flattening. Direct select drew each selected shape's anchors after asking
  `editor.activeShape`, which walks the whole selection, so select all in direct select was quadratic:
  about 227 ms per frame at full size. The overlay now asks once per frame.
- `EditorOverlay.layers(for:...cache:)` returns four layers in drawing order: the outline view's
  wireframe, the guides (frame, symmetry, bones, hover feedback, a part's pivot), the selection's
  outlines and anchors (scissors, direct select), and the top (pen path, the select tool's frame and
  handles, the marquee). `OverlayCache` keeps the wireframe and selection layers and rebuilds each only
  when its key changes: the drawing's `revision` and the exact zoom, plus isolation, ghost focus and
  dark mode for the wireframe, and tool, selection and selected anchors for the selection. The wiggle
  preview's moving art is never kept. The renderer uploads the kept layers into one pinned pool buffer
  when the cache's `generation` changes and draws them between the per-frame layers, so a hover frame
  copies nothing large. `EditorOverlay.vertices` still returns everything in one array, and a test
  steps one cache through hover, selection, anchor, zoom, tool, view and undo changes and checks every
  frame against a fresh build.
- The scissors' hover outline and cut point come from one search (`DrawingEditor.hoverCut`) rather
  than two.
- Not done: the zoom key is exact, so a pinch still rebuilds the kept layers every frame (widths are
  baked into the capsules in world units; a zoom bucket would draw them too thick or thin until the
  next bucket). Hover results are not stored on the editor: frames are drawn when something changes,
  so per frame is already per hover event, and a stored result would go stale on undo or a keyboard
  command while hovering. The wireframe still flattens on its own rather than reading the art cache,
  which the outline view skips; a rebuild costs 16 ms at full size, which only edits and pinches pay.
  The scissors' cut search is still a pass over every editable shape (about 1.3 ms per frame).

### 6. Three fresh `MTLBuffer`s per frame and a full vertex re-upload per art rebuild (S)

`drawCapsules` allocates a new shared-storage `MTLBuffer` for the live stroke, the mirrored stroke
and the overlay on every frame (`CanvasRenderer.swift:397-406`), and `updateArt` allocates a new one
per art rebuild (line 301). `device.makeBuffer(bytes:)` is an allocation plus a copy each time, and the
old buffers are released while the GPU may still read them (Metal keeps them alive, but it means
churn through the allocator at 120 Hz). The live stroke is also re-tessellated from its first point
every frame (`CapsuleTessellator.vertices(for:)`, line 237), which `recommendations.md` #14 noted;
a 5-second stroke at 240 Hz Pencil sampling is about 1,200 points, 7,200 vertices, 86,000 floats
copied per frame.

Recommendations:

- Keep a small ring (three frames deep, matching `maximumDrawableCount` plus one) of reusable
  `MTLBuffer`s per stream (art, overlay, live stroke) grown on demand, and copy into them with
  `contents()` rather than `makeBuffer(bytes:)`. Use `setVertexBytes` for anything under 4 KB (the
  view rectangle and reference quads already do).
- Append to the live-stroke buffer: keep the committed prefix's vertices and only tessellate the new
  points plus the predicted tail each frame.
- Only upload the art buffer when `vertices` changed; with finding 2 done, a drag won't change it.

Shipped (2026-10-11): `VertexBufferPool` (`ControlFlow/Canvas/VertexBufferPool.swift`) keeps
up to 16 shared-storage buffers, grown in powers of two, and writes into one only when every frame
that used it has finished (a `FrameClock` counts committed frames and the command buffers'
completion handlers report the finished ones); with none free it falls back to a one-off buffer, so
it never blocks. The art buffer is pinned until the next rebuild. Capsule draws under 4 KB use
`setVertexBytes`. `LiveStrokeTessellator` (ControlFlowCore) keeps the committed points' segments
between frames and tessellates only the new points and the predicted tail; a test checks it matches
`CapsuleTessellator.vertices(for:)` as a stroke grows, with pressure, and when a quick shape replaces
the points. The art buffer is still uploaded on every rebuild (that waits on finding 2), and the
per-frame copy of the live stroke into its buffer remains. Since finding 2 a drag no longer rebuilds
or re-uploads the art; other edits still upload it once per rebuild.

### 7. Undo history is unbounded and holds whole-drawing snapshots (S)

`UndoStack` never trims `undoStates` (`UndoStack.swift:6-22`). Snapshots share storage, but any edit
that touches a part copies that part's `shapes` array, and a `Drawing` snapshot keeps the old copy
alive. A long session of edits to a big part accumulates one copy of that part per step. Direct-select
drags, erasing and shape drawing each commit one step, so hundreds of steps per hour is normal.
`commit` also runs a full `before != drawing` comparison and the group and accessory validators every
time (`DrawingEditor.swift:1533-1542`); the validators are O(groups × shapes) and O(parts) and fine,
but the equality on a large drawing is a full tree compare whenever the fast path (shared buffers)
doesn't apply, which is exactly the case after a real edit.

Recommendations:

- Cap the stack (100-200 steps; Procreate-style apps use 250) and drop the oldest.
- Skip the `before != drawing` compare when the caller already knows it changed (most do); keep it
  only for the restyle path where a no-op is common, or compare `revision` instead.

Shipped (2026-10-11): `UndoStack` keeps the newest `limit` steps (default 200) and drops the oldest,
on record and on redo. The compare stays: after a real edit it stops at the first difference, and
synthesized `==` on arrays takes the shared-buffer fast path for every untouched part, so it only
walks a whole drawing when nothing changed, which is the case it is there to catch. 500 commits
measure 0.011 s either way.

### 8. Full-screen stencil passes per clip base and group, and 4x MSAA everywhere (M)

Every clip base emits a `.stencilView(clearClip)` that draws a view-sized rectangle
(`ArtBatch.swift:243`), and every clipped group adds two more (`copyClipToMask`, `restoreClip`,
lines 199-203, 220). These are stencil-only, but at 4x MSAA on a 2732 × 2048 display they each touch
22 M samples. An eye with a white, iris and highlight clipped in a group is already three full-screen
passes; a character with thirty clipped shapes is thirty-plus. The cover rectangles for fills and
outlines are already bounded to the shape, which is right.

The second cost is fill rate in general: 4x MSAA for both the color and stencil attachments, and
every fill is drawn twice (stencil fan, then cover) with the cover being a bounds rectangle rather
than the fan, so a big background shape pays its area twice.

Recommendations:

- Bound the `clearClip` and mask passes to the union of the base's and its clipped shapes' bounds
  (the builder knows both) instead of the whole view. This is a change to `ArtStep.stencilView` to
  carry a rect; `drawArt` already draws a rect for it.
- Measure before touching MSAA. If GPU time shows up, the options are: 2x MSAA on the stencil-only
  passes is not possible (attachments must match), but the whole pass could drop to 2x on the
  12.9-inch at 2x scale with little visible loss on thin outlines, or the cover could be drawn as the
  fan itself (no stencil, one pass) for convex-or-simple shapes detected at tessellation time.
- Reuse `PaintUniforms` for solid colors: it is 48 floats per cover step set with `setFragmentBytes`
  (`CanvasRenderer.swift:332-335`), which is fine, but note that it is rebuilt per step rather than
  stored in the batch.

Shipped (2026-10-11), on the tree without PR #17, which has no clipped groups yet, so only the
clip base's clear existed:

- A clip base clears the clip bit with a `stencil` step over a rectangle instead of `stencilView`:
  the union of the cover rectangles of the shapes it clips, which are the only places those shapes
  test the bit. No other shape reads the clip bit, so a stale bit outside the rectangle is harmless,
  and a base with nothing clipped shown clears nothing. While a live transform moves the base or one
  of its clipped shapes the clear stays full-view, since one rectangle can't follow both. Tests
  check the rectangle and play overlapping bases through the stencil simulator; the existing
  "clip starts over for each base" test covers a stale bit under a later base's clipped shape.
  PR #17's `copyClipToMask` and `restoreClip` should get the same treatment when it lands.
- MSAA and the double-drawn covers are untouched: GPU time can't be measured off a device, and
  nothing here shows fill rate is a problem. Record a Metal System Trace on a 12.9-inch iPad first.

### 9. Document hand-off and thumbnail re-render on every finished change (S)

`updateDocument()` (`CanvasStore.swift:187-197`) builds a `CharacterPackage` and hands it to the
SwiftUI document binding after every refresh whose `revision` changed, which includes every tick of a
continuous color change. Each hand-off marks the document dirty; the system coalesces autosaves, but
every save runs `fileWrapper(configuration:)` (`CharacterDocument.swift:28-31`), which encodes the
whole drawing to JSON (`CharacterFormat.encode`, then `JSONValue.formatted()` with its inline-width
probing) and renders a 512 px thumbnail through `ThumbnailRenderer`, which strokes every outline
with the full `Stroker` (`ThumbnailRenderer.swift:109`) and computes clip bases per shape (finding 3).
Also, `sentDocuments.contains(package)` (line 203) and `package != document` compare whole packages,
including the reference images' `Data`, every time the document binding changes.

Recommendations:

- Debounce the hand-off: don't call `onDocumentChange` while a coalescing key is active (a picker
  drag), only when the run ends or after a short delay.
- Render the thumbnail at a coarse tolerance (it is 512 px; `0.5 / k` is already scaled but the
  stroker still builds round joins at full fidelity) or from the art cache's polygons, and consider
  skipping it when the drawing hasn't changed since the last thumbnail.
- Compare `sentDocuments` by drawing identity (a revision tag stored in the package) rather than by
  value.

Shipped (2026-10-11):

- `DocumentHandOff` (ControlFlowCore) decides when `CanvasStore` hands the drawing to the document.
  Restyles (`refreshStyle`: colors, outline width, opacity, gradients, global colors) are held until
  `quietPeriod` (0.5 s) passes without another, then handed off once; any other finished change hands
  off at once, with whatever was held. The store flushes a held change when the document's view goes
  away or the scene leaves the foreground. A two-second picker drag at 60 ticks a second went from 120
  hand-offs (and as many chances for an autosave) to one, which the tests check.
- `ThumbnailRenderer.png` keeps the last thumbnail and the drawing it came from, and reuses it when a
  save finds the same art (a reference image or name change, a save on close). It flattens and strokes
  at one thumbnail pixel instead of half of one, and builds each clip base's mask once instead of once
  per clipped shape. None of this can run on Linux, so it has no benchmark.
- `sentDocuments` still compares by value: equality of a package the editor sent returns at the first
  array whose storage is shared, so it is a few pointer checks, and the tag would have to be kept out
  of the package's `==`.

### 10. Nothing is measured (S): shipped

Done on 2026-10-11, on top of `main` (so before #15-#17 landed):

- `PerformanceTests` in `ControlFlowCoreTests` times, on a generated `StressDrawing`:
  `ArtBuilder.build` cold and warm, `Drawing.hitTest` miss and hit (20 calls each), an eraser
  stroke of 20 samples diagonally across the character, `LayerTree(drawing:)` (10 calls),
  `CharacterFormat.encode` plus `formatted()`, `EditorOverlay.vertices` in outline view with a part
  selected, and 500 separate fill changes on the undo stack. `testStressDrawingIsValid` checks the
  drawing itself. The tests have no baselines, so they never fail on speed; CI runs them as part of
  the core tests and prints the numbers in its log.
- `StressDrawing` is deterministic (its own seeded generator): a grid of parts of 24-anchor closed
  smooth shapes with fills, two in three outlined, one in ten of those dashed, a clipped group (a
  base and two clipped shapes) in every fourth part, and every tenth part an accessory of the one
  before it. Behind-owner shapes come with PR #17 and can be added to it then.
- By default it is a quarter of the audit's size (10 parts × 15 shapes) so the debug `swift test`
  on every CI run stays quick (the suite takes about 20 s on a Mac). `STRESS_DRAWING=full` gives the full 40 ×
  60 × 24.
- Instead of a stress document in `Schema/examples/`, the generator is the repeatable source: the
  full drawing would be several megabytes of JSON, and the schema check and the byte-for-byte test
  would have to carry it.
- The app has `os_signpost` intervals (`ControlFlow/Canvas/Signposts.swift`, Points of Interest
  category): `Frame` around `CanvasRenderer.render`, `Art rebuild`, `Overlay build` and `Encode`
  inside it, and `Refresh` around `CanvasStore.refresh`. More were added later; see "Signposts" below.

Still to do by hand on a device: record one Instruments trace (Metal System Trace plus Time
Profiler, which show the signposts in their Points of Interest track) of each of: drawing a long
stroke, dragging the whole character, erasing across it, hovering in the select tool, a
color-picker drag with the layers panel open.

#### Measuring performance

```sh
# Quarter size, debug, as CI runs it
swift test --package-path Packages/ControlFlowCore --filter PerformanceTests
# Full size, optimized: closer to the app
STRESS_DRAWING=full swift test -c release --package-path Packages/ControlFlowCore --filter PerformanceTests
```

Each test logs `measured [Time, seconds] average: ...` over 10 runs. Compare the averages before
and after a change on the same machine; a single run's relative standard deviation is often 10-40%.

First numbers, full size, `-c release`, on the Mac this was written on (an M-series laptop, not an
iPad), average seconds per `measure` run:

| Test | Seconds | Per operation |
| --- | --- | --- |
| `testArtBuildCold` | 0.965 | |
| `testArtBuildWarm` | 0.844 | the cache saves only ~13% (findings 3 and 6) |
| `testHitTestMiss` (20 calls) | 0.195 | ~10 ms per hover frame off the art (finding 1) |
| `testHitTestHit` (20 calls) | 0.099 | ~5 ms per tap |
| `testEraseAlongDiagonal` (20 samples) | 2.694 | ~135 ms per eraser sample (finding 1) |
| `testLayerTree` (10 calls) | < 0.001 | |
| `testEncodeAndFormat` | 0.159 | |
| `testOverlayInOutlineView` | 11.912 | far beyond the flattening cost finding 5 describes; profile it first |
| `testUndoGrowthOver500Commits` | 0.011 | time only; XCTest can't measure memory on Linux |

After findings 1, 3, 6 and 7, same machine, same settings:

| Test | Before | After |
| --- | --- | --- |
| `testArtBuildCold` | 0.970 | 0.956 |
| `testArtBuildWarm` | 0.852 | 0.823 |
| `testArtBuildWarmOnePart` (new) | 0.857 | 0.854 |
| `testHitTestMiss` (20 calls) | 0.186 | 0.010 (~0.5 ms per hover frame) |
| `testHitTestHit` (20 calls) | 0.098 | 0.007 |
| `testEraseAlongDiagonal` (20 samples) | 2.686 | 0.015 (~0.75 ms per eraser sample) |
| `testLiveStrokeFullEveryFrame` / `Incremental` (new, 600 frames) | 0.006 | 0.002 |
| `testEncodeAndFormat` | 0.164 | 0.159 |
| `testOverlayInOutlineView` | 13.357 | 12.086 (noise; finding 5) |
| `testUndoGrowthOver500Commits` | 0.011 | 0.011 |

The live-stroke pair times the old per-frame full tessellation against the incremental one on the
same 1,200-point stroke, so its "before" is `testLiveStrokeFullEveryFrame`. The GPU-side half of
finding 6 (no buffer allocation per frame) can't be measured here; check it in Metal System Trace.
Art rebuilds are unchanged: what dominates them is still unknown and belongs with finding 2. (It was
quadratic vertex appends; see finding 2 and the next table.)

After findings 2 and 4 (on top of the table above), same machine and settings. The "before" for
the new tests is PR #19's code with the new test file:

| Test | Before | After |
| --- | --- | --- |
| `testArtBuildCold` | 0.914 | 0.070 |
| `testArtBuildWarm` | 0.832 | 0.011 |
| `testArtBuildWarmOnePart` | 0.813 | 0.011 |
| `testDragRebuildingEverySample` (new: select all, 20-sample drag, a build per sample) | 19.030 | 1.236 |
| `testDragWithLiveTransform` (new: the same drag as the renderer now draws it) | | 0.110 |
| `testRefreshQueries` (new: 10 refreshes' editor queries, everything selected) | 0.202 | 0.035 |
| `testOverlayInOutlineView` | 12.015 | 0.018 |
| `testEncodeAndFormat` | 0.157 | 0.158 |
| `testEraseAlongDiagonal` | 0.015 | 0.015 |
| `testHitTestMiss` / `testHitTestHit` | 0.006 / 0.007 | 0.010 / 0.007 |
| `testUndoGrowthOver500Commits` | 0.008 | 0.012 |

So a select-all drag of the full stress drawing went from about 0.9 s per sample to about 1 ms of
editor work per sample and no art work, plus one 55 ms rebuild when the Pencil lifts. The hit-test
and undo rows are within run-to-run noise.

After findings 5, 8 and 9 (on top of the table above), same machine and settings. The new hover
tests time 20 hover frames each; their "before" is PR #20's code with the new tests:

| Test | Before | After |
| --- | --- | --- |
| `testOverlayHoverDirectSelectAll` (new: everything selected in direct select) | 4.549 | 0.008 |
| `testOverlayHoverInOutlineView` (new) | 0.245 | 0.008 |
| `testOverlayHoverScissors` (new: one part selected) | 0.055 | 0.027 |
| `testOverlayHoverSelect` (new: one part selected) | 0.007 | 0.007 |
| `testOverlayInOutlineView` (one frame that rebuilds the wireframe) | 0.016 | 0.016 |
| `testArtBuildCold` / `testArtBuildWarm` | 0.069 / 0.011 | 0.069 / 0.011 |
| `testArtBuildWarmOnePart` (a third of the shapes clipped) | 0.011 | 0.011 |
| `testEncodeAndFormat` | 0.157 | 0.158 |

So a hover frame in direct select with everything selected went from about 227 ms to 0.4 ms, and one
in the outline view from about 12 ms to 0.4 ms, which is the select tool's hit test. Rebuilding the
wireframe after an edit costs what a frame used to. The art rows (two runs each, side by side) show
the clip rectangles cost nothing measurable to build; they add six vertices per base. Finding 9's
gains are in hand-offs and saves, not in anything these tests time.

What they said before these fixes: a warm art rebuild costs nearly as much as a cold one at this size, so the
per-shape cache is not what dominates; the outline view's overlay is the worst case by an order of
magnitude and is not explained by this document yet; hit-testing and erasing are slow enough to
drop frames on a big drawing, as finding 1 predicts.

#### Signposts

Everything the app marks for Instruments, all in the Points of Interest track. Intervals nest, so a
`Touches ended` that commits a stroke shows the `Edit` and `Refresh` inside it.

| Signpost | Kind | Where | What it covers |
| --- | --- | --- | --- |
| `Render wait` | interval | `MetalCanvasView` | From the first request for a frame (a touch, hover or store change) to the display-link tick that draws it: input-to-render latency on the CPU side |
| `Missed frame deadline` | event | `MetalCanvasView` | A tick whose work ran past the display's next refresh (`targetTimestamp`) |
| `Touches began` / `Touches moved` / `Touches ended` | interval | `MetalCanvasView` | Each touch event's routing through `CanvasSession`. `moved` says the phase (`draw`, `navigate`, `edit`) and the coalesced sample count; `ended` includes the curve fit and commit on lift, and the refresh |
| `Hover` | interval | `MetalCanvasView` | One Pencil hover update, which hit-tests in the select tools |
| `Quick shape check` | interval | `MetalCanvasView` | One QuickShape poll (every 100 ms while drawing) |
| `Frame` | interval | `CanvasRenderer.render` | The whole CPU side of a frame |
| `Next drawable` | interval | `CanvasRenderer.render` | Waiting for a drawable; long ones mean the GPU or display holds both |
| `No drawable` | event | `CanvasRenderer.render` | A dropped frame, retried on the next tick |
| `GPU frame` | event | command buffer completion | The frame's GPU time in ms (`gpuEndTime - gpuStartTime`) |
| `Render targets` | event | `CanvasRenderer.ensureTargets` | The MSAA and stencil targets reallocated, with the size |
| `Art rebuild` | interval | `CanvasRenderer.updateArt` | Building the art; ends with why: `edit`, `refine` (a background refine merged; a warm build), `drag`, `wiggle` or `focus` |
| `Art refine` | interval | background task | The job that re-flattens shapes at a new zoom bucket, off the main thread, with the number of shapes it made |
| `Art merge` | interval | `CanvasRenderer.mergeRefinement` | Taking one of the job's results into the cache on the main thread |
| `Art upload` | interval | `CanvasRenderer.updateArt` | Copying the art's vertices to the GPU, with the float count |
| `Encode` / `Art draw` / `Live stroke` / `Overlay build` | interval | `CanvasRenderer.render` | Encoding the pass, the art's draw calls inside it, the live stroke's incremental tessellation, and the overlay |
| `Reference texture` / `Reference decode` | interval | `CanvasRenderer`, `CanvasStore` | First use of a reference image: decoding it, then uploading it with mipmaps |
| `Edit` | interval | `CanvasStore.edit` / `restyle` | The editor command itself (including undo and redo), before `Refresh` |
| `Refresh` / `Refresh style` | interval | `CanvasStore` | Copying editor state into the SwiftUI panels |
| `Hand off` / `Document changed` | interval | `CanvasStore` | Handing the drawing to the document, and taking in one changed elsewhere |
| `Save` / `Thumbnail` / `Open` | interval | `CharacterDocument`, `ThumbnailRenderer` | Autosave (off the main thread), its thumbnail render, and reading a document |
| `SVG import` / `SVG export` / `PNG export` | interval | `CanvasStore` | The import and export commands |

SwiftUI's own work (panel bodies, layout) has no signposts of ours; record it with the SwiftUI
template in Instruments.

#### How drawings scale

`ScalingTests` times each workload in `Workloads.swift` (the interactive operations: drawing,
navigating, rendering, editing and files) on stress drawings of several sizes and prints one table.
By default it uses 60, 120 and 240 shapes in debug, as CI runs it; with `STRESS_DRAWING=full` it
uses 300 to 4,800. The growth column is the exponent k in time ∝ shapes^k between the smallest and
largest size. The same workloads at the audit's size (2,400 shapes) are also `PerformanceTests`
(`testArtRebuildAfterOneEdit`, `testPencilStroke`, `testOpenDocument` and so on).

```sh
STRESS_DRAWING=full swift test -c release --package-path Packages/ControlFlowCore --filter ScalingTests
```

First numbers, on top of PR #21, `-c release`, same Mac as above, milliseconds per call, median of 9:

| Workload | 300 shapes | 600 | 1,200 | 2,400 | 4,800 | Growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Art rebuild after one edit | 1.77 | 2.12 | 3.79 | 7.15 | 15.8 | 0.79 |
| Art rebuild, new zoom bucket | 11.7 | 22.9 | 44.2 | 89.9 | 179.5 | 0.99 |
| Hover frame (select tool) | 0.059 | 0.095 | 0.117 | 0.203 | 0.338 | 0.63 |
| Pencil stroke, 240 samples and lift | 0.045 | 0.043 | 0.043 | 0.046 | 0.054 | 0.07 |
| Quick shape check, 1,200 points | 0.215 | 0.214 | 0.214 | 0.214 | 0.214 | 0.00 |
| Eraser sample | 0.044 | 0.100 | 0.224 | 0.400 | 0.914 | 1.09 |
| Drag sample, everything selected | 0.086 | 0.173 | 0.368 | 0.843 | 1.80 | 1.10 |
| Undo and redo | < 0.001 | < 0.001 | < 0.001 | < 0.001 | < 0.001 | |
| Two-finger navigation, 60 samples | 0.018 | 0.018 | 0.018 | 0.018 | 0.018 | 0.00 |
| Refresh queries, everything selected | 0.368 | 0.732 | 1.52 | 3.15 | 6.55 | 1.04 |
| Layer tree | 0.001 | 0.002 | 0.004 | 0.008 | 0.019 | |
| Save: encode and format | 19.2 | 38.3 | 76.9 | 153.4 | 307.1 | 1.00 |
| Open: parse and decode | 48.2 | 96.7 | 194.9 | 389.7 | 783.9 | 1.01 |
| SVG export | 6.72 | 13.9 | 28.1 | 57.4 | 118.5 | 1.04 |
| SVG import | 49.8 | 101.0 | 202.8 | 406.2 | 827.3 | 1.01 |

What they say (on a Mac; an iPad will be slower, so read them against a 120 Hz frame's 8.3 ms):

- Nothing is worse than linear any more. Drawing a stroke, QuickShape, navigation and undo don't
  depend on the drawing's size at all.
- A frame after any edit still walks every shape: one changed fill costs 7 ms at 2,400 shapes and
  16 ms at 4,800, close to or over a frame. Only one shape re-tessellates, so this is the warm
  rebuild's per-shape cost (cache checks and vertex appends); not profiled further here.
- A zoom that crosses a power-of-two bucket re-tessellates everything: 90 ms at 2,400 shapes, a
  visible hitch mid-pinch. The `Art rebuild` signpost's `zoom` reason shows it on a device.
- Per-sample editor work for erasing and select-all drags, and the refresh after an edit with
  everything selected, are linear and reach 1-7 ms at 2,400 shapes.
- Opening, saving and SVG import are linear and in the hundreds of milliseconds at 2,400 shapes;
  saves run off the main thread, but SVG import runs on it, inside one `Edit`.

The plan for these is [performance-plan.md](performance-plan.md). The numbers after all of its steps, and what
to do next, are in [performance-next.md](performance-next.md).

#### The slow rows, split (plan step 0)

Step 0 of the plan added workloads that split the two slow rows into their parts, plus rows for the
outline-view wireframe and the scissors, and `testArtUploadSize`, which logs what the art pass hands
the GPU. Same Mac, `-c release`, median of 9, on main with PRs #15 to #23 merged:

| Workload | 300 shapes | 600 | 1,200 | 2,400 | 4,800 | Growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Art rebuild after one edit | 0.988 | 1.96 | 3.85 | 7.67 | 15.8 | 1.00 |
| Art rebuild after one edit, no vertices | 0.168 | 0.305 | 0.533 | 1.01 | 2.26 | 0.94 |
| Outline view, overlay at a new zoom | 1.46 | 3.09 | 6.52 | 13.0 | 26.6 | 1.05 |
| Scissors hover | 0.905 | 0.935 | 0.385 | 1.17 | 1.04 | 0.05 |
| Open: parse and decode | 48.3 | 97.2 | 194.6 | 388.9 | 783.5 | 1.00 |
| Open: parse only | 32.9 | 66.7 | 133.4 | 269.3 | 541.9 | 1.01 |
| Open: decode only | 15.3 | 30.5 | 60.5 | 120.4 | 241.5 | 0.99 |

| Shapes | Art vertices | Uploaded after every rebuild | Steps |
| ---: | ---: | ---: | ---: |
| 300 | 254,826 | 1.9 MB | 1,002 |
| 600 | 505,380 | 3.9 MB | 2,003 |
| 1,200 | 998,268 | 7.6 MB | 4,005 |
| 2,400 | 1,992,051 | 15.2 MB | 8,010 |
| 4,800 | 3,970,341 | 30.3 MB | 16,020 |

What the split says:

- **Art rebuild after one edit is the vertex appends.** The walk alone (cache lookups, shape
  comparisons, clip plans, steps) is 1.0 ms of the 7.7 ms at 2,400 shapes; the other 87% is
  converting cached `Vec2`s to floats and appending them. Step 2 starts with its first bullet, as
  written. The walk is still linear, so it remains after step 2.1 only for the edited part.
- **The upload is larger than expected.** Every rebuild copies the whole batch to the GPU: 15 MB at
  2,400 shapes, 30 MB at 4,800, after every edit. That copy isn't timed here (it is app code), but
  at that size it is likely to show in the `Art upload` signpost on an iPad, so step 2.3 is more
  likely to be needed than the plan assumed. Check it on a device trace right after step 2.1.
- **Open is mostly parsing.** `JSONValue(parsing:)` is 69% of open (269 of 389 ms at 2,400 shapes),
  decoding 31%. Step 3 does number parsing (its first bullet) first.
- **The outline-view wireframe** costs 13 ms per pinch frame at 2,400 shapes, linear. Step 4 as
  planned.
- **Scissors hover doesn't grow with the drawing.** About 1 ms at every size, varying with what is
  under the hover point (the stress drawing's busy point lands on different shapes at each size).
  So the per-frame cost is `nearestSegment` on the few shapes near the point, not the bounds pass
  over every shape. Step 5's segment skip (its third bullet) matters more for the scissors than
  the grid; the grid still matters for `hitTest` and the eraser, which do scale.

#### Step 1: pinch refine

Same Mac, `-c release`, `STRESS_DRAWING=full`, median of 9, milliseconds. Before is step 0 (`a542905`), after is this branch; the runs for all five steps went back to back with nothing else running.

| Workload | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Art rebuild, new zoom bucket (before, on the main thread inside the frame) | 11.3 | 22.5 | 44.6 | 90.9 | 179.7 |
| Art rebuild, new zoom bucket (after, same work, now the background job) | 11.2 | 22.6 | 43.8 | 87.8 | 175.0 |
| Zoom-in refine, visible shapes (after, the job's first result) | 7.7 | 9.8 | 15.6 | 20.7 | 16.5 |

The full re-tessellation costs what it did, but it no longer runs in a frame: a pinch that crosses a
bucket keeps drawing the current art while the job runs, and the visible shapes come back in 8 to 21 ms
instead of the whole drawing in 90 to 180 ms. The main-thread merge and the warm build after it are app
code and aren't timed here; a device trace of a pinch is the real check (no `zoom` reason on `Art
rebuild`, `Art merge` about the cost of a warm build). Other rows are unchanged within noise.

#### Step 2: edit frame proportional to the edit

Same Mac, `-c release`, `STRESS_DRAWING=full`, median of 9, milliseconds. Before is step 0 (`a542905`), after is this branch; the runs for all five steps went back to back with nothing else running.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Art rebuild after one edit | before | 0.996 | 1.91 | 3.87 | 7.69 | 15.8 |
| | after | 0.288 | 0.462 | 0.861 | 1.62 | 3.22 |
| Art rebuild after one edit, no vertices | before | 0.168 | 0.261 | 0.477 | 1.01 | 2.26 |
| | after | 0.108 | 0.124 | 0.155 | 0.213 | 0.345 |
| Art rebuild after one edit, with upload (what the app does) | after | 0.152 | 0.169 | 0.203 | 0.278 | 0.434 |
| Art rebuild, new zoom bucket | before | 11.3 | 22.5 | 44.6 | 90.9 | 179.7 |
| | after | 9.05 | 18.2 | 36.0 | 72.6 | 144.3 |

| Shapes | Uploaded after one edit, before | After |
| ---: | ---: | ---: |
| 300 | 1.9 MB | 0.38 MB |
| 2,400 | 15.2 MB | 0.38 MB |
| 4,800 | 30.3 MB | 0.38 MB |

The app's path (no concatenated array, only the edited part's buffer made) is 0.28 ms at 2,400 shapes,
down from 7.7 ms plus a 15 MB upload, and grows slowly with the number of parts rather than shapes. The
"after one edit" row still concatenates every part's floats, so it stays linear; it is kept for
comparison with the older tables. Storing floats in the shape cache also took 20% off the new-bucket
rebuild. The per-part Metal buffers are app code; check the `Art upload` signpost on an iPad.

#### Step 3: open and import

Same Mac, `-c release`, `STRESS_DRAWING=full`, median of 9, milliseconds. Before is step 0 (`a542905`), after is this branch; the runs for all five steps went back to back with nothing else running.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Open: parse and decode | before | 48.1 | 96.2 | 193.5 | 386.5 | 769.7 |
| | after | 17.3 | 34.6 | 69.6 | 140.0 | 280.7 |
| Open: parse only | before | 32.2 | 65.1 | 131.3 | 263.5 | 532.5 |
| | after | 7.9 | 15.9 | 31.9 | 64.1 | 128.6 |
| Open: decode only | before | 15.1 | 29.9 | 59.6 | 119.0 | 236.6 |
| | after | 9.3 | 18.8 | 37.9 | 75.7 | 151.4 |
| SVG import | before | 49.3 | 99.6 | 202.8 | 404.1 | 820.8 |
| | after | 2.77 | 5.55 | 11.1 | 22.2 | 45.4 |

Open is 2.8x faster (parsing 4.1x, decoding 1.6x) and misses the plan's 100 ms target at 2,400 shapes:
decoding is now the larger half, at 76 ms. SVG import is 18x faster, most of it from `XMLReader` no
longer building arrays per tag, and it now runs off the main thread as well.

#### Step 4: outline-view pinch

Same Mac, `-c release`, `STRESS_DRAWING=full`, median of 9, milliseconds. Before is step 0 (`a542905`), after is this branch; the runs for all five steps went back to back with nothing else running.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Outline view, overlay at a new zoom (inside a bucket) | before | 1.45 | 3.09 | 6.59 | 13.1 | 27.1 |
| | after | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 |
| Outline view, overlay across a zoom bucket | after | 1.46 | 3.08 | 6.43 | 12.7 | 30.0 |

A pinch inside a power of two keeps the wireframe and selection layers (under a microsecond); crossing a
bucket rebuilds them at the old cost, once per doubling instead of every frame. The screen-space widths
are a shader change that needs checking by eye in the Simulator.

#### Step 5: hover index

Same Mac, `-c release`, `STRESS_DRAWING=full`, median of 9, milliseconds. Before is step 0 (`a542905`), after is this branch; the runs for all five steps went back to back with nothing else running.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Hover frame (select tool) | before | 0.062 | 0.100 | 0.120 | 0.213 | 0.331 |
| | after | 0.048 | 0.050 | 0.049 | 0.049 | 0.049 |
| Select hover, hit test only | after | 0.005 | 0.008 | 0.005 | 0.007 | 0.005 |
| Scissors hover | before | 0.898 | 0.936 | 0.381 | 1.20 | 1.09 |
| | after | 0.080 | 0.080 | 0.027 | 0.079 | 0.032 |
| Eraser sample | before | 0.044 | 0.100 | 0.223 | 0.399 | 0.906 |
| | after | 0.024 | 0.037 | 0.078 | 0.081 | 0.214 |

Hover and scissors are now flat across sizes; scissors is 10 to 30x faster, mostly from the segment skip.
The eraser is 4x faster at 2,400 shapes but still grows, since the stress drawing packs more shapes under
the same eraser path as it gets denser.

#### Next 1 and 2: triangles and decoding

Recommendations 1 and 2 of [performance-next.md](performance-next.md). Same Mac, `-c release`,
`STRESS_DRAWING=full`, median of 9, milliseconds. Before is `712957d`, after is this branch, run back to back.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Art rebuild, new zoom bucket | before | 9.33 | 18.9 | 36.8 | 74.1 | 151.3 |
| | after | 7.45 | 13.3 | 26.4 | 53.6 | 105.7 |
| Zoom-in refine, visible shapes | before | 7.12 | 8.62 | 13.6 | 18.2 | 14.7 |
| | after | 4.65 | 5.92 | 9.55 | 12.9 | 10.7 |
| Art rebuild after one edit | before | 0.286 | 0.522 | 1.03 | 1.92 | 3.73 |
| | after | 0.268 | 0.467 | 0.744 | 1.42 | 2.96 |
| Open: parse and decode | before | 17.4 | 34.7 | 69.6 | 139.9 | 280.6 |
| | after | 9.29 | 18.6 | 37.3 | 74.8 | 149.7 |
| Open: decode only | before | 9.33 | 19.1 | 37.7 | 76.0 | 151.4 |
| | after | 1.13 | 2.28 | 4.68 | 9.66 | 19.1 |

`PerformanceTests` at 2,400 shapes: cold art build 58 to 44 ms, open 142 to 78 ms. Every tessellation is
about 28% faster without the per-triangle array, and decoding is 8x faster now that values of the right
type are read without a node or a path link. Open is now 87% parsing. Other rows are unchanged within noise.

#### Next 3: carry the dragged triangles on lift

Recommendation 3 of [performance-next.md](performance-next.md). Same Mac, `-c release`, `STRESS_DRAWING=full`,
median of 9, milliseconds, run back to back. Before is the same workload with the carry left out, which is the
renderer's lift as it was after recommendations 1 and 2. Both rows include copying a builder that drew the drag.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Drag end, everything moved | before | 5.05 | 10.3 | 20.5 | 41.1 | 82.4 |
| | after | 1.13 | 2.37 | 5.25 | 11.2 | 23.0 |
| Drag end, one part moved | before | 2.06 | 2.31 | 2.79 | 3.79 | 6.31 |
| | after | 0.559 | 0.799 | 1.28 | 2.29 | 4.54 |

What is left after dragging everything is the pass over the moved vertices, comparing each moved shape with
its transformed base, and the warm build copying every part's vertices. Other rows are unchanged within noise.
The renderer side (`CanvasRenderer.updateArt`) is checked only by CI's app build until a device trace.

#### Next 4: the wiggle draws through a live transform

Recommendation 4 of [performance-next.md](performance-next.md). Same Mac, `-c release`, `STRESS_DRAWING=full`,
median of 9, milliseconds, run back to back. Part 0 (60 shapes, no bones below) wiggles. Before is a frame as the
renderer drew it after recommendations 1 and 2: the turned drawing from `displayDrawing(at:)` and a warm build of
it. After is the "Wiggle frame" workload: reading `wiggleTransform(at:)`, whose id doesn't change, so nothing is
built; the art is built once when the wiggle starts and after each edit while it runs.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Wiggle frame | before | 2.04 | 2.25 | 2.62 | 3.43 | 5.01 |
| | after | 0.004 | 0.004 | 0.004 | 0.004 | 0.004 |

The overlay no longer turns a copy of the drawing every frame either; only the outline view's wireframe still
reads `displayDrawing(at:)`. The renderer side (`CanvasRenderer.updateArt`) is checked only by the app build
until a device trace (`Art rebuild` with reason `wiggle` once per wiggle, not per frame).

#### Next 5: the first frame doesn't wait for the cold build

Recommendation 5 of [performance-next.md](performance-next.md). Same Mac, `-c release`, `STRESS_DRAWING=full`,
median of 9, milliseconds, run back to back. "Open: first frame's art" is the art's share of the first frame on
the main thread; before is the same workload building cold, as `updateArt` did when `artTolerance == 0`. "Open:
first art in view" is new: the background job's first result for an iPad-sized view at 1x around the busy point
(planning whole parts against an empty cache and tessellating them), merging it and the build that shows them.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Open: first frame's art | before | 6.27 | 12.9 | 25.7 | 51.5 | 103.5 |
| | after | 0.001 | 0.002 | 0.004 | 0.008 | 0.015 |
| Open: first art in view | after | 6.70 | 12.1 | 24.5 | 47.4 | 78.3 |

At 1x most of the stress drawing is in view, so on the Mac the art arrives about when the cold build would have
ended. The gain is that the main thread no longer blocks: the canvas, frame and references show, and the
document can be panned or closed, while the job runs. A part with any shape in view is flattened whole, so no part
shows with shapes missing; a part edited before the job's last result waits for it. The renderer side
(`CanvasRenderer.updateArt`, `scheduleRefine`) is checked only by the app build until a device trace.

#### Next 6: reserve the tessellation output

Recommendation 6 of [performance-next.md](performance-next.md). Same Mac, `-c release`, `STRESS_DRAWING=full`,
median of 9, milliseconds. Before is `b9fb65e`, after is this branch, run back to back.

| Workload | | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Art rebuild, new zoom bucket | before | 6.75 | 13.6 | 26.6 | 53.6 | 107.6 |
| | after | 6.08 | 11.9 | 23.7 | 47.0 | 99.2 |
| Zoom-in refine, visible shapes | before | 4.66 | 6.07 | 9.68 | 12.7 | 10.6 |
| | after | 4.12 | 5.25 | 8.44 | 11.4 | 9.66 |

About 12% off every tessellation, the low end of the estimate. `flattened` and `flattenedWithWidths` reserve
from Wang's bound per segment plus a quarter (no path of the stress drawing outgrew it at 0.25, 0.05 or 0.01),
`Stroker.triangles` reserves a quad per segment, a triangle per joint and the caps, and `appendTriangles` uses
its input arrays as they are when no two neighbouring points repeat. Only dashed outlines still grow the output.
The vertex counts are identical and other rows are unchanged within noise. Writing the fill fan in
`ArtBuilder.tessellate` without its three-point literal was tried and made no difference, so it is left as is.

## Smaller notes

- `Drawing.drawStack` (`DrawingEditor+Accessories.swift:29-52`, PR #17) is recomputed per call and
  copies every part into a new array whenever any accessory has a behind-owner shape. It is called
  per art rebuild, per `hitTest` (so per hover frame) and per thumbnail. Cache it with the geometry
  cache, or have `hitTest` iterate `parts` directly when no part splits.
- `drawing` has a `didSet` (`DrawingEditor.swift:129-138`) with five lookups on every assignment,
  including every move sample in a drag. Negligible on its own; listed because `partIndex` is a
  linear scan and `Drawing` has no id → index map. A `[Int: Int]` part index rebuilt on structural
  change would make `indices(part:shape:)`, `family(of:)` and friends O(1).
- `restyleSelection` coalesces on `"\(key)-\(selection)"` (`DrawingEditor.swift:1527`), which
  stringifies a `Set<ShapeRef>` per call. Use a hash of the selection instead.
- `MetalCanvasView.disableAncestorPinches` walks the superview chain and stringifies recognizer
  types on every `touchesBegan` (`MetalCanvasView.swift:148-163, 195`). Cheap but it is per touch;
  it could run once per window attach plus once when the document's zoom transition installs its
  recognizers.
- `watchForQuickShape` polls `ShapeRecognizer.recognize` every 100 ms during a stroke
  (`MetalCanvasView.swift:215-227`); fine, but the recognizer runs on the full point list each poll.
  Early-out when the point count hasn't changed since the last poll.
- `JSONValue.formatted()` computes `inlineText` for every array and object and then discards it when
  it is too long (`JSONValue.swift:61-76`), so each path point's object is formatted twice. A length
  estimate before building the string, or a budget-limited writer, halves the encode cost. Byte-for-
  byte output must not change; `DocumentTests` guards it.
- `CurveFitter` and `ShapeRecognizer` run at lift only and are not a concern.
- `maximumDrawableCount = 2` (`CanvasRenderer.swift:186`) trades a frame of latency for occasional
  `nextDrawable` stalls under load; the retry on a dropped frame handles the correctness side. Keep it
  unless Metal System Trace shows the CPU waiting on drawables.

## Relationship to other plans

- `recommendations.md` #3 (hit-test tolerance) and #14 (GPU transform during drag, live-stroke prefix
  caching) are findings 1, 2 and 6 here and remain open.
- `layers-plan.md` phases 3-4 and the group masking in PR #17 are the source of finding 3 and most of
  finding 8; neither needs a design change, only the one-pass clip plan.
- The shared geometry cache in finding 1 is the enabling piece for findings 2, 5 and 9 and should be
  designed once, in ControlFlowCore, with the renderer as its first client.
