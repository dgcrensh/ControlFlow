# Images

Draft 1, 2026-10-15. Pictures placed in a presentation as objects whose opacity, place and size animate between keyframes, as the user asked. The forks were settled with these defaults: images come in from Photos or Files through More > Insert Image, are stored once each in the package by a hash of their bytes, and the web export copies them beside the page.

## Status

**Shipped:**

- `ShapeImage` and `ImageAssets` (`Image.swift`), `VectorShape.image`, `imagePlacement` and `hasEditablePath`, `Presentation.imageSources`, and `DrawingEditor.addImage` (`DrawingEditor+Image.swift`).
- The canvas (an image cover step in `ArtBuilder` and the `image_cover_fragment` shader), thumbnails and PNG export, SVG export (embedded as data URLs), the HTML export and `player.js`.
- Format 1.2 (`image` on shapes), the schema, `Schema/README.md`, the example's picture and the test vectors.

**Later:** cropping (a frame smaller than the picture, edited with Direct Select), replacing a picture in place, pasting a picture from the pasteboard as an image, SVG `<image>` import, and dropping a picture on the canvas as an image rather than a reference.

## Design

### The object

An image is a **`VectorShape` with an `image` payload and a closed path of four corners**, rather than a new node kind, as text is a shape with a `text` payload. It reuses everything a shape has: its id, layer and group membership, draw order, transform, opacity, outline, clipping, hide and lock, selection, the Layers panel, copy and paste, and undo.

- `image` is `ShapeImage { src }`, the package path of the encoded picture.
- The path's points are the frame's top-left, top-right, bottom-right and bottom-left corners. The picture's unit square maps onto the parallelogram of points 0, 1 and 3 (`imagePlacement`). Every transform the app applies is affine, so the frame stays a parallelogram and the picture fills it exactly.
- Unlike text, the geometry is real points rather than laid out, so baking transforms (Apply Transform, moving between layers, `Drawing.world`) needs nothing special. The corners aren't edited one by one: `hasEditablePath` is false for images and text, which keeps Direct Select's anchors, the scissors and `setWorldPath` off them.
- An image has no fill (`visibleFill` is nil); its picture is drawn where the fill would be, under its outline.

### Keyframes

Images fit the delta model with no new kinds of change:

| Property | How it animates |
| --- | --- |
| Place, size and turn (transform, or the corners themselves) | Lerped, as for any shape. Select's handles change the transform, so scaling and moving animate smoothly. |
| Opacity | Lerped. Fading in is opacity 0 at one keyframe and 1 at the next. |
| `image.src` | Snaps at the start of the transition. |

### Storage

- Pictures live in the package's `images/` folder, named by a 64-bit FNV-1a hash of their bytes and their type's extension (`ImageAssets.path(for:)`). The same picture inserted twice is one file, and a name always means the same pixels, in any document.
- `PresentationPackage.images` holds them by `src`; only those some keyframe shows (`Presentation.imageSources`) are written.
- In the app, `ImageLibrary` holds the pictures of every open document by `src`, so pasting an image into another document keeps its picture, and the renderer and thumbnails find pixels there.
- Inserted pictures are normalized as reference images are: orientation baked in, at most 4096 pixels on the long side, PNG when they have transparency and JPEG otherwise.

### Rendering

- **Canvas:** an image is stencilled like a fill, then a cover step samples its texture through `ArtImage.worldToImage`, so clipping, ghosting, isolation and live drags work unchanged. Until the texture loads (or if the file is missing) the cover paints a faint gray placeholder, which also clears the stencil as every cover must.
- **Thumbnails and PNG export:** Core Graphics clips to the frame and draws the picture through the placement.
- **SVG export:** `<image width="1" height="1" preserveAspectRatio="none" transform="matrix(...)">` with the bytes as a data URL.
- **HTML export:** the pictures are copied to their `src` beside `presentation.json`, and `player.js` draws the same `<image>` linking to them.

### File format 1.2

`image` is an optional key on shapes, `{ "src": "images/<hash>.<ext>" }`, so 1.0 and 1.1 files are valid 1.2 files and no migration step is needed. A reader that doesn't know `image` sees a closed shape without a fill and draws only its outline, if any.
