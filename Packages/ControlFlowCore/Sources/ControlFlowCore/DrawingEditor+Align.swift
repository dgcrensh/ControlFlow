import Foundation

/// What Align and Distribute line things up against: the selection's own bounds, or
/// the viewport.
public enum AlignTarget: Sendable {
    case selection, viewport
}

/// Align and distribute. Each command is one undo step, and only moves transforms
/// (or, with Direct Select, the selected anchors).
extension DrawingEditor {
    /// The selection split into what moves as one, each as a `Selection`, in draw order:
    /// each layer; each wholly selected group (unless it is the isolated group, or the
    /// tool is Direct Select) and each other shape; or the reference image.
    func alignmentUnits() -> [Selection] {
        switch selection {
        case .none:
            return []
        case .layer, .reference, .shape:
            return [selection]
        case .layers(let ids):
            return drawing.layers.filter { ids.contains($0.id) }.map { .layer($0.id) }
        case .shapes:
            let indices = drawing.shapeIndices(in: selection)
            var selectedInLayer: [Int: Set<Int>] = [:]
            for (p, s) in indices { selectedInLayer[p, default: []].insert(s) }
            var units: [Selection] = []
            var doneGroups: Set<ShapeRef> = []
            for (p, s) in indices {
                let layer = drawing.layers[p]
                let shape = layer.shapes[s]
                if tool != .directSelect, let g = shape.group,
                   !(isolatedLayer == layer.id && isolatedGroup == g),
                   layer.isWhole(group: g, in: selectedInLayer[p] ?? []) {
                    // Keyed by layer and group id, so each group is one unit.
                    guard doneGroups.insert(ShapeRef(layer: layer.id, shape: g)).inserted else { continue }
                    units.append(.shapes(Set(layer.members(ofGroup: g).map { ShapeRef(layer: layer.id, shape: layer.shapes[$0].id) })))
                } else {
                    units.append(.shape(layer: layer.id, shape: shape.id))
                }
            }
            return units
        }
    }

    /// The units with their world boxes (outline-free, axis-aligned); empty ones dropped.
    private func alignmentBoxes() -> [(unit: Selection, box: Rect)] {
        alignmentUnits().compactMap { unit in drawing.geometryBounds(of: unit).map { (unit, $0) } }
    }

    /// True when Align and Distribute work on the selected anchors (Direct Select with
    /// two or more selected).
    private var alignsAnchors: Bool {
        tool == .directSelect && selectedAnchors.count >= 2 && activeShape != nil
    }

    /// The number of things Align and Distribute move independently.
    public var alignmentUnitCount: Int { alignmentBoxes().count }

    /// True when Align applies: one or more units, or two or more anchors in Direct Select.
    public var canAlign: Bool { alignsAnchors || alignmentUnitCount >= 1 }

    /// True when Distribute applies: three or more units, or three or more anchors.
    public var canDistribute: Bool { alignsAnchors ? selectedAnchors.count >= 3 : alignmentUnitCount >= 3 }

    /// True when only one unit is selected, so Align always lines it up with the viewport.
    public var alignsToViewportOnly: Bool { !alignsAnchors && alignmentUnitCount == 1 }

    /// Lines the selection up on `edge`: each unit against the union of all of them, or
    /// against the viewport (always, with one unit). With Direct Select, the selected
    /// anchors line up with each other.
    public mutating func align(_ edge: AlignEdge, to target: AlignTarget) {
        if alignsAnchors {
            alignAnchors { Aligner.offsets(points: $0, edge: edge) }
            return
        }
        let boxes = alignmentBoxes()
        guard !boxes.isEmpty else { return }
        let reference = target == .viewport || boxes.count == 1
            ? drawing.viewport.bounds
            : boxes.reduce(Rect.null) { $0.union($1.box) }
        moveUnits(boxes.map(\.unit), by: Aligner.offsets(boxes: boxes.map(\.box), edge: edge, reference: reference))
    }

    /// Spaces three or more units (or anchors) evenly. Against the viewport, the outer
    /// ones move to its edges; otherwise they stay put.
    public mutating func distribute(_ mode: DistributeMode, to target: AlignTarget) {
        if alignsAnchors {
            alignAnchors { Distributor.offsets(points: $0, mode: mode) }
            return
        }
        let boxes = alignmentBoxes()
        let within = target == .viewport ? drawing.viewport.bounds : nil
        moveUnits(boxes.map(\.unit), by: Distributor.offsets(boxes: boxes.map(\.box), mode: mode, within: within))
    }

    /// Moves each unit by its offset, as one undo step (none when nothing moves).
    private mutating func moveUnits(_ units: [Selection], by offsets: [Vec2]) {
        guard offsets.contains(where: { $0 != .zero }) else { return }
        cancelGesture()
        let before = drawing
        for (unit, d) in zip(units, offsets) where d != .zero {
            drawing.apply(.translation(d), to: unit)
        }
        commit(from: before)
    }

    /// Moves the selected anchors by the offsets `offsets` gives for their world positions.
    private mutating func alignAnchors(_ offsets: ([Vec2]) -> [Vec2]) {
        cancelGesture()
        guard let ref = activeShape, let path = drawing.worldShape(ref)?.path else { return }
        let anchors = selectedAnchors.sorted().filter { path.points.indices.contains($0) }
        let moves = offsets(anchors.map { path.points[$0].position })
        moveAnchors(Dictionary(uniqueKeysWithValues: zip(anchors, moves)), key: nil)
    }
}
