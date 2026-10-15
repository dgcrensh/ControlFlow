import Foundation

/// Recognizes left and right in names such as `Arm.L`, `hand_r` or `Left Eye`, so
/// mirrored copies of layers and groups get the other side's name.
public enum SideName {
    public enum Side: Hashable, Sendable {
        case left, right
        public var opposite: Side { self == .left ? .right : .left }
    }

    /// Suffix pairs (left first), tried in order.
    private static let suffixes: [(String, String)] = [
        (".L", ".R"), ("_L", "_R"), ("-L", "-R"), (" L", " R"),
        (".l", ".r"), ("_l", "_r"), ("-l", "-r"),
    ]
    /// Whole-word pairs, matched anywhere in the name.
    private static let words: [(String, String)] = [("Left", "Right"), ("left", "right"), ("LEFT", "RIGHT")]

    /// The side a name says, if any.
    public static func side(of name: String) -> Side? {
        for (l, r) in suffixes {
            if name.hasSuffix(l), name.count > l.count { return .left }
            if name.hasSuffix(r), name.count > r.count { return .right }
        }
        for (l, r) in words {
            if containsWord(l, in: name) { return .left }
            if containsWord(r, in: name) { return .right }
        }
        return nil
    }

    /// The name with its side swapped (`Arm.L` to `Arm.R`), or nil when it names no side.
    public static func flipped(_ name: String) -> String? {
        for (l, r) in suffixes {
            if name.hasSuffix(l), name.count > l.count { return String(name.dropLast(l.count)) + r }
            if name.hasSuffix(r), name.count > r.count { return String(name.dropLast(r.count)) + l }
        }
        for (l, r) in words {
            if let range = wordRange(l, in: name) { return name.replacingCharacters(in: range, with: r) }
            if let range = wordRange(r, in: name) { return name.replacingCharacters(in: range, with: l) }
        }
        return nil
    }

    /// `name` with a `.L` or `.R` suffix for `side`, replacing any side it already names.
    public static func named(_ name: String, side: Side) -> String {
        if let current = self.side(of: name) {
            return current == side ? name : (flipped(name) ?? name)
        }
        return name + (side == .left ? ".L" : ".R")
    }

    /// The side a point is on, for a figure facing the viewer: its left is on the right
    /// of the screen.
    public static func side(ofX x: Double, axis: Double) -> Side {
        x > axis ? .left : .right
    }

    private static func containsWord(_ word: String, in name: String) -> Bool { wordRange(word, in: name) != nil }

    private static func wordRange(_ word: String, in name: String) -> Range<String.Index>? {
        var search = name.startIndex..<name.endIndex
        while let range = name.range(of: word, range: search) {
            let before = range.lowerBound == name.startIndex ? nil : name[name.index(before: range.lowerBound)]
            let after = range.upperBound == name.endIndex ? nil : name[range.upperBound]
            // A word: not inside a longer run of letters ("Cleft" is not "left"), except
            // that camel case starts a new word ("armLeft").
            let startsWord = before.map { !$0.isLetter || ($0.isLowercase && word.first!.isUppercase) } ?? true
            let endsWord = after.map { !$0.isLowercase } ?? true
            if startsWord, endsWord { return range }
            search = range.upperBound..<name.endIndex
        }
        return nil
    }
}

/// Symmetry and mirrored copies, and pivot snapping. Each command is one undo step.
extension DrawingEditor {
    // MARK: Snapping

    /// A dragged pivot snaps to other layers' pivots and the anchors of the art, whether
    /// or not snapping is on; then to the grid when snapping is on.
    func pivotSnapped(_ p: Vec2, part: Int?) -> Vec2 {
        var targets = drawing.partPivots(excluding: part)
        for part in drawing.parts where !part.isHidden {
            for (i, shape) in part.shapes.enumerated() where part.isShown(i) {
                targets += shape.path.points.map(\.position)
            }
        }
        if let best = targets.min(by: { $0.distance(to: p) < $1.distance(to: p) }), best.distance(to: p) <= snapRadius {
            return best
        }
        return snapped(p)
    }

    /// The part the selection is in, when it is all in one part.
    public var selectedPart: Int? {
        if let isolatedPart { return isolatedPart }
        let parts = Set(drawing.shapeRefs(in: selection).map(\.part))
        return parts.count == 1 ? parts.first : nil
    }

    // MARK: Symmetry

    /// The mirror image of `shape` across the symmetry axis, with a fresh id.
    mutating func mirrorImage(of shape: VectorShape) -> VectorShape {
        var copy = shape
        copy.id = drawing.makeID()
        copy.apply(symmetry.transform)
        return copy
    }

    /// True when `shape` already looks the same in the mirror (drawn centered on the axis).
    private func isSymmetric(_ shape: VectorShape) -> Bool {
        let a = shape.path.bounds()
        var mirrored = shape
        mirrored.apply(symmetry.transform)
        let b = mirrored.path.bounds()
        let tolerance = max(0.5, 0.01 * max(a.width, a.height))
        guard a.minPoint.isApproximately(b.minPoint, tolerance: tolerance),
              a.maxPoint.isApproximately(b.maxPoint, tolerance: tolerance) else { return false }
        // Same bounds: compare the outlines themselves.
        let pa = shape.path.flattened(tolerance: 0.5), pb = mirrored.path.flattened(tolerance: 0.5)
        return pa.allSatisfy { p in pb.contains { $0.distance(to: p) <= tolerance * 2 } }
    }

    /// With symmetry on, adds the mirror image of shape `ref` to its part, just above
    /// it. Does nothing to a shape that is its own mirror image. Does not record undo.
    mutating func addMirrorImage(of ref: ShapeRef) {
        guard symmetry.isEnabled, let idx = drawing.indices(ref) else { return }
        let shape = drawing.parts[idx.0].shapes[idx.1]
        guard !isSymmetric(shape) else { return }
        let copy = mirrorImage(of: shape)
        drawing.parts[idx.0].shapes.insert(copy, at: idx.1 + 1)
        // A part the shape just made keeps its pivot in the middle of both.
        if drawing.parts[idx.0].shapes.count == 2 { drawing.parts[idx.0].pivot = drawing.parts[idx.0].bounds.center }
    }

    /// What symmetry will add for the shape being drawn or the open pen path, for
    /// drawing as a preview.
    public var mirrorPreview: [BezierPath] {
        guard symmetry.isEnabled else { return [] }
        var refs: [ShapeRef] = []
        if let ref = shapeBeingDrawn { refs.append(ref) }
        if let pen = penPath { refs.append(ShapeRef(part: pen.part, shape: pen.shape)) }
        return refs.compactMap { drawing.shape($0) }.filter { !isSymmetric($0) }.map {
            var path = $0.path
            path.apply(symmetry.transform)
            return path
        }
    }

    /// Moves the symmetry axis to the middle of the selection.
    public mutating func centerSymmetryAxis() {
        if let frame = drawing.frame(of: selection) {
            symmetry.axis = frame.center.x
        }
    }

    // MARK: Duplicate mirrored

    /// True when the selection is art that can be copied mirrored.
    public var canDuplicateMirrored: Bool { !drawing.shapeIndices(in: selection).isEmpty }

    /// Copies the selection mirrored across the symmetry axis. A whole part becomes a new
    /// part named for the other side (`Arm.L` to `Arm.R`; a part naming no side gets one
    /// from where it is, and the copy the other). Shapes are copied into their own part.
    /// Selects the copy.
    public mutating func duplicateMirrored() {
        guard canDuplicateMirrored else { return }
        cancelGesture()
        let before = drawing
        if case .layer(let id) = selection, isolatedPart == nil, let part = drawing.part(id) {
            let side = SideName.side(ofX: part.bounds.center.x, axis: symmetry.axis)
            guard let copy = mirroredCopy(ofPart: id, side: side) else { return }
            selection = .layer(copy)
        } else {
            var copies: Set<ShapeRef> = []
            for p in Set(drawing.shapeIndices(in: selection).map(\.0)) {
                let part = drawing.parts[p]
                let selected = Set(drawing.shapeIndices(in: selection).filter { $0.0 == p }.map(\.1))
                // A wholly selected group is copied as a new group just above it, named for
                // the other side; other copies go just above their originals.
                let whole = part.groups.filter { group in
                    let members = part.members(ofGroup: group.id)
                    return !members.isEmpty && Set(members).isSubset(of: selected)
                }
                var fresh: [Int: Int] = [:]
                for group in whole {
                    let id = drawing.makeID()
                    fresh[group.id] = id
                    drawing.parts[p].groups.append(ShapeGroup(id: id, name: SideName.flipped(group.name) ?? group.name,
                                                                isClipped: group.isClipped))
                }
                var shapes: [VectorShape] = []
                var pending: [VectorShape] = []
                for (s, shape) in part.shapes.enumerated() {
                    shapes.append(shape)
                    guard selected.contains(s) else { continue }
                    var copy = mirrorImage(of: shape)
                    copies.insert(ShapeRef(part: part.id, shape: copy.id))
                    guard let g = shape.group, let id = fresh[g] else {
                        shapes.append(copy)
                        continue
                    }
                    copy.group = id
                    pending.append(copy)
                    if s + 1 == part.shapes.count || part.shapes[s + 1].group != g {
                        shapes += pending
                        pending = []
                    }
                }
                drawing.parts[p].shapes = shapes
            }
            let saved = style
            selection = .covering(copies)
            style = saved
        }
        commit(from: before)
    }

    /// Adds a mirrored copy of part `id` just above it, named for the other side, and
    /// returns its id. Names the original for `side` when it names none. Does not record undo.
    @discardableResult
    private mutating func mirroredCopy(ofPart id: Int, side: SideName.Side) -> Int? {
        guard let i = drawing.partIndex(id) else { return nil }
        if SideName.side(of: drawing.parts[i].name) == nil {
            drawing.parts[i].name = drawing.uniquePartName(SideName.named(drawing.parts[i].name, side: side), excluding: id)
        }
        var copy = drawing.parts[i]
        copy.id = drawing.makeID()
        copy.name = drawing.uniquePartName(SideName.flipped(copy.name) ?? copy.name)
        drawing.renewArtIDs(of: &copy)
        for s in copy.shapes.indices { copy.shapes[s].apply(symmetry.transform) }
        for g in copy.groups.indices { copy.groups[g].name = SideName.flipped(copy.groups[g].name) ?? copy.groups[g].name }
        copy.pivot = symmetry.mirror(copy.pivot)
        drawing.parts.insert(copy, at: i + 1)
        return copy.id
    }
}

extension Drawing {
    public func part(_ id: Int) -> Part? { partIndex(id).map { parts[$0] } }

    /// The other parts' pivots, for snapping a pivot.
    public func partPivots(excluding id: Int?) -> [Vec2] {
        parts.filter { $0.id != id && !$0.shapes.isEmpty && !$0.isHidden }.map(\.pivot)
    }

    /// Gives every shape and group `part` holds a new id (for a copy), keeping each shape
    /// in its group.
    public mutating func renewArtIDs(of part: inout Part) {
        var fresh: [Int: Int] = [:]
        for g in part.groups.indices {
            let id = makeID()
            fresh[part.groups[g].id] = id
            part.groups[g].id = id
        }
        for s in part.shapes.indices {
            part.shapes[s].id = makeID()
            part.shapes[s].group = part.shapes[s].group.flatMap { fresh[$0] }
        }
    }
}
