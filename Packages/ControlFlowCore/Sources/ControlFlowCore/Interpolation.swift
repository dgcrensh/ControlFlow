import Foundation

/// The scene partway through a transition (see `Schema/README.md`, "Transitions").
///
/// - Numbers (transform fields, opacity, outline width and miter limit, dash lengths and
///   offset, per-point width, gradient points and stop offsets) and points (vertex
///   positions and handle offsets) move linearly with the progress `p`. Rotation is a
///   plain number, so 0 to 720 turns twice.
/// - Colors (fills, outlines, gradient stops, global colors, the viewport background)
///   move componentwise in sRGB with straight alpha, as CSS does.
/// - A text's tracking and line height move linearly too, its lines broken as they are
///   at the end (see `TextContent.held`), so no word jumps between lines midway.
/// - Everything else (`closed`, handle modes, ends, corners, outline position, gradient
///   kind, clipping, fill or outline on or off, bare edges, group membership, draw order,
///   a text's words, font, weight, size, alignment and width) takes its new value at the
///   start.
/// - Objects that are created appear at the start; objects that are deleted stay, as they
///   were, until the end. A shape's vertices line up as `VertexMerge` describes.
/// - Values a curve carries past its ends are clamped where they must be: colors and
///   opacity to 0...1, widths to 0 or more, and a scale to its sign.
enum Interpolation {
    /// The scene `fraction` of the way through the transition from `a` to `b` (time, 0...1;
    /// at 1 or more this is `b`), at progress `p` (the timing curve's value there).
    /// `parameters` holds the keyframe's recorded `t` for born and dying vertices.
    static func scene(from a: Drawing, to b: Drawing, fraction: Double, progress p: Double,
                      parameters: [Int: Double]) -> Drawing {
        guard fraction < 1 else { return b }
        var out = b
        if a.viewport.id == b.viewport.id { out.viewport.background = color(a.viewport.background, b.viewport.background, p) }
        let oldGlobals = Dictionary(a.globalColors.map { ($0.id, $0.color) }, uniquingKeysWith: { x, _ in x })
        for g in out.globalColors.indices {
            if let old = oldGlobals[out.globalColors[g].id] { out.globalColors[g].color = color(old, out.globalColors[g].color, p) }
        }
        guard a.layers != b.layers else {
            out.syncGlobalColors()
            return out
        }

        let oldLayers = Dictionary(a.layers.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        var newShapes = Set<Int>(), newGroups = Set<Int>()
        for layer in b.layers {
            newShapes.formUnion(layer.shapes.map(\.id))
            newGroups.formUnion(layer.groups.map(\.id))
        }
        var layers: [Layer] = b.layers.map { layer in
            guard let old = oldLayers[layer.id], old != layer else { return layer }
            return self.layer(from: old, to: layer, p: p, newShapes: newShapes, newGroups: newGroups, parameters: parameters)
        }
        let newLayers = Set(b.layers.map(\.id))
        insertLeaving(a.layers, into: &layers) { !newLayers.contains($0.id) }
        out.layers = layers
        out.syncGlobalColors()
        return out
    }

    /// Puts the items of `old` that are leaving (by `isLeaving`) into `items`, each after
    /// the item it followed in `old` (first when that isn't there).
    private static func insertLeaving<T: Identifiable>(_ old: [T], into items: inout [T], isLeaving: (T) -> Bool) where T.ID == Int {
        for (i, item) in old.enumerated() where isLeaving(item) {
            let after = i > 0 ? old[i - 1].id : nil
            items.insert(item, at: Drawing.insertionIndex(after: after, in: items.map(\.id)))
        }
    }

    private static func layer(from a: Layer, to b: Layer, p: Double, newShapes: Set<Int>, newGroups: Set<Int>,
                              parameters: [Int: Double]) -> Layer {
        var out = b
        out.transform = transform(a.transform, b.transform, p)
        let oldGroups = Dictionary(a.groups.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for g in out.groups.indices {
            if let old = oldGroups[out.groups[g].id] { out.groups[g].transform = transform(old.transform, out.groups[g].transform, p) }
        }
        // Groups of shapes still leaving stay until the end too.
        out.groups += a.groups.filter { !newGroups.contains($0.id) }
        if a.shapes != b.shapes {
            let oldShapes = Dictionary(a.shapes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            out.shapes = b.shapes.map { shape in
                guard let old = oldShapes[shape.id], old != shape else { return shape }
                return self.shape(from: old, to: shape, p: p, parameters: parameters)
            }
            insertLeaving(a.shapes, into: &out.shapes) { !newShapes.contains($0.id) }
        }
        return out
    }

    static func shape(from a: VectorShape, to b: VectorShape, p: Double, parameters: [Int: Double]) -> VectorShape {
        var out = b
        out.transform = transform(a.transform, b.transform, p)
        out.opacity = unit(lerp(a.opacity, b.opacity, p))
        if let fa = a.fill, let fb = b.fill { out.fill = color(fa, fb, p) }
        if let ga = a.gradient, let gb = b.gradient, ga.kind == gb.kind, ga.stops.count == gb.stops.count {
            out.gradient!.start = Vec2.lerp(ga.start, gb.start, p)
            out.gradient!.end = Vec2.lerp(ga.end, gb.end, p)
            for i in gb.stops.indices {
                out.gradient!.stops[i] = GradientStop(offset: unit(lerp(ga.stops[i].offset, gb.stops[i].offset, p)),
                                                      color: color(ga.stops[i].color, gb.stops[i].color, p))
            }
        }
        if let sa = a.stroke, let sb = b.stroke {
            out.stroke!.color = color(sa.color, sb.color, p)
            out.stroke!.width = max(lerp(sa.width, sb.width, p), 0)
            out.stroke!.miterLimit = max(lerp(sa.miterLimit, sb.miterLimit, p), 1)
            out.stroke!.dashOffset = lerp(sa.dashOffset, sb.dashOffset, p)
            if sa.dash.count == sb.dash.count {
                out.stroke!.dash = zip(sa.dash, sb.dash).map { max(lerp($0, $1, p), 0) }
            }
        }
        if let ta = a.text, let tb = b.text, ta.tracking != tb.tracking || ta.lineHeight != tb.lineHeight {
            out.text!.tracking = lerp(ta.tracking, tb.tracking, p)
            out.text!.lineHeight = max(lerp(ta.lineHeight, tb.lineHeight, p), 0)
            out.text!.held = TextMetrics(tracking: tb.tracking, lineHeight: tb.lineHeight)
        }
        if a.path != b.path {
            let pairs: (from: [PathPoint], to: [PathPoint])
            if a.path.closed == b.path.closed, a.path.points.map(\.id) == b.path.points.map(\.id) {
                pairs = (a.path.points, b.path.points)
            } else if let merge = VertexMerge(from: a.path, to: b.path, parameter: { id, segment, position in
                parameters[id] ?? segment.nearest(to: position).t
            }) {
                pairs = (merge.from, merge.to)
            } else {
                pairs = VertexMerge.fallback(from: a.path, to: b.path)
            }
            out.path.points = zip(pairs.from, pairs.to).map { point(from: $0, to: $1, p: p) }
        }
        return out
    }

    /// A vertex between two versions; its mode and bare edge are the new one's.
    static func point(from a: PathPoint, to b: PathPoint, p: Double) -> PathPoint {
        var out = b
        out.position = Vec2.lerp(a.position, b.position, p)
        out.inHandle = Vec2.lerp(a.inHandle, b.inHandle, p)
        out.outHandle = Vec2.lerp(a.outHandle, b.outHandle, p)
        out.width = max(lerp(a.width, b.width, p), 0)
        return out
    }

    static func transform(_ a: Transform, _ b: Transform, _ p: Double) -> Transform {
        if a == b { return b }
        return Transform(position: Vec2.lerp(a.position, b.position, p), rotation: lerp(a.rotation, b.rotation, p),
                         scale: Vec2(scale(a.scale.x, b.scale.x, p), scale(a.scale.y, b.scale.y, p)),
                         pivot: Vec2.lerp(a.pivot, b.pivot, p))
    }

    static func lerp(_ a: Double, _ b: Double, _ p: Double) -> Double { a == b ? b : a + (b - a) * p }

    /// A scale overshooting past zero keeps the sign both ends share.
    private static func scale(_ a: Double, _ b: Double, _ p: Double) -> Double {
        let v = lerp(a, b, p)
        if a >= 0, b >= 0 { return max(v, 0) }
        if a <= 0, b <= 0 { return min(v, 0) }
        return v
    }

    private static func unit(_ v: Double) -> Double { min(max(v, 0), 1) }

    static func color(_ a: RGBAColor, _ b: RGBAColor, _ p: Double) -> RGBAColor {
        if a == b { return b }
        return RGBAColor(r: unit(lerp(a.r, b.r, p)), g: unit(lerp(a.g, b.g, p)), b: unit(lerp(a.b, b.b, p)), a: unit(lerp(a.a, b.a, p)))
    }
}
