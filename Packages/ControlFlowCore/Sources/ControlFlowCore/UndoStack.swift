import Foundation

/// Undo and redo of whole-state snapshots, up to `limit` undo steps. `Drawing` is a
/// value type with copy-on-write arrays, so a snapshot shares storage with the states
/// around it, but each step still keeps alive a copy of whatever it changed.
public struct UndoStack<State: Sendable>: Sendable {
    /// The default number of undo steps kept; the oldest is dropped past it.
    public static var defaultLimit: Int { 200 }

    public private(set) var undoStates: [State] = []
    public private(set) var redoStates: [State] = []
    public let limit: Int
    private var lastKey: String?

    public init(limit: Int = Self.defaultLimit) {
        self.limit = max(1, limit)
    }

    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }

    /// Records `before` as the state to return to. Consecutive records with the same
    /// non-nil `coalescingKey` (a color picker drag, say) share one undo step.
    public mutating func record(_ before: State, coalescingKey: String? = nil) {
        redoStates.removeAll()
        if let coalescingKey, coalescingKey == lastKey, !undoStates.isEmpty { return }
        push(before)
        lastKey = coalescingKey
    }

    public mutating func undo(current: State) -> State? {
        guard let state = undoStates.popLast() else { return nil }
        redoStates.append(current)
        lastKey = nil
        return state
    }

    public mutating func redo(current: State) -> State? {
        guard let state = redoStates.popLast() else { return nil }
        push(current)
        lastKey = nil
        return state
    }

    private mutating func push(_ state: State) {
        undoStates.append(state)
        if undoStates.count > limit { undoStates.removeFirst(undoStates.count - limit) }
    }

    /// Ends any coalescing run, so the next record starts a new undo step.
    public mutating func breakCoalescing() {
        lastKey = nil
    }
}
