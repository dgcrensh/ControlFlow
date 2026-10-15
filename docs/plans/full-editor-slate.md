# Toward a full vector editor: recommended feature slate

Planning pass on `main` after PR #5 (reasoned from code, nothing run on a device). Builds on
[recommendations.md](recommendations.md) and [vector-workflow.md](vector-workflow.md); everything they list as
M4a/M4b (Pen, Pencil rename, Select/Direct Select, marquee, handle modes, delete-with-heal, split/join, segment
drag, non-uniform scale, flip, pivot, snapping, numeric inspector, nudge) is already built and not repeated here.

Effort: S small, M medium, L large. Each item says why it matters for a **rigged, animated character**, because
that is what should break ties: anything that looks right only in the rest pose is worth less here than in a
general illustration app.

## What is still missing, in one paragraph

Shapes can only be made by Pencil or Pen; there are no primitives, no duplicate/copy/paste, no z-order inside a
part, no hide/lock, no eraser or knife, no booleans, and appearance is one solid fill plus one uniform round-cap
stroke (`VectorShape`, Drawing.swift:15-19; renderer is capsules only, CanvasRenderer.swift:316-321). Pencil
pressure, tilt, double-tap and squeeze are unused; hover only drives the Pen cursor (DrawingEditor.swift:211).
The skeleton (milestone 4) isn't started, so now is the cheap moment to shape the editor so parts deform and
swap well later.

## Tier 1: everyday editing gaps (next editor milestone, mostly S-M, no format change)

1. **Shape tools (M).** Rectangle/rounded rect, ellipse, polygon/star, line, each producing an ordinary
   `BezierPath`. Plus **QuickShape**: hold the Pencil still at the end of a stroke to snap it to a line, arc,
   ellipse or rectangle. *Rig:* limbs and joints are mostly capsules and circles; clean primitives give
   predictable pivots.
2. **Duplicate, copy, paste (S-M).** Cmd-D, Option-drag (or modifier strip) to duplicate; copy/paste of shapes
   and parts using the file format's own JSON on the pasteboard, so paste works across documents. *Rig:* draw
   one hand, paste it as the other.
3. **Arrange within and between parts (S).** Bring forward/backward/front/back for shapes inside a part; move
   shapes to another part; merge and split parts. Today the only order is part order in the layers tree.
4. **Hide, lock and isolate (S-M).** Per part and per shape. **Isolation mode**: double-tap a part to edit only it
   with the rest dimmed and untouchable. *Rig:* overlapping limbs make tapping the right shape the main daily
   friction once a character is assembled. Store hide/lock as optional editor hints (no version bump).
5. **Eraser, scissors, knife (S to L).** Vector eraser that deletes the shapes it crosses (S); scissors that
   split a path mid-segment by reusing `insertPoint` + `splitAtSelectedAnchor` (S); knife that cuts a closed
   shape in two along a Pencil stroke (L, needs Tier 3 booleans).
6. **Pencil-native controls (S-M, pulled forward from milestone 6).** Double-tap switches to the last tool or
   to eraser (respect `preferredTapAction`); squeeze opens a radial palette (tools, recent colors, undo);
   hover shows brush size and highlights the shape/anchor that would be hit in every tool, not just Pen;
   barrel roll rotates the rotate handle or polygon tool. Cheap because hover is already plumbed.
7. **Smoothing and simplify (S-M).** Live stabilizer on Pencil strokes (from recommendations #10) and a
   Simplify command with a slider that refits a selection with fewer anchors. *Rig:* fewer, well-placed anchors
   deform more cleanly when weights arrive.
8. **Keyboard and modifier strip (S).** V/A/P/N/M/L/E tool keys, Delete, Cmd-Z/Shift-Cmd-Z/D/C/V/G, arrows,
   Space-drag pan, and a small floating Shift/Option strip for constraint and duplicate without a keyboard.

## Tier 2: appearance (one format bump to 0.2, done as a batch)

Group these so the schema changes once. Each new key optional, `CharacterFormat.migrations` gets a 0.1 to 0.2
step, and the example and schema update together (per CLAUDE.md).

9. **A real stroker (M-L, prerequisite).** Replace round-cap capsules with a polyline stroker that supports
   caps (butt/round/square), joins (miter/round/bevel) and miter limit. Needed by everything below.
10. **Variable-width strokes from Pencil pressure (M).** Store width as a per-anchor multiplier on the path
    (`w` on each point) rather than outlining the stroke into a filled shape. *Rig:* a width profile on the
    centerline keeps the line weight correct when a bone bends the path; an outlined shape would smear.
    This is the single most "drawn by hand" upgrade for character line art.
    **Decision:** pressure-to-width is an optional toggle, off by default; uniform width stays the
    default stroke.
11. **Clipping inside a part (M).** Mark a shape as a clip; shapes above it in the same part draw only inside
    it. *Rig:* this is how cutout characters do shading and highlights: paint a shadow loosely over the arm
    and it stays clipped to the arm in every pose. Higher value per effort than gradients.
12. **Gradients and opacity (M).** Linear and radial fills with stops, defined in the shape's local space so
    they rotate with the part; per-shape opacity. Skip blend modes for now.
13. **Dashes and stroke alignment (S once 9 exists).** Dash pattern; inside/center/outside alignment.
14. **Global colors (S-M).** Named palette entries that shapes reference, so recoloring a character (or a
    costume variant) is one edit. Fits the existing `palette` key.

## Tier 3: construction (core geometry library, L)

15. **Boolean operations (L).** Union, subtract, intersect, exclude, divide. Needs a polygon clipper in
    CharacterCore (Foundation only, so written in-house or ported, with tests on Linux), then `CurveFitter`
    to refit curves. Unlocks the knife (#5) and the two items below.
16. **Shape builder with the Pencil (M once 15 exists).** Scribble across overlapping regions to merge them,
    Option-scribble to remove. Far more natural on iPad than picking two shapes and a menu command.
17. **Offset path and outline stroke (M once 15 exists).** For making a cast shadow or a thick outer contour
    from a silhouette.

## Tier 4: character and rig aware (the part no general vector app has)

These bridge directly into milestones 4-5 and are where the app earns its purpose.

18. **Mirror drawing and mirrored parts (M).** Live symmetry about a vertical axis while drawing, and
    "Duplicate Mirrored" that flips a part and renames `Arm.L` to `Arm.R`. *Rig:* consistent L/R naming lets
    the animation system mirror poses later.
19. **Joint-aware drawing (M).** For a part with a pivot, a **wiggle preview**: hold a button (or squeeze) and
    the part rocks ±30 degrees about its pivot while you keep editing, so you see gaps and overlaps at the
    joint before any bones exist. Plus a **joint cap** helper that adds a circle centered on the pivot sized
    to the limb, the standard fix for cutout elbows and knees.
20. **Swappable variants per part (M, format already allows it).** A part can hold several drawings (mouth
    shapes, hand poses, eye blinks) with one active; the format's `skins` and attachments already model this.
    Editor needs Add Variant, a variant strip on the part, and onion-skinning of the other variants. *Rig:*
    lip sync and hand poses are the most common animation swaps. *Shipped with milestone 6, along with skins
    (see the README's milestone 6 notes).*
21. **Pivot and bone handoff (S-M).** Pivot snaps to anchors, to the other part's pivot, and later to bone
    heads; shows the pivot in every tool when the part is selected. Makes milestone 4 bone placement fall out
    of work already done.
22. **Clean for rig (M).** As in vector-workflow.md #12: close stray gaps, consistent winding, resample
    long segments so weighted deformation has anchors to work with. Run it as a check that lists problems
    before applying fixes. *Shipped with milestone 7 (More > Clean for Rig).*

## Tier 5: workspace and interchange

23. **Outline view and onion/ghost overlays (S).** Wireframe toggle; dim everything but the selection.
24. **Character frame (S).** A ground line and a target bounds box so proportions are judged against the
    final frame.
25. **SVG import (M) and SVG/PNG export (M, planned for milestone 6).** Import lets art from Procreate,
    Illustrator or Affinity come in as editable parts. The parser belongs in CharacterCore with tests.

## Recommended order

1. **Editor completeness** (no format change): 1, 2, 3, 4, 6, 8, plus the S parts of 5 (eraser, scissors).
   Biggest felt improvement; all CharacterCore-testable.
2. **Appearance 0.2** in one bump: 9, then 10 and 11, then 12-14.
3. **Skeleton (milestone 4)**, bringing in 18, 19, 21 alongside bone drawing since they share the pivot work.
4. **Booleans and shape builder**: 15, 16, 17, then the knife from 5, and 22.
5. **Variants and interchange**: 20 with milestone 5's binding, 25 with milestone 6.

My call for the very next milestone is step 1. If one appearance feature is wanted sooner, take
**clipping (#11)** before gradients, and do **variable width (#10)** before the skeleton so the stroke model
is settled before deformation depends on it.

## Risks

- Undo stores whole `Drawing` snapshots; booleans and simplify on large selections are fine, but variants
  multiply drawing size, so watch snapshot cost once 20 lands.
- The stroker (9) is the riskiest renderer work: miter joins on tight curves and variable width need careful
  flattening tolerance at high zoom (same faceting issue as recommendations #3).
- Booleans in Foundation-only Swift must be robust to near-coincident edges; budget test time on degenerate
  inputs, since a bad result silently corrupts art.
