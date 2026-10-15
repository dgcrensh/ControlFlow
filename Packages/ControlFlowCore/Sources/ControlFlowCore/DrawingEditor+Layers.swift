import Foundation

/// Groups: named sets of shapes inside one part that select, arrange and copy together.
extension Drawing {
    /// The group a selection is, when its shapes are all in one group of one part and
    /// cover every editable shape of it.
    public func selectedGroup(_ selection: Selection) -> (part: Int, group: ShapeGroup)? {
        if case .layer = selection { return nil }
        let indices = shapeIndices(in: selection)
        guard let first = indices.first, let id = parts[first.0].shapes[first.1].group,
              indices.allSatisfy({ $0.0 == first.0 && parts[$0.0].shapes[$0.1].group == id }) else { return nil }
        let part = parts[first.0]
        guard let group = part.group(id) else { return nil }
        let editable = part.members(ofGroup: id).filter(part.isEditable)
        guard Set(editable).isSubset(of: Set(indices.map(\.1))) else { return nil }
        return (part.id, group)
    }

    /// True when every group has shapes, its shapes sit together, group ids are not
    /// repeated, and every shape's group exists in its part.
    public var groupsAreValid: Bool {
        var ids = Set<Int>()
        for part in parts {
            for group in part.groups {
                guard ids.insert(group.id).inserted else { return false }
                let members = part.members(ofGroup: group.id)
                guard let first = members.first, let last = members.last, last - first + 1 == members.count else { return false }
            }
            for shape in part.shapes {
                if let g = shape.group, part.group(g) == nil { return false }
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
        for p in parts.indices {
            var part = parts[p]
            var groups: [ShapeGroup] = []
            for group in part.groups where !groups.contains(where: { $0.id == group.id }) {
                groups.append(group)
            }
            let known = Set(groups.map(\.id))
            for s in part.shapes.indices {
                if let g = part.shapes[s].group, !known.contains(g) { part.shapes[s].group = nil }
            }
            var repaired: [ShapeGroup] = []
            for group in groups {
                // Each run of the group's shapes; the first keeps the id unless another part has it.
                var runs: [[Int]] = []
                for i in part.members(ofGroup: group.id) {
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
                    for i in run { part.shapes[i].group = id }
                }
            }
            part.groups = repaired
            parts[p] = part
        }
    }

    /// Gives `part`'s groups fresh ids (for a copy of a part), keeping its shapes in them.
    mutating func renewGroups(of part: inout Part) {
        var fresh: [Int: Int] = [:]
        for g in part.groups.indices {
            let id = makeID()
            fresh[part.groups[g].id] = id
            part.groups[g].id = id
        }
        for s in part.shapes.indices {
            part.shapes[s].group = part.shapes[s].group.flatMap { fresh[$0] }
        }
    }
}

/// Group, ungroup, rename and add to group. Each command is one undo step.
extension DrawingEditor {
    /// The group the selection is, if it is one whole group.
    public var selectedGroup: (part: Int, group: ShapeGroup)? { drawing.selectedGroup(selection) }

    /// The group being edited on its own, if any.
    public var isolatedGroupInfo: ShapeGroup? {
        guard let id = isolatedGroup, let part = isolatedPart.flatMap({ drawing.part($0) }) else { return nil }
        return part.group(id)
    }

    /// Adds `shape` to part index `p` where new art goes: on top of the isolated group
    /// (joining it) when the part is the one being edited in, otherwise on top of the part.
    /// Does not record undo.
    mutating func addToActiveLayer(_ shape: inout VectorShape, part p: Int) {
        let part = drawing.parts[p]
        if let group = isolatedGroup, part.id == isolatedPart, let last = part.members(ofGroup: group).last {
            shape.group = group
            drawing.parts[p].shapes.insert(shape, at: last + 1)
        } else {
            drawing.parts[p].shapes.append(shape)
        }
    }

    /// The part all the selected shapes are in, and their indices, when they are all in one part.
    private var selectionInOnePart: (part: Int, indices: [Int])? {
        let targets = drawing.shapeIndices(in: selection)
        guard let first = targets.first, targets.allSatisfy({ $0.0 == first.0 }) else { return nil }
        return (first.0, targets.map(\.1))
    }

    /// True when two or more shapes of one part are selected and they aren't already
    /// exactly one group.
    public var canGroupSelection: Bool {
        guard let sel = selectionInOnePart, sel.indices.count >= 2 else { return false }
        if let group = selectedGroup?.group {
            return drawing.parts[sel.part].members(ofGroup: group.id).count != sel.indices.count
        }
        return true
    }

    /// True when the selection holds shapes from more than one part, which can't be grouped.
    public var selectionSpansParts: Bool {
        Set(drawing.shapeIndices(in: selection).map(\.0)).count > 1
    }

    /// Groups the selected shapes, which must all be in one part. They move to sit
    /// together just below the topmost of them, keeping their order, and leave any
    /// group they were in (groups don't nest). The new group is selected.
    public mutating func groupSelection(name: String? = nil) {
        guard canGroupSelection, let sel = selectionInOnePart else { return }
        cancelGesture()
        let before = drawing
        let p = sel.part
        let part = drawing.parts[p]
        let picked = Set(sel.indices)
        let top = sel.indices.max()!
        var others = part.shapes.indices.filter { !picked.contains($0) }.map { part.shapes[$0] }
        var insertAt = part.shapes.indices.filter { !picked.contains($0) && $0 < top }.count
        // Not inside another group: past the rest of it.
        if insertAt > 0, insertAt < others.count, let g = others[insertAt].group, others[insertAt - 1].group == g {
            while insertAt < others.count, others[insertAt].group == g { insertAt += 1 }
        }
        let id = drawing.makeID()
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let groupName = trimmed.isEmpty ? part.uniqueGroupName("Group \(part.groups.count + 1)") : trimmed
        var grouped = sel.indices.sorted().map { part.shapes[$0] }
        for s in grouped.indices { grouped[s].group = id }
        others.insert(contentsOf: grouped, at: insertAt)
        drawing.parts[p].shapes = others
        drawing.parts[p].groups.append(ShapeGroup(id: id, name: groupName))
        commit(from: before)
        selection = .covering(Set(grouped.map { ShapeRef(part: part.id, shape: $0.id) }))
    }

    /// True when any selected shape is in a group.
    public var canUngroupSelection: Bool {
        drawing.shapeIndices(in: selection).contains { drawing.parts[$0.0].shapes[$0.1].group != nil }
    }

    /// Dissolves every group a selected shape is in. The shapes stay where they are,
    /// and stay selected.
    public mutating func ungroupSelection() {
        guard canUngroupSelection else { return }
        cancelGesture()
        let before = drawing
        for p in Set(drawing.shapeIndices(in: selection).map(\.0)) {
            let doomed = Set(drawing.shapeIndices(in: selection).filter { $0.0 == p }
                .compactMap { drawing.parts[p].shapes[$0.1].group })
            for s in drawing.parts[p].shapes.indices {
                if let g = drawing.parts[p].shapes[s].group, doomed.contains(g) { drawing.parts[p].shapes[s].group = nil }
            }
            drawing.parts[p].groups.removeAll { doomed.contains($0.id) }
        }
        commit(from: before)
    }

    /// Renames group `id` in part `part`. Names are trimmed; an empty name is ignored.
    public mutating func renameGroup(_ id: Int, inPart part: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let p = drawing.partIndex(part),
              let g = drawing.parts[p].groups.firstIndex(where: { $0.id == id }) else { return }
        let before = drawing
        drawing.parts[p].groups[g].name = trimmed
        commit(from: before)
    }

    /// True when group `id` of part `part` has a shape below it to clip to.
    public func canClipGroup(_ id: Int, inPart part: Int) -> Bool {
        guard let part = drawing.part(part), let first = part.members(ofGroup: id).first else { return false }
        return first > 0
    }

    /// Makes group `id` of part `part` draw only inside the shape below it, or draws it
    /// whole again. One undo step.
    public mutating func setGroupClipped(_ id: Int, inPart part: Int, _ clipped: Bool) {
        guard let p = drawing.partIndex(part), let g = drawing.parts[p].groups.firstIndex(where: { $0.id == id }),
              !clipped || canClipGroup(id, inPart: part) else { return }
        let before = drawing
        drawing.parts[p].groups[g].isClipped = clipped
        commit(from: before)
    }

    /// The groups the selected shapes can be added to: the other groups of their part.
    public var groupsToAddSelectionTo: [ShapeGroup] {
        guard let sel = selectionInOnePart else { return [] }
        let part = drawing.parts[sel.part]
        return part.groupRuns.map(\.group).filter { group in
            sel.indices.contains { part.shapes[$0].group != group.id }
        }
    }

    /// Moves the selected shapes into group `id` of their part, on top of its shapes,
    /// keeping their order. The selection stays on the moved shapes.
    public mutating func addSelection(toGroup id: Int) {
        guard let sel = selectionInOnePart, groupsToAddSelectionTo.contains(where: { $0.id == id }) else { return }
        cancelGesture()
        let before = drawing
        let p = sel.part
        let part = drawing.parts[p]
        let picked = Set(sel.indices.filter { part.shapes[$0].group != id })
        var shapes = part.shapes.indices.filter { !picked.contains($0) }.map { part.shapes[$0] }
        guard let last = shapes.lastIndex(where: { $0.group == id }) else { return }
        var moving = picked.sorted().map { part.shapes[$0] }
        for s in moving.indices { moving[s].group = id }
        shapes.insert(contentsOf: moving, at: last + 1)
        drawing.parts[p].shapes = shapes
        commit(from: before)
    }
}
