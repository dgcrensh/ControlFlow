import Foundation

/// One path with an optional fill (closed paths only) and an optional outline. A text
/// shape (one with `text`) or a formula (one with `math`) draws its glyph outlines
/// instead, and keeps its own path empty and closed. An image shape (one with `image`) draws its picture in place of a
/// fill, over the frame its four points make (see `imagePlacement`).
public struct VectorShape: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var path: BezierPath
    /// The words a text shape shows, and how they are set (see `TextContent`).
    public var text: TextContent?
    /// The LaTeX a formula shows, and how it is set (see `MathContent`).
    public var math: MathContent?
    /// A text or formula as it is drawn (see `resolvingLayout()`): its box's corners,
    /// carried with the path by every transform. Nil in a drawing's own shapes.
    public internal(set) var layoutFrame: [Vec2]?
    /// The picture an image shape shows (see `ShapeImage`).
    public var image: ShapeImage?
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
    /// Places the path in its group, or its layer when it has none. The path's points
    /// are in the shape's own space.
    public var transform = Transform.identity

    public init(id: Int, path: BezierPath, fill: RGBAColor? = nil, stroke: StrokeStyle? = nil,
                isHidden: Bool = false, isLocked: Bool = false, transform: Transform = .identity) {
        self.transform = transform
        self.id = id
        self.path = path
        self.fill = fill
        self.gradient = nil
        self.fillGlobal = nil
        self.stroke = stroke
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// A text shape with `text`, at the origin of its own space.
    public init(id: Int, text: TextContent, fill: RGBAColor? = .black, transform: Transform = .identity) {
        self.init(id: id, path: BezierPath(closed: true), fill: fill, transform: transform)
        self.text = text
    }

    /// A formula showing `math`, at the origin of its own space.
    public init(id: Int, math: MathContent, fill: RGBAColor? = .black, transform: Transform = .identity) {
        self.init(id: id, path: BezierPath(closed: true), fill: fill, transform: transform)
        self.math = math
    }

    /// Fill only applies to closed paths, and not to an image, which draws its picture instead.
    public var visibleFill: RGBAColor? { path.closed && image == nil ? fill : nil }

    public var isText: Bool { text != nil }

    /// True for a shape whose path comes from a layout, not its points: a text or a formula.
    public var isLaidOut: Bool { text != nil || math != nil }

    /// The shape as it is drawn: a text's or formula's glyph outlines in its path (one
    /// path, bridged) and its box in `layoutFrame`. A formula whose layout isn't known
    /// yet (see `MathTypesetting`) has an empty path and a placeholder box. Any other
    /// shape, or one already resolved, as it is.
    public func resolvingLayout() -> VectorShape {
        guard isLaidOut, layoutFrame == nil else { return self }
        var copy = self
        if let text {
            copy.path = TextShaping.outline(text)
            copy.layoutFrame = TextShaping.layout(text).frame.corners
        } else if let math, let frame = MathMorph.frame(math) {
            // Partway through a morph (see `MathMorph`).
            copy.path = frame.outline
            copy.layoutFrame = frame.bounds.corners
        } else if let math {
            let layout = MathTypesetting.layout(math)
            copy.path = layout?.outline ?? BezierPath(closed: true)
            copy.layoutFrame = (layout?.bounds ?? MathLayout.placeholder(math)).corners
        }
        copy.path.closed = true
        // Outlines on text and formulas come later: their glyphs are filled only.
        copy.stroke = nil
        return copy
    }

    /// The box of a text or formula in the shape's own space, when it isn't resolved.
    private var layoutBounds: Rect? {
        if let layoutFrame { return Rect(points: layoutFrame) }
        if let text { return TextShaping.layout(text).frame }
        if let math { return MathTypesetting.layout(math)?.bounds ?? MathLayout.placeholder(math) }
        return nil
    }

    /// How far the outline reaches from the path at its widest, in points.
    public var outlineReach: Double {
        guard let stroke else { return 0 }
        let alignment = path.closed ? stroke.alignment : .center
        return stroke.width * path.maxWidth * (alignment == .outside ? 1 : 0.5)
    }

    public var bounds: Rect {
        if let box = layoutBounds { return box.union(path.bounds()) }
        return path.bounds().outset(by: outlineReach)
    }

    /// A conservative `bounds` (from the control points, so it needs no flattening) for
    /// rejecting points and rectangles that can't touch the shape.
    public var hitBounds: Rect {
        if let box = layoutBounds { return box.union(path.controlBounds) }
        return path.controlBounds.outset(by: outlineReach)
    }

    /// True when `geometryBounds` isn't null, found without measuring the path. A
    /// transform never changes it, so it holds for the shape in world space too.
    public var hasGeometry: Bool {
        !path.points.isEmpty || !(layoutBounds?.isNull ?? true)
    }

    /// The bounds of the geometry, without outline width: the path's, or a text's box.
    public var geometryBounds: Rect {
        if let box = layoutBounds { return box.union(path.bounds()) }
        return path.bounds()
    }

    /// The shape with `m` (its whole transform from its own space to world space, see
    /// `Layer.worldMatrix(ofShape:)`) applied to its path and gradient, and its own
    /// transform cleared: what it looks like in world space. A text shape is resolved
    /// first (see `resolvingLayout()`).
    public func baked(_ m: Affine2D) -> VectorShape {
        var copy = resolvingLayout()
        copy.transform = .identity
        if m != .identity { copy.apply(m) }
        return copy
    }

    /// `baked`, for a shape that stays in a drawing: a text or formula keeps its words or
    /// source and takes `m` as its own transform (about its pivot), or, where `m` can't
    /// be a transform (a skew), keeps its own.
    public func bakedKeepingLayout(_ m: Affine2D) -> VectorShape {
        guard isLaidOut else { return baked(m) }
        var copy = self
        copy.layoutFrame = nil
        if let t = Transform(matrix: m, pivot: transform.pivot, near: transform.rotation) { copy.transform = t }
        return copy
    }

    /// Transforms the path and gradient; outline width and dashes scale with the
    /// transform's area scale. The shape's `transform` is left alone, except on a text
    /// shape (not resolved), whose glyphs are laid out at its origin: it takes `t` into
    /// its transform instead, where `t` can be one.
    public mutating func apply(_ t: Affine2D) {
        if isLaidOut, layoutFrame == nil {
            guard t != .identity, let inverse = t.inverted,
                  let next = Transform(matrix: transform.matrix * t, pivot: inverse.apply(transform.pivot),
                                       near: transform.rotation) else { return }
            transform = next
            return
        }
        path.apply(t)
        gradient?.apply(t)
        if layoutFrame != nil { layoutFrame = layoutFrame!.map(t.apply) }
        if stroke != nil {
            let k = abs(t.determinant).squareRoot()
            stroke!.width *= k
            stroke!.dash = stroke!.dash.map { $0 * k }
            stroke!.dashOffset *= k
        }
    }

    /// True when the shapes are the same but for float rounding (1e-9 points) in their
    /// geometry: points, handles, gradient, outline width and dashes.
    public func isApproximately(_ o: VectorShape, tolerance: Double = 1e-9) -> Bool {
        if self == o { return true }
        guard id == o.id, path.closed == o.path.closed, path.points.count == o.path.points.count,
              text == o.text, math == o.math, image == o.image, (layoutFrame == nil) == (o.layoutFrame == nil), fill == o.fill, fillGlobal == o.fillGlobal, opacity == o.opacity, isClipped == o.isClipped,
              isHidden == o.isHidden, isLocked == o.isLocked, group == o.group, transform == o.transform,
              (stroke == nil) == (o.stroke == nil), (gradient == nil) == (o.gradient == nil) else { return false }
        for (a, b) in zip(path.points, o.path.points) {
            guard a.id == b.id, a.mode == b.mode, a.stroked == b.stroked, abs(a.width - b.width) <= tolerance,
                  a.position.isApproximately(b.position, tolerance: tolerance),
                  a.inHandle.isApproximately(b.inHandle, tolerance: tolerance),
                  a.outHandle.isApproximately(b.outHandle, tolerance: tolerance) else { return false }
        }
        if var s1 = stroke, let s2 = o.stroke {
            guard abs(s1.width - s2.width) <= tolerance, abs(s1.dashOffset - s2.dashOffset) <= tolerance,
                  s1.dash.count == s2.dash.count, zip(s1.dash, s2.dash).allSatisfy({ abs($0 - $1) <= tolerance }) else { return false }
            s1.width = s2.width
            s1.dash = s2.dash
            s1.dashOffset = s2.dashOffset
            guard s1 == s2 else { return false }
        }
        if let f1 = layoutFrame, let f2 = o.layoutFrame {
            guard f1.count == f2.count, zip(f1, f2).allSatisfy({ $0.isApproximately($1, tolerance: tolerance) }) else { return false }
        }
        if var g1 = gradient, let g2 = o.gradient {
            guard g1.start.isApproximately(g2.start, tolerance: tolerance),
                  g1.end.isApproximately(g2.end, tolerance: tolerance) else { return false }
            g1.start = g2.start
            g1.end = g2.end
            guard g1 == g2 else { return false }
        }
        return true
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
        // A text or formula is picked anywhere in its box, between the letters too.
        if let frame = layoutFrame ?? layoutBounds?.corners, frame.count >= 3 {
            if windingNumber(of: p, polygon: frame) != 0 { return true }
            for i in frame.indices where p.distance(toSegment: frame[i], frame[(i + 1) % frame.count]) <= tolerance {
                return true
            }
            return false
        }
        let outline = outlineReach + tolerance
        if visibleFill != nil || image != nil, poly.count >= 3, windingNumber(of: p, polygon: poly) != 0 {
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
    /// Places the group's shapes in their layer.
    public var transform = Transform.identity

    public init(id: Int, name: String, isClipped: Bool = false, transform: Transform = .identity) {
        self.id = id
        self.name = name
        self.isClipped = isClipped
        self.transform = transform
    }
}

/// A layer: shapes drawn together, in order, with their groups.
public struct Layer: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var shapes: [VectorShape]
    /// Places the layer's groups and shapes in the world.
    public var transform = Transform.identity
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
        self.transform = Transform(pivot: pivot)
        self.isHidden = isHidden
        self.isLocked = isLocked
    }

    /// The point the layer rotates and scales about, in the layer's own space (its
    /// transform's pivot). See `worldPivot`.
    public var pivot: Vec2 {
        get { transform.pivot }
        set { transform.pivot = newValue }
    }

    /// Where the pivot is in the world.
    public var worldPivot: Vec2 { transform.matrix.apply(pivot) }

    /// Moves the pivot to world point `p` without moving the art. Ignored when the
    /// layer's transform collapses it to a line or a point.
    public mutating func setWorldPivot(_ p: Vec2) {
        guard let inverse = transform.matrix.inverted else { return }
        transform = transform.withPivot(inverse.apply(p))
    }

    /// True when the layer, or any of its groups or shapes, has a transform.
    public var hasTransforms: Bool {
        !transform.isIdentity || groups.contains { !$0.transform.isIdentity } || shapes.contains { !$0.transform.isIdentity }
    }

    /// Maps a shape's parent space (its group's, or the layer's when it has no group) to
    /// the world: where a shape in group `group` puts its transform.
    public func parentMatrix(group: Int?) -> Affine2D {
        let layerMatrix = transform.matrix
        guard let group, let g = self.group(group), !g.transform.isIdentity else { return layerMatrix }
        return layerMatrix * g.transform.matrix
    }

    /// Maps shape `index`'s points to the world.
    public func worldMatrix(ofShape index: Int) -> Affine2D {
        let shape = shapes[index]
        let parent = parentMatrix(group: shape.group)
        return shape.transform.isIdentity ? parent : parent * shape.transform.matrix
    }

    /// True when any shape is text, whose glyphs are laid out to draw it.
    public var hasText: Bool { shapes.contains { $0.text != nil } }

    /// True when any shape is text or a formula, whose glyphs are laid out to draw it.
    public var hasLaidOut: Bool { shapes.contains(where: \.isLaidOut) }

    /// True when the layer drawn differs from the layer itself: it has transforms, text
    /// or formulas.
    var needsWorld: Bool { hasTransforms || hasLaidOut }

    /// Shape `index` as it is drawn: in world space, with no transform, and a text's or
    /// formula's glyphs in its path.
    public func worldShape(_ index: Int) -> VectorShape {
        let m = worldMatrix(ofShape: index)
        return m == .identity ? shapes[index].resolvingLayout() : shapes[index].baked(m)
    }

    /// Every shape as it is drawn (see `worldShape(_:)`).
    public var worldShapes: [VectorShape] {
        needsWorld ? shapes.indices.map(worldShape) : shapes
    }

    /// Sets shape `index` from a world-space version of it (one with no transform, such as
    /// `worldShape` returns, edited), keeping its own transform. Returns false, changing
    /// nothing, when the shape's transform collapses it so it can't be edited.
    @discardableResult
    public mutating func setWorldShape(_ index: Int, _ world: VectorShape) -> Bool {
        let m = worldMatrix(ofShape: index)
        var shape = world
        shape.transform = shapes[index].transform
        shape.group = world.group
        if world.layoutFrame != nil || shapes[index].isLaidOut {
            // A text's or formula's glyphs are laid out, not kept: only its gradient comes back.
            shape.path = shapes[index].path
            shape.layoutFrame = nil
            if m != .identity {
                guard let inverse = m.inverted else { return false }
                shape.gradient?.apply(inverse)
            }
            shapes[index] = shape
            return true
        }
        if m != .identity {
            guard let inverse = m.inverted else { return false }
            shape.apply(inverse)
        }
        shapes[index] = shape
        return true
    }

    /// Changes shape `index` in world space (see `setWorldShape`). Returns false, changing
    /// nothing, when its transform collapses it.
    @discardableResult
    public mutating func updateWorldShape(_ index: Int, _ change: (inout VectorShape) -> Void) -> Bool {
        if worldMatrix(ofShape: index) == .identity {
            change(&shapes[index])
            return true
        }
        var world = worldShape(index)
        change(&world)
        return setWorldShape(index, world)
    }

    /// Adds `shape` at `index`, or on top, as `adopting` does.
    public mutating func insertWorldShape(_ shape: VectorShape, at index: Int? = nil) {
        shapes.insert(adopting(shape), at: index ?? shapes.count)
    }

    /// `shape`, whose own transform places it in the world (as if its parent had none),
    /// made to look the same as a shape of this layer in its group `shape.group`: its
    /// transform takes the inverse of the layer's and group's, or when that can't be a
    /// transform, its points do.
    public func adopting(_ shape: VectorShape) -> VectorShape {
        adopting(shape, from: .identity)
    }

    /// `shape`, placed in the world by `from` and its own transform, made to look the
    /// same as a shape of this layer in its group `shape.group` (see `adopting(_:)`).
    public func adopting(_ shape: VectorShape, from parent: Affine2D) -> VectorShape {
        let m = parentMatrix(group: shape.group)
        guard m != parent, let inverse = m.inverted else { return shape }
        let change = inverse * parent
        var out = shape
        if let t = Transform(matrix: change * shape.transform.matrix, pivot: shape.transform.pivot,
                             near: shape.transform.rotation) {
            out.transform = t.isIdentity ? .identity : t
            if out.transform.isIdentity { out.transform.pivot = .zero }
            return out
        }
        return shape.bakedKeepingLayout(change * shape.transform.matrix)
    }

    /// Adds groups and shapes taken from another layer (see `TakenArt`) on top, so they
    /// look as they did there.
    public mutating func adopt(_ art: TakenArt) {
        let own = transform.matrix
        // Groups whose placement can't be a transform here: their members take it instead.
        var baked: [Int: Affine2D] = [:]
        for (group, parent) in art.groups {
            var copy = group
            let world = parent * group.transform.matrix
            if world != own {
                if let inverse = own.inverted,
                   let t = Transform(matrix: inverse * world, pivot: group.transform.pivot, near: group.transform.rotation) {
                    copy.transform = t
                } else {
                    copy.transform = .identity
                    baked[group.id] = world
                }
            }
            groups.append(copy)
        }
        for (shape, parent) in art.shapes {
            if let g = shape.group, art.groups.contains(where: { $0.group.id == g }) {
                shapes.append(baked[g].map { adopting(shape, from: $0) } ?? shape)
            } else {
                shapes.append(adopting(shape, from: parent))
            }
        }
    }

    /// `t` (in world space) as it acts on shape `index`'s own points: what to apply to
    /// them to move the shape by `t`.
    public func local(_ t: Affine2D, forShape index: Int) -> Affine2D {
        let m = worldMatrix(ofShape: index)
        guard m != .identity, let inverse = m.inverted else { return t }
        return inverse * t * m
    }

    /// Moves the whole layer by world translation `shift`: a layer with no transform
    /// moves its points and pivot, one with a transform moves its position.
    public mutating func move(by shift: Affine2D) {
        if transform.isIdentity {
            for s in shapes.indices { shapes[s].apply(local(shift, forShape: s)) }
            pivot = shift.apply(pivot)
        } else {
            transform.position += Vec2(shift.tx, shift.ty)
        }
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

    /// True when `indices` (shape indices in this layer) hold every shape of group `id`.
    public func isWhole(group id: Int, in indices: Set<Int>) -> Bool {
        let members = members(ofGroup: id)
        return !members.isEmpty && members.allSatisfy(indices.contains)
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
        guard worldShape(index).contains(p, tolerance: tolerance) else { return false }
        for base in [clipBase(of: index), groupClipBase(of: index)].compactMap({ $0 }) {
            guard isShown(base), worldShape(base).contains(p, tolerance: 0) else { return false }
        }
        return true
    }

    /// The bounds of the art in world space.
    public var bounds: Rect {
        worldShapes.reduce(Rect.null) { $0.union($1.bounds) }
    }

    /// The bounds of the art in the layer's own space, before its transform.
    public var localBounds: Rect {
        let m = transform.matrix
        guard m != .identity, let inverse = m.inverted else { return bounds }
        return shapes.indices.reduce(Rect.null) { $0.union(shapes[$1].baked(inverse * worldMatrix(ofShape: $1)).bounds) }
    }
}

/// Shapes and whole groups leaving a layer, each with the matrix that placed its parent
/// space in the world there (for a shape, its group's or layer's; for a group, its
/// layer's), so `Layer.adopt` can keep them where they are.
public struct TakenArt: Sendable {
    public var shapes: [(shape: VectorShape, parent: Affine2D)] = []
    public var groups: [(group: ShapeGroup, parent: Affine2D)] = []

    public init(shapes: [(shape: VectorShape, parent: Affine2D)] = [], groups: [(group: ShapeGroup, parent: Affine2D)] = []) {
        self.shapes = shapes
        self.groups = groups
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
            guard let p = layerIndex(id) else { return nil }
            let layer = layers[p]
            let m = layer.transform.matrix
            if m != .identity, m.inverted != nil {
                return Self.frame(localBounds: layer.localBounds, matrix: m)
            }
            return layer.bounds.isNull ? nil : SelectionFrame(rect: layer.bounds)
        case .layers(let ids):
            let bounds = layers.filter { ids.contains($0.id) }.reduce(Rect.null) { $0.union($1.bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .shape(let l, let s):
            guard let (p, i) = indices(layer: l, shape: s) else { return nil }
            let m = layers[p].worldMatrix(ofShape: i)
            if m != .identity, m.inverted != nil {
                return Self.frame(localBounds: layers[p].shapes[i].bounds, matrix: m)
            }
            return SelectionFrame(rect: layers[p].worldShape(i).bounds)
        case .shapes:
            if let (p, group) = wholeGroup(selection) {
                let layer = layers[p]
                let m = layer.parentMatrix(group: group.id)
                if m != .identity, let inverse = m.inverted {
                    let local = layer.members(ofGroup: group.id).reduce(Rect.null) {
                        $0.union(layer.shapes[$1].baked(inverse * layer.worldMatrix(ofShape: $1)).bounds)
                    }
                    return Self.frame(localBounds: local, matrix: m)
                }
            }
            let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(layers[$1.0].worldShape($1.1).bounds) }
            return bounds.isNull ? nil : SelectionFrame(rect: bounds)
        case .reference(let id):
            return referenceIndex(id).map { SelectionFrame(corners: references[$0].corners) }
        }
    }

    /// A frame round `localBounds` carried into the world by `m`, so it turns and
    /// stretches with the object.
    private static func frame(localBounds: Rect, matrix m: Affine2D) -> SelectionFrame? {
        localBounds.isNull ? nil : SelectionFrame(corners: localBounds.corners.map(m.apply))
    }

    /// The layer index and group when `selection` is every shape of one group, so
    /// transforming it changes the group's transform.
    func wholeGroup(_ selection: Selection) -> (Int, ShapeGroup)? {
        guard case .shapes = selection else { return nil }
        let indices = shapeIndices(in: selection)
        guard let first = indices.first, let id = layers[first.0].shapes[first.1].group,
              let group = layers[first.0].group(id) else { return nil }
        guard indices.allSatisfy({ $0.0 == first.0 }), layers[first.0].isWhole(group: id, in: Set(indices.map(\.1))),
              indices.allSatisfy({ layers[first.0].shapes[$0.1].group == id }) else { return nil }
        return (first.0, group)
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
        let bounds = shapeIndices(in: selection).reduce(Rect.null) { $0.union(layers[$1.0].worldShape($1.1).geometryBounds) }
        return bounds.isNull ? nil : bounds
    }

    /// Sets the path of the shape at `idx` (layer and shape index) from a path in world
    /// space, keeping the shape's transform. Ignored when the shape's transform collapses
    /// it, so it can't be edited.
    public mutating func setWorldPath(_ path: BezierPath, at idx: (Int, Int)) {
        // A text's glyphs are laid out from its words, and an image's frame isn't edited.
        guard layers[idx.0].shapes[idx.1].hasEditablePath else { return }
        let m = layers[idx.0].worldMatrix(ofShape: idx.1)
        if m == .identity {
            layers[idx.0].shapes[idx.1].path = path
        } else if let inverse = m.inverted {
            var local = path
            local.apply(inverse)
            layers[idx.0].shapes[idx.1].path = local
        }
    }

    /// Changes the path of the shape at `idx` in world space (see `setWorldPath`).
    public mutating func updateWorldPath(at idx: (Int, Int), _ change: (inout BezierPath) -> Void) {
        guard layers[idx.0].shapes[idx.1].hasEditablePath else { return }
        if layers[idx.0].worldMatrix(ofShape: idx.1) == .identity {
            change(&layers[idx.0].shapes[idx.1].path)
            return
        }
        var path = layers[idx.0].worldShape(idx.1).path
        change(&path)
        setWorldPath(path, at: idx)
    }

    /// Shape `ref` as it is drawn: in world space, with no transform.
    public func worldShape(_ ref: ShapeRef) -> VectorShape? {
        indices(ref).map { layers[$0.0].worldShape($0.1) }
    }

    /// Moves, turns, scales or flips the selection by `t` (in world space), as the Select
    /// tool does: by changing the transform of the selected layers, of a wholly selected
    /// group, or of each selected shape, so the points stay as they are. When the result
    /// can't be a transform (a stretch across a turned object skews it), `t` goes into
    /// the points instead. `pivot` (world space), when given, becomes the pivot of the
    /// shapes' and group's transforms, so the turn they keep is about it.
    public mutating func apply(_ t: Affine2D, to selection: Selection, pivot: Vec2? = nil) {
        switch selection {
        case .none:
            break
        case .layer(let id):
            if let p = layerIndex(id) { transformLayer(p, by: t) }
        case .layers(let ids):
            for p in layers.indices where ids.contains(layers[p].id) { transformLayer(p, by: t) }
        case .shape, .shapes:
            if let (p, group) = wholeGroup(selection), let g = layers[p].groups.firstIndex(where: { $0.id == group.id }) {
                let parent = layers[p].transform.matrix
                if let inverse = parent.inverted {
                    let old = layers[p].groups[g].transform
                    var start = old
                    if let pivot, let toOwn = (parent * old.matrix).inverted { start = old.withPivot(toOwn.apply(pivot)) }
                    if let next = Transform(matrix: inverse * t * parent * old.matrix, pivot: start.pivot, near: old.rotation) {
                        layers[p].groups[g].transform = next
                        return
                    }
                }
            }
            for (p, s) in shapeIndices(in: selection) { transformShape(p, s, by: t, pivot: pivot) }
        case .reference(let id):
            guard let r = referenceIndex(id) else { return }
            references[r].apply(t)
        }
    }

    /// `apply` for layer index `p`: its transform takes `t`, about its own pivot.
    private mutating func transformLayer(_ p: Int, by t: Affine2D) {
        let old = layers[p].transform
        if let next = Transform(matrix: t * old.matrix, pivot: old.pivot, near: old.rotation) {
            layers[p].transform = next
        } else {
            for s in layers[p].shapes.indices { layers[p].updateWorldShape(s) { $0.apply(t) } }
        }
    }

    /// `apply` for shape `s` of layer index `p`.
    private mutating func transformShape(_ p: Int, _ s: Int, by t: Affine2D, pivot: Vec2?) {
        let layer = layers[p]
        let parent = layer.parentMatrix(group: layer.shapes[s].group)
        let old = layer.shapes[s].transform
        if let inverse = parent.inverted {
            var start = old
            if let pivot, let toOwn = (parent * old.matrix).inverted { start = old.withPivot(toOwn.apply(pivot)) }
            if let next = Transform(matrix: inverse * t * parent * old.matrix, pivot: start.pivot, near: old.rotation) {
                layers[p].shapes[s].transform = next
                return
            }
        }
        layers[p].updateWorldShape(s) { $0.apply(t) }
    }

    /// The drawing as it is drawn: every layer, group and shape transform applied to the
    /// points, and cleared (a layer keeps its pivot, now in the world). Ids and the rest
    /// are unchanged. Renderers, exports and the shape index work from this. Without
    /// transforms it is the drawing itself.
    public var world: Drawing {
        guard layers.contains(where: \.needsWorld) else { return self }
        var copy = self
        copy.layers = layers.map(Drawing.drawnLayer)
        return copy
    }

    /// `layer` as it is drawn (see `world`): `worldLayer`, with text shapes' glyphs laid
    /// out in their paths.
    static func drawnLayer(_ layer: Layer) -> Layer {
        guard layer.needsWorld else { return layer }
        var copy = layer
        copy.shapes = layer.worldShapes
        guard layer.hasTransforms else { return copy }
        copy.transform = Transform(pivot: layer.worldPivot)
        for g in layer.groups.indices { copy.groups[g].transform = .identity }
        return copy
    }

    /// `layer` with every layer, group and shape transform applied to the points and
    /// cleared (the layer keeps its pivot, now in the world), for keeping in a drawing.
    /// A text shape can't take a transform into points, so it takes its whole placement
    /// as its own transform instead.
    public static func worldLayer(_ layer: Layer) -> Layer {
        guard layer.hasTransforms else { return layer }
        var copy = layer
        copy.shapes = layer.shapes.indices.map { i in
            layer.shapes[i].isLaidOut ? layer.shapes[i].bakedKeepingLayout(layer.worldMatrix(ofShape: i)) : layer.worldShape(i)
        }
        copy.transform = Transform(pivot: layer.worldPivot)
        for g in layer.groups.indices { copy.groups[g].transform = .identity }
        return copy
    }

    public func applying(_ t: Affine2D, to selection: Selection, pivot: Vec2? = nil) -> Drawing {
        var copy = self
        copy.apply(t, to: selection, pivot: pivot)
        return copy
    }
}
