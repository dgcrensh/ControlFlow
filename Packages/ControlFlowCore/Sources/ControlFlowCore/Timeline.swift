import Foundation

/// A presentation with the scene state at each keyframe resolved on demand: the opening
/// state, then each keyframe's changes applied in turn. States are copy-on-write
/// `Drawing`s, so unchanged layers and shapes share storage, and each is kept until an
/// edit before it invalidates it.
///
/// Positions in the chain are *chain indices*: 0 is the opening state and 1 the first
/// keyframe of the first sequence.
public struct Timeline: Sendable {
    public private(set) var presentation: Presentation
    /// Resolved states by chain index; nil until asked for.
    private(set) var states: [Drawing?]
    /// The transition the next new keyframe gets: the one last set on a keyframe.
    public var lastTransition = Transition.standard

    public init(_ presentation: Presentation = Presentation()) {
        var presentation = presentation
        presentation.opening.syncGlobalColors()
        self.presentation = presentation
        states = [presentation.opening] + Array(repeating: nil, count: presentation.keyframeCount)
    }

    /// The number of states: the opening state and every keyframe.
    public var count: Int { states.count }

    // MARK: States

    /// The scene at chain index `index`.
    public mutating func state(at index: Int) -> Drawing {
        let index = min(max(index, 0), states.count - 1)
        var known = index
        while states[known] == nil { known -= 1 }
        if known < index {
            var state = states[known]!
            // One lookup for the whole run, kept up to date as each keyframe applies.
            var lookup = SceneLookup(state, indexingVertices: false)
            for i in (known + 1)...index {
                if let keyframe = presentation.keyframe(atChainIndex: i) { state.apply(keyframe.changes, lookup: &lookup) }
                states[i] = state
            }
        }
        var state = states[index]!
        state.nextID = presentation.opening.nextID
        return state
    }

    /// The scene at keyframe `id`, or the opening state for nil.
    public mutating func state(atKeyframe id: Int?) -> Drawing {
        state(at: presentation.chainIndex(of: id) ?? 0)
    }

    /// Takes the states `other` has resolved that still hold here: those before the first
    /// keyframe whose changes differ, when the opening states match. Undo and redo use
    /// this so a state is rebuilt only from the keyframe the step changed.
    public mutating func reuseStates(of other: Timeline) {
        let opening = presentation.opening
        guard other.presentation.opening.withNextID(opening.nextID) == opening else { return }
        var a = presentation.sequences.lazy.flatMap(\.keyframes).makeIterator()
        var b = other.presentation.sequences.lazy.flatMap(\.keyframes).makeIterator()
        for i in 1..<min(states.count, other.states.count) {
            guard let mine = a.next(), let theirs = b.next(), mine.changes == theirs.changes,
                  let state = other.states[i] else { return }
            states[i] = state
        }
    }

    private mutating func invalidate(after index: Int) {
        for i in states.indices where i > index { states[i] = nil }
    }

    /// Makes sure ids from here on start at `next` or above.
    public mutating func reserveIDs(below next: Int) {
        presentation.opening.nextID = max(presentation.opening.nextID, next)
    }

    // MARK: Editing

    /// Records `edited` as the scene at chain index `index`. For a keyframe, its changes
    /// become what turns the state before it into `edited`: properties set back to their
    /// earlier values drop out. Later keyframes keep their own changes, so an edit carries
    /// forward until a keyframe that sets the same property, and changes that refer to
    /// objects this edit deleted are dropped. What isn't keyed (see `Presentation`) is
    /// changed for every state.
    public mutating func record(_ edited: Drawing, at index: Int) {
        let index = min(max(index, 0), states.count - 1)
        var edited = edited
        edited.nextID = max(edited.nextID, presentation.opening.nextID)
        let old = state(at: index)
        guard old != edited else { return }
        presentation.opening.nextID = edited.nextID
        guard old.layers != edited.layers || old.withNextID(edited.nextID) != edited else { return }
        let removed = old.idsMissing(from: edited)
        if index == 0 {
            presentation.opening = edited
            presentation.opening.syncGlobalColors()
            states[0] = presentation.opening
            invalidate(after: 0)
        } else {
            let previous = state(at: index - 1)
            let changes = SceneDiff.changes(from: previous, to: edited)
            presentation.updateKeyframe(atChainIndex: index) { $0.changes = changes }
            let unkeyed = Timeline.unkeyedChanges(from: previous, to: edited)
            if !unkeyed.isEmpty || !previous.hasSameDocumentSettings(as: edited) {
                presentation.opening.adoptDocumentSettings(of: edited)
                if !unkeyed.isEmpty { applyEverywhere(unkeyed) }
                for i in states.indices { states[i] = nil }
                states[0] = presentation.opening
            } else {
                invalidate(after: index)
            }
            states[index] = edited
        }
        presentation.opening.nextID = max(presentation.opening.nextID, edited.nextID)
        if !removed.isEmpty { prune(after: index) }
    }

    /// Drops the changes of keyframes after `index` that no longer apply, resolving each
    /// state on the way.
    private mutating func prune(after index: Int) {
        guard index + 1 < states.count else { return }
        var state = self.state(at: index)
        var lookup = SceneLookup(state, indexingVertices: false)
        for i in (index + 1)..<states.count {
            guard let keyframe = presentation.keyframe(atChainIndex: i) else { continue }
            var changes = keyframe.changes
            // Orders list only the children still there.
            if changes.contains(where: { if case .order = $0 { true } else { false } }) {
                let ids = state.objectIDs
                changes = changes.map { change in
                    if case .order(let parent, let order) = change { .order(parent: parent, ids: order.filter(ids.contains)) } else { change }
                }
            }
            let failed = Set(state.apply(changes, lookup: &lookup))
            if !failed.isEmpty || changes != keyframe.changes {
                let kept = changes.indices.filter { !failed.contains($0) }.map { changes[$0] }
                presentation.updateKeyframe(atChainIndex: i) { $0.changes = kept }
            }
            states[i] = state
        }
    }

    /// Names and editor hints that differ between two states, for objects in both.
    private static func unkeyedChanges(from a: Drawing, to b: Drawing) -> [Int: Unkeyed] {
        // Only layers that changed can hold a change (an object moving between layers
        // changes both).
        let changed = a.changedLayerIDs(comparedTo: b)
        guard !changed.isEmpty else { return [:] }
        let old = Unkeyed.values(in: a.layers.filter { changed.contains($0.id) })
        var out: [Int: Unkeyed] = [:]
        for (id, value) in Unkeyed.values(in: b.layers.filter { changed.contains($0.id) }) where old[id] != nil && old[id] != value {
            out[id] = value
        }
        return out
    }

    /// Sets names and editor hints in the opening state and in every created object.
    private mutating func applyEverywhere(_ values: [Int: Unkeyed]) {
        for l in presentation.opening.layers.indices { Unkeyed.apply(values, to: &presentation.opening.layers[l]) }
        for s in presentation.sequences.indices {
            for k in presentation.sequences[s].keyframes.indices {
                for c in presentation.sequences[s].keyframes[k].changes.indices {
                    guard case .create(var object, let parent, let after, let before, let t) =
                        presentation.sequences[s].keyframes[k].changes[c] else { continue }
                    switch object {
                    case .layer(var layer):
                        Unkeyed.apply(values, to: &layer)
                        object = .layer(layer)
                    case .group(var group):
                        if let v = values[group.id], let name = v.name { group.name = name }
                        object = .group(group)
                    case .shape(var shape):
                        if let v = values[shape.id] { shape.isHidden = v.hidden; shape.isLocked = v.locked }
                        object = .shape(shape)
                    case .vertex:
                        continue
                    }
                    presentation.sequences[s].keyframes[k].changes[c] = .create(object, parent: parent, after: after, before: before, t: t)
                }
            }
        }
    }

    // MARK: Keyframes and sequences

    /// Inserts a keyframe with no changes (so it looks like the one before it) after chain
    /// index `index`, in the same sequence; after the opening state it starts the first
    /// sequence (making one if there is none). Returns its id.
    @discardableResult
    public mutating func insertKeyframe(after index: Int, transition: Transition? = nil) -> Int {
        let index = min(max(index, 0), states.count - 1)
        if index == 0, presentation.sequences.isEmpty {
            presentation.sequences.append(KeyframeSequence(id: presentation.opening.makeID()))
        }
        let keyframe = Keyframe(id: presentation.opening.makeID(), transition: transition ?? lastTransition)
        if index == 0 {
            presentation.sequences[0].keyframes.insert(keyframe, at: 0)
        } else if let id = presentation.keyframe(atChainIndex: index)?.id, let (s, k) = presentation.location(ofKeyframe: id) {
            presentation.sequences[s].keyframes.insert(keyframe, at: k + 1)
        }
        states.insert(states[index], at: index + 1)
        return keyframe.id
    }

    /// Inserts a sequence holding one new keyframe after the sequence of chain index
    /// `index` (first, after the opening state). Returns the keyframe's id.
    @discardableResult
    public mutating func insertSequence(after index: Int, transition: Transition? = nil) -> Int {
        let index = min(max(index, 0), states.count - 1)
        var position = 0
        if index > 0, let id = presentation.keyframe(atChainIndex: index)?.id, let (s, _) = presentation.location(ofKeyframe: id) {
            position = s + 1
        }
        let end = position == 0 ? 0 : presentation.chainRange(ofSequence: position - 1)?.upperBound ?? 0
        let sequence = presentation.opening.makeID()
        let keyframe = Keyframe(id: presentation.opening.makeID(), transition: transition ?? lastTransition)
        presentation.sequences.insert(KeyframeSequence(id: sequence, keyframes: [keyframe]), at: position)
        states.insert(states[end], at: end + 1)
        return keyframe.id
    }

    /// Splits keyframe `id`'s sequence so `id` starts a new one. False when it already
    /// starts its sequence.
    @discardableResult
    public mutating func splitSequence(at id: Int) -> Bool {
        guard let (s, k) = presentation.location(ofKeyframe: id), k > 0 else { return false }
        let tail = Array(presentation.sequences[s].keyframes[k...])
        presentation.sequences[s].keyframes.removeSubrange(k...)
        presentation.sequences.insert(KeyframeSequence(id: presentation.opening.makeID(), keyframes: tail), at: s + 1)
        return true
    }

    /// Joins the sequence at `index` with the one after it. False when it is the last.
    @discardableResult
    public mutating func mergeSequence(at index: Int) -> Bool {
        guard index >= 0, index + 1 < presentation.sequences.count else { return false }
        presentation.sequences[index].keyframes += presentation.sequences[index + 1].keyframes
        presentation.sequences.remove(at: index + 1)
        return true
    }

    /// Deletes keyframe `id`. Its changes fold into the next keyframe, so every later
    /// state looks the same; a sequence left empty goes too. Returns the chain index of
    /// the state before it, or nil when there is no such keyframe.
    @discardableResult
    public mutating func deleteKeyframe(_ id: Int) -> Int? {
        guard let index = presentation.chainIndex(of: id), index > 0, let (s, k) = presentation.location(ofKeyframe: id) else { return nil }
        if index + 1 < states.count {
            let changes = SceneDiff.changes(from: state(at: index - 1), to: state(at: index + 1))
            presentation.updateKeyframe(atChainIndex: index + 1) { $0.changes = changes }
        }
        presentation.sequences[s].keyframes.remove(at: k)
        if presentation.sequences[s].keyframes.isEmpty { presentation.sequences.remove(at: s) }
        states.remove(at: index)
        return index - 1
    }

    /// Deletes every keyframe of sequence `index`, folding their changes into the next
    /// sequence, so later states look the same.
    public mutating func deleteSequence(at index: Int) {
        guard presentation.sequences.indices.contains(index) else { return }
        let ids = presentation.sequences[index].keyframes.map(\.id)
        for id in ids { deleteKeyframe(id) }
        if presentation.sequences.indices.contains(index), presentation.sequences[index].keyframes.isEmpty {
            presentation.sequences.remove(at: index)
        }
    }

    /// Empties keyframe `id`'s changes, so it looks like the keyframe before it.
    public mutating func revertKeyframe(_ id: Int) {
        guard let index = presentation.chainIndex(of: id), index > 0 else { return }
        record(state(at: index - 1), at: index)
    }

    /// Inserts a copy of keyframe `id` after it, as a hold (no changes, the same
    /// transition). Returns the copy's id.
    @discardableResult
    public mutating func duplicateKeyframe(_ id: Int) -> Int? {
        guard let index = presentation.chainIndex(of: id), index > 0, let keyframe = presentation.keyframe(id) else { return nil }
        return insertKeyframe(after: index, transition: keyframe.transition)
    }

    /// Moves keyframe `id` to position `position` of sequence `sequence` (an id), counted
    /// before the move. Every keyframe's changes are rebuilt from the resolved states, so
    /// each still looks as it did. A sequence left empty goes. False when nothing moved.
    @discardableResult
    public mutating func moveKeyframe(_ id: Int, toSequence sequence: Int, at position: Int) -> Bool {
        guard let (s, k) = presentation.location(ofKeyframe: id),
              let target = presentation.sequences.firstIndex(where: { $0.id == sequence }) else { return false }
        var resolved: [Int: Drawing] = [:]
        for i in 1..<states.count {
            if let keyframe = presentation.keyframe(atChainIndex: i) { resolved[keyframe.id] = state(at: i) }
        }
        var sequences = presentation.sequences
        let moving = sequences[s].keyframes[k]
        var at = min(max(position, 0), sequences[target].keyframes.count)
        if s == target, k < at { at -= 1 }
        sequences[s].keyframes.remove(at: k)
        sequences[target].keyframes.insert(moving, at: at)
        sequences.removeAll { $0.keyframes.isEmpty }
        guard sequences.map({ $0.keyframes.map(\.id) }) != presentation.sequences.map({ $0.keyframes.map(\.id) }) else {
            presentation.sequences = sequences
            return false
        }
        var previous = presentation.opening
        var newStates: [Drawing?] = [presentation.opening]
        for si in sequences.indices {
            for ki in sequences[si].keyframes.indices {
                let state = resolved[sequences[si].keyframes[ki].id]!
                sequences[si].keyframes[ki].changes = SceneDiff.changes(from: previous, to: state)
                newStates.append(state)
                previous = state
            }
        }
        presentation.sequences = sequences
        states = newStates
        return true
    }

    public mutating func setTransition(_ transition: Transition, ofKeyframe id: Int) {
        guard let (s, k) = presentation.location(ofKeyframe: id) else { return }
        presentation.sequences[s].keyframes[k].transition = transition
        lastTransition = transition
    }

    /// Names keyframe `id`; an empty name clears it.
    public mutating func renameKeyframe(_ id: Int, to name: String) {
        guard let (s, k) = presentation.location(ofKeyframe: id) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        presentation.sequences[s].keyframes[k].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Names sequence `id`; an empty name clears it.
    public mutating func renameSequence(_ id: Int, to name: String) {
        guard let s = presentation.sequences.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        presentation.sequences[s].name = trimmed.isEmpty ? nil : trimmed
    }

    /// The objects keyframe `id` changes, with the shapes and layers they belong to: what
    /// the Layers panel marks as changed there.
    public mutating func changedObjects(inKeyframe id: Int) -> Set<Int> {
        guard let index = presentation.chainIndex(of: id), index > 0, let keyframe = presentation.keyframe(id) else { return [] }
        var ids = Set<Int>()
        // Parents a change names itself: a created object's.
        var parents: [Int: Int] = [:]
        for change in keyframe.changes {
            var parent: Int?
            switch change {
            case .create(let object, let p, _, _, _):
                parent = p
                if let p { parents[object.id] = p }
            case .order(let p, _): parent = p
            case .set, .delete: break
            }
            for id in [change.target, parent].compactMap({ $0 }) { ids.insert(id) }
        }
        // The rest are looked up in the state before the keyframe, then in its own (for
        // objects it creates), searching only for the ids still wanted rather than
        // indexing every object and vertex of the scene.
        var wanted = ids.subtracting(parents.keys)
        for state in [self.state(at: index - 1), self.state(at: index)] where !wanted.isEmpty {
            Self.findParents(of: &wanted, in: state, into: &parents)
        }
        // Each parent's own parent: a vertex's shape belongs to a layer.
        wanted = Set(parents.values).subtracting(ids).subtracting(parents.keys)
        for state in [self.state(at: index - 1), self.state(at: index)] where !wanted.isEmpty {
            Self.findParents(of: &wanted, in: state, into: &parents)
        }
        for id in ids {
            var current = parents[id]
            while let c = current, ids.insert(c).inserted { current = parents[c] }
        }
        return ids
    }

    /// Finds the parents of the ids in `wanted` in `drawing` (a group's or shape's layer,
    /// a vertex's shape and its layer) and removes each id found, parent or not. The
    /// points are searched only while vertices may be left.
    static func findParents(of wanted: inout Set<Int>, in drawing: Drawing, into parents: inout [Int: Int]) {
        wanted.remove(drawing.viewport.id)
        for global in drawing.globalColors { wanted.remove(global.id) }
        for layer in drawing.layers where !wanted.isEmpty {
            wanted.remove(layer.id)
            for group in layer.groups where wanted.remove(group.id) != nil { parents[group.id] = layer.id }
            for shape in layer.shapes where wanted.remove(shape.id) != nil { parents[shape.id] = layer.id }
        }
        guard !wanted.isEmpty else { return }
        for layer in drawing.layers {
            for shape in layer.shapes {
                for point in shape.path.points where wanted.remove(point.id) != nil {
                    parents[point.id] = shape.id
                    parents[shape.id] = parents[shape.id] ?? layer.id
                }
                if wanted.isEmpty { return }
            }
        }
    }

    // MARK: Playing

    /// The scene `elapsed` seconds into the transition into chain index `index`.
    public mutating func transition(into index: Int, elapsed: Double) -> Drawing {
        guard index > 0, let keyframe = presentation.keyframe(atChainIndex: index) else { return state(at: 0) }
        let duration = keyframe.transition.duration
        let fraction = duration > 0 ? elapsed / duration : 1
        let to = state(at: index)
        guard fraction < 1 else { return to }
        let from = state(at: index - 1)
        var scene = Interpolation.scene(from: from, to: to, fraction: max(fraction, 0),
                                        progress: keyframe.transition.curve.progress(at: fraction),
                                        parameters: Timeline.parameters(of: keyframe))
        scene.nextID = to.nextID
        return scene
    }

    /// The seconds sequence `index` takes to play.
    public func duration(ofSequence index: Int) -> Double {
        guard presentation.sequences.indices.contains(index) else { return 0 }
        return presentation.sequences[index].keyframes.reduce(0) { $0 + $1.transition.duration }
    }

    /// The scene `time` seconds into playing sequence `index` from the end of the one
    /// before it, keyframe after keyframe, and whether it has reached its last keyframe.
    public mutating func playing(sequence index: Int, at time: Double) -> (scene: Drawing, finished: Bool) {
        guard let range = presentation.chainRange(ofSequence: index), let playing = playing(range, at: time) else {
            return (state(at: 0), true)
        }
        return playing
    }

    /// The scene `time` seconds into playing the keyframes at chain indices `range`, from
    /// the state before the first, and whether it has reached the last. Nil when the
    /// range is not in the chain.
    public mutating func playing(_ range: ClosedRange<Int>, at time: Double) -> (scene: Drawing, finished: Bool)? {
        guard range.lowerBound > 0, range.upperBound < states.count else { return nil }
        var remaining = max(time.isFinite ? time : 0, 0)
        for chain in range {
            let duration = presentation.keyframe(atChainIndex: chain)!.transition.duration
            if remaining < duration { return (transition(into: chain, elapsed: remaining), false) }
            remaining -= duration
        }
        return (state(at: range.upperBound), true)
    }

    /// The seconds the keyframes at chain indices `range` take to play.
    public func duration(of range: ClosedRange<Int>) -> Double {
        range.reduce(0) { $0 + (presentation.keyframe(atChainIndex: $1)?.transition.duration ?? 0) }
    }

    /// The `t` recorded for each vertex the keyframe adds or removes on a segment.
    static func parameters(of keyframe: Keyframe) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for change in keyframe.changes {
            switch change {
            case .create(.vertex(let point), _, _, _, let t?): out[point.id] = t
            case .delete(let id, let t?): out[id] = t
            default: break
            }
        }
        return out
    }
}

extension Timeline: Equatable {
    public static func == (a: Timeline, b: Timeline) -> Bool { a.presentation == b.presentation }
}

/// A layer's, group's or shape's name and editor hints, which are the same at every
/// keyframe.
private struct Unkeyed: Equatable {
    var name: String?
    var hidden = false
    var locked = false

    static func values(in layers: [Layer]) -> [Int: Unkeyed] {
        var out: [Int: Unkeyed] = [:]
        for layer in layers {
            out[layer.id] = Unkeyed(name: layer.name, hidden: layer.isHidden, locked: layer.isLocked)
            for group in layer.groups { out[group.id] = Unkeyed(name: group.name) }
            for shape in layer.shapes { out[shape.id] = Unkeyed(hidden: shape.isHidden, locked: shape.isLocked) }
        }
        return out
    }

    static func apply(_ values: [Int: Unkeyed], to layer: inout Layer) {
        if let v = values[layer.id] {
            if let name = v.name { layer.name = name }
            layer.isHidden = v.hidden
            layer.isLocked = v.locked
        }
        for g in layer.groups.indices { if let name = values[layer.groups[g].id]?.name { layer.groups[g].name = name } }
        for s in layer.shapes.indices {
            if let v = values[layer.shapes[s].id] {
                layer.shapes[s].isHidden = v.hidden
                layer.shapes[s].isLocked = v.locked
            }
        }
    }
}

extension Drawing {
    func withNextID(_ next: Int) -> Drawing {
        var copy = self
        copy.nextID = next
        return copy
    }

    /// True when the parts of the document that aren't keyed are the same: the name, the
    /// viewport's size, the palette, reference images and which global colors there are
    /// (with their names).
    func hasSameDocumentSettings(as other: Drawing) -> Bool {
        name == other.name && viewport.width == other.viewport.width && viewport.height == other.viewport.height &&
            viewport.id == other.viewport.id && palette == other.palette && references == other.references &&
            globalColors.map(\.id) == other.globalColors.map(\.id) && globalColors.map(\.name) == other.globalColors.map(\.name)
    }

    /// Takes `other`'s document settings (see `hasSameDocumentSettings`), keeping the
    /// colors of global colors this drawing already has.
    mutating func adoptDocumentSettings(of other: Drawing) {
        name = other.name
        viewport.width = other.viewport.width
        viewport.height = other.viewport.height
        palette = other.palette
        references = other.references
        let colors = Dictionary(globalColors.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        globalColors = other.globalColors.map { global in
            var copy = global
            if let color = colors[global.id] { copy.color = color }
            return copy
        }
        syncGlobalColors()
    }
}
