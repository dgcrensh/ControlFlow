import Foundation

/// A stencil comparison, as Metal defines it: the test passes when
/// `(reference & readMask) <op> (stored & readMask)`.
public enum StencilCompare: Hashable, Sendable {
    case always, equal, notEqual, less
}

public enum StencilOperation: Hashable, Sendable {
    case keep, zero, replace, incrementWrap, decrementWrap
}

/// One depth-stencil configuration. Front faces (counter-clockwise on a y-up plane)
/// use `pass`; back faces use `backPass`. Only bits in `writeMask` change.
public struct StencilState: Hashable, Sendable {
    public var compare: StencilCompare
    public var readMask: UInt8
    public var writeMask: UInt8
    public var pass: StencilOperation
    public var backPass: StencilOperation
    public var fail: StencilOperation

    public init(compare: StencilCompare, readMask: UInt8 = 0xFF, writeMask: UInt8, pass: StencilOperation,
                backPass: StencilOperation? = nil, fail: StencilOperation = .keep) {
        self.compare = compare
        self.readMask = readMask
        self.writeMask = writeMask
        self.pass = pass
        self.backPass = backPass ?? pass
        self.fail = fail
    }
}

/// How the art uses the 8-bit stencil buffer:
///
/// - bits 0-4: the fill's winding number (modulo 32) while a fill is being drawn;
/// - bit 5: the group mask, where a clipped group's base drew, while the group draws;
/// - bit 6: "the outline covers this sample" while an outline is being drawn;
/// - bit 7: the clip, where the current clip base drew.
///
/// Every paint step leaves bits 0-4 and 6 clear again, so the next shape starts clean,
/// and the group mask is cleared when its group ends.
public enum ArtStencil {
    public static let windingBits: UInt8 = 0x1F
    public static let maskBit: UInt8 = 0x20
    public static let outlineBit: UInt8 = 0x40
    public static let clipBit: UInt8 = 0x80
    static let workBits: UInt8 = 0x5F

    /// Fan triangles add their winding into bits 0-5.
    public static let winding = StencilState(compare: .always, writeMask: windingBits,
                                             pass: .incrementWrap, backPass: .decrementWrap)
    /// Outline triangles set bit 6 (reference `outlineBit`), however often they overlap.
    public static let outline = StencilState(compare: .always, writeMask: outlineBit, pass: .replace)
    /// Clears the clip bit everywhere before a new clip base.
    public static let clearClip = StencilState(compare: .always, writeMask: clipBit, pass: .zero)
    /// Clears the winding and outline bits after a clip base's outline when it can leave
    /// them set.
    public static let cleanUp = StencilState(compare: .always, writeMask: workBits, pass: .zero)
    /// At the start of a clipped group: the group mask becomes the clip its base drew
    /// (reference `clipBit | maskBit`), so clip bases inside the group can reuse the clip.
    public static let copyClipToMask = StencilState(compare: .equal, readMask: clipBit, writeMask: maskBit,
                                                    pass: .replace, fail: .zero)
    /// At the end of a clipped group: the clip becomes the group's base again, for the
    /// clipped shapes above the group, and the mask is cleared (reference `clipBit`).
    public static let restoreClip = StencilState(compare: .notEqual, readMask: maskBit, writeMask: clipBit | maskBit,
                                                 pass: .replace, fail: .zero)
}

/// How a shape takes layer in clipping.
public enum ClipRole: Hashable, Sendable {
    case none
    /// Draws, and marks the clip where it draws.
    case base
    /// Draws only where the clip is marked.
    case clipped
}

/// What a cover step paints.
public struct ArtPaint: Hashable, Sendable {
    public var color: RGBAColor
    public var gradient: ShapeGradient?
    public var opacity: Double
    /// An image shape's picture, painted instead of `color` when the renderer has its
    /// pixels; `color` is then what shows while they are missing.
    public var image: ArtImage?

    public init(color: RGBAColor, gradient: ShapeGradient? = nil, opacity: Double = 1, image: ArtImage? = nil) {
        self.color = color
        self.gradient = gradient
        self.opacity = opacity
        self.image = image
    }

    /// What an image shape shows where its pixels are missing.
    public static let missingImage = RGBAColor(r: 0.5, g: 0.5, b: 0.5, a: 0.25)

    /// The straight-alpha color at `p`, opacity applied. Like the GPU, the gradient sees
    /// the point in the space the step's vertices are in (see `ArtStep.place`).
    public func color(at p: Vec2) -> RGBAColor {
        var c = gradient.map { $0.color(at: $0.parameter(at: p)) } ?? color
        c.a *= min(max(opacity, 0), 1)
        return c
    }
}

/// An image painted by a cover step: its pixels' `src` and where they go.
public struct ArtImage: Hashable, Sendable {
    public var src: String
    /// Maps a point in the space of the step's vertices (see `ArtStep.place`) to the
    /// image's unit square (x across, y down, 0...1), the texture coordinate to sample there.
    public var worldToImage: Affine2D

    public init(src: String, worldToImage: Affine2D) {
        self.src = src
        self.worldToImage = worldToImage
    }
}

/// One draw in the art pass. Vertex ranges index `ArtBatch.vertices` (in points), which
/// are in the space `place` and the segment's `transform` map to the world.
public enum ArtStep: Hashable, Sendable {
    /// Triangles that only change the stencil.
    case stencil(vertices: Range<Int>, state: StencilState, reference: UInt8)
    /// A rectangle (two triangles) painted with `paint` where the stencil test passes.
    case cover(vertices: Range<Int>, paint: ArtPaint, state: StencilState, reference: UInt8)
    /// A stencil-only pass over the whole view. Clearing the clip uses a rectangle
    /// (`stencil`) instead, except while a live transform moves the shapes involved.
    case stencilView(state: StencilState, reference: UInt8)
    /// Dims everything drawn so far: the layers outside isolation.
    case veil
    /// The `stencil` and `cover` steps that follow draw shapes a live transform is
    /// moving (true) or not (false): the renderer applies the transform to them, so a
    /// drag needs no rebuild. See `DrawingEditor.liveTransform`.
    case moving(Bool)
    /// The `stencil` and `cover` steps that follow, until the next `place`, have their
    /// vertices (and their paint's gradient and image) in a space this matrix maps into
    /// the segment's space: a shape tessellated in its own space, placed by its group and
    /// shape transforms. Each segment starts with the identity.
    case place(Affine2D)
}

/// The art ready for the GPU: triangles and the steps that draw them. Each segment's
/// triangles are in its layer's space, which `ArtSegment.transform` maps to the world.
public struct ArtBatch: Hashable, Sendable {
    /// Two floats (x, y) per vertex. Empty when the builder doesn't concatenate them
    /// (`ArtBuilder.concatenatesVertices`); the segments still hold every layer's floats.
    public var vertices: [Float] = []
    public var steps: [ArtStep] = []
    /// One per layer in the draw stack, in order: which steps and vertices it drew.
    public var segments: [ArtSegment] = []
    /// Layers a build `leavingOutUncached` left out because a shape had no tessellation yet.
    public var layersLeftOut = 0

    public var vertexCount: Int { vertices.count / 2 }
}

/// One layer's share of an `ArtBatch`, so the renderer can keep each layer's vertices in
/// its own GPU buffer and upload only the layers an edit changed.
public struct ArtSegment: Hashable, Sendable {
    /// Names these vertices: a segment in a later batch from the same `ArtBuilder` with
    /// the same id has the same `floats`. Never reused by that builder.
    public var id: Int
    /// The layer (its id in the drawing) whose art this is.
    public var layer: Int
    /// The layer's vertices, in the batch's vertex numbering.
    public var vertices: Range<Int>
    /// The layer's steps, as indices into `ArtBatch.steps`.
    public var steps: Range<Int>
    /// The layer's vertices, two floats each (shared with the builder's cache, not copied).
    public var floats: [Float]
    /// Maps the layer's vertices (and its `place` steps' spaces) to the world: the layer's
    /// transform, which moving the layer changes without changing `id` or `floats`.
    public var transform: Affine2D = .identity

    /// `range` (from one of this segment's steps) counted from the segment's first vertex,
    /// for drawing from a buffer that holds only `floats`.
    public func local(_ range: Range<Int>) -> Range<Int> {
        (range.lowerBound - vertices.lowerBound)..<(range.upperBound - vertices.lowerBound)
    }
}

extension ArtBatch {
    /// The segments whose vertices aren't in a GPU buffer yet: those with vertices whose
    /// id isn't in `resident`. After one edit that is the edited layer's segment only.
    public func segmentsToUpload(resident: Set<Int>) -> [ArtSegment] {
        segments.filter { !$0.floats.isEmpty && !resident.contains($0.id) }
    }

    /// The ids whose buffers this batch draws from; buffers for any other id can go.
    public var residentIDs: Set<Int> {
        Set(segments.lazy.filter { !$0.floats.isEmpty }.map(\.id))
    }
}

extension ArtStep {
    /// The same step with its vertex range moved by `offset`.
    func offset(by offset: Int) -> ArtStep {
        switch self {
        case .stencil(let range, let state, let reference):
            .stencil(vertices: (range.lowerBound + offset)..<(range.upperBound + offset), state: state, reference: reference)
        case .cover(let range, let paint, let state, let reference):
            .cover(vertices: (range.lowerBound + offset)..<(range.upperBound + offset), paint: paint, state: state,
                   reference: reference)
        case .stencilView, .veil, .moving, .place:
            self
        }
    }
}

/// A shape as the art draws it (see `ArtBuilder.artShape(_:of:placement:tolerance:)`):
/// `shape` in the space its triangles are made in, usually its own; `place`, which maps
/// that space to its layer's segment space; and the tolerance it is flattened at there.
public struct ArtShape: Sendable {
    public var shape: VectorShape
    public var place: Affine2D
    public var tolerance: Double

    public var id: Int { shape.id }
}

/// How a layer's art reaches the world (see `ArtBuilder.placement(of:)`).
struct LayerPlacement: Sendable {
    /// Maps the layer's vertices to the world: `ArtSegment.transform`.
    var segment: Affine2D
    /// The layer's transform, when its shapes take it into their points instead: one that
    /// would stretch the layer's outlines unevenly.
    var baked: Affine2D?
    /// How much `segment` enlarges the art, as a power of two (see `ArtBuilder.detail(of:)`).
    var detail: Double
}

/// Builds the art pass for a drawing and keeps each shape's triangles until that
/// shape (or the flattening tolerance) changes, so an edit re-tessellates only the
/// shapes it touches. It also keeps each layer's finished steps and vertices, so an edit
/// rebuilds only the layers it touches and the rest are copied as they are.
///
/// Each shape is tessellated in its own space and drawn through its group and shape
/// transforms (`ArtStep.place`) and its layer's (`ArtSegment.transform`), which the GPU
/// applies. So moving, turning or scaling a shape, a group or a layer flattens nothing
/// again, and a transition that slides the whole stage draws every frame from the same
/// triangles: a layer whose transform alone changed reuses its steps and its buffer.
/// Only a transform that would stretch an outline unevenly (a stretch or a skew of a
/// shape with an outline) is baked into the points instead. A shape is flattened at the
/// art's tolerance divided by how much its transforms enlarge it, rounded up to a power
/// of two, so a scale tween flattens it again only once per doubling.
///
/// Each fill is drawn with stencil-then-cover: its fan marks winding numbers, then a
/// rectangle over it paints where the winding is non-zero, which fills any outline
/// (self-intersecting or not) without triangulating it. Each outline marks the
/// stroker's triangles, then paints the marked area once. Inside and outside outlines
/// are stroked twice as wide and then kept only where the path's own winding is
/// non-zero (inside) or zero (outside). A clip base also sets the clip bit where it
/// paints; clipped shapes paint only where that bit is set. A clipped group copies its
/// base's clip into the mask bit as it starts, and its shapes paint only where that bit
/// is set; clipped shapes inside it then clip to bases that only drew within the mask.
public struct ArtBuilder: Sendable {
    struct Tessellation: Sendable {
        var shape: VectorShape
        var tolerance: Double
        /// Fan over the flattened path (closed paths only), two floats per vertex, and its bounds.
        var fan: [Float]
        var fanBounds: Rect
        /// Outline triangles, two floats per vertex, and their bounds.
        var outline: [Float]
        var outlineBounds: Rect

        /// What the cache counts against its second-tier limit.
        var vertexCount: Int { (fan.count + outline.count) / 2 }

        /// The triangles are those of `shape` too: it has the same id and path, and its
        /// outline has the same geometry. Paint (fill, gradient, opacity, image and outline
        /// color) plays no part in them; `tessellate` reads only the path and the outline.
        /// Nor does the shape's transform, which places the triangles (see `ArtShape`).
        func matches(_ shape: VectorShape) -> Bool {
            self.shape.id == shape.id && self.shape.path == shape.path && Self.sameOutline(self.shape.stroke, shape.stroke)
        }

        private static func sameOutline(_ a: StrokeStyle?, _ b: StrokeStyle?) -> Bool {
            guard let a, let b else { return a == nil && b == nil }
            return a.width == b.width && a.cap == b.cap && a.join == b.join && a.miterLimit == b.miterLimit &&
                a.dash == b.dash && a.dashOffset == b.dashOffset && a.alignment == b.alignment
        }
    }

    /// What one layer's steps and vertices depend on besides its shapes' tessellations:
    /// a layer whose key is unchanged reuses its `LayerBatch`. Comparing the shapes is a
    /// pointer compare for an untouched layer, whose array shares storage with the last one.
    /// The layer's own transform is not in it, only what it does to the build: moving the
    /// layer changes only its segment's `transform`.
    struct LayerKey: Equatable, Sendable {
        var shapes: [VectorShape]
        var groups: [ShapeGroup]
        var isHidden: Bool
        var tolerance: Double
        var isIsolated: Bool
        /// The isolated group, when this is the isolated layer and has that group.
        var isolatedGroup: Int?
        /// The ghost focus and the moving set, restricted to this layer's shapes.
        var ghostFocus: Set<Int>?
        var moving: Set<Int>
        /// `LayerPlacement.baked` and `detail`.
        var bakedLayer: Affine2D?
        var detail: Double
    }

    /// One layer's steps, with vertex ranges counted from the start of its own `vertices`.
    /// Each starts and ends with `moving` off, and starts with `place` the identity.
    struct LayerBatch: Sendable {
        var key: LayerKey
        var id: Int
        /// Every shape was drawn at its tolerance. A layer built while a refine was under
        /// way may hold shapes at an older tolerance; it is rebuilt rather than reused, so
        /// it picks up the refined shapes once they are merged.
        var isExact: Bool
        var vertices: [Float]
        var steps: [ArtStep]
    }

    /// Each layer's last build, by layer id.
    private var layerCache: [Int: LayerBatch] = [:]
    private var nextLayerBatchID = 1
    /// How many layer batches have been built rather than reused, for tests.
    private(set) var layerBuilds = 0
    /// How many shapes have a cached tessellation, for tests.
    var cachedShapeCount: Int { tessellations.count }
    /// Each shape's tessellation. Public so the renderer can refine a copy in the
    /// background and merge the result (see `TessellationCache`).
    public var tessellations = TessellationCache()
    /// While building: use a cached tessellation of an unchanged shape at any tolerance
    /// rather than tessellating it again.
    private var reusesOtherTolerances = false
    /// How many shapes builds have tessellated, for tests.
    var tessellationCount = 0
    /// Set while building a layer when a shape used a tessellation at another tolerance.
    private var usedOtherTolerance = false
    /// Builds the steps without writing any vertices (their ranges are empty), so
    /// `ScalingTests` can time the cache walk apart from the vertex appends.
    var skipsVertices = false
    /// Concatenates every layer's floats into `ArtBatch.vertices`. A renderer that uploads
    /// the segments one by one turns it off and skips the copy.
    public var concatenatesVertices = true
    /// While building a layer: the shapes to mark as moving, and whether the last mark was
    /// on; and the last `place`.
    private var moving: Set<Int> = []
    private var isMoving = false
    private var place = Affine2D.identity

    /// How strongly the ghost view draws the shapes outside its focus.
    public static let ghostOpacity = 0.25

    public init() {}

    /// The isolated layer draws on top of a veil over everything else; with an
    /// `isolatedGroup` in it, only that group does, and the rest of the layer stays under
    /// the veil. With a `ghostFocus` (shape ids), every other shape draws at `ghostOpacity`.
    /// The shapes in `moving` are bracketed by `.moving` steps.
    ///
    /// With `reusingOtherTolerances`, an unchanged shape cached at another tolerance
    /// keeps that tessellation; only new and edited shapes are tessellated, at their
    /// tolerance. The renderer builds that way while a background refine is under way.
    ///
    /// With `leavingOutUncached`, a layer with a shown shape that has no tessellation at
    /// any tolerance is left out rather than tessellated, and counted in `layersLeftOut`.
    /// The renderer's first builds after opening a document do this while a refine job
    /// tessellates the drawing, the layers in view first, so the first frame shows
    /// without waiting for every shape to be flattened. A whole layer is left out, never
    /// some of its shapes, so a clipped shape never paints without its base.
    public mutating func build(_ drawing: Drawing, isolatedLayer: Int?, isolatedGroup: Int? = nil, tolerance: Double,
                               ghostFocus: Set<Int>? = nil, moving: Set<Int> = [],
                               reusingOtherTolerances: Bool = false, leavingOutUncached: Bool = false) -> ArtBatch {
        var batch = ArtBatch()
        reusesOtherTolerances = reusingOtherTolerances
        defer { reusesOtherTolerances = false }
        var layers = drawing.layers
        if let isolatedLayer {
            layers = layers.filter { $0.id != isolatedLayer } + layers.filter { $0.id == isolatedLayer }
        }
        var seen: Set<Int> = []
        // The shapes of layers rebuilt or gone, and of the rebuilt layers as they are now:
        // the difference has left the drawing, so its tessellations can go.
        var retired: Set<Int> = [], fresh: Set<Int> = []
        for layer in layers {
            let slot = layer.id
            seen.insert(slot)
            let placement = Self.placement(of: layer)
            // Left out before its cache is looked at, so a layer built earlier and edited
            // since keeps its cache entry (and its shapes' tessellations) for when it is ready.
            if leavingOutUncached, !isTessellated(layer, placement: placement, tolerance: tolerance) {
                batch.layersLeftOut += 1
                continue
            }
            let isolated = layer.id == isolatedLayer
            let key = LayerKey(shapes: layer.shapes, groups: layer.groups, isHidden: layer.isHidden, tolerance: tolerance,
                              isIsolated: isolated,
                              isolatedGroup: isolated ? isolatedGroup.flatMap { layer.group($0) == nil ? nil : $0 } : nil,
                              ghostFocus: ghostFocus.map { Self.restrict($0, to: layer) },
                              moving: Self.restrict(moving, to: layer),
                              bakedLayer: placement.baked, detail: placement.detail)
            if let cached = layerCache[slot], cached.isExact, cached.key == key {
                batch.append(cached, layer: layer.id, transform: placement.segment, concatenating: concatenatesVertices)
                continue
            }
            if let old = layerCache[slot] { retired.formUnion(old.key.shapes.lazy.map(\.id)) }
            fresh.formUnion(layer.shapes.lazy.map(\.id))
            let built = buildLayer(layer, key: key, placement: placement)
            layerCache[slot] = built
            batch.append(built, layer: layer.id, transform: placement.segment, concatenating: concatenatesVertices)
        }
        for slot in Array(layerCache.keys) where !seen.contains(slot) {
            if let old = layerCache.removeValue(forKey: slot) { retired.formUnion(old.key.shapes.lazy.map(\.id)) }
        }
        for id in retired where !fresh.contains(id) { tessellations.remove(id) }
        return batch
    }

    // MARK: Placing shapes

    /// How `layer`'s art reaches the world. Its transform goes on the segment, applied by
    /// the GPU, unless it isn't a similarity and the layer has a shape that a stretch
    /// draws differently from its baked points (see `stretches(_:)`); then the shapes
    /// take it into their points.
    static func placement(of layer: Layer) -> LayerPlacement {
        guard !layer.transform.isIdentity else { return LayerPlacement(segment: .identity, baked: nil, detail: 1) }
        let m = layer.transform.matrix
        if m.isSimilarity || !layer.shapes.contains(where: stretchesUnlikeItsPoints) {
            return LayerPlacement(segment: m, baked: nil, detail: detail(of: m))
        }
        return LayerPlacement(segment: .identity, baked: m, detail: 1)
    }

    /// Shape `index` of `layer` as the art draws it, with `layer` placed by `placement`:
    /// in its own space, with its group and shape transforms as its `place`, or, where
    /// drawing it through them would differ from baking them (see
    /// `stretchesUnlikeItsPoints`), with them baked into its points. A text
    /// shape's glyphs are laid out (see `VectorShape.resolvingText()`). `tolerance` is the
    /// art's, in the world; the result's is in the shape's space.
    static func artShape(_ index: Int, of layer: Layer, placement: LayerPlacement, tolerance: Double) -> ArtShape {
        let shape = layer.shapes[index]
        var inner = Affine2D.identity
        if let id = shape.group, let group = layer.group(id), !group.transform.isIdentity { inner = group.transform.matrix }
        if !shape.transform.isIdentity { inner = inner * shape.transform.matrix }
        let r = placement.baked.map { $0 * inner } ?? inner
        if r == .identity {
            return ArtShape(shape: shape.resolvingText(), place: .identity, tolerance: tolerance / placement.detail)
        }
        if r.isSimilarity || !stretchesUnlikeItsPoints(shape) {
            return ArtShape(shape: shape.resolvingText(), place: r, tolerance: tolerance / detail(of: placement.segment * r))
        }
        return ArtShape(shape: shape.baked(r), place: .identity, tolerance: tolerance / placement.detail)
    }

    /// Every shape of `layer` as the art draws it at `tolerance` (see `artShape`), and
    /// the layer's segment transform.
    static func artShapes(of layer: Layer, tolerance: Double) -> (segment: Affine2D, shapes: [ArtShape]) {
        let placement = placement(of: layer)
        return (placement.segment,
                layer.shapes.indices.map { artShape($0, of: layer, placement: placement, tolerance: tolerance) })
    }

    /// True when drawing `shape` through a stretch or a skew looks different from baking
    /// it into the points, as the file and the exports do: an outline would widen
    /// unevenly (baking scales its width by the area), and a gradient's bands would lean
    /// (baking keeps them square to its axis, and a radial one round). Text has neither:
    /// its glyphs are filled only.
    private static func stretchesUnlikeItsPoints(_ shape: VectorShape) -> Bool {
        if shape.gradient != nil { return true }
        guard shape.text == nil, let stroke = shape.stroke else { return false }
        return stroke.width > 0
    }

    /// How much `m` enlarges what it maps at most (its larger singular value), rounded up
    /// to a power of two: a shape drawn through `m` is flattened at the art's tolerance
    /// divided by this, so it looks as smooth as it would flattened in place, and a scale
    /// that changes within one power of two keeps its triangles. 1 for a collapsed `m`.
    static func detail(of m: Affine2D) -> Double {
        let e = m.a * m.a + m.b * m.b + m.c * m.c + m.d * m.d, det = m.determinant
        let stretch = ((e + max(e * e - 4 * det * det, 0).squareRoot()) / 2).squareRoot()
        guard stretch > 1e-6, stretch.isFinite else { return 1 }
        // Slack, so a scale of 1 that rounding made 1.0000000001 stays 1.
        return pow(2, (log2(stretch) - 1e-9).rounded(.up))
    }

    /// True when every shown shape of `layer` has a cached tessellation, at any tolerance.
    private func isTessellated(_ layer: Layer, placement: LayerPlacement, tolerance: Double) -> Bool {
        layer.shapes.indices.allSatisfy {
            !layer.isShown($0) ||
                tessellations.anyTessellation(of: Self.artShape($0, of: layer, placement: placement, tolerance: tolerance).shape) != nil
        }
    }

    /// The ids in `set` that are shapes of `layer`.
    private static func restrict(_ set: Set<Int>, to layer: Layer) -> Set<Int> {
        guard !set.isEmpty else { return [] }
        var result: Set<Int> = []
        for shape in layer.shapes where set.contains(shape.id) { result.insert(shape.id) }
        return result
    }

    // MARK: Building a layer

    /// Draws one layer from scratch (its shapes' tessellations still come from the cache).
    private mutating func buildLayer(_ layer: Layer, key: LayerKey, placement: LayerPlacement) -> LayerBatch {
        layerBuilds += 1
        var batch = ArtBatch()
        moving = key.moving
        isMoving = false
        place = .identity
        usedOtherTolerance = false
        let arts = layer.shapes.indices.map { Self.artShape($0, of: layer, placement: placement, tolerance: key.tolerance) }
        let all = Array(layer.shapes.indices)
        if let group = key.isolatedGroup {
            let inGroup = all.filter { layer.shapes[$0].group == group }
            appendShapes(all.filter { layer.shapes[$0].group != group }, of: layer, arts: arts, skippingBases: Set(inGroup),
                         ghostFocus: key.ghostFocus, to: &batch)
            batch.steps.append(.veil)
            appendShapes(inGroup, of: layer, arts: arts, skippingBases: [], ghostFocus: key.ghostFocus, to: &batch)
        } else {
            if key.isIsolated { batch.steps.append(.veil) }
            appendShapes(all, of: layer, arts: arts, skippingBases: [], ghostFocus: key.ghostFocus, to: &batch)
        }
        if isMoving { batch.steps.append(.moving(false)) }
        moving = []
        isMoving = false
        place = .identity
        defer { nextLayerBatchID += 1 }
        return LayerBatch(key: key, id: nextLayerBatchID, isExact: !usedOtherTolerance, vertices: batch.vertices,
                         steps: batch.steps)
    }

    /// Adds the shapes at `indices` of `layer` (drawn as `arts`), leaving out clipped
    /// shapes and clipped groups whose base is in `skippingBases` (drawn in another pass,
    /// so there is nothing to clip to here). A clipped group whose base isn't in
    /// `indices` draws unclipped.
    private mutating func appendShapes(_ indices: [Int], of layer: Layer, arts: [ArtShape], skippingBases: Set<Int>,
                                       ghostFocus: Set<Int>?, to batch: inout ArtBatch) {
        let drawn = Set(indices)
        let clips = layer.clipPlan()
        // The clipped group whose mask is up.
        var masking: Int?
        for index in indices {
            let shape = layer.shapes[index]
            guard layer.isShown(index) else { continue }
            var mask = clips.groupBase(of: index)
            if let base = mask {
                guard layer.isShown(base), !skippingBases.contains(base) else { continue }
                if !drawn.contains(base) { mask = nil }
            }
            let group = mask == nil ? nil : shape.group
            if group != masking {
                if masking != nil { batch.steps.append(.stencilView(state: ArtStencil.restoreClip, reference: ArtStencil.clipBit)) }
                if group != nil {
                    batch.steps.append(.stencilView(state: ArtStencil.copyClipToMask,
                                                    reference: ArtStencil.clipBit | ArtStencil.maskBit))
                }
                masking = group
            }
            let role: ClipRole
            if let base = clips.base(of: index) {
                // Nothing to clip to when the base is hidden.
                guard layer.isShown(base), !skippingBases.contains(base) else { continue }
                role = .clipped
            } else {
                // A base whose clipped shapes draw in another pass needn't mark the clip.
                role = clips.isBase(index) && drawn.contains(index + 1) ? .base : .none
            }
            let geometry = tessellation(of: arts[index])
            let fade = ghostFocus.map { $0.contains(shape.id) ? 1 : Self.ghostOpacity } ?? 1
            let clear = role == .base ? clipArea(of: index, in: layer, arts: arts, clips: clips, drawn: drawn) : nil
            // A clipped shape in the group needs no mask: its base only drew inside it.
            append(arts[index], geometry, role: role, clipArea: clear, masked: mask != nil && role != .clipped, fade: fade,
                   to: &batch)
        }
        if masking != nil { batch.steps.append(.stencilView(state: ArtStencil.restoreClip, reference: ArtStencil.clipBit)) }
    }

    /// Where clearing the clip for base `index` matters, in the layer's space: the union
    /// of the cover rectangles of the shapes it clips, and of every shape in a clipped
    /// group on it, which test the clip (or the group mask copied from it) only inside
    /// them. Other shapes never read the clip bit, so a stale bit elsewhere does no harm.
    /// Nil while a live transform moves the base or a shape it clips, since the rectangle
    /// would have to move with some of them and not others; the clear then covers the view.
    private mutating func clipArea(of index: Int, in layer: Layer, arts: [ArtShape], clips: ClipPlan,
                                   drawn: Set<Int>) -> Rect? {
        guard !moving.contains(layer.shapes[index].id) else { return nil }
        var area = Rect.null
        func add(_ rect: Rect, through place: Affine2D) {
            area = area.union(place == .identity ? rect : Rect(points: rect.corners.map(place.apply)))
        }
        var j = index + 1
        while j < layer.shapes.count, clips.base(of: j) == index || clips.groupBase(of: j) == index {
            defer { j += 1 }
            let art = arts[j]
            guard layer.isShown(j), drawn.contains(j) else { continue }
            if moving.contains(art.id) { return nil }
            let geometry = tessellation(of: art)
            if art.shape.visibleFill != nil || art.shape.image != nil, !geometry.fan.isEmpty {
                add(geometry.fanBounds, through: art.place)
            }
            if art.shape.stroke != nil, !geometry.outline.isEmpty { add(geometry.outlineBounds, through: art.place) }
        }
        return area
    }

    private mutating func tessellation(of art: ArtShape) -> Tessellation {
        if let cached = tessellations.use(art.shape, tolerance: art.tolerance) { return cached }
        if reusesOtherTolerances, let cached = tessellations.anyTessellation(of: art.shape) {
            usedOtherTolerance = true
            return cached
        }
        let result = Self.tessellate(art.shape, tolerance: art.tolerance)
        tessellationCount += 1
        tessellations.store(result)
        return result
    }

    /// What `carry(_:to:tolerance:)` did.
    public struct Carry: Equatable, Sendable {
        /// Moved shapes that kept their tessellation.
        public var carried = 0
        /// Of those, the ones the drag enlarged, now coarser than the art's tolerance.
        public var coarse = 0
    }

    /// When a drag drawn through `live` ends, keeps the moved shapes' triangles for the
    /// art of `drawing` at `tolerance`. A drag changes transforms, not points, so a moved
    /// shape's triangles still fit it; only the tolerance it wants can change, when the
    /// drag scaled it across a power of two (see `detail(of:)`). A shrunk shape's finer
    /// triangles are stored at its new tolerance, so the next build draws it without
    /// flattening it again. An enlarged shape's are left coarser than it wants, as they
    /// looked during the drag, and counted as `coarse`: a build reusing other tolerances
    /// keeps them, and a refine replaces them. A shape whose drag was baked into its
    /// points (a stretched outline), or that the lift changed, is tessellated by the next
    /// build as usual.
    @discardableResult
    public mutating func carry(_ live: LiveTransform, to drawing: Drawing, tolerance: Double) -> Carry {
        var result = Carry()
        guard live.movesTessellation else { return result }
        for layer in drawing.layers where layer.shapes.contains(where: { live.shapes.contains($0.id) }) {
            let placement = Self.placement(of: layer)
            for index in layer.shapes.indices where live.shapes.contains(layer.shapes[index].id) {
                let art = Self.artShape(index, of: layer, placement: placement, tolerance: tolerance)
                if tessellations.tessellation(of: art.shape, tolerance: art.tolerance) != nil {
                    result.carried += 1
                    continue
                }
                guard var kept = tessellations.anyTessellation(of: art.shape) else { continue }
                result.carried += 1
                if kept.tolerance <= art.tolerance {
                    kept.tolerance = art.tolerance
                    tessellations.store(kept)
                } else {
                    result.coarse += 1
                }
            }
        }
        return result
    }

    /// Flattens and strokes one shape. Pure, so a background refine can call it.
    static func tessellate(_ shape: VectorShape, tolerance: Double) -> Tessellation {
        let poly = shape.path.flattened(tolerance: tolerance)
        var fan: [Float] = []
        if shape.path.closed, poly.count >= 3 {
            fan.reserveCapacity((poly.count - 2) * 6)
            for i in 1..<(poly.count - 1) {
                for p in [poly[0], poly[i], poly[i + 1]] {
                    fan.append(Float(p.x))
                    fan.append(Float(p.y))
                }
            }
        }
        var outline: [Vec2] = []
        if let stroke = shape.stroke, stroke.width > 0 {
            let aligned = shape.path.closed && stroke.alignment != .center
            outline = Stroker.triangles(for: shape.path, style: stroke, widthScale: aligned ? 2 : 1, tolerance: tolerance)
        }
        // Stored as floats, ready to copy: a layer's rebuild then converts nothing.
        var outlineFloats: [Float] = []
        outlineFloats.reserveCapacity(outline.count * 2)
        for p in outline {
            outlineFloats.append(Float(p.x))
            outlineFloats.append(Float(p.y))
        }
        let result = Tessellation(shape: shape, tolerance: tolerance, fan: fan, fanBounds: Rect(points: poly),
                                  outline: outlineFloats, outlineBounds: Rect(points: outline))
        return result
    }

    /// `clipArea` bounds the clip clear before a base (see `clipArea(of:in:arts:clips:drawn:)`),
    /// in the layer's space.
    private mutating func append(_ art: ArtShape, _ geometry: Tessellation, role: ClipRole, clipArea: Rect?,
                                 masked: Bool, fade: Double, to batch: inout ArtBatch) {
        let shape = art.shape
        let moves = moving.contains(shape.id)
        if moves != isMoving {
            batch.steps.append(.moving(moves))
            isMoving = moves
        }
        if role == .base {
            if let clipArea {
                // Nothing clipped draws: no clip to clear.
                if !clipArea.isNull {
                    setPlace(.identity, in: &batch)
                    batch.steps.append(.stencil(vertices: addRect(to: &batch, clipArea), state: ArtStencil.clearClip, reference: 0))
                }
            } else {
                batch.steps.append(.stencilView(state: ArtStencil.clearClip, reference: 0))
            }
        }
        setPlace(art.place, in: &batch)

        if let image = shape.image, !geometry.fan.isEmpty {
            // Stencilled like a fill, then covered with the picture.
            let fan = add(to: &batch, geometry.fan)
            batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            let cover = addRect(to: &batch, geometry.fanBounds)
            let (state, reference) = Self.fillCover(role, masked: masked)
            let placed = shape.imagePlacement?.inverted.map { ArtImage(src: image.src, worldToImage: $0) }
            let paint = ArtPaint(color: ArtPaint.missingImage, opacity: shape.opacity * fade, image: placed)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
        } else if let fill = shape.visibleFill, !geometry.fan.isEmpty {
            let fan = add(to: &batch, geometry.fan)
            batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            let cover = addRect(to: &batch, geometry.fanBounds)
            let (state, reference) = Self.fillCover(role, masked: masked)
            let paint = ArtPaint(color: fill, gradient: shape.gradient, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
        }

        if let stroke = shape.stroke, !geometry.outline.isEmpty {
            let alignment = shape.path.closed && !geometry.fan.isEmpty ? stroke.alignment : .center
            let marks = add(to: &batch, geometry.outline)
            batch.steps.append(.stencil(vertices: marks, state: ArtStencil.outline, reference: ArtStencil.outlineBit))
            if alignment != .center {
                let fan = add(to: &batch, geometry.fan)
                batch.steps.append(.stencil(vertices: fan, state: ArtStencil.winding, reference: 0))
            }
            let cover = addRect(to: &batch, geometry.outlineBounds)
            let (state, reference) = Self.outlineCover(role, alignment, masked: masked)
            let paint = ArtPaint(color: stroke.color, opacity: shape.opacity * fade)
            batch.steps.append(.cover(vertices: cover, paint: paint, state: state, reference: reference))
            if role == .base, alignment != .center || masked {
                batch.steps.append(.stencil(vertices: cover, state: ArtStencil.cleanUp, reference: 0))
            }
        }
    }

    /// Adds a `place` step when the shapes that follow are placed by another matrix.
    private mutating func setPlace(_ matrix: Affine2D, in batch: inout ArtBatch) {
        guard matrix != place else { return }
        batch.steps.append(.place(matrix))
        place = matrix
    }

    private func add(to batch: inout ArtBatch, _ points: [Float]) -> Range<Int> {
        skipsVertices ? batch.vertexCount..<batch.vertexCount : batch.add(points)
    }

    private func addRect(to batch: inout ArtBatch, _ rect: Rect) -> Range<Int> {
        skipsVertices ? batch.vertexCount..<batch.vertexCount : batch.addRect(rect)
    }

    /// The cover state for a fill: paint where the winding is non-zero, and with
    /// `masked`, only where the group mask is set.
    static func fillCover(_ role: ClipRole, masked: Bool = false) -> (StencilState, UInt8) {
        let clip = ArtStencil.clipBit, mask = ArtStencil.maskBit, winding = ArtStencil.windingBits
        let work = ArtStencil.workBits
        switch (role, masked) {
        case (.none, false):
            return (StencilState(compare: .notEqual, readMask: winding, writeMask: work, pass: .zero, fail: .zero), 0)
        case (.none, true):
            // (stored & 0x3F) > 0x20: the mask and a non-zero winding.
            return (StencilState(compare: .less, readMask: mask | winding, writeMask: work, pass: .zero, fail: .zero), mask)
        case (.clipped, _):
            // (stored & 0x9F) > 0x80: the clip bit and a non-zero winding.
            return (StencilState(compare: .less, readMask: clip | winding, writeMask: work,
                                 pass: .zero, fail: .zero), clip)
        case (.base, false):
            // Replace writes the clip bit and clears the winding.
            return (StencilState(compare: .notEqual, readMask: winding, writeMask: clip | work,
                                 pass: .replace, fail: .keep), clip)
        case (.base, true):
            // The clip was just cleared, so failing samples can be zeroed too.
            return (StencilState(compare: .less, readMask: mask | winding, writeMask: clip | work,
                                 pass: .replace, fail: .zero), clip | mask)
        }
    }

    /// The cover state for an outline: paint where it is marked, and for inside or
    /// outside outlines, only where the path's winding is non-zero or zero. With
    /// `masked`, only where the group mask is set.
    static func outlineCover(_ role: ClipRole, _ alignment: StrokeAlignment,
                             masked: Bool = false) -> (StencilState, UInt8) {
        let clip = ArtStencil.clipBit, mark = ArtStencil.outlineBit, work = ArtStencil.workBits
        let mask = masked ? ArtStencil.maskBit : 0
        switch (role, alignment) {
        case (.none, .center):
            return masked
                ? (StencilState(compare: .equal, readMask: mask | mark, writeMask: work, pass: .zero, fail: .zero), mask | mark)
                : (StencilState(compare: .notEqual, readMask: mark, writeMask: work, pass: .zero, fail: .zero), 0)
        case (.none, .inside):
            // (stored & 0x5F) > 0x40: marked, with a non-zero winding (and the mask).
            return (StencilState(compare: .less, readMask: mask | work, writeMask: work, pass: .zero, fail: .zero),
                    mask | mark)
        case (.none, .outside):
            return (StencilState(compare: .equal, readMask: mask | work, writeMask: work, pass: .zero, fail: .zero),
                    mask | mark)
        case (.clipped, .center):
            return (StencilState(compare: .equal, readMask: clip | mark, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.clipped, .inside):
            return (StencilState(compare: .less, readMask: clip | work, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.clipped, .outside):
            return (StencilState(compare: .equal, readMask: clip | work, writeMask: work, pass: .zero, fail: .zero),
                    clip | mark)
        case (.base, .center):
            if masked {
                // Writes the clip bit; the mark is cleared by a clean-up pass after.
                return (StencilState(compare: .equal, readMask: mask | mark, writeMask: clip | ArtStencil.windingBits,
                                     pass: .replace, fail: .keep), clip | mask | mark)
            }
            return (StencilState(compare: .notEqual, readMask: mark, writeMask: clip | work, pass: .replace, fail: .keep),
                    clip)
        case (.base, .inside):
            // Writes the clip bit; the mark and winding are cleared by a clean-up pass after.
            return (StencilState(compare: .less, readMask: mask | work, writeMask: clip | ArtStencil.windingBits,
                                 pass: .replace, fail: .keep), clip | mask | mark)
        case (.base, .outside):
            return (StencilState(compare: .equal, readMask: mask | work, writeMask: clip | ArtStencil.windingBits,
                                 pass: .replace, fail: .keep), clip | mask | mark)
        }
    }
}

extension ArtBatch {
    /// Appends a layer's batch as the next segment, placed in the world by `transform`,
    /// moving its vertex ranges past the vertices so far. A `moving(false)` ending the
    /// last layer and a `moving(true)` starting this one cancel out, as they would in one
    /// walk across both layers.
    mutating func append(_ layer: ArtBuilder.LayerBatch, layer id: Int, transform: Affine2D, concatenating: Bool) {
        let base = segments.last?.vertices.upperBound ?? 0
        var layerSteps = layer.steps[...]
        if case .moving(true)? = layerSteps.first, case .moving(false)? = steps.last, let last = segments.indices.last {
            steps.removeLast()
            segments[last].steps = segments[last].steps.lowerBound..<(segments[last].steps.upperBound - 1)
            layerSteps = layerSteps.dropFirst()
        }
        let firstStep = steps.count
        if base == 0 {
            steps.append(contentsOf: layerSteps)
        } else {
            steps.reserveAdditional(layerSteps.count)
            for step in layerSteps { steps.append(step.offset(by: base)) }
        }
        if concatenating { vertices.append(contentsOf: layer.vertices) }
        segments.append(ArtSegment(id: layer.id, layer: id, vertices: base..<(base + layer.vertices.count / 2),
                                   steps: firstStep..<steps.count, floats: layer.vertices, transform: transform))
    }

    mutating func add(_ points: [Float]) -> Range<Int> {
        let start = vertexCount
        vertices.append(contentsOf: points)
        return start..<vertexCount
    }

    mutating func add(_ points: [Vec2]) -> Range<Int> {
        let start = vertexCount
        vertices.reserveAdditional(points.count * 2)
        for p in points {
            vertices.append(Float(p.x))
            vertices.append(Float(p.y))
        }
        return start..<vertexCount
    }

    mutating func addRect(_ rect: Rect) -> Range<Int> {
        let c = rect.corners
        return add([c[0], c[1], c[2], c[0], c[2], c[3]])
    }
}
