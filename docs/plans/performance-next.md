# Performance: what is slow after the plan

Research pass on main at `ab04981`, with all six steps of [performance-plan.md](performance-plan.md) merged. It
re-runs the scaling and performance tests, profiles the slow rows with Instruments' Time Profiler, and tries the
cheapest fixes on a scratch copy to size them. Nothing here is built; the prototypes were reverted. Line numbers
are from `ab04981`.

Effort: S small (hours), M medium (a day or two), L large.

## Where things stand

Same Mac as the audit (an M-series laptop), `STRESS_DRAWING=full`, `-c release`, median of 9, milliseconds:

| Workload | 300 shapes | 600 | 1,200 | 2,400 | 4,800 | Growth |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Art rebuild after one edit | 0.296 | 0.558 | 1.06 | 1.69 | 3.29 | 0.87 |
| Art rebuild after one edit, no vertices | 0.127 | 0.141 | 0.184 | 0.221 | 0.384 | 0.40 |
| Art rebuild after one edit, with upload | 0.156 | 0.173 | 0.206 | 0.281 | 0.450 | 0.38 |
| Art rebuild, new zoom bucket | 9.50 | 19.0 | 37.4 | 74.8 | 152.6 | 1.00 |
| Zoom-in refine, visible shapes | 6.89 | 8.50 | 13.7 | 18.2 | 15.0 | 0.28 |
| Hover frame (select tool) | 0.047 | 0.049 | 0.048 | 0.048 | 0.048 | 0.01 |
| Select hover, hit test only | 0.004 | 0.007 | 0.005 | 0.006 | 0.005 | |
| Outline view, overlay at a new zoom | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | |
| Outline view, overlay across a zoom bucket | 1.49 | 3.48 | 7.26 | 14.0 | 27.5 | 1.05 |
| Scissors hover | 0.078 | 0.082 | 0.026 | 0.077 | 0.031 | |
| Pencil stroke, 240 samples and lift | 0.039 | 0.041 | 0.042 | 0.045 | 0.053 | 0.10 |
| Quick shape check, 1,200 points | 0.210 | 0.210 | 0.210 | 0.225 | 0.210 | 0.00 |
| Eraser sample | 0.024 | 0.036 | 0.074 | 0.078 | 0.207 | 0.79 |
| Drag sample, everything selected | 0.085 | 0.189 | 0.350 | 0.825 | 1.76 | 1.09 |
| Undo and redo | < 0.001 | < 0.001 | < 0.001 | < 0.001 | < 0.001 | |
| Two-finger navigation, 60 samples | 0.017 | 0.017 | 0.017 | 0.017 | 0.019 | 0.03 |
| Refresh queries, everything selected | 0.371 | 0.729 | 1.50 | 3.09 | 6.36 | 1.02 |
| Layer tree | 0.002 | 0.004 | 0.007 | 0.014 | 0.030 | |
| Save: encode and format | 18.7 | 37.7 | 75.1 | 150.7 | 300.5 | 1.00 |
| Open: parse and decode | 17.3 | 35.0 | 70.1 | 139.6 | 279.9 | 1.00 |
| Open: parse only | 7.96 | 15.9 | 32.1 | 64.6 | 129.9 | 1.01 |
| Open: decode only | 9.46 | 18.9 | 37.6 | 75.0 | 150.2 | 1.00 |
| SVG export | 6.62 | 13.8 | 27.6 | 56.6 | 116.0 | 1.03 |
| SVG import | 2.74 | 5.47 | 11.2 | 22.5 | 45.8 | 1.02 |

The numbers match the "after" columns in the audit's step tables, so nothing regressed when the steps merged.
`PerformanceTests` at 2,400 shapes agrees: cold art build 59 ms, open 144 ms, encode and format 156 ms.

Five operations had no row, so the profiling pass added them as scratch workloads (reverted with the rest; the
recommendations below say which to keep):

| Scratch workload | 300 shapes | 600 | 1,200 | 2,400 | 4,800 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Wiggle frame (display drawing and art build) | 2.94 | 3.10 | 3.62 | 4.53 | 6.48 |
| Drag end, one part moved (the rebuild on lift) | 1.48 | 1.69 | 2.07 | 2.90 | 4.81 |
| Drag end, everything moved | 6.99 | 14.3 | 28.3 | 56.6 | 113.3 |
| Open to first art (parse, decode, cold build) | 27.3 | 55.2 | 109.2 | 218.5 | 437.2 |
| Editor init and layer tree, on open | 0.084 | 0.170 | 0.342 | 0.688 | 1.40 |

Interactive work inside a frame is in good shape: hovering, drawing, navigation, undo and the frame after an edit
no longer depend on the drawing's size, or barely do. What is left falls into three groups:

- **Work the user waits on once.** Opening a document is 140 ms to parse and decode, then about 60 ms of cold art
  build before the first frame shows anything: 220 ms on the Mac at 2,400 shapes, likely several times that on
  an iPad. Lifting the Pencil after dragging a lot of art re-tessellates everything it moved (57 ms for the
  whole drawing).
- **Work repeated every frame of an animation.** The wiggle preview re-tessellates the wiggling part on every
  frame: 4.5 ms of a 120 Hz frame's 8.3 ms on the Mac, for a part of 60 shapes.
- **Background work.** Autosave encodes and formats for 150 ms after every finished change, and the background
  refine after a zoom is 75 ms of CPU. Neither blocks a frame, but on an iPad both compete with the main thread
  for cores and battery.

## What the profiles found

Time Profiler on the release test binary, running the matching `PerformanceTests` case
(`xcrun xctrace record --template 'Time Profiler' --launch -- "$(xcrun -f xctest)" -XCTest
CharacterCoreTests.PerformanceTests/<test> .build/release/CharacterCoreTests.xctest`, with `STRESS_DRAWING=full`
set). The percentages are shares of samples inside the test.

### Tessellation: an array allocated for every triangle

`Stroker.triangle` (`Stroker.swift:255-263`) appends each triangle with `out.append(contentsOf: [a, b, c])`. The
optimizer doesn't remove the array literal here, so every triangle allocates and frees a three-element array. In a
new-zoom-bucket rebuild that is 31 to 34% of all samples (allocation, release and copy under `triangle`), and the
same function dominates the cold build, the drag-end rebuild and the wiggle frame, since all of them stroke
shapes.

Prototype: three plain `append`s. Every workload that tessellates got faster, and the full test suite passed:

| Workload, 2,400 shapes | Before | Prototype |
| --- | ---: | ---: |
| Art rebuild, new zoom bucket | 74.8 | 53.5 |
| Zoom-in refine, visible shapes | 18.2 | 12.9 |
| Cold art build (`testArtBuildCold`) | 59 | 45 |
| Drag end, everything moved | 56.6 | 41.6 |
| Drag end, one part moved | 2.90 | 2.50 |
| Wiggle frame | 4.53 | 3.66 |

`CapsuleTessellator.append` (`CapsuleTessellator.swift:49`) uses the same pattern with a twelve-float literal, but
there the optimizer does keep it on the stack: rewriting it as single appends made the outline-view rebuild slower
(14.0 to 18.3 ms). Leave it alone. No other `append(contentsOf: [` literal is left in the core.

What remains of a tessellation after the fix is flattening (`CubicBezier.flatten`, 22%), round joins and caps
(`atan2`, `acos`, `Stroker.arc`, about 9%) and array growth: `Array._createNewBuffer` and `memmove` together are
about 28% of the rebuild, from `Stroker.triangles`' output, `appendTriangles`' de-duplicated copies `p` and `r`
(`Stroker.swift:35-44`), and the flattened polylines, all of which start empty and double.

### Open: decoding builds a node and a path link for every value

After plan step 3, decoding is the larger half of open (75 of 140 ms). Within it, `CharacterFormat.shape` is 99%,
and inside that:

- `Node.vec2` is 59%. It calls `array()`, which allocates a `[Node]` for the pair (through a generic
  `enumerated().map`), and each of those nodes and the array share a newly allocated `PathLink`
  (`CharacterFormat.swift:726-730, 752-756`). A point has up to three pairs.
- Every `field` and `require` allocates a `PathLink` too (`Node.link` is a computed property that makes one per
  call, `CharacterFormat.swift:699, 713-724`), even when the key is missing. A point asks for seven keys.
- Releasing the links is another 10% (`outlined destroy of PathLink?`).

So a path point costs about ten heap allocations in the decoder alone, all to keep an error path that is almost
never read.

Prototype: give `Node` value accessors (`vec2(_ key:)`, `number(_ key:)`, `bool(_ key:)`) that read the member's
`JSONValue` directly and return it when it has the right type, and fall back to today's `field(key)!.vec2()` (and
so on) when it doesn't, so a bad file still throws exactly today's error; plus the same fast path at the top of
`vec2()`. Applied to the points loop only:

| Workload, 2,400 shapes | Before | Prototype |
| --- | ---: | ---: |
| Open: decode only | 75.0 | 14.2 |
| Open: parse and decode | 139.6 | 78.9 |
| Open to first art (with the triangle fix too) | 218.5 | 131.4 |

All 483 core tests passed with it, including every test that pins an error path (the fallback re-runs the old
code, so the messages can't drift).

### Open: parsing allocates the tree

With decoding fixed, parsing is 72% of open (65 ms), and freeing the parsed `JSONValue` tree once decoding is done
is another 11%. Inside the parser, about 45% of the samples are allocating and growing the arrays behind every
object and array (a point is an object and up to three two-element arrays), and 18% is making the key strings:
`String(validating:as:)` on an `ArraySlice` goes through generic metadata lookups at run time. The number
parsing step 3 rewrote is under 10%.

Two cheap tries didn't pay, so they are not recommendations:

- Building each container on a shared scratch stack and copying it out at its exact size (one allocation per
  container instead of growth): 4% faster.
- Making key strings from an `UnsafeBufferPointer` instead of an `ArraySlice`: 2% faster.

What is left is the cost of having a tree at all. Going below about 65 ms needs decoding straight from the bytes
(below).

### Save: each small object is formatted twice

Encode and format is 150 ms at 2,400 shapes. `JSONValue.inlineText` is 35% of it, `write` 13% and `joined` 7%:
the audit's smaller note about `formatted()` building the one-line text of every array and object and then
discarding it when it is too long (`JSONValue.swift:58-108`) is the whole story. Number formatting
(`_Float64ToASCII`) is 7%.

### Outline view across a zoom bucket

14 ms at 2,400 shapes, once per doubling of the zoom in outline view (step 4 made it once per bucket instead of
every frame). About half is flattening every shape again (`Builder.wireframe`, `EditorOverlay.swift:246-260`), the
rest is `CapsuleTessellator` writing 72 floats per segment and the array growing to hold them.

### Refresh with everything selected

3 ms at 2,400 shapes, all of it the editor queries `refresh()` reads: control bounds (`CubicBezier.include`, 21%)
and hashing `ShapeRef`s into sets (`Set.contains` and `Hasher`, 35%). Select-all on a large drawing is rare, so
this stays low.

## Recommendations, ranked

Ranked by what the user feels per hour of work. The first two are each a few lines and were measured; the rest
are estimates where marked.

### 1. Append triangles without an array literal (S): shipped

Shipped: new-bucket rebuild 74.1 to 53.6 ms and cold build 58 to 44 ms at 2,400 shapes (the audit's "Next 1
and 2" table).


`Stroker.swift:259, 261`: three `append`s instead of `append(contentsOf: [a, b, c])`. Measured above: 28% off a
new-bucket refine and 24% off the cold build, and every other rebuild that tessellates gets the same. Keep the
`CapsuleTessellator` literal as it is (measured slower without it). No test changes; the art tests compare
triangles and the order is unchanged.

### 2. Decode values without building nodes (S): shipped

Shipped, for the points loop and the rest of `shape`, `stroke` and the part loop: decoding 76.0 to 9.7 ms and
open 139.9 to 74.8 ms at 2,400 shapes. `testWrongValueTypesAreReportedWithTheirPath` pins the error for each
accessor and passes on the old decoder too.


As prototyped: value accessors on `Node` that fall back to today's path on any mismatch, and the fast path in
`vec2()`. Measured above: decoding 75 to 14 ms, open 140 to 79 ms at 2,400 shapes. Then apply the same accessors
to the rest of `shape`, `stroke` and the part loop (`fill`, `opacity`, `hidden`, `locked`, `clipped` and the rest),
which is most of the remaining 14 ms. The existing error tests are the guard and must pass unchanged; add one
test per accessor that a wrong type (a string for a point, a three-element pair, `NaN` written as a huge number)
still produces today's exact message.

### 3. Lift after a drag reuses the moved tessellations (M): shipped

Shipped as `ArtBuilder.carry(_:to:)`, called by the renderer on the first frame after a live drag: the frame
after dragging everything went from 41.1 to 11.2 ms at 2,400 shapes, and after dragging one part from 3.8 to
2.3 ms (the audit's "Next 3" table). Enlarged shapes are stored at their enlarged tolerance and the art goes
mixed, so the background refine redoes them. A shape is flattened again after 8 carries in a row, so float
rounding can't build up. Needs a device trace (`Art carry` then `Art rebuild` with reason `edit`) to confirm.


Today the drag's art is drawn through `LiveTransform` without re-tessellating, but when the Pencil lifts, every
moved shape is a changed shape, and the next build strokes them all again on the main thread: 57 ms for
everything at 2,400 shapes (42 ms after recommendation 1), 2.9 ms for one 60-shape part.

`LiveTransform.movesTessellation` already establishes that drawing the old triangles through a similarity looks
like drawing the transformed shapes. So at the end of such a drag, the cache can take each moved shape's
tessellation through the transform (a multiply-add per vertex) and store it under the new shape, instead of
dropping it. A scale above 1 leaves the art coarser than its bucket, as it was during the drag; mark those shapes
for the next background refine rather than re-tessellating in the frame.

Estimate, not measured: the lift becomes a pass over the moved vertices (about 2 million vertices for the
whole drawing, a few ms) plus a warm build. Tests: a build after a cache-transformed drop matches a fresh build of
the moved drawing up to flattening error, for a translation, a rotation and a uniform scale; a non-similarity
(skew) falls back to re-tessellating. Keep "Drag end, one part moved" and "Drag end, everything moved" as
workloads.

### 4. The wiggle preview draws through the live transform (S-M): shipped

Shipped as `DrawingEditor.wiggleTransform(at:)`, which the renderer draws like a drag: a wiggle frame went from
3.4 ms to 0.004 ms at 2,400 shapes (the audit's "Next 4" table). Its id changes with the drawing, so an edit
while the part rocks rebuilds once. The overlay reads the turned drawing only in the outline view. Needs a device
trace (`Art rebuild` with reason `wiggle` once per wiggle) to confirm.


`displayDrawing(at:)` (`DrawingEditor+Bones.swift:473-488`) rotates the wiggling part, its accessories and the
parts on bones below it, and `updateArt` rebuilds the art from that drawing on every frame
(`CanvasRenderer.swift:384-386`), re-tessellating every one of those shapes: 4.5 ms per frame on the Mac for one
60-shape part with no bone children (3.7 ms after recommendation 1), more for a part with limbs below it. The
renderer also calls `displayDrawing` a second time per frame for the overlay (`CanvasRenderer.swift:322`).

A wiggle is a rotation about the pivot of a known set of shapes, which is exactly what `LiveTransform` describes.
Expose the wiggle as a `LiveTransform` (base: the drawing, shapes: the wiggling parts' shapes, transform: the
turn at `time`) and let the renderer's existing live path draw it: the art is built once when the wiggle starts and
each frame sets one uniform. Compute the turn once per frame and pass it to the overlay. Estimate: under 0.1 ms
per frame of CPU, like a drag sample's art, plus the overlay. Keep "Wiggle frame" as a workload.

### 5. Show the first frame before the cold build finishes (M): shipped

Shipped as `ArtBuilder.build(leavingOutUncached:)` and `refinePlan(wholeParts:)`: the first frame's art went from
a 51.5 ms cold build to 0.008 ms at 2,400 shapes, and a refine job flattens the drawing meanwhile, whole parts in
view first (the audit's "Next 5" table). It is shipped ahead of the device trace this section asked for, at
the owner's request. The trace is still the acceptance: `Art rebuild` with reason `open` in the first frame, then
`Art merge` and `Art rebuild` with reason `open` as each result arrives.


Opening still ends with a cold art build on the main thread inside the first frame (`updateArt` when
`artTolerance == 0`, `CanvasRenderer.swift:381-390`): 59 ms at 2,400 shapes, 45 ms after recommendation 1. This is
plan step 3's deferred third bullet, which waited for step 1's background job; that job now exists. Start a refine
job for the first build (visible shapes first), draw the references, frame and an empty canvas meanwhile, and
merge as the results come in. With recommendations 1 and 2, open to first visible art would be about 80 ms of
parse and decode plus the visible shapes' share of the build, instead of 220 ms.

Worth doing only after a device trace of an open (the `Open` interval to the first `Art rebuild`) shows the gap
is felt. Whether SwiftUI calls `CharacterDocument.init(configuration:)` on the main thread was not checked here;
the trace answers that too.

### 6. Reserve tessellation output instead of growing it (S-M): shipped

Shipped: new-bucket rebuild 53.6 to 47.0 ms and zoom-in refine 12.7 to 11.4 ms at 2,400 shapes (the audit's
"Next 6" table), with the same vertices. About 12%, the low end of the estimate.


After recommendation 1, array growth is about 28% of a rebuild. `Stroker.triangles` can reserve from the
flattened point count (a stroke emits a known number of triangles per segment plus joins and caps),
`appendTriangles` can skip copying into `p` and `r` when the input has no duplicate points (the common case), and
`flattenedWithWidths` can reserve from its segment count. Estimate: 10 to 20% off every tessellation. Measure
with "Art rebuild, new zoom bucket"; keep the output identical, which the art tests check.

### 7. Format each value once when saving (S-M)

The audit's smaller note, now measured: `inlineText` and its `joined` are about 40% of encode and format, and
`write` another 13%. Write the one-line form into the output directly with a character budget, and roll back to
the multi-line form when the budget runs out, so nothing is built twice. Estimate: about half of 150 ms. Off the
main thread, so it matters for an iPad's cores and battery during autosave, not for frames; `DocumentTests`'
byte-for-byte round trip guards the output.

### 8. Decode straight from the bytes (L, only if open still matters)

After recommendation 2, open is about 80 ms, 65 of it building the `JSONValue` tree and 9 freeing it. A decoder
that reads the current format directly from the bytes (the same grammar checks, the same error paths, reading
point arrays into `PathPoint`s without an intermediate tree) would remove both. Older files would keep going
through `JSONValue` and `CharacterFormat.migrations`. Estimate: open at 2,400 shapes from about 80 ms to 25 to
35 ms. It duplicates the decoder's knowledge of the format, so only do it if a device trace after
recommendations 2 and 5 still shows opening as slow.

### 9. Lower priority

- **Outline view across a bucket (M).** 14 ms once per doubling in outline view. Plan step 4's deferred third
  bullet (read flattened outlines from `TessellationCache`) removes the flattening half, but the outline view
  doesn't fill the cache today. Drawing capsules as instances (one 12-float instance per segment instead of six
  12-float vertices) would cut the other half by about 6x in bytes. Wait for a device trace.
- **Refresh with everything selected (S).** 3 ms, mostly control bounds and `ShapeRef` hashing. Caching each
  shape's control bounds with the shape index from step 5 would remove most of it.
- **SVG export (S).** 57 ms, on the main thread (`CanvasStore.svgData`, `CanvasStore.swift:627-629`). Not
  profiled; it runs once per export. Moving it to a detached task like the import is simple if it shows.

## Not worth doing now

- Hover, scissors, eraser, pencil strokes, QuickShape, navigation, undo and the frame after an edit (0.28 ms with
  the upload at 2,400 shapes): flat or near flat, and well inside a frame.
- The parser's container and string allocations on their own (see "Open: parsing allocates the tree": 4% and 2%).
- `CapsuleTessellator`'s array literal (measured slower without it).

## Verifying

Each recommendation's PR runs
`STRESS_DRAWING=full swift test -c release --package-path Packages/CharacterCore --filter ScalingTests` before and
after on the same machine and adds its rows to the audit, as the plan's steps did. Recommendations 3, 4 and 5
touch `CanvasRenderer`, which only CI's `app-build` job and a device can check; their PRs should say so, and a
device trace (`Art rebuild` with reasons `drag`, `wiggle` and the first build after `Open`) is the real acceptance.
