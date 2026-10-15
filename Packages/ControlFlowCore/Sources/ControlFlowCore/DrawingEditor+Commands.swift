import Foundation

/// Point editing, path commands, flips and numeric edits. Each call is one undo step.
extension DrawingEditor {
    // MARK: Anchors

    public var canDeleteSelectedAnchor: Bool { activeShape != nil && !selectedAnchors.isEmpty }

    /// Deletes the selected anchors. The shape keeps its form: neighbours keep their
    /// handle directions and the gap is healed. A shape left with too few points is deleted.
    public mutating func deleteSelectedAnchors() {
        guard let ref = activeShape, !selectedAnchors.isEmpty, let path = drawing.shape(ref)?.path else { return }
        cancelGesture()
        let doomed = selectedAnchors.filter { path.points.indices.contains($0) }
        let minimum = path.closed ? 3 : 2
        let before = drawing
        if path.points.count - doomed.count < minimum {
            removeShape(ref)
            selection = .none
        } else {
            if let idx = drawing.indices(ref),
               let changed = changingPoints(of: drawing.parts[idx.0].shapes[idx.1],
                                            { var p = $0; p.removePoints(at: doomed); return p }) {
                drawing.parts[idx.0].shapes[idx.1] = changed
            }
            selectedAnchors = []
        }
        commit(from: before)
    }

    public mutating func deleteSelectedAnchor() { deleteSelectedAnchors() }

    /// The handle mode shared by the selected anchors, or nil when none is selected or they differ.
    public var selectedAnchorMode: HandleMode? {
        guard let ref = activeShape, let path = drawing.shape(ref)?.path else { return nil }
        let modes = Set(selectedAnchors.compactMap { path.points.indices.contains($0) ? path.points[$0].mode : nil })
        return modes.count == 1 ? modes.first : nil
    }

    /// The selected anchors' smooth state, when they agree.
    public var selectedAnchorIsSmooth: Bool? { selectedAnchorMode.map { $0 != .corner } }

    public mutating func setSelectedAnchorMode(_ mode: HandleMode) {
        guard let ref = activeShape, !selectedAnchors.isEmpty else { return }
        let anchors = selectedAnchors
        editShape(ref) { shape in
            for i in anchors where shape.path.points.indices.contains(i) { shape.path.setMode(i, mode) }
        }
    }

    public mutating func toggleSelectedAnchorSmooth() {
        setSelectedAnchorMode(selectedAnchorMode == .corner ? .smooth : .corner)
    }

    /// Retracts the selected anchors' handles into sharp corners.
    public mutating func breakSelectedAnchorHandles() {
        guard let ref = activeShape, !selectedAnchors.isEmpty else { return }
        let anchors = selectedAnchors
        editShape(ref) { shape in
            for i in anchors where shape.path.points.indices.contains(i) { shape.path.breakHandles(i) }
        }
    }

    // MARK: Edge outlines

    /// The segments of the point-edited shape whose two end anchors are both selected.
    public var selectedEdges: [Int] {
        guard let ref = activeShape, let path = drawing.shape(ref)?.path, selectedAnchors.count >= 2 else { return [] }
        let n = path.points.count
        return (0..<path.segmentCount).filter { selectedAnchors.contains($0) && selectedAnchors.contains(($0 + 1) % n) }
    }

    /// Whether the selected edges are outlined: false only when every one is bare,
    /// nil when no edge is selected.
    public var selectedEdgesStroked: Bool? {
        guard let ref = activeShape, let path = drawing.shape(ref)?.path else { return nil }
        let edges = selectedEdges
        guard !edges.isEmpty else { return nil }
        return edges.contains { path.points[$0].stroked }
    }

    /// Turns the outline on or off along the selected edges. A bare edge keeps its
    /// fill, so the shape still covers what lies beneath it there.
    public mutating func setSelectedEdgesStroked(_ stroked: Bool) {
        guard let ref = activeShape else { return }
        let edges = selectedEdges
        guard !edges.isEmpty else { return }
        editShape(ref) { shape in
            for i in edges { shape.path.points[i].stroked = stroked }
        }
    }

    /// Hides the outline on the selected edges, or shows it again when they are all bare.
    public mutating func toggleSelectedEdgesStroked() {
        guard let stroked = selectedEdgesStroked else { return }
        setSelectedEdgesStroked(!stroked)
    }

    // MARK: Split and join

    public var canSplitAtSelectedAnchor: Bool {
        guard let ref = activeShape, let a = selectedAnchor, let path = drawing.shape(ref)?.path else { return false }
        return path.split(at: a) != nil
    }

    /// Cuts the shape at the selected anchor into separate shapes (or opens a closed
    /// one). The pieces keep the shape's style and part, and are selected.
    public mutating func splitAtSelectedAnchor() {
        guard let ref = activeShape, let a = selectedAnchor, let shape = drawing.shape(ref),
              shape.path.split(at: a) != nil, let idx = drawing.indices(ref) else { return }
        cancelGesture()
        guard let pieces = changingPoints(of: shape, { $0.split(at: a) }) else { return }
        let before = drawing
        drawing.parts[idx.0].shapes[idx.1] = pieces[0]
        var refs: Set<ShapeRef> = [ref]
        var insertAt = idx.1 + 1
        for piece in pieces.dropFirst() {
            var copy = piece
            copy.id = drawing.makeID()
            drawing.parts[idx.0].shapes.insert(copy, at: insertAt)
            insertAt += 1
            refs.insert(ShapeRef(part: ref.part, shape: copy.id))
        }
        selection = .covering(refs)
        commit(from: before)
    }

    public var canJoinSelection: Bool {
        let open = drawing.shapeRefs(in: selection).compactMap { drawing.shape($0) }.filter { !$0.path.closed }
        if open.count >= 2 { return true }
        return drawing.shapeRefs(in: selection).count == 1 && open.first.map { $0.path.points.count >= 3 } == true
    }

    /// Joins the selected open shapes end to end (nearest ends first, into the lowest
    /// shape). A single open shape is closed instead.
    public mutating func joinSelection() {
        let refs = drawing.shapeRefs(in: selection)
        guard let first = refs.first, canJoinSelection else { return }
        cancelGesture()
        let before = drawing
        if refs.count == 1 {
            if let idx = drawing.indices(first) {
                let shape = drawing.parts[idx.0].shapes[idx.1]
                let ends = (shape.path.endPoint(.start), shape.path.endPoint(.end))
                let merge = ends.0.flatMap { a in ends.1.map { a.distance(to: $0) <= 1e-6 } } ?? false
                if let closed = changingPoints(of: shape,
                                               { $0.closedByJoiningEnds(mergeWithin: merge ? .infinity : -1) }) {
                    drawing.parts[idx.0].shapes[idx.1] = closed
                }
            }
        } else {
            var remaining = refs.dropFirst().filter { drawing.shape($0).map { !$0.path.closed } == true }
            while !remaining.isEmpty, let base = drawing.shape(first), !base.path.closed {
                var best: (index: Int, aEnd: PathEnd, bEnd: PathEnd, distance: Double)?
                for (i, ref) in remaining.enumerated() {
                    guard let other = drawing.shape(ref) else { continue }
                    for aEnd in [PathEnd.start, .end] {
                        for bEnd in [PathEnd.start, .end] {
                            guard let pa = base.path.endPoint(aEnd), let pb = other.path.endPoint(bEnd) else { continue }
                            let d = pa.distance(to: pb)
                            if d < (best?.distance ?? .infinity) { best = (i, aEnd, bEnd, d) }
                        }
                    }
                }
                guard let best else { break }
                _ = joinShapes(first, best.aEnd, remaining[best.index], best.bEnd)
                remaining.remove(at: best.index)
            }
        }
        let saved = style
        selection = .shape(part: first.part, shape: first.shape)
        style = saved
        commit(from: before)
    }

    // MARK: Transforms

    /// True when the selection is art that can be flipped and resized.
    public var canTransformSelection: Bool { !drawing.shapeIndices(in: selection).isEmpty }

    /// Applies `t` to the selection as one undo step.
    mutating func transformSelection(_ t: Affine2D, key: String? = nil) {
        guard canTransformSelection || selectionIsReference else { return }
        cancelGesture()
        let before = drawing
        drawing.apply(t, to: selection)
        commit(from: before, key: key)
    }

    private var selectionIsReference: Bool {
        if case .reference = selection { return true }
        return false
    }

    /// Mirrors the selection about the middle of its frame.
    public mutating func flipSelection(horizontal: Bool) {
        guard canTransformSelection, let center = drawing.frame(of: selection)?.center else { return }
        let flip = horizontal ? Affine2D.scale(x: -1, y: 1) : Affine2D.scale(x: 1, y: -1)
        transformSelection(Affine2D.translation(center) * flip * Affine2D.translation(-center))
    }

    /// Turns the selection about its pivot.
    public mutating func rotateSelection(byDegrees degrees: Double) {
        guard let center = pivot, abs(degrees) > 1e-12 else { return }
        let turn = Affine2D.translation(center) * Affine2D.rotation(degrees * .pi / 180) * Affine2D.translation(-center)
        transformSelection(turn)
    }

    /// Resets a dragged pivot: a part's goes back to the middle of its art.
    public mutating func resetPivot() {
        customPivot = nil
        guard case .layer(let id) = selection, let i = drawing.partIndex(id), let frame = drawing.frame(of: selection) else { return }
        let before = drawing
        drawing.parts[i].pivot = frame.center
        commit(from: before)
    }

    // MARK: Numeric edits (the inspector)

    /// The selection's outline-free bounds, for the X, Y, width and height fields.
    public var selectionGeometry: Rect? { drawing.geometryBounds(of: selection) }

    /// Moves the selection so its left edge and top edge are at `x` and `y`.
    public mutating func setSelectionOrigin(x: Double? = nil, y: Double? = nil) {
        guard let bounds = selectionGeometry else { return }
        let delta = Vec2(x.map { $0 - bounds.minPoint.x } ?? 0, y.map { $0 - bounds.minPoint.y } ?? 0)
        guard delta != .zero else { return }
        transformSelection(.translation(delta), key: "inspector-origin-\(selection)")
    }

    /// Scales the selection along each given axis from its top-left corner. Reference
    /// images only scale uniformly, so they are left alone.
    public mutating func setSelectionSize(width: Double? = nil, height: Double? = nil) {
        guard canTransformSelection, let bounds = selectionGeometry else { return }
        var kx = 1.0, ky = 1.0
        if let width, bounds.width > 1e-9 { kx = max(width, 0.01) / bounds.width }
        if let height, bounds.height > 1e-9 { ky = max(height, 0.01) / bounds.height }
        guard kx != 1 || ky != 1 else { return }
        let origin = bounds.minPoint
        transformSelection(Affine2D.translation(origin) * Affine2D.scale(x: kx, y: ky) * Affine2D.translation(-origin),
                           key: "inspector-size-\(selection)")
    }

    /// The middle of the selected anchors.
    public var selectedAnchorsCentroid: Vec2? {
        guard let ref = activeShape, let path = drawing.shape(ref)?.path else { return nil }
        let points = selectedAnchors.compactMap { path.points.indices.contains($0) ? path.points[$0].position : nil }
        guard !points.isEmpty else { return nil }
        return points.reduce(Vec2.zero, +) / Double(points.count)
    }

    /// Moves the selected anchors so their middle is at `x` and `y`.
    public mutating func setSelectedAnchorsPosition(x: Double? = nil, y: Double? = nil) {
        guard let c = selectedAnchorsCentroid else { return }
        moveSelectedAnchors(by: Vec2(x.map { $0 - c.x } ?? 0, y.map { $0 - c.y } ?? 0), key: "inspector-anchor")
    }

    private mutating func moveSelectedAnchors(by delta: Vec2, key: String) {
        guard let ref = activeShape, delta != .zero else { return }
        let anchors = selectedAnchors
        editShape(ref, key: "\(key)-\(selection)") { shape in
            for i in anchors where shape.path.points.indices.contains(i) {
                shape.path.points[i].position = shape.path.points[i].position + delta
            }
        }
    }

    /// Nudges the selected anchors by `delta` world points, or the whole selection when
    /// no anchors are selected.
    public mutating func nudge(by delta: Vec2) {
        if !selectedAnchors.isEmpty, activeShape != nil {
            moveSelectedAnchors(by: delta, key: "nudge")
        } else {
            transformSelection(.translation(delta), key: "nudge-\(selection)")
        }
    }

    // MARK: Changing points

    /// `shape` with its path changed by `change`, one shape per path it gives (the first
    /// keeps the shape's id). Nil when `change` gives nil.
    func changingPoints(of shape: VectorShape, _ change: (BezierPath) -> [BezierPath]?) -> [VectorShape]? {
        change(shape.path)?.map { path in
            var out = shape
            out.path = path
            return out
        }
    }

    /// `changingPoints` for a change that keeps one path.
    func changingPoints(of shape: VectorShape, _ change: (BezierPath) -> BezierPath?) -> VectorShape? {
        changingPoints(of: shape, { path in change(path).map { [$0] } })?.first
    }
}
