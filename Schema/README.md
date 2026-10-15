# Document file format (interim)

ControlFlow still saves to the Character Studio package format, format 0.3, until its own presentation format replaces it (milestone 3 of [the plan](../docs/plans/animation-app.md)). It writes only the parts of that format it still uses, and reads older character files with their rig, keeping only the art.

A document is a `.charstudio` package (a folder that Files shows as one document):

| File | What it is |
| --- | --- |
| `character.json` | The document. Validated by [`character-0.3.schema.json`](character-0.3.schema.json). |
| `thumbnail.png` | Optional 512 x 512 preview of the art. |
| `references/` | Pixels of editor-only reference images, named `reference-1.png`, `reference-2.jpg`, ... |

[`examples/robo.charstudio`](examples/robo.charstudio) is a complete example. The core tests check that the app re-saves it byte for byte, and CI validates it against the schema (`python Schema/validate.py`, which needs `pip install jsonschema`).

## Conventions

- Points, y-axis down. Angles in degrees, clockwise on screen. Colors are `#RRGGBBAA` sRGB with straight alpha.
- Numbers are written with at most 4 decimal places. Keys are written in a fixed order, so saving twice gives the same file.
- `formatVersion` is semantic. In 0.x a newer minor version may break compatibility, so the app refuses it. Older files are upgraded on open by the steps in `CharacterFormat.migrations`; a 0.1 or 0.2 file reads unchanged and is saved as 0.3.
- Readers should ignore keys they do not know.

## What the app writes

In this order:

- `formatVersion` and `name`, the presentation's name.
- `bones`: only `root`, with `parent: null`, `length: 0` and no transform, so every attachment is in world space.
- `slots`: one per layer, all on `root`. A slot's id is the layer's name, kept unique.
- `drawOrder`: slot ids from back to front.
- `skins.default[slot][slot]`: a `vector` attachment with the layer's `pivot`, an optional `transform`, its `groups` and its `shapes`, back to front. Attachments and shapes may carry `hidden: true` and `locked: true`, editor hints written only when set.
- A shape is `closed`, an optional `fill`, an optional `stroke` (`color`, `width`) and `points`. Each point has the anchor `p`, handles `in` and `out` as offsets from `p`, `smooth: false` on corner points, and `symmetric: true` on points whose handles are kept equally long.
- `palette`: reusable colors. Plain `#RRGGBBAA` strings come first, then global colors as `{ "name", "color" }`.
- `references`: editor-only reference images, bottom to top, with placement (`x`, `y` center, `rotation`, `scale`), `opacity` and `hidden`.
- `viewport`: the stage the presentation shows, `{ "width", "height", "background" }`. Its top-left is at the world origin. It is the area the editor exports and the area outside it is dimmed while editing. A file without it opens with 1920 x 1080 on white.

## Reading older files

Character Studio files can hold a skeleton, poses, weights, parameters, keyforms, accessories, variants, skins, switches, deformers and a character frame. ControlFlow opens them with each layer's art placed where the bones put it at rest, in world space, and drops the rest: only the default skin's shown attachment of each slot is read, accessories become plain layers, keyforms and weights are ignored, and `frame` is ignored. Saving writes the subset above.

## Appearance (0.2)

Every key here is optional and written only when it differs from its default, so a shape that uses none of them looks exactly like a 0.1 shape.

- **Outline options** on `stroke`: `cap` (`butt`, `round`, `square`; default `round`), `join` (`miter`, `round`, `bevel`; default `round`), `miterLimit` (in half-widths; default 4), `dash` (dash and gap lengths in points, alternating from a dash; an odd list repeats twice), `dashOffset`, and `align` (`center`, `inside`, `outside`; closed paths only, default `center`).
- **Variable width**: a point's `w` multiplies the stroke `width` there, blended linearly along each segment (default 1). The width lives on the path's centerline, not as an outlined shape.
- **Unstroked edges**: `stroked: false` on a point leaves the segment from that point to the next without an outline, while the fill still covers it (default true). The outline is drawn as separate open runs over the stroked segments, each ending in the stroke's `cap`, and dashes start afresh on each run. On an open path the last point's flag is ignored.
- **Gradients**: `gradient` replaces a shape's solid `fill` with `{ "type", "start", "end", "stops" }`. `linear` runs from `start` to `end`; `radial` runs from `start` (the center) out to the circle through `end`. Stops are `{ "offset", "color" }`, interpolated in straight alpha. The points are in the attachment's space, so the gradient moves, turns and scales with the shape. `fill` stays as the color for readers without gradients (the app keeps it equal to the first stop).
- **Opacity**: `opacity` (0 to 1) multiplies the alpha of the fill and of the outline, each on its own.
- **Clipping**: a shape with `clipped: true` draws only where the nearest unclipped shape below it in the same attachment draws (its fill and outline), like a clipping mask. Several clipped shapes in a row share that base. A clipped shape with nothing below it draws unclipped. In a [group](#groups), the base is looked for only within the group, so a clipped shape at the bottom of its group draws unclipped. Outside a group, the shapes of a clipped group count as clipped, so a clipped shape above a clipped group shares the group's base.
- **Global colors**: `fillGlobal` on a shape and `global` on a stroke name a global color in `palette`. `fill` and `color` still hold the current value, so readers that ignore global colors draw the same thing; the editor changes every follower when the global color changes.

## Transforms

ControlFlow's layers, groups and shapes each have a transform, saved as an optional `transform` object on the attachment, on a group and on a shape. These keys are new in ControlFlow; the version stays 0.3, and a file without them reads as before.

- `transform` is `{ "position", "rotation", "scale", "pivot" }`: the object scales by `scale` and turns by `rotation` (degrees, clockwise) about `pivot`, then moves by `position`. As a matrix, `translate(position + pivot) · rotate(rotation) · scale(scale) · translate(-pivot)`.
- They compose layer, then group, then shape, and a shape's `points` (and its gradient) are in the shape's own space, before its transform. An outline's width scales with the transform as the art does.
- `transform` is written only when it moves something, and each key only when it isn't its default (`[0, 0]`, `0`, `[1, 1]`, `[0, 0]`). A layer's transform has no `pivot`: its pivot is the attachment's `pivot`.
- `rotation` is not wrapped, so `720` is two turns, and a negative `scale` flips.

## Groups

Added after 0.2 shipped, as optional keys, so the version stays 0.2. Both are written only when a part has groups.

- `groups` on a vector attachment lists the attachment's groups of shapes as `{ "id", "name" }`, bottom to top, with `"clipped": true` on a clipped group. Ids are whole numbers local to the attachment; the app numbers them from 1.
- `group` on a shape names the group it belongs to. A group's shapes are next to each other in `shapes`, and groups don't nest.
- Groups only say which shapes belong together for editing; they don't change how anything draws, except that a clipped shape looks for its base only within its group (see Clipping above), and a clipped group draws as a whole inside its base. Readers that ignore `groups` and `group` draw the same picture as long as no group is clipped.
- **Clipped groups**: a group with `clipped: true` draws only where the nearest shape below the group that isn't clipped (or in another clipped group) draws, its fill and outline, as if each of its shapes were clipped to that base. Clipping inside the group still works: a clipped shape in the group draws inside both its base in the group and the group's base. A clipped group with nothing below it draws unclipped, and one whose base is hidden is hidden too.
- Readers should treat a shape naming an unknown group as ungrouped, and drop groups no shape uses. The app reads a group whose shapes are not next to each other as one group per run of shapes, each with the group's name. Two groups with the same id in one attachment are an error.
