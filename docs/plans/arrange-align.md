# Arranging and aligning: implementation plan

2026-10-15. Builds the project's arrange and align design proposal, with every recommended default accepted: one object aligns to the viewport, objects align by their geometry box (no outline width), smart guides are on by default and ship now as PR 2, Direct Select's points align and distribute too, no key object yet, and several objects aligned to the viewport move separately. File references are to `main` at `59a7605`; `Core/` means `Packages/ControlFlowCore/Sources/ControlFlowCore/` and `Tests/` means `Packages/ControlFlowCore/Tests/ControlFlowCoreTests/`.

## Status

- **PR 1 (align, distribute and the small extras): shipped.** `Alignment.swift` (`AlignEdge`, `DistributeMode`, `Aligner`, `Distributor`) with `AlignmentTests`; `DrawingEditor+Align.swift` (`AlignTarget`, `alignmentUnits()`, `align`, `distribute`, `canAlign`, `canDistribute`, `alignsToViewportOnly`) with `AlignTests`; `Layer.isWhole(group:in:)` shared with `Drawing.wholeGroup`; `moveAnchors(_:key:)` generalising the anchor nudge. In the app: the Arrange popover on the Select context bar (and Align Points in Direct Select), the Arrange menu's Align and Distribute submenus with the Option-letter shortcuts, the Edit menu's Arrange submenu, Shift-arrow nudges of 10 points and the Rotate Left and Right buttons. As built, the Edit menu's Arrange submenu stays enabled when only Align applies (its draw-order items disable on their own), and the spacing buttons use the `distribute.*.center` symbols, with the centers modes' `.fill` variants in the `…` menu.
- **PR 2 (smart guides): shipped.** `SmartGuides.swift` (`GuideTargets`, `GuideLine`, `GuideSnap`, `SmartGuides.snapMove`, `snapPoint` and `lines`) with `SmartGuideTests`; `SnapSettings.smartGuides` (default on, editor state); `DrawingEditor.guideLines`, collected on a transform drag's first step and drawn by `EditorOverlay` in `guideColor`; `PerformanceTests.testSmartGuideTargets`. In the app: the Smart Guides toggle in the Snap menu, View > Smart Guides on Cmd-U and the per-iPad `UserDefaults` preference. As built, the edge and corner snapping is one `snapPoint` rather than `snapEdge`; on a resize a guide beats the grid; resizing a turned frame shows no guides; `Snapper.translation` reports which axes snapped (`snapTranslation` wraps it); and target collection took about 3 ms per drag on the stress drawing, so the visible-rect fallback wasn't needed.

## The plan

Two PRs. Each one ships working on its own, passes `scripts/check.sh core` and `schema` in the cloud, and relies on CI's `app-build` job for the app target (the app can't be built off a Mac). Neither PR changes the file format, the schema, `Schema/vectors` or `player.js`.

Per `CLAUDE.md`, PR 1 also adds this plan as `docs/plans/arrange-align.md` and PR 2 marks its items shipped there.

---

## PR 1: Align, distribute and the small extras

### 1. Pure geometry: `Core/Alignment.swift` (new)

Foundation only, no editor types, so it's tested in isolation.

```swift
public enum AlignEdge: Sendable, CaseIterable { case left, centerX, right, top, centerY, bottom }
public enum DistributeMode: Sendable, CaseIterable { case spacingX, spacingY, centersX, centersY }

public enum Aligner {
    /// One translation per box so its `edge` matches `reference`'s.
    public static func offsets(boxes: [Rect], edge: AlignEdge, reference: Rect) -> [Vec2]
    /// The same for points (Direct Select): each point's x or y goes to the reference's
    /// min, middle or max; centers use the points' bounding box middle.
    public static func offsets(points: [Vec2], edge: AlignEdge) -> [Vec2]
}

public enum Distributor {
    /// One translation per box. Boxes are ordered by center along the axis (ties keep
    /// input order). With `within` nil, the first and last stay put; with a rect (the
    /// viewport), the first and last move to its edges and the rest spread between.
    public static func offsets(boxes: [Rect], mode: DistributeMode, within: Rect?) -> [Vec2]
    public static func offsets(points: [Vec2], mode: DistributeMode) -> [Vec2]
}
```

- Spacing mode: total gap = (span of the outer boxes) − (sum of widths); each gap = total / (n − 1), negative allowed. Centers mode: equal steps between the first and last centers. For points, spacing and centers are the same thing.
- Offsets below 1e-9 are returned as zero so callers can skip units that don't move.

**Tests** (`Tests/AlignmentTests.swift`, new): each `AlignEdge` against a hand-made set of boxes; the reference box being one of the boxes (it doesn't move); distribute with equal, unequal and overlapping boxes (negative gaps come out equal); ties in center order; `within` the viewport; fewer than three boxes returns all zeros; points.

### 2. Editor commands: `Core/DrawingEditor+Align.swift` (new)

```swift
public enum AlignTarget: Sendable { case selection, viewport }

extension DrawingEditor {
    /// The selection split into what moves as one, each as a `Selection`.
    func alignmentUnits() -> [Selection]
    public var alignmentUnitCount: Int
    public var canAlign: Bool        // ≥ 1 unit, or ≥ 2 anchors in Direct Select
    public var canDistribute: Bool   // ≥ 3 units, or ≥ 3 anchors
    public var alignsToViewportOnly: Bool  // exactly one unit
    public mutating func align(_ edge: AlignEdge, to target: AlignTarget)
    public mutating func distribute(_ mode: DistributeMode, to target: AlignTarget)
}
```

**`alignmentUnits()`**, following the design's table:

- `.layer(id)` → `[.layer(id)]`; `.layers(ids)` → one `.layer` each, in draw order.
- `.reference(id)` → `[.reference(id)]`.
- `.shape` / `.shapes`: walk `drawing.shapeIndices(in:)` in draw order. For each layer, a group whose members are all selected becomes one unit, `.shapes(members)`, which `Drawing.wholeGroup` already recognises, so `apply` moves the group's transform. Every other shape is `.shape`. **Exception:** when `isolatedGroup` is that group, or the tool is Direct Select, every shape is its own unit. Pull the "all members selected" test out of `Drawing.wholeGroup` (`Core/Drawing.swift:935`) into a helper both can use.

**Boxes:** `drawing.geometryBounds(of: unit)` per unit (world, axis-aligned, outline-free, includes a text's box). Units with a null box (empty layer) are dropped.

**`align` / `distribute`:**

1. Direct Select with ≥ 2 selected anchors goes to the points path (below).
2. Otherwise get the units and boxes, choose the reference (`viewport.bounds` when `target == .viewport` or there is one unit; else the union of the boxes), and get offsets from `Aligner` / `Distributor`.
3. `cancelGesture()`, `let before = drawing`, then `drawing.apply(.translation(d), to: unit)` for each unit whose offset isn't zero, then one `commit(from: before)`. No coalescing key: each command is its own undo step. If nothing moved, don't commit.

Reference images can be aligned to the viewport on their own. A mixed selection can't contain one, so no other case is needed.

**Points:** with Direct Select, take `selectedAnchors` of `activeShape` in world space (as `selectedAnchorsCentroid` does, `Core/DrawingEditor+Commands.swift:292`), get per-point offsets, and apply them in one `drawing.updateWorldPath` with one commit. This generalises the private `moveSelectedAnchors(by:key:)` (line 306) to take a per-anchor offset; nudge keeps calling it with the same delta for all.

**Keyframes:** nothing special. `commit` already turns the change into keyed transform (or point) changes at the current keyframe, so aligned objects animate into place.

**Tests** (`Tests/AlignTests.swift`, new), building drawings in code as `GroupTests` and `TransformTests` do:

- Units: two layers; a whole group plus a loose shape (two units, and the group's transform changes, not its shapes'); part of a group (each shape); the isolated group's shapes; Direct Select inside a group.
- A single shape centers on the viewport; a single layer too; `.selection` with one unit still uses the viewport.
- Three shapes Align Left to the selection: the leftmost doesn't move, the others' left edges match, and the points are byte-for-byte untouched (only `transform.position` changed).
- A turned shape aligns by its axis-aligned world box.
- Text aligns by its box (two texts with different first glyphs end up with equal box lefts).
- Viewport with three units: each lands on the edge (separately, not as a block).
- Distribute spacing over three and four shapes; distribute to the viewport puts the outer ones on its edges.
- Points: three anchors Vertical Centers end level; distribute spaces them.
- Undo: one `undo()` restores everything; a no-op align adds no undo step.
- At a keyframe (as in `KeyframeTests`): after Align Left at keyframe 1, the opening state is unchanged and keyframe 1 has keyed positions.
- `canAlign` / `canDistribute` / `alignsToViewportOnly` for each selection kind.

### 3. Shift-arrow nudge and rotate buttons

- `ControlFlow/EditorCommands.swift:96`: add four Shift-arrow items calling `store?.nudge(±10, 0)` / `(0, ±10)` with `.keyboardShortcut(.leftArrow, modifiers: .shift)` etc., inside the same `.disabled(typing)` group. Shift-arrow while typing keeps extending the text selection.
- `ContentView.flipControls` (`ControlFlow/ContentView.swift:647`): add "Rotate Left" (`rotate.left`) and "Rotate Right" (`rotate.right`) calling the existing `store.rotateSelection(degrees: -90 / 90)`.
- Test in `TransformTests`: `nudge(by: Vec2(10, 0))` moves by 10 (it already works for any delta; this just pins the behaviour).

### 4. App wiring

**`CanvasStore`** (`ControlFlow/Canvas/CanvasStore.swift`):

- `EditorUIState` gains `canAlign`, `canDistribute`, `alignsToViewportOnly` and `alignTarget: AlignTarget` (default `.selection`), refreshed beside `canTransform` (line 319).
- `func align(_ edge: AlignEdge)` and `func distribute(_ mode: DistributeMode)` call the editor with `ui.alignTarget` through `edit { }`, like `arrange` (line 566). `func setAlignTarget(_:)`.
- `alignTarget` lives on the store only: not in the file, not in `UserDefaults`.

**Arrange popover** (`ContentView.swift`): a new `ArrangePopover` view and a button (`align.horizontal.left`) added to the Select tool's context bar beside `flipControls`, shown when `ui.canAlign`.

- Row 1, Align: six icon buttons (`align.horizontal.left`, `align.horizontal.center`, `align.horizontal.right`, `align.vertical.top`, `align.vertical.center`, `align.vertical.bottom`). Under them a segmented Selection | Viewport picker bound to `alignTarget`, showing Viewport and disabled when `alignsToViewportOnly`.
- Row 2, Distribute: horizontal and vertical spacing buttons (`distribute.horizontal`, `distribute.vertical`), and a `…` menu with Horizontal Centers and Vertical Centers. Disabled unless `canDistribute`.
- Row 3, Order: the four `arrange` buttons using the same icons as the Edit menu's Arrange submenu (line 317).

In Direct Select, when `ui.anchorCount >= 2`, `pointControls` gets the same popover with only the Align and Distribute rows and no target picker.

**Menus:**

- `EditorCommands.swift`, `CommandMenu("Arrange")` (line 63): add `Menu("Align")` with the six items on Option-A, Option-H, Option-D, Option-W, Option-V, Option-S, and `Menu("Distribute")` with Horizontal Spacing (Shift-Option-H), Vertical Spacing (Shift-Option-V), Horizontal Centers and Vertical Centers. Each item is disabled when `typing` (Option-letters type characters there) or when it can't apply.
- `ContentView.swift`'s Edit menu Arrange submenu (line 317): the same Align and Distribute submenus, without shortcuts.

**Docs in the same PR:** README's Select and keyboard notes (around lines 190 and 248, and the current milestone section) describe Align, Distribute, Align To, the viewport rule, Shift-arrow, rotate buttons and the shortcuts. `docs/plans/arrange-align.md` holds this plan, and `docs/plans/animation-app.md` gets a one-line entry pointing to it.

---

## PR 2: Smart guides

### 5. Pure guide matching: `Core/SmartGuides.swift` (new)

```swift
public struct GuideTargets: Sendable {
    /// Candidate x and y lines, each with the box it came from (for drawing the line).
    public var xs: [(value: Double, kind: GuideKind, box: Rect)]
    public var ys: [(value: Double, kind: GuideKind, box: Rect)]
    public init(boxes: [Rect], viewport: Rect)
}
public enum GuideKind: Sendable { case edge, center }

public struct GuideLine: Hashable, Sendable { public var from: Vec2; public var to: Vec2; public var isCenter: Bool }

public enum SmartGuides {
    /// Adjusts `delta` so one of `box`'s three x lines (and independently three y
    /// lines), moved by `delta`, lands on a target within `radius`. Returns the new
    /// delta, which axes snapped, and the lines to draw.
    public static func snapMove(box: Rect, delta: Vec2, targets: GuideTargets, radius: Double)
        -> (delta: Vec2, snappedX: Bool, snappedY: Bool, lines: [GuideLine])
    /// For a resize: snaps the one moving edge (x or y or both) of `box`.
    public static func snapEdge(_ p: Vec2, movingX: Bool, movingY: Bool, targets: GuideTargets, radius: Double)
        -> (point: Vec2, lines: [GuideLine])
}
```

- Targets are sorted, so matching is a binary search per line: 6 lookups per move step.
- Each axis picks the smallest adjustment; ties prefer edge-to-edge over center matches, then the viewport.
- A line runs along the matched coordinate from the dragged box to the farthest matching target box on that axis (all boxes sharing that coordinate), so three aligned objects show one long line. Viewport lines span the viewport.

**Tests** (`Tests/SmartGuideTests.swift`, new): a box near another's left edge snaps x only; near a center snaps with `isCenter`; just outside the radius doesn't snap; x and y snap independently; viewport center; the line spans all boxes sharing the coordinate; `snapEdge` for an edge handle.

### 6. Editor integration (`Core/DrawingEditor.swift`)

- `SnapSettings` (`Core/Snapping.swift`) gains `smartGuides: Bool = true`. Not saved in the file; `SnapSettings` is editor state.
- New `public private(set) var guideLines: [GuideLine] = []` and a private `guideTargets: GuideTargets?`. The `gesture` `didSet` (line 251) clears both whenever the gesture isn't `.transform`, the same way it clears `liveTransform`.
- `guideTargets` is built lazily on the first move step of a `.transform` gesture, from `before`: the world `geometryBounds` of every shown shape and of every group (union of its shown members), skipping the shapes in the target. Locked art is included. Layers aren't added on their own.
- `transform(_:from:to:target:before:)` (line 1182) becomes `mutating` (or returns the lines alongside the transform; the cleaner choice is a small private struct returned from it):
  - **move:** after the constrain step, if `snap.smartGuides`, run `SmartGuides.snapMove` on `before.geometryBounds(of: target)` with radius `EditorMetrics.guideRadius / gestureZoom` (6 screen points). Then, if `snap.isEnabled`, run the existing `Snapper.snapTranslation`. An anchor hit replaces both axes; a grid hit replaces an axis only if it's nearer than the guide's adjustment. Drop the lines for any axis the anchor or grid took over.
  - **stretch:** snap the moving edge with `snapEdge` (one axis).
  - **scale (corner):** snap the dragged corner with `snapEdge` on both axes, then keep the uniform scale from whichever axis snapped (x first). If neither snapped, no lines.
  - **rotate:** no guides.
- A constrained (Shift) move only snaps along its free axis.

**Overlay** (`Core/EditorOverlay.swift`): in the `guides` layer, after the viewport border, draw each `GuideLine` as a 1-screen-point capsule in a new `EditorOverlay.guideColor` (a magenta like Illustrator's, distinct from the selection accent), and a small cross (two 6-point capsules) at each end of a center line. The `guides` layer isn't cached, so nothing to invalidate.

**Performance:** target collection walks the drawing once per drag. Add a case to `PerformanceTests` timing it on the stress drawing. If it is slow there, restrict targets to shapes whose boxes intersect the view: `pencilBegan(at:zoom:)` would take the visible world rect from the app, which already has it for the overlay (`viewRect`).

**Tests** (`Tests/SmartGuideTests.swift`): a drag through `pencilBegan`/`pencilMoved`/`pencilEnded` (as `DirectSelectFlowTests` does) where a shape stops exactly on another's left edge and on the viewport's center line; `guideLines` is non-empty mid-drag and empty after; with `smartGuides` off nothing snaps; an anchor snap beats a guide; an edge-handle stretch snaps to a target edge; one undo step for the drag, as before.

### 7. App wiring

- `ContentView.snapMenu` (line 597): add `Toggle("Smart Guides", isOn: snapBinding(\.smartGuides))` above the existing Snap toggle, and show the snap menu with the Select tool even when Snap itself is off (it already shows for Select).
- `EditorCommands.swift`, View group (line 109): "Smart Guides" on Cmd-U.
- Per-iPad preference: `CanvasStore` saves `smartGuides` to `UserDefaults` under `smartGuides` (default true) and applies it to `editor.snap` at launch, like the rotation lock (`CanvasStore.swift:896-907`).
- The renderer needs no change: guide lines arrive in `overlay.guides`.
- README: Snap notes (line 192) and the current milestone describe Smart Guides, their targets, the radius and the toggle; `docs/plans/arrange-align.md` marks both PRs shipped.

---

## Order of work and checks

| Step | PR | Checked by |
| --- | --- | --- |
| `Alignment.swift` + `AlignmentTests` | 1 | `swift test` on Linux |
| `DrawingEditor+Align.swift` + `AlignTests` | 1 | `swift test` |
| Shift-nudge, rotate buttons, store, popover, menus | 1 | CI `app-build` |
| README, `docs/plans/arrange-align.md` | 1 | review |
| `SmartGuides.swift` + tests | 2 | `swift test` |
| Editor drag integration, overlay, perf case | 2 | `swift test` |
| Snap menu, View menu, `UserDefaults` | 2 | CI `app-build` |

Things to try on the iPad after each PR, since the cloud can't run the app: center a title on the slide with one tap; align three shapes left and undo once; distribute four shapes; align points level in Direct Select; Option-letter shortcuts with a keyboard; drag a shape onto another's edge and see the line; Cmd-U turns guides off.

## Risks

- **Option-letter shortcuts while typing.** They must stay disabled while a text is being edited, or Option-A inserts "å" and aligns at once. Handled with the existing `typing` flag.
- **Guide noise on busy slides.** Many shapes can make lines flicker. If it's distracting, a later tweak is to match groups before their shapes, or only objects near the dragged one.
- **Corner-scale snapping** is the fiddliest part. If it feels wrong it can be dropped from PR 2 without affecting the rest.
