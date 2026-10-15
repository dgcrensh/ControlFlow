import Foundation

/// One path with an optional fill (closed paths only) and an optional outline.
public struct VectorShape: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var path: BezierPath
    /// The fill color. With a `gradient` it is the solid color readers without
    /// gradients fall back to; `nil` means no fill at all.
    public var fill: RGBAColor?
    /// Draws the fill as a gradient instead of `fill`.
    public var gradient: ShapeGradient?
    /// The global color `fill` follows, if any (a `GlobalColor` id).
    public var fillGlobal: Int?
    public var stroke: StrokeStyle?
    /// Multiplies the alpha of the fill and the outline (each on its own).
    public var opacity: Double = 1
    /// Draws only where the nearest unclipped shape below it in the same layer draws
    /// (its fill and outline), like a clipping mask. Shapes above a clipped shape can
    /// be clipped to the same base.
    public var isClipped = false
    /// Editor hints, saved in the file: a hidden shape is not drawn in the editor, and
    /// neither a hidden nor a locked shape can be tapped, selected or erased.
    public var isHidden: Bool
    public var isLocked: Bool
    /// The group (a `ShapeGroup` id in the same layer) this shape belongs to, if any.
    public var group: Int?

    public init(id: Int, path: BezierPath, fill: RGBAColor? = nil, stroke: StrokeStyle? = nil,
                isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.path = path
        self.fill = fill
        self.gradient = nil
        self.fillGlobal = nil
        self.stroke = stroke
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// Fill only applies to closed paths.
    public var visibleFill: RGBAColor? { path.closed ? fill : nil }

    /// How far the outline reaches from the path at its widest, in points.
    public var outlineReach: Double {
        guard let stroke else { return 0 }
        let alignment = path.closed ? stroke.alignment : .center
        return stroke.width * path.maxWidth * (alignment == .outside ? 1 : 0.5)
    }

    public var bounds: Rect {
        path.bounds().outset(by: outlineReach)
    }

    /// A conservative `bounds` (from the control points, so it needs no flattening) for
    /// rejecting points and rectangles that can't touch the shape.
    public var hitBounds: Rect {
        path.controlBounds.outset(by: outlineReach)
    }

    /// Transforms the path and gradient; outline width and dashes scale with the
    /// transform's area scale.
    public mutating func apply(_ t: Affine2D) {
        path.apply(t)
        gradient?.apply(t)
        if stroke != nil {
            let k = abs(t.determinant).squareRoot()
            stroke!.width *= k
            stroke!.dash = stroke!.dash.map { $0 * k }
            stroke!.dashOffset *= k
        }
    }

    /// True when `p` is inside the fill or within `tolerance` of the outline.
    public func contains(_ p: Vec2, tolerance: Double) -> Bool {
        guard hitBounds.outset(by: tolerance).contains(p) else { return false }
        return contains(p, tolerance: tolerance, polygon: path.flattened(tolerance: 0.5))
    }

    /// True when any of `points` is on the shape, as `contains`, flattening the path at
    /// most once.
    public func containsAny(of points: [Vec2], tolerance: Double) -> Bool {
        let reject = hitBounds.outset(by: tolerance)
        let candidates = points.filter { reject.contains($0) }
        guard !candidates.isEmpty else { return false }
        let poly = path.flattened(tolerance: 0.5)
        return candidates.contains { contains($0, tolerance: tolerance, polygon: poly) }
    }

    private func contains(_ p: Vec2, tolerance: Double, polygon poly: [Vec2]) -> Bool {
        let outline = outlineReach + tolerance
        if visibleFill != nil, poly.count >= 3, windingNumber(of: p, polygon: poly) != 0 {
            return true
        }
        guard let first = poly.first else { return false }
        if poly.count == 1 { return p.distance(to: first) <= outline }
        for i in 1..<poly.count where p.distance(toSegment: poly[i - 1], poly[i]) <= outline {
            return true
        }
        if path.closed, p.distance(toSegment: poly[poly.count - 1], first) <= outline { return true }
        return false
    }
}

/// Non-zero winding number of a closed polygon around `p`.
public func windingNumber(of p: Vec2, polygon: [Vec2]) -> Int {
    var wn = 0
    let n = polygon.count
    for i in 0..<n {
        let a = polygon[i], b = polygon[(i + 1) % n]
        let side = (b - a).cross(p - a)
        if a.y <= p.y {
            if b.y > p.y, side > 0 { wn += 1 }
        } else if b.y <= p.y, side < 0 {
            wn -= 1
        }
    }
    return wn
}

/// Every shape's clip bases in one layer, from `Layer.clipPlan()`.
public struct ClipPlan: Hashable, Sendable {
    /// `clipBase(of:)` by shape index.
    public let bases: [Int?]
    /// `groupClipBase(of:)` by shape index.
    public let groupBases: [Int?]

    public func base(of index: Int) -> Int? { bases[index] }

    public func groupBase(of index: Int) -> Int? { groupBases[index] }

    /// True when shape `index` is the base of the clipped shapes, or the clipped group,
    /// right above it.
    public func isBase(_ index: Int) -> Bool {
        index + 1 < bases.count && (bases[index + 1] == index || groupBases[index + 1] == index)
    }
}

/// A named set of shapes inside one layer, such as an eye's white, iris and highlight.
/// They select, hide and arrange together. Shapes point at their group with
/// `VectorShape.group`, and a group's shapes are always next to each other in the layer.
public struct ShapeGroup: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    /// Draws the whole group only where the nearest shape below it draws, like a
    /// clipped shape (see `Layer.clipBase(ofGroup:)`). Clipping inside the group still works.
    public var isClipped = false

    public init(id: Int, name: String, isClipped: Bool = false) {
        self.id = id
        self.name = name
        self.isClipped = isClipped
    }
}

/// A layer: shapes drawn together, in order, with their groups.
public struct Layer: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var shapes: [VectorShape]
    /// The point the layer rotates and scales about.
    public var pivot: Vec2
    /// Editor hints, saved in the file, that apply to every shape in the layer.
    public var isHidden: Bool
    public var isLocked: Bool
    /// The layer's groups of shapes, in no particular order (the shapes keep the order).
    public var groups: [ShapeGroup] = []

    public init(id: Int, name: String, shapes: [VectorShape] = [], pivot: Vec2 = .zero,
                isHidden: Bool = false, isLocked: Bool = false) {
        self.id = id
        self.name = name
        self.shapes = shapes
        self.pivot = pivot
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// Changes every shape in the layer.
    public mutating func updateAllShapes(_ body: (inout VectorShape) -> Void) {
        for i in shapes.indices { body(&shapes[i]) }
    }

    /// True when shape `index` is drawn in the editor.
    public func isShown(_ index: Int) -> Bool { !isHidden && !shapes[index].isHidden }

    /// True when shape `index` can be tapped, selected, erased or cut.
    public func isEditable(_ index: Int) -> Bool { isShown(index) && !isLocked && !shapes[index].isLocked }

    /// True when shape `index` is clipped or in a clipped group, so it isn't a base for
    /// the clipped shapes and groups above it.
    public func isClipping(_ index: Int) -> Bool {
        shapes[index].isClipped || shapes[index].group.map { group($0)?.isClipped == true } == true
    }

    /// The index of the shape that clipped shape `index` draws inside: the nearest
    /// unclipped shape below it, without leaving the shape's group. Outside a group,
    /// shapes in clipped groups count as clipped, so they share the base below them.
    /// Nil for an unclipped shape, or a clipped one with nothing below it (which draws
    /// unclipped).
    public func clipBase(of index: Int) -> Int? {
        guard shapes[index].isClipped else { return nil }
        if let group = shapes[index].group, let first = shapes.firstIndex(where: { $0.group == group }) {
            return shapes[first..<index].lastIndex { !$0.isClipped }
        }
        return (0..<index).last { !isClipping($0) }
    }

    /// The index of the shape clipped group `id` draws inside: the nearest shape below
    /// the group that isn't clipped or in a clipped group. Nil when the group isn't
    /// clipped, or has nothing below it (it draws unclipped).
    public func clipBase(ofGroup id: Int) -> Int? {
        guard group(id)?.isClipped == true, let first = shapes.firstIndex(where: { $0.group == id }) else { return nil }
        return (0..<first).last { !isClipping($0) }
    }

    /// The shape whose area shape `index` is masked to as a member of a clipped group.
    public func groupClipBase(of index: Int) -> Int? {
        shapes[index].group.flatMap { clipBase(ofGroup: $0) }
    }

    /// True when shape `index` is the base of the clipped shapes, or the clipped group,
    /// right above it.
    public func isClipBase(_ index: Int) -> Bool {
        index + 1 < shapes.count && (clipBase(of: index + 1) == index || groupClipBase(of: index + 1) == index)
    }

    /// `clipBase(of:)` and `groupClipBase(of:)` for every shape, in one pass. Use it when
    /// walking the whole layer, where asking shape by shape would be quadratic.
    public func clipPlan() -> ClipPlan {
        var bases: [Int?] = [], groupBases: [Int?] = []
        bases.reserveCapacity(shapes.count)
        groupBases.reserveCapacity(shapes.count)
        let clippedGroups = Set(groups.filter(\.isClipped).map(\.id))
        // The last shape that isn't clipped or in a clipped group, and in each group the
        // last shape that isn't clipped.
        var lastBase: Int?
        var lastInGroup: [Int: Int] = [:]
        var groupBase: [Int: Int?] = [:]
        for (index, shape) in shapes.enumerated() {
            if let group = shape.group {
                if groupBase[group] == nil { groupBase[group] = clippedGroups.contains(group) ? lastBase : nil }
                groupBases.append(groupBase[group] ?? nil)
                bases.append(shape.isClipped ? lastInGroup[group] : nil)
                if !shape.isClipped { lastInGroup[group] = index }
            } else {
                groupBases.append(nil)
                bases.append(shape.isClipped ? lastBase : nil)
            }
            let inClippedGroup = shape.group.map(clippedGroups.contains) ?? false
            if !shape.isClipped, !inClippedGroup { lastBase = index }
        }
        return ClipPlan(bases: bases, groupBases: groupBases)
    }

    public func group(_ id: Int) -> ShapeGroup? { groups.first { $0.id == id } }

    /// The indices of group `id`'s shapes, bottom to top.
    public func members(ofGroup id: Int) -> [Int] {
        shapes.indices.filter { shapes[$0].group == id }
    }

    /// The groups in stacking order (by their bottom shape), each with its shape indices.
    public var groupRuns: [(group: ShapeGroup, indices: [Int])] {
        var seen: [Int] = []
        for shape in shapes { if let g = shape.group, !seen.contains(g) { seen.append(g) } }
        return seen.compactMap { id in group(id).map { ($0, members(ofGroup: id)) } }
    }

    /// `base`, or `base 2`, `base 3`... so no other group in the layer has the same name.
    public func uniqueGroupName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(groups.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// True when `p` is on shape `index` where it shows: a clipped shape only shows
    /// inside its base, and a shape in a clipped group only inside the group's base.
    public func shape(_ index: Int, contains p: Vec2, tolerance: Double) -> Bool {
        guard shapes[index].contains(p, tolerance: tolerance) else { return false }
        for base in [clipBase(of: index), groupClipBase(of: index)].compactMap({ $0 }) {
            guard isShown(base), shapes[base].contains(p, tolerance: 0) else { return false }
        }
        return true
    }

    public var bounds: Rect {
        shapes.reduce(Rect.null) { $0.union($1.bounds) }
    }
}

/// An imported photo or sketch drawn under the art. Editor-only: never exported with
/// the art. The pixels live with the app; this holds placement and display.
public struct ReferenceImage: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    /// Natural size in world points (before `scale`).
    public var size: Vec2
    public var center: Vec2
    /// Radians, clockwise on screen.
    public var rotation: Double
    public var scale: Double
    public var opacity: Double
    public var isHidden: Bool

    public init(id: Int, name: String, size: Vec2, center: Vec2, rotation: Double = 0, scale: Double = 1,
                opacity: Double = 0.5, isHidden: Bool = false) {
        self.id = id
        self.name = name
        self.size = size
        self.center = center
        self.rotation = rotation
        self.scale = scale
        self.opacity = opacity
        self.isHidden = isHidden
    }

    /// Maps image space (0...width, 0...height, y-down) to world space.
    public var transform: Affine2D {
        Affine2D.translation(center) * Affine2D.rotation(rotation) * Affine2D.scale(scale) *
            Affine2D.translation(-(size / 2))
    }

    /// Top-left, top-right, bottom-right, bottom-left in world space.
    public var corners: [Vec2] {
        let t = transform
        return [Vec2(0, 0), Vec2(size.x, 0), size, Vec2(0, size.y)].map(t.apply)
    }

    /// Applies a similarity transform (move, uniform scale, rotate).
    public mutating func apply(_ t: Affine2D) {
        center = t.apply(center)
        rotation += t.rotationAngle
        scale *= t.uniformScale
    }
}

/// The address of one shape: its layer and its own id.
public struct ShapeRef: Hashable, Sendable, Comparable {
    public var layer: Int
    public var shape: Int

    public init(layer: Int, shape: Int) {
        self.layer = layer
        self.shape = shape
    }

    public static func < (a: ShapeRef, b: ShapeRef) -> Bool {
        a.layer != b.layer ? a.layer < b.layer : a.shape < b.shape
    }
}

/// What the Pencil has selected.
public enum Selection: Hashable, Sendable {
    case none
    /// A whole layer (a layer).
    case layer(Int)
    /// Several whole layers, picked in the layers panel. Use `coveringLayers` to build
    /// one, so a single layer is always `.layer`.
    case layers(Set<Int>)
    case shape(layer: Int, shape: Int)
    /// Several shapes picked one by one or with a marquee. Use `covering` to build
    /// one, so a single shape is always `.shape`.
    case shapes(Set<ShapeRef>)
    case reference(Int)

    /// The smallest selection holding exactly `refs`: none, one shape, or several.
    public static func covering(_ refs: Set<ShapeRef>) -> Selection {
        switch refs.count {
        case 0: .none
        case 1: .shape(layer: refs.first!.layer, shape: refs.first!.shape)
        default: .shapes(refs)
        }
    }

    /// The smallest selection holding exactly the layers `ids`: none, one layer, or several.
    public static func coveringLayers(_ ids: Set<Int>) -> Selection {
        switch ids.count {
        case 0: .none
        case 1: .layer(ids.first!)
        default: .layers(ids)
        }
    }
}

/// The on-canvas frame drawn around a selection, with its handles.
public struct SelectionFrame: Hashable, Sendable {
    /// Top-left, top-right, bottom-right, bottom-left in world space.
    public var corners: [Vec2]

    public init(corners: [Vec2]) {
        self.corners = corners
    }

    public init(rect: Rect) {
        self.corners = rect.corners
    }

    public var center: Vec2 { (corners[0] + corners[2]) / 2 }
    /// Midpoints of the top, right, bottom and left edges, in that order.
    public var edgeMidpoints: [Vec2] { (0..<4).map { (corners[$0] + corners[($0 + 1) % 4]) / 2 } }
    public var topCenter: Vec2 { (corners[0] + corners[1]) / 2 }

    /// Unit vector from the bottom edge toward the top edge.
    public var up: Vec2 {
        let v = (corners[0] - corners[3]).normalized
        return v == .zero ? Vec2(0, -1) : v
    }

    /// Where the rotate handle sits, `offset` world points above the top edge.
    public func rotateHandle(offset: Double) -> Vec2 { topCenter + up * offset }

    public func contains(_ p: Vec2) -> Bool {
        var sign = 0.0
        for i in 0..<4 {
            let a = corners[i], b = corners[(i + 1) % 4]
            let c = (b - a).cross(p - a)
            if abs(c) < 1e-12 { continue }
            if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false }
        }
        return true
    }
}

/// Everything the user has drawn in one presentation, plus editor-only reference images.
public struct Drawing: Hashable, Sendable, Codable {
    /// The presentation's name, saved in the file. The document's file name is separate.
    public var name = "Untitled"
    /// The fixed-aspect stage the presentation shows.
    public var viewport = Viewport()
    /// Back to front: this is the draw order.
    public var layers: [Layer] = []
    /// Bottom to top.
    public var references: [ReferenceImage] = []
    /// Colors kept for reuse.
    public var palette: [RGBAColor] = []
    /// Named colors that shapes follow.
    public var globalColors: [GlobalColor] = []
    public var nextID = 1

    public init() {}

    public mutating func makeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }

    public var shapeCount: Int { layers.reduce(0) { $0 + $1.shapes.count } }

    /// Gives a fresh id to every vertex without one (0), with an id from outside this
    /// drawing's range, or with an id an earlier vertex in draw order already has (a
    /// copied point). Vertices that already have a unique id keep it.
    public mutating func assignVertexIDs() {
        var seen = [Bool](repeating: false, count: max(nextID, 1))
        for l in layers.indices {
            for s in layers[l].shapes.indices {
                let points = layers[l].shapes[s].path.points
                for i in points.indices {
                    let id = points[i].id
                    if id > 0, id < seen.count, !seen[id] {
                        seen[id] = true
                    } else {
                        layers[l].shapes[s].path.points[i].id = makeID()
                    }
                }
            }
        }
    }

    /// True when every vertex has an id and no two share one.
    public var vertexIDsAreValid: Bool {
        var seen = Set<Int>()
        for layer in layers {
            for shape in layer.shapes {
                for point in shape.path.points where point.id <= 0 || point.id >= nextID || !seen.insert(point.id).inserted {
                    return false
                }
            }
        }
        return true
    }

    public func layerIndex(_ id: Int) -> Int? { layers.firstIndex { $0.id == id } }

    public func indices(layer: Int, shape: Int) -> (Int, Int)? {
        guard let p = layerIndex(layer), let s = layers[p].shapes.firstIndex(where: { $0.id == shape }) else { return nil }
        return (p, s)
    }

    public func shape(layer: Int, shape: Int) -> VectorShape? {
        indices(layer: layer, shape: shape).map { layers[$0.0].shapes[$0.1] }
    }

    public func shape(_ ref: ShapeRef) -> VectorShape? { shape(layer: ref.layer, shape: ref.shape) }

    public func indices(_ ref: ShapeRef) -> (Int, Int)? { indices(layer: ref.layer, shape: ref.shape) }

    public func referenceIndex(_ id: Int) -> Int? { references.firstIndex { $0.id == id } }

    public func globalColor(_ id: Int) -> GlobalColor? { globalColors.first { $0.id == id } }

    /// `base`, or `base 2`, `base 3`... so no other global color has the same name.
    /// Shapes refer to global colors by name in the file, so names are kept unique.
    public func uniqueGlobalColorName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(globalColors.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// `base`, or `base 2`, `base 3`... so no other layer has the same name. Layer names
    /// become slot ids in the file, so they are kept unique.
    public func uniqueLayerName(_ base: String, excluding id: Int? = nil) -> String {
        let taken = Set(layers.filter { $0.id != id }.map(\.name))
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    /// The topmost editable shape under `p`, only in layer `within` when it is given,
    /// and only in its group `group` when that is given too. Hidden and locked shapes,
    /// and reference images, are never hit.
    public func hitTest(_ p: Vec2, tolerance: Double, within: Int? = nil, group: Int? = nil) -> (layer: Int, shape: Int)? {
        for layer in layers.reversed() where within == nil || layer.id == within {
            for i in layer.shapes.indices.reversed() where (group == nil || layer.shapes[i].group == group) &&
                layer.isEditable(i) && layer.shape(i, contains: p, tolerance: tolerance) {
                return (layer.id, layer.shapes[i].id)
            }
        }
        return nil
    }

    /// Every editable shape, in draw order, only in layer `within` when it is given,
    /// and only in its group `group` when that is given too.
    public func editableShapeRefs(within: Int? = nil, group: Int? = nil) -> [ShapeRef] {
        var out: [ShapeRef] = []
        for layer in layers where within == nil || layer.id == within {
            for i in layer.shapes.indices where (group == nil || layer.shapes[i].group == group) && layer.isEditable(i) {
                out.append(ShapeRef(layer: layer.id, shape: layer.shapes[i].id))
            }
        }
        return out
    }

    public func exists(_ selection: Selection) -> Bool {
        switch selection {
        case .none: true
        case .layer(let id): layerIndex(id) != nil
        case .layers(let ids): !ids.isEmpty && ids.allSatisfy { layerIndex($0) != nil }
        case .shape(let p, let s): indices(layer: p, shape: s) != nil
        case .shapes(let refs): !refs.isEmpty && refs.allSatisfy { indices($0) != nil }
        case .reference(let id): referenceIndex(id) != nil
        }
    }

    public func frame(of selection: Selection) -> SelectionFrame? {
        switch selection {
        case .none:
            return nil
        case .layer(let id):
            let bounds = layerIndex(id).map { layers[$0].bounds } ?? .null
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .layers(let ids):
            let bounds = layers.filter { ids.contains($0.id) }.reduce(Rect.null) { $0.union($1.bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .shape(let p, let s):
            return shape(layer: p, shape: s).map { SelectionFrame(rect: $0.bounds) }
        case .shapes:
            let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(layers[$1.0].shapes[$1.1].bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .reference(let id):
            return referenceIndex(id).map { SelectionFrame(corners: references[$0].corners) }
        }
    }

    /// The shapes a selection covers, as (layer index, shape index).
    public func shapeIndices(in selection: Selection) -> [(Int, Int)] {
        switch selection {
        case .layer(let id):
            guard let p = layerIndex(id) else { return [] }
            return layers[p].shapes.indices.map { (p, $0) }
        case .layers(let ids):
            return layers.indices.filter { ids.contains(layers[$0].id) }.flatMap { p in layers[p].shapes.indices.map { (p, $0) } }
        case .shape(let p, let s):
            return indices(layer: p, shape: s).map { [$0] } ?? []
        case .shapes(let refs):
            // In draw order, whatever the set's own order.
            var out: [(Int, Int)] = []
            for (pi, layer) in layers.enumerated() {
                for (si, shape) in layer.shapes.enumerated() where refs.contains(ShapeRef(layer: layer.id, shape: shape.id)) {
                    out.append((pi, si))
                }
            }
            return out
        case .none, .reference:
            return []
        }
    }

    /// The shapes a selection covers, in draw order.
    public func shapeRefs(in selection: Selection) -> [ShapeRef] {
        shapeIndices(in: selection).map { ShapeRef(layer: layers[$0.0].id, shape: layers[$0.0].shapes[$0.1].id) }
    }

    /// The selection's bounds without outline width, for numeric position and size.
    public func geometryBounds(of selection: Selection) -> Rect? {
        if case .reference(let id) = selection {
            return referenceIndex(id).map { Rect(points: references[$0].corners) }
        }
        let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(layers[$1.0].shapes[$1.1].path.bounds()) }
        return bounds.isNull ? nil : bounds
    }

    public mutating func apply(_ t: Affine2D, to selection: Selection) {
        switch selection {
        case .none:
            break
        case .layer(let id):
            applyToLayers(t, layerIndex(id).map { [$0] } ?? [])
        case .layers(let ids):
            applyToLayers(t, layers.indices.filter { ids.contains(layers[$0].id) })
        case .shape(let pid, let sid):
            guard let idx = indices(layer: pid, shape: sid) else { return }
            layers[idx.0].shapes[idx.1].apply(t)
        case .shapes:
            for (p, s) in shapeIndices(in: selection) { layers[p].shapes[s].apply(t) }
        case .reference(let id):
            guard let r = referenceIndex(id) else { return }
            references[r].apply(t)
        }
    }

    /// Transforms whole layers (layer indices) and their pivots.
    private mutating func applyToLayers(_ t: Affine2D, _ indices: [Int]) {
        for p in indices {
            for s in layers[p].shapes.indices { layers[p].shapes[s].apply(t) }
            layers[p].pivot = t.apply(layers[p].pivot)
        }
    }

    public func applying(_ t: Affine2D, to selection: Selection) -> Drawing {
        var copy = self
        copy.apply(t, to: selection)
        return copy
    }
}
