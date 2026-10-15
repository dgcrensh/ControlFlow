import Foundation

/// What a presenter's input does.
public enum PresentationAction: Hashable, Sendable {
    /// Plays the next sequence, or jumps to the end of the one playing.
    case advance
    /// Jumps to the end of the previous sequence, or to the opening state.
    case back
    /// Leaves presentation mode.
    case exit
}

/// The keys presentation mode answers to. Clickers send Page Down, Page Up or arrows.
public enum PresentationKey: CaseIterable, Hashable, Sendable {
    case space, returnKey, rightArrow, downArrow, pageDown
    case leftArrow, upArrow, pageUp
    case escape

    public var action: PresentationAction {
        switch self {
        case .space, .returnKey, .rightArrow, .downArrow, .pageDown: .advance
        case .leftArrow, .upArrow, .pageUp: .back
        case .escape: .exit
        }
    }
}

/// Presentation mode: the opening state, then one sequence per Advance, played keyframe
/// after keyframe and stopping on its last. Advancing while a sequence plays jumps to
/// its end rather than queueing; Back jumps, with no animation, to the end of the
/// sequence before.
///
/// The presentation is fixed when presenting starts. Time is the display's (seconds):
/// a sequence starts on the first frame asked for after Advance, so it plays from its
/// beginning however long the frame took to come.
public struct Presenter: Sendable {
    private var timeline: Timeline
    /// The sequences played to their end: 0 at the opening state, `sequenceCount` once
    /// every sequence has played. While a sequence plays it is the playing one's index.
    public private(set) var position = 0
    /// The sequence playing, by index, and the display time it started.
    private var playing: (sequence: Int, start: Double?)?
    /// Changes whenever the scene jumps (Advance, Back, or a sequence reaching its end),
    /// but not with each frame of a sequence playing.
    public private(set) var revision = 0

    public init(presentation: Presentation) {
        timeline = Timeline(presentation)
    }

    public var presentation: Presentation { timeline.presentation }
    public var viewport: Viewport { timeline.presentation.opening.viewport }
    public var sequenceCount: Int { timeline.presentation.sequences.count }

    /// The sequence playing (its index), or nil when resting on a sequence's end.
    public var playingSequence: Int? { playing?.sequence }
    public var isPlaying: Bool { playing != nil }
    /// The sequence the next Advance plays from rest, or nil at the end.
    public var nextSequence: Int? {
        let next = playing.map { $0.sequence + 1 } ?? position
        return next < sequenceCount ? next : nil
    }
    public var isAtStart: Bool { position == 0 && playing == nil }
    public var isAtEnd: Bool { position == sequenceCount && playing == nil }

    // MARK: Inputs

    /// Advance or Back. Exit is the caller's to handle; it changes nothing here.
    public mutating func perform(_ action: PresentationAction) {
        switch action {
        case .advance: advance()
        case .back: back()
        case .exit: break
        }
    }

    public mutating func advance() {
        if let playing {
            finish(playing.sequence)
        } else if position < sequenceCount {
            // A sequence with no keyframes has nothing to play.
            if timeline.presentation.chainRange(ofSequence: position) == nil {
                finish(position)
            } else {
                playing = (position, nil)
                revision &+= 1
            }
        }
    }

    public mutating func back() {
        if let playing {
            // The end of the sequence before the one playing: where Advance was pressed.
            position = playing.sequence
            self.playing = nil
        } else if position > 0 {
            position -= 1
        } else {
            return
        }
        revision &+= 1
    }

    private mutating func finish(_ sequence: Int) {
        playing = nil
        position = sequence + 1
        revision &+= 1
    }

    // MARK: Scenes

    /// The scene to show at display time `time`, which also moves playback on: a
    /// sequence that has reached its last keyframe stops there.
    public mutating func scene(at time: Double) -> Drawing {
        guard var current = playing else { return state(afterSequences: position) }
        let start = current.start ?? time
        current.start = start
        playing = current
        guard let range = timeline.presentation.chainRange(ofSequence: current.sequence),
              let (scene, finished) = timeline.playing(range, at: time - start)
        else {
            finish(current.sequence)
            return state(afterSequences: position)
        }
        if finished { finish(current.sequence) }
        return scene
    }

    /// The scene once the first `count` sequences have played: the opening state for 0.
    public mutating func state(afterSequences count: Int) -> Drawing {
        timeline.state(at: chainIndex(afterSequences: count))
    }

    /// Where the next sequence ends, for the presenter view, or nil at the end.
    public mutating func nextEndState() -> Drawing? {
        nextSequence.map { state(afterSequences: $0 + 1) }
    }

    /// The chain index of the last keyframe of the first `count` sequences.
    private func chainIndex(afterSequences count: Int) -> Int {
        let sequences = timeline.presentation.sequences
        return sequences.prefix(max(min(count, sequences.count), 0)).reduce(0) { $0 + $1.keyframes.count }
    }

    // MARK: Labels

    /// The presenter view's counter: "Sequence 3 of 12", counting the one playing.
    public var counter: String {
        let total = sequenceCount
        guard total > 0 else { return "No sequences" }
        let shown = playing.map { $0.sequence + 1 } ?? position
        return shown == 0 ? "Opening, \(total) \(total == 1 ? "sequence" : "sequences")" : "Sequence \(shown) of \(total)"
    }

    /// The name of the sequence Advance plays next, for the presenter view.
    public var nextSequenceTitle: String? {
        nextSequence.map { timeline.presentation.sequences[$0].name ?? "Sequence \($0 + 1)" }
    }

    // MARK: Layout

    /// The camera that fills a view of `viewSize` points with the viewport, letterboxed
    /// and centered, turned `rotation` degrees clockwise (0, or the rotation lock's
    /// quarter turn on the iPad's own screen).
    public static func camera(fitting viewport: Viewport, in viewSize: Vec2, rotation: Double = 0) -> CanvasCamera {
        guard viewport.width > 0, viewport.height > 0, viewSize.x > 0, viewSize.y > 0 else { return CanvasCamera() }
        let turn = Affine2D.rotation(degrees: rotation)
        let width = abs(turn.a) * viewport.width + abs(turn.c) * viewport.height
        let height = abs(turn.b) * viewport.width + abs(turn.d) * viewport.height
        let zoom = min(viewSize.x / width, viewSize.y / height)
        return CanvasCamera(worldToScreen: Affine2D.translation(viewSize / 2) * turn * Affine2D.scale(zoom) *
            Affine2D.translation(-viewport.center))
    }
}

/// Touches in presentation mode: a tap on the right half advances and on the left half
/// goes back, and a two-finger pinch-in exits. Any other touch does nothing.
public struct PresentationTouches: Sendable {
    /// How far (points) a tap may move, and how long (seconds) it may last.
    public static let tapSlop = 20.0
    public static let tapDuration = 0.5
    /// A pinch exits once the fingers close to this fraction of their starting distance.
    public static let pinchExitRatio = 0.6

    private struct Touch: Sendable {
        var start: Vec2
        var location: Vec2
        var time: Double
    }

    private var touches: [Int: Touch] = [:]
    /// The most fingers down at once since the first landed.
    private var mostDown = 0
    /// The two fingers' distance when the second landed.
    private var pinchStart: Double?
    /// The touches have done their action, or can no longer be a tap.
    private var spent = false

    public init() {}

    public mutating func began(id: Int, at location: Vec2, time: Double) {
        touches[id] = Touch(start: location, location: location, time: time)
        mostDown = max(mostDown, touches.count)
        if touches.count == 2 {
            let points = touches.values.map(\.location)
            pinchStart = (points[0] - points[1]).length
        } else {
            pinchStart = nil
        }
    }

    /// Returns `.exit` when a pinch-in closes far enough.
    public mutating func moved(id: Int, to location: Vec2) -> PresentationAction? {
        guard touches[id] != nil else { return nil }
        touches[id]?.location = location
        guard !spent, touches.count == 2, let start = pinchStart, start > 0 else { return nil }
        let points = touches.values.map(\.location)
        guard (points[0] - points[1]).length < start * Self.pinchExitRatio else { return nil }
        spent = true
        return .exit
    }

    /// Returns `.advance` or `.back` for a tap on a view `width` points wide.
    public mutating func ended(id: Int, at location: Vec2, time: Double, width: Double) -> PresentationAction? {
        ended(id: id, at: location, time: time, viewSize: Vec2(width, 0))
    }

    /// Returns `.advance` or `.back` for a tap on a view of `viewSize` points showing the
    /// deck turned `rotation` degrees clockwise: the halves are the deck's as you read it,
    /// so with the deck turned a quarter turn, its right half is the bottom of the screen.
    public mutating func ended(id: Int, at location: Vec2, time: Double, viewSize: Vec2,
                               rotation: Double = 0) -> PresentationAction? {
        guard let touch = touches.removeValue(forKey: id) else { return nil }
        defer { if touches.isEmpty { reset() } }
        guard touches.isEmpty, mostDown == 1, !spent,
              (location - touch.start).length <= Self.tapSlop, time - touch.time <= Self.tapDuration
        else { return nil }
        let center = viewSize / 2
        let onDeck = Affine2D.rotation(degrees: -rotation).applyToVector(location - center)
        return onDeck.x >= 0 ? .advance : .back
    }

    public mutating func cancelled(id: Int) {
        touches[id] = nil
        spent = true
        if touches.isEmpty { reset() }
    }

    private mutating func reset() {
        mostDown = 0
        pinchStart = nil
        spent = false
    }
}

extension DrawingEditor {
    /// Shows `scene` in place of the drawing, view-only, as presentation mode does with
    /// an editor of its own.
    public mutating func showScene(_ scene: Drawing) {
        if preview != scene { preview = scene }
    }
}
