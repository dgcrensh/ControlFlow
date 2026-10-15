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
        syncTimeline()
        penPath = nil
        currentKeyframe = id
        drawing = timeline.state(at: currentChainIndex)
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

    /// The scene `elapsed` seconds into the transition into keyframe `id`, for scrubbing.
    public mutating func scrub(into id: Int, elapsed: Double) -> Drawing {
        guard let index = timeline.presentation.chainIndex(of: id) else { return drawing }
        return timeline.transition(into: index, elapsed: elapsed)
    }

    /// Runs a timeline command as one undo step, then shows the current keyframe.
    private mutating func timelineCommand(key: String? = nil, _ body: (inout DrawingEditor) -> Void) {
        cancelGesture()
        syncTimeline()
        let before = snapshot
        body(&self)
        if currentKeyframe.map({ timeline.presentation.chainIndex(of: $0) == nil }) ?? false { currentKeyframe = nil }
        guard snapshot != before else { return }
        if snapshot.presentation != before.presentation { undoStack.record(before, coalescingKey: key) }
        if before.keyframe != currentKeyframe { penPath = nil }
        let state = timeline.state(at: currentChainIndex)
        if state != drawing { drawing = state }
        validateSelection()
    }
}
