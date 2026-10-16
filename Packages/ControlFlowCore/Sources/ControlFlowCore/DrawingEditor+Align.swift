import Foundation

/// What Align and Distribute line things up against: the selection's own bounds, or
/// the viewport.
public enum AlignTarget: Sendable {
    case selection, viewport
}

/// Whether Align and Distribute apply to the selection (see `DrawingEditor.alignAvailability`).
public struct AlignAvailability: Equatable, Sendable {
    public var canAlign: Bool
    public var canDistribute: Bool
    public var alignsToViewportOnly: Bool
}

/// Align and distribute. Each command is one undo step, and only moves transforms
/// (or, with Direct Select, the selected anchors).
extension DrawingEditor {
    /// The selection split into what moves as one, each as a `Selection`, in draw order:
    /// each layer; each wholly selected group (unless it is the isolated group, or the
    /// tool is Direct Select) and each other shape; or the reference image.
    func alignmentUnits() -> [Selection] {
        alignmentUnitsWithShapes().map(\.unit)
    }

    /// The units, each with the layer and shape indices of its shapes, found in one walk
    /// of the selection so no unit is looked up again (a reference has none).
    private func alignmentUnitsWithShapes() -> [(unit: Selection, shapes: [(Int, Int)])] {
        switch selection {
        case .none:
            return []
        case .reference:
            return [(selection, [])]
        case .layer, .shape:
            return [(selection, drawing.shapeIndices(in: selection))]
        case .layers(let ids):
            return drawing.layers.indices.filter { ids.contains(drawing.layers[$0].id) }.map { p in
                (.layer(drawing.layers[p].id), drawing.layers[p].shapes.indices.map { (p, $0) })
            }
        case .shapes:
            let indices = drawing.shapeIndices(in: selection)
            var selectedInLayer: [Int: Set<Int>] = [:]
            for (p, s) in indices { selectedInLayer[p, default: []].insert(s) }
            var units: [(unit: Selection, shapes: [(Int, Int)])] = []
            // Each layer's groups and their members, found once per layer; and whether
            // each group is wholly selected, by layer index and group id.
            var groupMembers: [Int: [Int: [Int]]] = [:]
            var isWhole: [ShapeRef: Bool] = [:]
            var doneGroups: Set<ShapeRef> = []
            for (p, s) in indices {
                let layer = drawing.layers[p]
                let shape = layer.shapes[s]
                if tool != .directSelect, let g = shape.group, !(isolatedLayer == layer.id && isolatedGroup == g) {
                    if groupMembers[p] == nil {
                        groupMembers[p] = Dictionary(grouping: layer.shapes.indices.filter { layer.shapes[$0].group != nil }) {
                            layer.shapes[$0].group!
                        }
                    }
                    let members = groupMembers[p]?[g] ?? []
                    let key = ShapeRef(layer: p, shape: g)
                    if isWhole[key] == nil {
                        let selected = selectedInLayer[p] ?? []
                        isWhole[key] = !members.isEmpty && members.allSatisfy(selected.contains)
                    }
                    if isWhole[key] == true {
                        // Each group is one unit.
                        guard doneGroups.insert(key).inserted else { continue }
                        units.append((.shapes(Set(members.map { ShapeRef(layer: layer.id, shape: layer.shapes[$0].id) })),
                                      members.map { (p, $0) }))
                        continue
                    }
                }
                units.append((.shape(layer: layer.id, shape: shape.id), [(p, s)]))
            }
            return units
        }
    }

    /// The units with their world boxes (outline-free, axis-aligned); empty ones dropped.
    private func alignmentBoxes() -> [(unit: Selection, box: Rect)] {
        alignmentUnitsWithShapes().compactMap { unit, shapes in
            if case .reference = unit { return drawing.geometryBounds(of: unit).map { (unit, $0) } }
            let box = shapes.reduce(Rect.null) { $0.union(drawing.layers[$1.0].worldShape($1.1).geometryBounds) }
            return box.isNull ? nil : (unit, box)
        }
    }

    /// True when Align and Distribute work on the selected anchors (Direct Select with
    /// two or more selected).
    private var alignsAnchors: Bool {
        tool == .directSelect && selectedAnchors.count >= 2 && activeShape != nil
    }

    /// The number of things Align and Distribute move independently: the units of
    /// `alignmentBoxes()`, counted without baking any bounds.
    public var alignmentUnitCount: Int {
        alignmentUnitsWithShapes().count(where: { unit, shapes in
            if case .reference(let id) = unit { return drawing.referenceIndex(id) != nil }
            return shapes.contains { drawing.layers[$0.0].shapes[$0.1].hasGeometry }
        })
    }

    /// What Align and Distribute can do with the selection, from one count of its units,
    /// for a caller that reads all three (the app's refresh).
    public var alignAvailability: AlignAvailability {
        if alignsAnchors {
            return AlignAvailability(canAlign: true, canDistribute: selectedAnchors.count >= 3, alignsToViewportOnly: false)
        }
        let count = alignmentUnitCount
        return AlignAvailability(canAlign: count >= 1, canDistribute: count >= 3, alignsToViewportOnly: count == 1)
    }

    /// True when Align applies: one or more units, or two or more anchors in Direct Select.
    public var canAlign: Bool { alignAvailability.canAlign }

    /// True when Distribute applies: three or more units, or three or more anchors.
    public var canDistribute: Bool { alignAvailability.canDistribute }

    /// True when only one unit is selected, so Align always lines it up with the viewport.
    public var alignsToViewportOnly: Bool { alignAvailability.alignsToViewportOnly }

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
