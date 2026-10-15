import Foundation

/// The document and the keyframe being edited, as undo keeps them.
public struct EditorSnapshot: Hashable, Sendable {
    public var presentation: Presentation
    /// The keyframe being edited, or nil for the opening state.
    public var keyframe: Int?
}

/// Keyframes: which one is being edited, and the timeline commands. Edits to `drawing`
/// at a keyframe become that keyframe's changes when committed (see `Timeline.record`).
extension DrawingEditor {
    /// The document as it would be saved.
    public var presentation: Presentation {
        var copy = timeline
        copy.record(drawing, at: currentChainIndex)
        return copy.presentation
    }

    /// Records `state` (by default `drawing`) as the current keyframe's scene when it was
    /// changed without a commit, which makes no undo step.
    mutating func syncTimeline(with state: Drawing? = nil) {
        timeline.record(state ?? drawing, at: currentChainIndex)
    }

    /// Where `currentKeyframe` is in the chain: 0 for the opening state.
    public var currentChainIndex: Int { timeline.presentation.chainIndex(of: currentKeyframe) ?? 0 }

    /// Makes keyframe `id` (nil: the opening state) the one being edited. Not an undo step.
    public mutating func selectKeyframe(_ id: Int?) {
        guard id != currentKeyframe, id == nil || timeline.presentation.chainIndex(of: id) != nil else { return }
        cancelGesture()
        endPreview()
        syncTimeline()
        penPath = nil
        currentKeyframe = id
        drawing = timeline.state(at: currentChainIndex)
        updateOnionSkin()
        validateSelection()
    }

    /// Set Keyframe: inserts a keyframe after the current one that looks the same, with
    /// the last transition used, and makes it current. Returns its id.
    @discardableResult
    public mutating func setKeyframe() -> Int {
        timelineCommand { $0.currentKeyframe = $0.timeline.insertKeyframe(after: $0.currentChainIndex) }
        return currentKeyframe ?? 0
    }

    /// New Sequence: inserts a sequence after the current one holding one new keyframe,
    /// and makes the keyframe current. Returns its id.
    @discardableResult
    public mutating func newSequence() -> Int {
        timelineCommand { $0.currentKeyframe = $0.timeline.insertSequence(after: $0.currentChainIndex) }
        return currentKeyframe ?? 0
    }

    /// Split Sequence Here: keyframe `id` starts a new sequence.
    public mutating func splitSequence(at id: Int) {
        timelineCommand { $0.timeline.splitSequence(at: id) }
    }

    /// Merge with Next: sequence `id` takes the keyframes of the one after it.
    public mutating func mergeSequenceWithNext(_ id: Int) {
        guard let index = timeline.presentation.sequences.firstIndex(where: { $0.id == id }) else { return }
        timelineCommand { $0.timeline.mergeSequence(at: index) }
    }

    /// Deletes keyframe `id`, folding its changes into the next keyframe so later
    /// keyframes look the same. When it was current, the one before it becomes current.
    public mutating func deleteKeyframe(_ id: Int) {
        timelineCommand { editor in
            let wasCurrent = editor.currentKeyframe == id
            guard let previous = editor.timeline.deleteKeyframe(id) else { return }
            if wasCurrent { editor.currentKeyframe = editor.timeline.presentation.keyframe(atChainIndex: previous)?.id }
        }
    }

    /// Deletes sequence `id` and its keyframes, folding their changes into what follows.
    public mutating func deleteSequence(_ id: Int) {
        guard let index = timeline.presentation.sequences.firstIndex(where: { $0.id == id }) else { return }
        let start = timeline.presentation.chainRange(ofSequence: index)?.lowerBound ?? 1
        let ids = Set(timeline.presentation.sequences[index].keyframes.map(\.id))
        timelineCommand { editor in
            editor.timeline.deleteSequence(at: index)
            if let current = editor.currentKeyframe, ids.contains(current) {
                editor.currentKeyframe = editor.timeline.presentation.keyframe(atChainIndex: start - 1)?.id
            }
        }
    }

    /// Revert Keyframe: removes all of keyframe `id`'s changes.
    public mutating func revertKeyframe(_ id: Int) {
        timelineCommand { $0.timeline.revertKeyframe(id) }
    }

    /// Duplicate Keyframe: inserts a hold after keyframe `id` and makes it current.
    public mutating func duplicateKeyframe(_ id: Int) {
        timelineCommand { editor in
            if let copy = editor.timeline.duplicateKeyframe(id) { editor.currentKeyframe = copy }
        }
    }

    /// Moves keyframe `id` to `position` in sequence `sequence` (an id), keeping how every
    /// keyframe looks.
    public mutating func moveKeyframe(_ id: Int, toSequence sequence: Int, at position: Int) {
        timelineCommand { $0.timeline.moveKeyframe(id, toSequence: sequence, at: position) }
    }

    /// Sets keyframe `id`'s transition, which new keyframes then take too. Changes with
    /// `continuous` in a row (a slider drag) are one undo step.
    public mutating func setTransition(_ transition: Transition, ofKeyframe id: Int, continuous: Bool = false) {
        timelineCommand(key: continuous ? "transition-\(id)" : nil) { $0.timeline.setTransition(transition, ofKeyframe: id) }
    }

    public mutating func renameKeyframe(_ id: Int, to name: String) {
        timelineCommand { $0.timeline.renameKeyframe(id, to: name) }
    }

    public mutating func renameSequence(_ id: Int, to name: String) {
        timelineCommand { $0.timeline.renameSequence(id, to: name) }
    }

    /// Revert to Previous: the selected layers or shapes go back to how they are at the
    /// keyframe before the current one, so the current keyframe no longer changes them
    /// (shapes and layers it created are removed). Names and editor hints stay.
    public mutating func revertSelectionToPrevious() {
        let index = currentChainIndex
        guard index > 0 else { return }
        cancelGesture()
        let previous = timeline.state(at: index - 1)
        let before = drawing
        func reverted(_ layer: Layer, from old: Layer) -> Layer {
            var copy = old
            copy.name = layer.name
            copy.isHidden = layer.isHidden
            copy.isLocked = layer.isLocked
            return copy
        }
        switch selection {
        case .layer, .layers:
            let ids: Set<Int> = if case .layer(let id) = selection { [id] } else if case .layers(let ids) = selection { ids } else { [] }
            for id in ids {
                guard let l = drawing.layerIndex(id) else { continue }
                if let old = previous.layer(id) { drawing.layers[l] = reverted(drawing.layers[l], from: old) } else { drawing.layers.remove(at: l) }
            }
        case .shape, .shapes:
            for ref in drawing.shapeRefs(in: selection) {
                guard let (l, s) = drawing.indices(ref) else { continue }
                if let old = previous.shape(ref) {
                    var shape = old
                    shape.isHidden = drawing.layers[l].shapes[s].isHidden
                    shape.isLocked = drawing.layers[l].shapes[s].isLocked
                    drawing.layers[l].shapes[s] = shape
                } else {
                    drawing.layers[l].shapes.remove(at: s)
                }
            }
        case .none, .reference:
            return
        }
        validateSelection()
        commit(from: before)
    }

    /// The objects the current keyframe changes, with the shapes and layers they are in.
    public mutating func changedObjects() -> Set<Int> {
        currentKeyframe.map { timeline.changedObjects(inKeyframe: $0) } ?? []
    }

    /// The scene `elapsed` seconds into the transition into keyframe `id`.
    public mutating func scrub(into id: Int, elapsed: Double) -> Drawing {
        guard let index = timeline.presentation.chainIndex(of: id) else { return drawing }
        return timeline.transition(into: index, elapsed: elapsed)
    }

    /// What the timeline strip shows.
    public var timelineStrip: TimelineStrip { TimelineStrip(presentation: timeline.presentation, currentKeyframe: currentKeyframe) }

    /// The scene at keyframe `id` (nil: the opening state), for its chip's thumbnail.
    public mutating func state(atKeyframe id: Int?) -> Drawing {
        if id == currentKeyframe { return drawing }
        return timeline.state(atKeyframe: id)
    }

    // MARK: Previews

    /// The scene the canvas shows: the preview while there is one, else `drawing`.
    public var shownDrawing: Drawing { preview ?? drawing }

    /// Scrubbing: shows the scene `fraction` (0...1, of its duration) of the way through
    /// the transition into keyframe `id`, view-only, until `endPreview()`. A cut shows
    /// the keyframe before it until the end.
    public mutating func scrubPreview(into id: Int, fraction: Double) {
        guard let index = timeline.presentation.chainIndex(of: id), index > 0,
              let keyframe = timeline.presentation.keyframe(atChainIndex: index) else { return }
        cancelGesture()
        syncTimeline()
        let fraction = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let duration = keyframe.transition.duration
        preview = duration > 0 ? timeline.transition(into: index, elapsed: fraction * duration)
            : timeline.state(at: fraction < 1 ? index - 1 : index)
    }

    /// Back to showing the current keyframe.
    public mutating func endPreview() {
        if preview != nil { preview = nil }
    }

    /// The keyframes Play Sequence plays (chain indices): the current keyframe's sequence,
    /// or the first one from the opening state. Nil when there are no keyframes.
    public var currentSequenceRange: ClosedRange<Int>? {
        let presentation = timeline.presentation
        let sequence = currentKeyframe.flatMap { presentation.location(ofKeyframe: $0)?.sequence } ?? 0
        return presentation.chainRange(ofSequence: sequence)
    }

    /// The keyframes sequence `id` plays (chain indices).
    public func chainRange(ofSequence id: Int) -> ClosedRange<Int>? {
        timeline.presentation.sequences.firstIndex { $0.id == id }.flatMap { timeline.presentation.chainRange(ofSequence: $0) }
    }

    /// The chain index of keyframe `id`, for previewing the transition into it alone.
    public func chainIndex(ofKeyframe id: Int) -> Int? {
        timeline.presentation.chainIndex(of: id).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Playing: shows the scene `time` seconds into playing the keyframes in `range` (chain
    /// indices) from the state before the first, view-only. Returns true once it has
    /// reached the end, when it shows the current keyframe again.
    @discardableResult
    public mutating func playPreview(_ range: ClosedRange<Int>, at time: Double) -> Bool {
        if preview == nil {
            cancelGesture()
            syncTimeline()
        }
        guard let (scene, finished) = timeline.playing(range, at: time), !finished else {
            endPreview()
            return true
        }
        preview = scene
        return false
    }

    /// Shows the keyframe before the current one in `onionSkin`, when that is on.
    mutating func updateOnionSkin() {
        let index = currentChainIndex
        let ghost: Drawing? = showsOnionSkin && index > 0 ? timeline.state(at: index - 1) : nil
        if ghost != onionSkin { onionSkin = ghost }
    }

    // MARK: Changed indicators

    /// What the current keyframe keys on the selection: the property keys it sets on the
    /// selected layers or shapes (dotted, as in the file, such as `transform.position` or
    /// `fill`), `points` when it changes their vertices, and `created` when it creates
    /// them. Empty at the opening state.
    public mutating func keyedProperties() -> Set<String> {
        guard let id = currentKeyframe, let keyframe = timeline.presentation.keyframe(id) else { return [] }
        var selected = Set<Int>()
        switch selection {
        case .layer(let id): selected = [id]
        case .layers(let ids): selected = ids
        case .shape, .shapes: selected = Set(drawing.shapeRefs(in: selection).map(\.shape))
        case .none, .reference: return []
        }
        guard !selected.isEmpty else { return [] }
        // Vertices of the selected shapes, as they are now or were before.
        var vertices = Set<Int>()
        for layer in drawing.layers + timeline.state(at: currentChainIndex - 1).layers {
            for shape in layer.shapes where selected.contains(shape.id) { vertices.formUnion(shape.path.points.map(\.id)) }
        }
        var keys = Set<String>()
        for change in keyframe.changes {
            switch change {
            case .set(let target, let props):
                if selected.contains(target) { keys.formUnion(props.map(\.key)) } else if vertices.contains(target) { keys.insert("points") }
            case .create(let object, let parent, _, _, _):
                if selected.contains(object.id) { keys.insert("created") } else if let parent, selected.contains(parent), case .vertex = object {
                    keys.insert("points")
                }
            case .delete(let target, _):
                if vertices.contains(target) { keys.insert("points") }
            case .order(let parent, _):
                if let parent, selected.contains(parent) { keys.insert(drawing.layer(parent) != nil ? "order" : "points") }
            }
        }
        return keys
    }

    /// Runs a timeline command as one undo step, then shows the current keyframe.
    private mutating func timelineCommand(key: String? = nil, _ body: (inout DrawingEditor) -> Void) {
        cancelGesture()
        endPreview()
        syncTimeline()
        let before = snapshot
        body(&self)
        if currentKeyframe.map({ timeline.presentation.chainIndex(of: $0) == nil }) ?? false { currentKeyframe = nil }
        guard snapshot != before else { return }
        if snapshot.presentation != before.presentation { undoStack.record(before, coalescingKey: key) }
        if before.keyframe != currentKeyframe { penPath = nil }
        let state = timeline.state(at: currentChainIndex)
        if state != drawing { drawing = state }
        updateOnionSkin()
        validateSelection()
    }
}
