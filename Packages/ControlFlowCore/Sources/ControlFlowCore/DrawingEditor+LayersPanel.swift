import Foundation

/// What the layers panel drives: the active layer new art goes into, selecting several
/// layers at once, groups' eyes and locks, and dragging rows of the layer tree.
extension DrawingEditor {
    // MARK: Active layer

    /// `targetLayer` when it can take new art: it exists and is neither hidden nor locked.
    var usableTargetLayer: Int? {
        guard let id = targetLayer, let layer = drawing.layer(id), !layer.isHidden, !layer.isLocked else { return nil }
        return id
    }

    /// The layer new strokes, pen paths and shapes go into: the isolated layer, else the
    /// layer made active in the panel, else (with auto-join on) the selected layer. Nil
    /// when each new piece of art starts a new layer.
    public var activeLayer: Int? {
        if let id = isolatedLayer ?? usableTargetLayer { return id }
        return autoJoinSelectedLayer ? selectedLayerID : nil
    }

    /// Makes layer `id` the one new art goes into, or with nil goes back to starting a
    /// new layer for each new piece of art. Not an undo step: it changes no art.
    public mutating func setActiveLayer(_ id: Int?) {
        if let id { guard drawing.layerIndex(id) != nil else { return } }
        targetLayer = id
    }

    // MARK: Selecting layers

    /// Selects the layers `ids` (one or several) as whole layers, leaving out hidden and
    /// locked ones. Selecting layers other than the isolated one ends isolation.
    public mutating func selectLayers(_ ids: Set<Int>) {
        let picked = ids.filter { id in drawing.layer(id).map { !$0.isHidden && !$0.isLocked } ?? false }
        cancelGesture()
        if let isolated = isolatedLayer, picked != [isolated] { exitIsolation() }
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

    /// Selects group `id` of layer `layer`: its editable shapes, as tapping it does.
    public mutating func selectGroup(_ id: Int, inLayer layer: Int) {
        guard let p = drawing.layerIndex(layer), drawing.layers[p].group(id) != nil,
              !drawing.layers[p].isHidden, !drawing.layers[p].isLocked else { return }
        let found = drawing.layers[p]
        let refs = found.members(ofGroup: id).filter(found.isEditable).map { ShapeRef(layer: layer, shape: found.shapes[$0].id) }
        guard !refs.isEmpty else { return }
        cancelGesture()
        if let isolated = isolatedLayer, isolated != layer { exitIsolation() }
        if isolatedGroup != id { isolatedGroup = nil }
        selection = .covering(Set(refs))
    }

    /// Hides or shows every shape of group `id` of layer `layer`.
    public mutating func setGroupHidden(_ id: Int, inLayer layer: Int, _ hidden: Bool) {
        changeGroup(id, inLayer: layer) { $0.isHidden = hidden }
    }

    /// Locks or unlocks every shape of group `id` of layer `layer`.
    public mutating func setGroupLocked(_ id: Int, inLayer layer: Int, _ locked: Bool) {
        changeGroup(id, inLayer: layer) { $0.isLocked = locked }
    }

    private mutating func changeGroup(_ id: Int, inLayer layer: Int, _ change: (inout VectorShape) -> Void) {
        guard let p = drawing.layerIndex(layer), drawing.layers[p].group(id) != nil else { return }
        cancelGesture()
        let before = drawing
        for s in drawing.layers[p].members(ofGroup: id) { change(&drawing.layers[p].shapes[s]) }
        // Hidden or locked art can't stay selected, or be edited inside.
        let selected = drawing.shapeIndices(in: selection)
        if selected.contains(where: { !drawing.layers[$0.0].isEditable($0.1) }) { selection = .none }
        if isolatedGroup == id, !drawing.layers[p].members(ofGroup: id).contains(where: drawing.layers[p].isEditable) {
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
              destination != source, destination != source + 1, let moving = drawing.layer(rows[source].layer.id)
        else { return }
        var others = rows
        others.remove(at: source)
        let drop = destination > source ? destination - 1 : destination
        let below = others[drop...].first { $0.kind == .layer }?.layer.id
        var layers = drawing.layers.filter { $0.id != moving.id }
        let slot = below.flatMap { id in layers.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        layers.insert(moving, at: slot)
        guard layers.map(\.id) != drawing.layers.map(\.id) else { return }
        cancelGesture()
        let before = drawing
        drawing.layers = layers
        commit(from: before)
    }
}
