import Foundation

/// What the layers panel drives: the active layer new art goes into, selecting several
/// layers at once, groups' eyes and locks, and dragging rows of the layer tree.
extension DrawingEditor {
    // MARK: Active layer

    /// `targetLayer` when it can take new art: it exists and is neither hidden nor locked.
    var usableTargetLayer: Int? {
        guard let id = targetLayer, let part = drawing.part(id), !part.isHidden, !part.isLocked else { return nil }
        return id
    }

    /// The layer new strokes, pen paths and shapes go into: the isolated layer, else the
    /// layer made active in the panel, else (with auto-join on) the selected layer. Nil
    /// when each new piece of art starts a new part.
    public var activeLayer: Int? {
        if let id = isolatedPart ?? usableTargetLayer { return id }
        return autoJoinSelectedPart ? selectedPartID : nil
    }

    /// Makes layer `id` the one new art goes into, or with nil goes back to starting a
    /// new part for each new piece of art. Not an undo step: it changes no art.
    public mutating func setActiveLayer(_ id: Int?) {
        if let id { guard drawing.partIndex(id) != nil else { return } }
        targetLayer = id
    }

    // MARK: Selecting layers

    /// Selects the layers `ids` (one or several) as whole layers, leaving out hidden and
    /// locked ones. Selecting layers other than the isolated one ends isolation.
    public mutating func selectLayers(_ ids: Set<Int>) {
        let picked = ids.filter { id in drawing.part(id).map { !$0.isHidden && !$0.isLocked } ?? false }
        cancelGesture()
        if let isolated = isolatedPart, picked != [isolated] { exitIsolation() }
        isolatedGroup = nil
        selection = .coveringLayers(picked)
    }

    /// The layers the selection is, when it is one or more whole layers.
    public var selectedLayers: Set<Int> {
        switch selection {
        case .layer(let id): [id]
        case .layers(let ids): ids
        default: []
        }
    }

    // MARK: Groups in the panel

    /// Selects group `id` of layer `part`: its editable shapes, as tapping it does.
    public mutating func selectGroup(_ id: Int, inPart part: Int) {
        guard let p = drawing.partIndex(part), drawing.parts[p].group(id) != nil,
              !drawing.parts[p].isHidden, !drawing.parts[p].isLocked else { return }
        let layer = drawing.parts[p]
        let refs = layer.members(ofGroup: id).filter(layer.isEditable).map { ShapeRef(part: part, shape: layer.shapes[$0].id) }
        guard !refs.isEmpty else { return }
        cancelGesture()
        if let isolated = isolatedPart, isolated != part { exitIsolation() }
        if isolatedGroup != id { isolatedGroup = nil }
        selection = .covering(Set(refs))
    }

    /// Hides or shows every shape of group `id` of layer `part`.
    public mutating func setGroupHidden(_ id: Int, inPart part: Int, _ hidden: Bool) {
        changeGroup(id, inPart: part) { $0.isHidden = hidden }
    }

    /// Locks or unlocks every shape of group `id` of layer `part`.
    public mutating func setGroupLocked(_ id: Int, inPart part: Int, _ locked: Bool) {
        changeGroup(id, inPart: part) { $0.isLocked = locked }
    }

    private mutating func changeGroup(_ id: Int, inPart part: Int, _ change: (inout VectorShape) -> Void) {
        guard let p = drawing.partIndex(part), drawing.parts[p].group(id) != nil else { return }
        cancelGesture()
        let before = drawing
        for s in drawing.parts[p].members(ofGroup: id) { change(&drawing.parts[p].shapes[s]) }
        // Hidden or locked art can't stay selected, or be edited inside.
        let selected = drawing.shapeIndices(in: selection)
        if selected.contains(where: { !drawing.parts[$0.0].isEditable($0.1) }) { selection = .none }
        if isolatedGroup == id, !drawing.parts[p].members(ofGroup: id).contains(where: drawing.parts[p].isEditable) {
            isolatedGroup = nil
        }
        commit(from: before)
    }

    // MARK: Dragging tree rows

    /// Moves the layer on tree row `source` to before row `destination` (offsets into
    /// `rows`, as a list's drag reports them), as one undo step. The layer goes just in
    /// front of the next layer below where it is dropped, or to the very back when
    /// dropped last.
    public mutating func moveTreeRow(from source: Int, to destination: Int, in rows: [LayerTree.Row]) {
        guard rows.indices.contains(source), rows[source].kind == .layer, destination >= 0, destination <= rows.count,
              destination != source, destination != source + 1, let moving = drawing.part(rows[source].layer.id)
        else { return }
        var others = rows
        others.remove(at: source)
        let drop = destination > source ? destination - 1 : destination
        let below = others[drop...].first { $0.kind == .layer }?.layer.id
        var parts = drawing.parts.filter { $0.id != moving.id }
        let slot = below.flatMap { id in parts.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        parts.insert(moving, at: slot)
        guard parts.map(\.id) != drawing.parts.map(\.id) else { return }
        cancelGesture()
        let before = drawing
        drawing.parts = parts
        commit(from: before)
    }
}
