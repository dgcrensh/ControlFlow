import Foundation

/// Groups: named sets of shapes inside one layer that select, arrange and copy together.
extension Drawing {
    /// The group a selection is, when its shapes are all in one group of one layer and
    /// cover every editable shape of it.
    public func selectedGroup(_ selection: Selection) -> (layer: Int, group: ShapeGroup)? {
        if case .layer = selection { return nil }
        let indices = shapeIndices(in: selection)
        guard let first = indices.first, let id = layers[first.0].shapes[first.1].group,
              indices.allSatisfy({ $0.0 == first.0 && layers[$0.0].shapes[$0.1].group == id }) else { return nil }
        let layer = layers[first.0]
        guard let group = layer.group(id) else { return nil }
        let editable = layer.members(ofGroup: id).filter(layer.isEditable)
        guard Set(editable).isSubset(of: Set(indices.map(\.1))) else { return nil }
        return (layer.id, group)
    }

    /// True when every group has shapes, its shapes sit together, group ids are not
    /// repeated, and every shape's group exists in its layer.
    public var groupsAreValid: Bool {
        var ids = Set<Int>()
        for layer in layers {
            for group in layer.groups {
                guard ids.insert(group.id).inserted else { return false }
                let members = layer.members(ofGroup: group.id)
                guard let first = members.first, let last = members.last, last - first + 1 == members.count else { return false }
            }
            for shape in layer.shapes {
                if let g = shape.group, layer.group(g) == nil { return false }
            }
        }
        return true
    }

    /// Makes the groups valid (see `groupsAreValid`): drops groups with no shapes and
    /// shapes' references to missing groups, gives repeated group ids fresh ones, and
    /// splits a group whose shapes are not together into one group per run, each
    /// keeping the name.
    public mutating func repairGroups() {
        var seen = Set<Int>()
        for p in layers.indices {
            var layer = layers[p]
            var groups: [ShapeGroup] = []
            for group in layer.groups where !groups.contains(where: { $0.id == group.id }) {
                groups.append(group)
            }
            let known = Set(groups.map(\.id))
            for s in layer.shapes.indices {
                if let g = layer.shapes[s].group, !known.contains(g) { layer.shapes[s].group = nil }
            }
            var repaired: [ShapeGroup] = []
            for group in groups {
                // Each run of the group's shapes; the first keeps the id unless another layer has it.
                var runs: [[Int]] = []
                for i in layer.members(ofGroup: group.id) {
                    if let last = runs.last?.last, last == i - 1 {
                        runs[runs.count - 1].append(i)
                    } else {
                        runs.append([i])
                    }
                }
                for (k, run) in runs.enumerated() {
                    let id = k == 0 && !seen.contains(group.id) ? group.id : makeID()
                    seen.insert(id)
                    repaired.append(ShapeGroup(id: id, name: group.name, isClipped: group.isClipped))
                    for i in run { layer.shapes[i].group = id }
                }
            }
            layer.groups = repaired
            layers[p] = layer
        }
    }

    /// Gives `layer`'s groups fresh ids (for a copy of a layer), keeping its shapes in them.
    mutating func renewGroups(of layer: inout Layer) {
        var fresh: [Int: Int] = [:]
        for g in layer.groups.indices {
            let id = makeID()
            fresh[layer.groups[g].id] = id
            layer.groups[g].id = id
        }
        for s in layer.shapes.indices {
            layer.shapes[s].group = layer.shapes[s].group.flatMap { fresh[$0] }
        }
    }
}

/// Group, ungroup, rename and add to group. Each command is one undo step.
extension DrawingEditor {
    /// The group the selection is, if it is one whole group.
    public var selectedGroup: (layer: Int, group: ShapeGroup)? { drawing.selectedGroup(selection) }

    /// The group being edited on its own, if any.
    public var isolatedGroupInfo: ShapeGroup? {
        guard let id = isolatedGroup, let layer = isolatedLayer.flatMap({ drawing.layer($0) }) else { return nil }
        return layer.group(id)
    }

    /// Adds `shape` to layer index `p` where new art goes: on top of the isolated group
    /// (joining it) when the layer is the one being edited in, otherwise on top of the layer.
    /// Does not record undo.
    mutating func addToActiveLayer(_ shape: inout VectorShape, layer p: Int) {
        let layer = drawing.layers[p]
        if let group = isolatedGroup, layer.id == isolatedLayer, let last = layer.members(ofGroup: group).last {
            shape.group = group
            drawing.layers[p].shapes.insert(shape, at: last + 1)
        } else {
            drawing.layers[p].shapes.append(shape)
        }
    }

    /// The layer all the selected shapes are in, and their indices, when they are all in one layer.
    private var selectionInOneLayer: (layer: Int, indices: [Int])? {
        let targets = drawing.shapeIndices(in: selection)
        guard let first = targets.first, targets.allSatisfy({ $0.0 == first.0 }) else { return nil }
        return (first.0, targets.map(\.1))
    }

    /// True when two or more shapes of one layer are selected and they aren't already
    /// exactly one group.
    public var canGroupSelection: Bool {
        guard let sel = selectionInOneLayer, sel.indices.count >= 2 else { return false }
        if let group = selectedGroup?.group {
            return drawing.layers[sel.layer].members(ofGroup: group.id).count != sel.indices.count
        }
        return true
    }

    /// True when the selection holds shapes from more than one layer, which can't be grouped.
    public var selectionSpansLayers: Bool {
        Set(drawing.shapeIndices(in: selection).map(\.0)).count > 1
    }

    /// Groups the selected shapes, which must all be in one layer. They move to sit
    /// together just below the topmost of them, keeping their order, and leave any
    /// group they were in (groups don't nest). The new group is selected.
    public mutating func groupSelection(name: String? = nil) {
        guard canGroupSelection, let sel = selectionInOneLayer else { return }
        cancelGesture()
        let before = drawing
        let p = sel.layer
        let layer = drawing.layers[p]
        let picked = Set(sel.indices)
        let top = sel.indices.max()!
        var others = layer.shapes.indices.filter { !picked.contains($0) }.map { layer.shapes[$0] }
        var insertAt = layer.shapes.indices.filter { !picked.contains($0) && $0 < top }.count
        // Not inside another group: past the rest of it.
        if insertAt > 0, insertAt < others.count, let g = others[insertAt].group, others[insertAt - 1].group == g {
            while insertAt < others.count, others[insertAt].group == g { insertAt += 1 }
        }
        let id = drawing.makeID()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupName = trimmed.isEmpty ? layer.uniqueGroupName("Group \(layer.groups.count + 1)") : trimmed
        var grouped = sel.indices.sorted().map { layer.shapes[$0] }
        for s in grouped.indices { grouped[s].group = id }
        others.insert(contentsOf: grouped, at: insertAt)
        drawing.layers[p].shapes = others
        drawing.layers[p].groups.append(ShapeGroup(id: id, name: groupName))
        commit(from: before)
        selection = .covering(Set(grouped.map { ShapeRef(layer: layer.id, shape: $0.id) }))
    }

    /// True when any selected shape is in a group.
    public var canUngroupSelection: Bool {
        drawing.shapeIndices(in: selection).contains { drawing.layers[$0.0].shapes[$0.1].group != nil }
    }

    /// Dissolves every group a selected shape is in. The shapes stay where they are,
    /// and stay selected.
    public mutating func ungroupSelection() {
        guard canUngroupSelection else { return }
        cancelGesture()
        let before = drawing
        for p in Set(drawing.shapeIndices(in: selection).map(\.0)) {
            let doomed = Set(drawing.shapeIndices(in: selection).filter { $0.0 == p }
                .compactMap { drawing.layers[p].shapes[$0.1].group })
            for s in drawing.layers[p].shapes.indices {
                if let g = drawing.layers[p].shapes[s].group, doomed.contains(g) { drawing.layers[p].shapes[s].group = nil }
            }
            drawing.layers[p].groups.removeAll { doomed.contains($0.id) }
        }
        commit(from: before)
    }

    /// Renames group `id` in layer `layer`. Names are trimmed; an empty name is ignored.
    public mutating func renameGroup(_ id: Int, inLayer layer: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let p = drawing.layerIndex(layer),
              let g = drawing.layers[p].groups.firstIndex(where: { $0.id == id }) else { return }
        let before = drawing
        drawing.layers[p].groups[g].name = trimmed
        commit(from: before)
    }

    /// True when group `id` of layer `layer` has a shape below it to clip to.
    public func canClipGroup(_ id: Int, inLayer layer: Int) -> Bool {
        guard let layer = drawing.layer(layer), let first = layer.members(ofGroup: id).first else { return false }
        return first > 0
    }

    /// Makes group `id` of layer `layer` draw only inside the shape below it, or draws it
    /// whole again. One undo step.
    public mutating func setGroupClipped(_ id: Int, inLayer layer: Int, _ clipped: Bool) {
        guard let p = drawing.layerIndex(layer), let g = drawing.layers[p].groups.firstIndex(where: { $0.id == id }),
              !clipped || canClipGroup(id, inLayer: layer) else { return }
        let before = drawing
        drawing.layers[p].groups[g].isClipped = clipped
        commit(from: before)
    }

    /// The groups the selected shapes can be added to: the other groups of their layer.
    public var groupsToAddSelectionTo: [ShapeGroup] {
        guard let sel = selectionInOneLayer else { return [] }
        let layer = drawing.layers[sel.layer]
        return layer.groupRuns.map(\.group).filter { group in
            sel.indices.contains { layer.shapes[$0].group != group.id }
        }
    }

    /// Moves the selected shapes into group `id` of their layer, on top of its shapes,
    /// keeping their order. The selection stays on the moved shapes.
    public mutating func addSelection(toGroup id: Int) {
        guard let sel = selectionInOneLayer, groupsToAddSelectionTo.contains(where: { $0.id == id }) else { return }
        cancelGesture()
        let before = drawing
        let p = sel.layer
        let layer = drawing.layers[p]
        let picked = Set(sel.indices.filter { layer.shapes[$0].group != id })
        var shapes = layer.shapes.indices.filter { !picked.contains($0) }.map { layer.shapes[$0] }
        guard let last = shapes.lastIndex(where: { $0.group == id }) else { return }
        var moving = picked.sorted().map { layer.shapes[$0] }
        for s in moving.indices { moving[s].group = id }
        shapes.insert(contentsOf: moving, at: last + 1)
        drawing.layers[p].shapes = shapes
        commit(from: before)
    }
}
