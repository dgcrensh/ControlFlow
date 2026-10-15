import Foundation

/// How `arrange` moves the selection in draw order.
public enum ArrangeMove: Hashable, Sendable, CaseIterable {
    case bringToFront
    case bringForward
    case sendBackward
    case sendToBack
}

/// Isolation, hide and lock, arranging, duplicating, the clipboard, the scissors and
/// Pencil tool switching. Each command is one undo step.
extension DrawingEditor {
    // MARK: Isolation

    /// Edits `layer` on its own: the rest is dimmed and can't be touched, and new shapes
    /// join this layer, until `exitIsolation`.
    public mutating func isolate(layer id: Int) {
        guard drawing.layerIndex(id) != nil else { return }
        cancelGesture()
        if let pen = penPath, pen.layer != id { penFinish() }
        isolatedLayer = id
        isolatedGroup = nil
        if drawing.shapeRefs(in: selection).contains(where: { $0.layer != id }) { selection = .none }
    }

    /// Edits group `id` of layer `layer` on its own, one level in from isolating the layer:
    /// only the group's shapes can be picked (one at a time), and new shapes join the
    /// group, until `stepOutOfIsolation`.
    public mutating func isolate(group id: Int, inLayer layer: Int) {
        guard let p = drawing.layerIndex(layer), drawing.layers[p].group(id) != nil else { return }
        isolate(layer: layer)
        isolatedGroup = id
        let members = Set(drawing.layers[p].members(ofGroup: id).map { drawing.layers[p].shapes[$0].id })
        if drawing.shapeRefs(in: selection).contains(where: { !members.contains($0.shape) }) { selection = .none }
    }

    /// Ends isolation altogether.
    public mutating func exitIsolation() {
        isolatedLayer = nil
        isolatedGroup = nil
    }

    /// Goes one level out (Escape): from a group to its layer, selecting the group; from
    /// an isolated layer to the whole drawing; otherwise clears the selection.
    public mutating func stepOutOfIsolation() {
        cancelGesture()
        if let group = isolatedGroup, let layer = isolatedLayer, let p = drawing.layerIndex(layer) {
            isolatedGroup = nil
            let refs = drawing.layers[p].members(ofGroup: group).filter(drawing.layers[p].isEditable)
                .map { ShapeRef(layer: layer, shape: drawing.layers[p].shapes[$0].id) }
            selection = .covering(Set(refs))
        } else if isolatedLayer != nil {
            exitIsolation()
        } else {
            selection = .none
        }
    }

    // MARK: Hide and lock

    /// True when the selection is art that can be hidden or locked.
    public var canHideOrLockSelection: Bool { !drawing.shapeIndices(in: selection).isEmpty }

    public var hasHiddenArt: Bool {
        drawing.layers.contains { $0.isHidden || $0.shapes.contains(where: \.isHidden) }
    }

    public var hasLockedArt: Bool {
        drawing.layers.contains { $0.isLocked || $0.shapes.contains(where: \.isLocked) }
    }

    /// Hides the selected layer or shapes and deselects them.
    public mutating func hideSelection() {
        changeSelectedFlags { $0.isHidden = true } layer: { $0.isHidden = true }
    }

    /// Locks the selected layer or shapes and deselects them.
    public mutating func lockSelection() {
        changeSelectedFlags { $0.isLocked = true } layer: { $0.isLocked = true }
    }

    public mutating func setLayerHidden(_ id: Int, _ hidden: Bool) {
        changeLayer(id) { $0.isHidden = hidden }
    }

    public mutating func setLayerLocked(_ id: Int, _ locked: Bool) {
        changeLayer(id) { $0.isLocked = locked }
    }

    /// Shows every hidden layer and shape.
    public mutating func showAll() {
        changeEverything { $0.isHidden = false } layer: { $0.isHidden = false }
    }

    /// Unlocks every locked layer and shape.
    public mutating func unlockAll() {
        changeEverything { $0.isLocked = false } layer: { $0.isLocked = false }
    }

    private mutating func changeSelectedFlags(_ shapeChange: (inout VectorShape) -> Void, layer layerChange: (inout Layer) -> Void) {
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return }
        cancelGesture()
        let before = drawing
        if case .layer(let id) = selection, let i = drawing.layerIndex(id) {
            layerChange(&drawing.layers[i])
        } else if case .layers(let ids) = selection {
            for i in drawing.layers.indices where ids.contains(drawing.layers[i].id) { layerChange(&drawing.layers[i]) }
        } else {
            for (p, s) in targets { shapeChange(&drawing.layers[p].shapes[s]) }
        }
        selection = .none
        dropUneditableIsolation()
        commit(from: before)
    }

    /// Changes layer `id`.
    private mutating func changeLayer(_ id: Int, _ change: (inout Layer) -> Void) {
        guard let i = drawing.layerIndex(id) else { return }
        cancelGesture()
        let before = drawing
        change(&drawing.layers[i])
        // Hidden or locked art can't stay selected.
        let selected = drawing.shapeIndices(in: selection)
        if selected.contains(where: { !drawing.layers[$0.0].isEditable($0.1) }) { selection = .none }
        dropUneditableIsolation()
        commit(from: before)
    }

    private mutating func changeEverything(_ shapeChange: (inout VectorShape) -> Void, layer layerChange: (inout Layer) -> Void) {
        cancelGesture()
        let before = drawing
        for p in drawing.layers.indices {
            layerChange(&drawing.layers[p])
            for s in drawing.layers[p].shapes.indices { shapeChange(&drawing.layers[p].shapes[s]) }
        }
        commit(from: before)
    }

    /// Isolation ends when its layer is hidden.
    private mutating func dropUneditableIsolation() {
        if let id = isolatedLayer, let i = drawing.layerIndex(id), drawing.layers[i].isHidden { exitIsolation() }
    }

    // MARK: Arrange

    /// True when the selection is a layer or shapes that can change draw order.
    public var canArrange: Bool { !drawing.shapeIndices(in: selection).isEmpty }

    /// Moves a selected layer among the layers, or selected shapes within their own layers.
    /// Several selected layers move together, each by itself.
    /// A group moves as one unit among its layer's shapes (with any of its shapes
    /// selected); shapes picked inside one group, or inside the isolated group, move
    /// among that group's shapes.
    public mutating func arrange(_ move: ArrangeMove) {
        guard canArrange else { return }
        cancelGesture()
        let before = drawing
        if case .layer(let id) = selection {
            drawing.layers = Self.arranged(drawing.layers, move) { $0.id == id }
        } else if case .layers(let ids) = selection {
            drawing.layers = Self.arranged(drawing.layers, move) { ids.contains($0.id) }
        } else {
            let refs = Set(drawing.shapeRefs(in: selection))
            for p in drawing.layers.indices {
                let layerID = drawing.layers[p].id
                drawing.layers[p].shapes = arrangedShapes(drawing.layers[p], move) {
                    refs.contains(ShapeRef(layer: layerID, shape: $0.id))
                }
            }
        }
        commit(from: before)
    }

    /// `layer`'s shapes with the selected ones arranged, keeping each group together.
    private func arrangedShapes(_ layer: Layer, _ move: ArrangeMove, isSelected: (VectorShape) -> Bool) -> [VectorShape] {
        let selected = layer.shapes.filter(isSelected)
        guard !selected.isEmpty else { return layer.shapes }
        // Inside one group: arrange among its shapes only.
        if let group = selected[0].group, selected.allSatisfy({ $0.group == group }) {
            let members = layer.members(ofGroup: group)
            if isolatedGroup == group || members.count > selected.count, let first = members.first, let last = members.last {
                var shapes = layer.shapes
                shapes.replaceSubrange(first...last, with: Self.arranged(Array(shapes[first...last]), move, isSelected: isSelected))
                return shapes
            }
        }
        // Otherwise each group is one unit, selected when any of its shapes is.
        var units: [[VectorShape]] = []
        for shape in layer.shapes {
            if let group = shape.group, units.last?.last?.group == group {
                units[units.count - 1].append(shape)
            } else {
                units.append([shape])
            }
        }
        return Self.arranged(units, move) { $0.contains(where: isSelected) }.flatMap { $0 }
    }

    /// `items` (back to front) with the selected ones moved; the rest keep their order.
    static func arranged<T>(_ items: [T], _ move: ArrangeMove, isSelected: (T) -> Bool) -> [T] {
        var out = items
        switch move {
        case .bringToFront:
            out = items.filter { !isSelected($0) } + items.filter(isSelected)
        case .sendToBack:
            out = items.filter(isSelected) + items.filter { !isSelected($0) }
        case .bringForward:
            var i = out.count - 2
            while i >= 0 {
                if isSelected(out[i]), !isSelected(out[i + 1]) { out.swapAt(i, i + 1) }
                i -= 1
            }
        case .sendBackward:
            var i = 1
            while i < out.count {
                if isSelected(out[i]), !isSelected(out[i - 1]) { out.swapAt(i, i - 1) }
                i += 1
            }
        }
        return out
    }

    /// Reorders the layers to `ids`, listed front to back as the layers panel shows them.
    public mutating func setLayerOrder(frontToBack ids: [Int]) {
        guard ids.count == drawing.layers.count, Set(ids) == Set(drawing.layers.map(\.id)) else { return }
        let reordered = ids.reversed().compactMap { id in drawing.layers.first { $0.id == id } }
        guard reordered.map(\.id) != drawing.layers.map(\.id) else { return }
        cancelGesture()
        let before = drawing
        drawing.layers = reordered
        commit(from: before)
    }

    /// True when layer `id` has a layer below it to merge into.
    public func canMergeLayerDown(_ id: Int) -> Bool {
        guard let i = drawing.layerIndex(id) else { return false }
        return i > 0
    }

    /// Moves layer `id`'s shapes into the layer below it (keeping how they stack) and
    /// removes it. The merged layer keeps the lower layer's name and pivot.
    public mutating func mergeLayerDown(_ id: Int) {
        guard canMergeLayerDown(id), let i = drawing.layerIndex(id) else { return }
        cancelGesture()
        let before = drawing
        let wasIsolated = isolatedLayer == id
        let target = drawing.layers[i - 1].id
        drawing.layers[i - 1].shapes += drawing.layers[i].shapes
        drawing.layers[i - 1].groups += drawing.layers[i].groups
        drawing.layers.remove(at: i)
        if wasIsolated { isolatedLayer = target }
        selection = .layer(target)
        commit(from: before)
    }

    /// True when the selection is shapes (not a whole layer) that can move to another layer.
    public var canMoveSelectedShapes: Bool {
        switch selection {
        case .shape, .shapes: !drawing.shapeIndices(in: selection).isEmpty
        default: false
        }
    }

    /// Moves the selected shapes into a new layer above the topmost layer they came from.
    public mutating func moveSelectionToNewLayer() {
        guard canMoveSelectedShapes else { return }
        cancelGesture()
        let before = drawing
        let refs = Set(drawing.shapeRefs(in: selection))
        let topIndex = drawing.shapeIndices(in: selection).map(\.0).max() ?? 0
        var kept: [Layer] = []
        var moved: [VectorShape] = []
        var movedGroups: [ShapeGroup] = []
        var insertAt = 0
        for (i, layer) in drawing.layers.enumerated() {
            var remaining = layer
            remaining.shapes = layer.shapes.filter { !refs.contains(ShapeRef(layer: layer.id, shape: $0.id)) }
            let taken = Self.takeGroups(from: layer, moving: layer.shapes.filter { refs.contains(ShapeRef(layer: layer.id, shape: $0.id)) })
            moved += taken.shapes
            movedGroups += taken.groups
            // Only layers emptied by the move go; empty layers that lost nothing stay.
            if !remaining.shapes.isEmpty || remaining.shapes.count == layer.shapes.count {
                kept.append(remaining)
            }
            if i == topIndex { insertAt = kept.count }
        }
        drawing.layers = kept
        let id = drawing.makeID()
        var layer = Layer(id: id, name: drawing.uniqueLayerName("Layer \(kept.count + 1)"), shapes: moved)
        layer.groups = movedGroups
        layer.pivot = layer.bounds.center
        drawing.layers.insert(layer, at: insertAt)
        selection = .layer(id)
        commit(from: before)
    }

    /// Moves the selection into layer `id`, on top of its shapes. A whole selected layer
    /// is merged into it and removed.
    public mutating func moveSelection(toLayer id: Int) {
        guard drawing.layerIndex(id) != nil else { return }
        let refs = Set(drawing.shapeRefs(in: selection))
        guard !refs.isEmpty, refs.contains(where: { $0.layer != id }) else { return }
        cancelGesture()
        let before = drawing
        let wasIsolated = isolatedLayer != nil
        var moved: [VectorShape] = []
        var movedGroups: [ShapeGroup] = []
        var emptied: Set<Int> = []
        for p in drawing.layers.indices where drawing.layers[p].id != id {
            let layerID = drawing.layers[p].id
            if drawing.layers[p].shapes.allSatisfy({ refs.contains(ShapeRef(layer: layerID, shape: $0.id)) }),
               !drawing.layers[p].shapes.isEmpty {
                emptied.insert(layerID)
            }
            let taken = Self.takeGroups(from: drawing.layers[p],
                                        moving: drawing.layers[p].shapes.filter { refs.contains(ShapeRef(layer: layerID, shape: $0.id)) })
            moved += taken.shapes
            movedGroups += taken.groups
            drawing.layers[p].shapes.removeAll { refs.contains(ShapeRef(layer: layerID, shape: $0.id)) }
        }
        drawing.layers.removeAll { emptied.contains($0.id) }
        guard let target = drawing.layerIndex(id) else { return }
        drawing.layers[target].shapes += moved
        drawing.layers[target].groups += movedGroups
        // Moving an isolated layer's art into another layer carries isolation along.
        if wasIsolated, isolatedLayer == nil { isolatedLayer = id }
        selection = .covering(Set(moved.map { ShapeRef(layer: id, shape: $0.id) }))
        commit(from: before)
    }

    /// `moving` (shapes leaving `layer`) ready for another layer: groups that leave whole
    /// go with them; shapes leaving layer of a group leave the group. Groups left empty
    /// behind are tidied by `commit`.
    static func takeGroups(from layer: Layer, moving: [VectorShape]) -> (shapes: [VectorShape], groups: [ShapeGroup]) {
        let ids = Set(moving.map(\.id))
        var whole: [ShapeGroup] = []
        for group in layer.groups where layer.shapes.contains(where: { $0.group == group.id }) &&
            layer.shapes.allSatisfy({ $0.group != group.id || ids.contains($0.id) }) {
            whole.append(group)
        }
        let kept = Set(whole.map(\.id))
        let shapes = moving.map { shape in
            var copy = shape
            if let g = copy.group, !kept.contains(g) { copy.group = nil }
            return copy
        }
        return (shapes, whole)
    }

    // MARK: Duplicate

    /// Copies the selection `offset` points away and selects the copies, as one undo step.
    public mutating func duplicateSelection(offset: Vec2 = Vec2(10, 10)) {
        cancelGesture()
        let before = drawing
        guard duplicateInPlace(offset: offset) else { return }
        commit(from: before)
    }

    /// Copies the selection, moved by `offset`, and selects the copies. A layer's copy
    /// goes just above it; shape copies go just above the topmost original in each
    /// layer. Does not record undo. False when there is nothing to copy.
    @discardableResult
    mutating func duplicateInPlace(offset: Vec2) -> Bool {
        let shift = Affine2D.translation(offset)
        if case .layer(let id) = selection, isolatedLayer == nil, let copy = duplicateLayer(id, shift: shift) {
            selection = .layer(copy)
            return true
        }
        if case .layers(let ids) = selection, isolatedLayer == nil {
            let copies = ids.sorted().compactMap { duplicateLayer($0, shift: shift) }
            selection = .coveringLayers(Set(copies))
            return !copies.isEmpty
        }
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return false }
        var copies: Set<ShapeRef> = []
        for p in Set(targets.map(\.0)) {
            let indices = targets.filter { $0.0 == p }.map(\.1).sorted()
            let layer = drawing.layers[p]
            // Copies go above the topmost original, past the rest of its group.
            var insertAt = (indices.last ?? 0) + 1
            if let group = layer.shapes[insertAt - 1].group {
                while insertAt < layer.shapes.count, layer.shapes[insertAt].group == group { insertAt += 1 }
            }
            // A wholly copied group is copied as a new group; a copy of layer of a group
            // stays in that group.
            let selectedIDs = Set(indices.map { layer.shapes[$0].id })
            var fresh: [Int: Int] = [:]
            for group in layer.groups where layer.shapes.contains(where: { $0.group == group.id }) &&
                layer.shapes.allSatisfy({ $0.group != group.id || selectedIDs.contains($0.id) }) {
                let id = drawing.makeID()
                fresh[group.id] = id
                drawing.layers[p].groups.append(ShapeGroup(id: id, name: group.name, isClipped: group.isClipped))
            }
            for s in indices {
                var copy = layer.shapes[s]
                copy.id = drawing.makeID()
                copy.apply(shift)
                if let g = copy.group, let id = fresh[g] { copy.group = id }
                drawing.layers[p].shapes.insert(copy, at: insertAt)
                insertAt += 1
                copies.insert(ShapeRef(layer: layer.id, shape: copy.id))
            }
        }
        let saved = style
        selection = .covering(copies)
        style = saved
        return true
    }

    /// Copies layer `id` just above it, moved by `shift`. Returns the copy's id. Does not
    /// record undo.
    private mutating func duplicateLayer(_ id: Int, shift: Affine2D) -> Int? {
        guard let i = drawing.layerIndex(id) else { return nil }
        var copy = drawing.layers[i]
        copy.id = drawing.makeID()
        copy.name = drawing.uniqueLayerName(copy.name)
        drawing.renewArtIDs(of: &copy)
        copy.updateAllShapes { $0.apply(shift) }
        copy.pivot = shift.apply(copy.pivot)
        drawing.layers.insert(copy, at: i + 1)
        return copy.id
    }

    // MARK: Clipboard

    /// The pasteboard type for copied art: file JSON holding the copied layers.
    public static let clipboardType = "com.dgcrensh.controlflow.art"

    /// The selection as file JSON (only the layers and shapes copied), for the
    /// pasteboard, so it pastes into any document. Nil when nothing is selected.
    public func copySelection() -> String? {
        var clip = Drawing()
        clip.name = drawing.name
        let kind: String
        if case .layer(let id) = selection, isolatedLayer == nil {
            guard let i = drawing.layerIndex(id) else { return nil }
            clip.layers = [drawing.layers[i]]
            kind = "layers"
        } else if case .layers(let ids) = selection, isolatedLayer == nil {
            clip.layers = drawing.layers.filter { ids.contains($0.id) }
            kind = "layers"
        } else {
            let refs = Set(drawing.shapeRefs(in: selection))
            for layer in drawing.layers {
                var copy = layer
                copy.shapes = layer.shapes.filter { refs.contains(ShapeRef(layer: layer.id, shape: $0.id)) }
                if !copy.shapes.isEmpty { clip.layers.append(copy) }
            }
            kind = "shapes"
        }
        // The global colors the copied shapes follow travel with them, by name.
        let used = Set(clip.layers.flatMap { $0.shapes.flatMap { [$0.fillGlobal, $0.stroke?.global].compactMap { $0 } } })
        clip.globalColors = drawing.globalColors.filter { used.contains($0.id) }
        guard !clip.layers.isEmpty, case .object(var members) = CharacterFormat.encode(clip) else { return nil }
        members.append((key: "clipboard", value: .string(kind)))
        return JSONValue.object(members).formatted()
    }

    /// Copies the selection, then deletes it.
    public mutating func cutSelection() -> String? {
        guard let text = copySelection() else { return nil }
        deleteSelection()
        return text
    }

    /// Pastes file JSON (from `copySelection`, or a whole `character.json`).
    /// Copied shapes join the isolated or selected layer; copied layers arrive as new
    /// layers on top. A paste that would land exactly on art already there is moved 10
    /// points down and right. The pasted art is selected. False when `text` holds no art.
    @discardableResult
    public mutating func paste(_ text: String) -> Bool {
        guard let json = try? JSONValue(parsing: text), let decoded = try? CharacterFormat.decode(json) else { return false }
        let layers = decoded.drawing.layers.filter { !$0.shapes.isEmpty }
        guard !layers.isEmpty else { return false }
        cancelGesture()
        let before = drawing

        let offset = pasteOffset(for: layers[0].shapes[0].path)
        let shift = Affine2D.translation(offset)
        let shapesOnly = json["clipboard"] == JSONValue.string("shapes")
        let globals = adoptGlobalColors(decoded.drawing.globalColors)
        var refs: Set<ShapeRef> = []
        if let target = shapesOnly ? selectedLayerID : isolatedLayer, let p = drawing.layerIndex(target) {
            for layer in layers {
                // Pasted groups come along as new groups of the target layer.
                var groups: [Int: Int] = [:]
                if isolatedGroup == nil || isolatedLayer != target {
                    for group in layer.groups {
                        let id = drawing.makeID()
                        groups[group.id] = id
                        drawing.layers[p].groups.append(ShapeGroup(id: id, name: group.name, isClipped: group.isClipped))
                    }
                }
                for shape in layer.shapes {
                    var copy = pastedCopy(of: shape, moved: shift, globals: globals)
                    copy.group = copy.group.flatMap { groups[$0] }
                    addToActiveLayer(&copy, layer: p)
                    refs.insert(ShapeRef(layer: target, shape: copy.id))
                }
            }
            selection = .covering(refs)
        } else {
            var added: [Int] = []
            for layer in layers {
                var copy = Layer(id: drawing.makeID(), name: drawing.uniqueLayerName(layer.name), pivot: shift.apply(layer.pivot))
                for shape in layer.shapes { copy.shapes.append(pastedCopy(of: shape, moved: shift, globals: globals)) }
                copy.groups = layer.groups
                drawing.renewGroups(of: &copy)
                drawing.layers.append(copy)
                added.append(copy.id)
                for shape in copy.shapes { refs.insert(ShapeRef(layer: copy.id, shape: shape.id)) }
            }
            selection = added.count == 1 ? .layer(added[0]) : .covering(refs)
        }
        commit(from: before)
        return true
    }

    /// Matches pasted global colors to this document's by name, adding any it lacks.
    /// Returns the pasted id to this document's global color for each.
    private mutating func adoptGlobalColors(_ pasted: [GlobalColor]) -> [Int: GlobalColor] {
        var map: [Int: GlobalColor] = [:]
        for global in pasted {
            if let existing = drawing.globalColors.first(where: { $0.name == global.name }) {
                map[global.id] = existing
            } else {
                let added = GlobalColor(id: drawing.makeID(), name: global.name, color: global.color)
                drawing.globalColors.append(added)
                map[global.id] = added
            }
        }
        return map
    }

    /// A visible, unlocked copy of `shape` with a fresh id, following this document's
    /// global colors.
    private mutating func pastedCopy(of shape: VectorShape, moved shift: Affine2D,
                                     globals: [Int: GlobalColor]) -> VectorShape {
        var copy = shape
        copy.id = drawing.makeID()
        copy.apply(shift)
        copy.isHidden = false
        copy.isLocked = false
        copy.fillGlobal = copy.fillGlobal.flatMap { globals[$0]?.id }
        if let global = shape.fillGlobal.flatMap({ globals[$0] }), copy.fill != nil {
            copy.fill = global.color
            if copy.gradient != nil { copy.gradient!.stops[0].color = global.color }
        }
        if copy.stroke != nil {
            let global = shape.stroke?.global.flatMap { globals[$0] }
            copy.stroke!.global = global?.id
            if let global { copy.stroke!.color = global.color }
        }
        return copy
    }

    /// Steps of 10 points down and right until the pasted path no longer sits exactly
    /// on an existing shape.
    private func pasteOffset(for path: BezierPath) -> Vec2 {
        let existing = drawing.layers.flatMap { $0.shapes.map { $0.path.bounds() } }
        let bounds = path.bounds()
        func same(_ a: Rect, _ b: Rect) -> Bool {
            a.minPoint.isApproximately(b.minPoint, tolerance: 0.01) && a.maxPoint.isApproximately(b.maxPoint, tolerance: 0.01)
        }
        var offset = Vec2.zero
        for _ in 0..<50 {
            let moved = Rect(minPoint: bounds.minPoint + offset, maxPoint: bounds.maxPoint + offset)
            guard existing.contains(where: { same($0, moved) }) else { break }
            offset += Vec2(10, 10)
        }
        return offset
    }

    // MARK: Scissors

    /// Cuts shape `ref` at parameter `t` of segment `segment`, reusing the split command:
    /// a closed path opens there, an open path becomes two. The pieces are selected. A
    /// cut that leaves an open path with no outline gives it one, so it stays visible.
    mutating func cut(_ ref: ShapeRef, segment: Int, t: Double) {
        guard let idx = drawing.indices(ref) else { return }
        let shape = drawing.layers[idx.0].shapes[idx.1]
        guard segment >= 0, segment < shape.path.segmentCount else { return }
        guard let pieces = changingPoints(of: shape, { path -> [BezierPath]? in
            var path = path
            let index: Int
            if t < 0.02 {
                index = segment
            } else if t > 0.98 {
                index = (segment + 1) % path.points.count
            } else {
                index = path.insertPoint(segment: segment, t: t)
            }
            return path.split(at: index)
        }) else { return }
        let before = drawing
        var first = pieces[0]
        if first.stroke == nil { first.stroke = style.makeStroke() }
        drawing.layers[idx.0].shapes[idx.1] = first
        var refs: Set<ShapeRef> = [ref]
        for (k, piece) in pieces.dropFirst().enumerated() {
            var copy = piece
            copy.stroke = first.stroke
            copy.id = drawing.makeID()
            drawing.layers[idx.0].shapes.insert(copy, at: idx.1 + 1 + k)
            refs.insert(ShapeRef(layer: ref.layer, shape: copy.id))
        }
        let saved = style
        selection = .covering(refs)
        style = saved
        commit(from: before)
    }

    // MARK: Pencil tool switching

    /// Goes back to the tool used before this one (the Pencil's double tap).
    public mutating func switchToPreviousTool() {
        guard let previous = previousTool else { return }
        tool = previous
    }

    /// Switches to the eraser, or from the eraser back to the previous tool.
    public mutating func toggleEraser() {
        if tool == .eraser {
            tool = previousTool ?? .pencil
        } else {
            tool = .eraser
        }
    }
}
