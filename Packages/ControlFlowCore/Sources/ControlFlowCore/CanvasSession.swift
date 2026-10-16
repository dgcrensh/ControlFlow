import Foundation

/// What produced a touch. The app maps `UITouch.TouchType.pencil` to `.pencil`
/// and `.direct` to `.finger`; other touch types are not forwarded.
public enum TouchKind: Hashable, Sendable {
    case pencil
    case finger
}

/// Tuning for input routing and palm rejection.
public struct InputOptions: Hashable, Sendable {
    /// Fingers draw only when this is on. The spec is Pencil-only; the app turns this
    /// on in the iOS Simulator, which has no Pencil.
    public var fingerDraws: Bool = false
    /// Touches with a major radius above this (in points) are treated as a resting palm.
    /// iPad reports finger radii in steps of about 10.4 pt, and a fingertip pressed
    /// into a pinch often reads 41.8, so the cut sits above 52.3 and below a palm.
    public var palmMajorRadius: Double = 56
    /// Samples closer than this many screen points to the previous one are dropped.
    public var minSampleSpacing: Double = 0.5
    /// A multi-finger tap must lift within this many seconds...
    public var tapMaxDuration: Double = 0.35
    /// ...and no finger may move further than this many screen points.
    public var tapMaxMovement: Double = 12
    /// QuickShape: holding the Pencil this many seconds at the end of a stroke...
    public var quickShapeDelay: Double = 0.5
    /// ...within this many screen points snaps the stroke to a clean shape.
    public var quickShapeStillness: Double = 4

    public init(fingerDraws: Bool = false, palmMajorRadius: Double = 56, minSampleSpacing: Double = 0.5,
                tapMaxDuration: Double = 0.35, tapMaxMovement: Double = 12,
                quickShapeDelay: Double = 0.5, quickShapeStillness: Double = 4) {
        self.fingerDraws = fingerDraws
        self.palmMajorRadius = palmMajorRadius
        self.minSampleSpacing = minSampleSpacing
        self.tapMaxDuration = tapMaxDuration
        self.tapMaxMovement = tapMaxMovement
        self.quickShapeDelay = quickShapeDelay
        self.quickShapeStillness = quickShapeStillness
    }
}

/// A command triggered by a multi-finger tap.
public enum TapCommand: Hashable, Sendable {
    case undo
    case redo
}

/// The canvas state machine: camera, the vector editor, the live pencil stroke, and
/// the touch routing that decides what each touch does. It is pure Swift, so palm
/// rejection and gesture behaviour are unit-tested without UIKit.
///
/// Routing rules (spec, "Apple Pencil and touch input"):
/// - The Pencil draws, selects and edits, depending on the tool. Only one Pencil
///   touch is tracked at a time.
/// - One finger never draws or edits.
/// - Two fingers pan, pinch-zoom and rotate the canvas together. With the rotation
///   locked they pan and zoom only (see `RotationLock`).
/// - While the Pencil is down, finger touches are ignored, so a resting palm cannot
///   move the canvas mid-stroke. Large-radius touches are ignored as palms anyway.
/// - Fingers beyond the first two do not navigate.
/// - A quick two-finger tap undoes; a three-finger tap redoes.
public struct CanvasSession: Sendable {
    public var camera = CanvasCamera()
    public var options: InputOptions
    public var editor = DrawingEditor()

    /// The pencil stroke being drawn right now, including predicted samples.
    public private(set) var liveStroke: InkStroke?
    /// The clean shape the live stroke snapped to (QuickShape), committed on lift.
    public private(set) var quickShape: BezierPath?
    /// Where and when the Pencil last moved more than `quickShapeStillness`, in screen points.
    private var stillSince: (point: Vec2, time: Double)?
    /// The last multi-finger tap command, and a counter that changes with each one.
    public private(set) var lastTapCommand: TapCommand?
    public private(set) var tapCommandCount = 0

    /// The Pencil touch (or, in the Simulator, the drawing finger) in progress.
    private var drawingTouch: Int?
    private var tap: FingerTap?
    private var fingers: [Int: Vec2] = [:]
    private var fingerOrder: [Int] = []
    private var ignored: Set<Int> = []
    private var navigation: (ids: (Int, Int), gesture: TwoFingerNavigation)?
    private var nextStrokeID = 1

    /// The rotation lock (see `RotationLock`): two fingers don't rotate, and the camera
    /// keeps the quarter turn that lines the viewport up with the view. Set it with
    /// `setRotationLocked(_:viewSize:animated:)`.
    public private(set) var isRotationLocked = false
    /// The camera snapping to the locked rotation, while it animates.
    public private(set) var turn: CameraTurn?

    public init(options: InputOptions = InputOptions(), drawing: Drawing = Drawing()) {
        self.init(options: options, presentation: Presentation(opening: drawing))
    }

    public init(options: InputOptions = InputOptions(), presentation: Presentation) {
        self.options = options
        self.editor = DrawingEditor(presentation: presentation)
    }

    public var isNavigating: Bool { navigation != nil }
    public var isTurning: Bool { turn != nil }
    public var isDrawing: Bool { liveStroke != nil }

    /// The live stroke's mirror image while symmetry is on, for drawing as a preview.
    public var mirroredLiveStroke: InkStroke? {
        guard editor.symmetry.isEnabled, var stroke = liveStroke else { return nil }
        let symmetry = editor.symmetry
        stroke.points = stroke.points.map(symmetry.mirror)
        stroke.predicted = stroke.predicted.map(symmetry.mirror)
        return stroke
    }
    /// True while the Pencil (or the Simulator's drawing finger) is down.
    public var isPencilActive: Bool { drawingTouch != nil }

    // MARK: Commands

    /// 100% zoom with the world origin at the center of the view, unrotated, or at the
    /// locked rotation while the lock is on.
    public mutating func resetView(viewSize: Vec2) {
        turn = nil
        camera = .centered(in: viewSize)
        if isRotationLocked {
            camera = camera.turned(to: lockedRotation(viewSize: viewSize), about: viewSize / 2)
        }
        navigation = nil
    }

    /// Fits `rect` (world space) in the view, centered, with `margin` screen points to
    /// spare on the tighter side: unrotated, or at the locked rotation while the lock is on.
    public mutating func zoom(toFit rect: Rect, viewSize: Vec2, margin: Double = 48) {
        let rotation = isRotationLocked ? lockedRotation(viewSize: viewSize) : 0
        zoom(toFit: rect, viewSize: viewSize, rotation: rotation, margin: margin)
    }

    /// Fits `rect` (world space) in the view at rotation `rotation` (degrees clockwise).
    public mutating func zoom(toFit rect: Rect, viewSize: Vec2, rotation: Double, margin: Double = 48) {
        guard let fitted = CanvasCamera.fitting(rect, in: viewSize, rotation: rotation, margin: margin) else { return }
        turn = nil
        camera = fitted
        navigation = nil
    }

    // MARK: Rotation lock

    /// The rotation the lock wants for a view of `viewSize` points, in degrees clockwise.
    public func lockedRotation(viewSize: Vec2, interfaceTurn: Double? = nil) -> Double {
        let current = turn?.end.rotationDegrees ?? camera.rotationDegrees
        return RotationLock.targetRotation(viewport: editor.drawing.viewport, viewSize: viewSize,
                                           current: current, interfaceTurn: interfaceTurn)
    }

    /// Turns the lock on or off. Turning it on snaps the rotation to the locked one about
    /// the view's center, keeping the zoom: over `RotationLock.snapDuration` when
    /// `animated` (the app then calls `stepTurn(at:)` each frame), else at once.
    /// Turning it off leaves the camera where it is.
    public mutating func setRotationLocked(_ locked: Bool, viewSize: Vec2, animated: Bool = true) {
        guard locked != isRotationLocked else { return }
        isRotationLocked = locked
        if let nav = navigation {
            // A navigation in progress carries on under the new rule from where it is.
            let p0 = fingers[nav.ids.0] ?? nav.gesture.start0, p1 = fingers[nav.ids.1] ?? nav.gesture.start1
            navigation = (nav.ids, TwoFingerNavigation(startCamera: camera, start0: p0, start1: p1, rotates: !locked))
        }
        if locked {
            keepRotationLocked(viewSize: viewSize, animated: animated)
        } else {
            finishTurn()
        }
    }

    /// Snaps the camera back to the locked rotation if it has left it, for instance after
    /// the viewport changed between landscape and portrait. Does nothing while the lock
    /// is off, a turn is animating or two fingers are navigating.
    public mutating func keepRotationLocked(viewSize: Vec2, animated: Bool = true) {
        guard isRotationLocked, turn == nil, navigation == nil, viewSize.x > 0, viewSize.y > 0 else { return }
        let target = lockedRotation(viewSize: viewSize)
        guard abs(RotationLock.signedDegrees(target - camera.rotationDegrees)) > 1e-6 else { return }
        let center = viewSize / 2
        if animated {
            turn = CameraTurn(start: camera, to: target, about: center)
        } else {
            camera = camera.turned(to: target, about: center)
        }
    }

    /// Moves an animated turn on to display time `time`. Returns true while it runs.
    @discardableResult
    public mutating func stepTurn(at time: Double) -> Bool {
        guard var current = turn else { return false }
        let (camera, finished) = current.camera(at: time)
        self.camera = camera
        turn = finished ? nil : current
        return !finished
    }

    /// Jumps an animated turn to its end.
    private mutating func finishTurn() {
        if let turn { camera = turn.end }
        turn = nil
    }

    /// The canvas view changed size from `old` to `new` points: keeps the world point at
    /// the center of the view at the center, and, with the lock on, turns the camera about
    /// it to the locked rotation, keeping the zoom. `interfaceTurn` is how far the
    /// interface turned on the glass (`DisplayOrientation.turn(from:to:)`), when the
    /// resize came from turning the iPad.
    public mutating func viewDidResize(from old: Vec2, to new: Vec2, interfaceTurn: Double? = nil) {
        guard old != new, new.x > 0, new.y > 0 else { return }
        finishTurn()
        let center = new / 2
        let world = camera.toWorld(old / 2)
        camera = CanvasCamera(worldToScreen: Affine2D.translation(center - camera.toScreen(world)) * camera.worldToScreen)
        if isRotationLocked {
            camera = camera.turned(to: lockedRotation(viewSize: new, interfaceTurn: interfaceTurn), about: center)
        }
        if let nav = navigation {
            // Restart the gesture from the new camera so it doesn't jump back.
            navigation = (nav.ids, TwoFingerNavigation(startCamera: camera, start0: fingers[nav.ids.0] ?? nav.gesture.start0,
                                                       start1: fingers[nav.ids.1] ?? nav.gesture.start1,
                                                       rotates: !isRotationLocked))
        }
    }

    /// Removes all art. Undoable.
    public mutating func clear() {
        cancelPencil()
        editor.clearArt()
    }

    public mutating func undo() {
        cancelPencil()
        editor.undo()
    }

    public mutating func redo() {
        cancelPencil()
        editor.redo()
    }

    /// The Pencil hovering above the screen at `location`, or `nil` when it leaves. The
    /// pen tool draws its rubber band to it.
    @discardableResult
    public mutating func pencilHovered(at location: Vec2?) -> Bool {
        guard drawingTouch == nil, editor.preview == nil else { return false }
        return editor.pencilHovered(at: location.map { camera.toWorld($0) }, zoom: camera.zoom)
    }

    /// Checks for a QuickShape hold: the app calls this on a timer while the Pencil is
    /// down, since a still Pencil sends no events. When the Pencil has stayed put for
    /// `quickShapeDelay` at the end of a freehand stroke that looks like a line, arc,
    /// ellipse, rectangle or polygon, the stroke snaps to that shape. Returns true when
    /// it snapped. After a line snaps, its end keeps following the Pencil.
    @discardableResult
    public mutating func checkQuickShape(time: Double) -> Bool {
        guard quickShape == nil, var stroke = liveStroke, let still = stillSince,
              time - still.time >= options.quickShapeDelay,
              let path = ShapeRecognizer.recognize(stroke.points, zoom: camera.zoom) else { return false }
        quickShape = path
        stroke.points = Self.preview(of: path, zoom: camera.zoom)
        stroke.predicted = []
        liveStroke = stroke
        return true
    }

    /// The polyline the live stroke shows for a QuickShape.
    private static func preview(of path: BezierPath, zoom: Double) -> [Vec2] {
        let poly = path.flattened(tolerance: 0.25 / max(zoom, 1e-9))
        return path.closed && poly.count > 2 ? poly + [poly[0]] : poly
    }

    // MARK: Touches (screen-space points, times in seconds)

    /// `pressure` is the Pencil's force as a fraction (0...1) of the most it reports,
    /// when known.
    public mutating func touchBegan(id: Int, kind: TouchKind, location: Vec2, majorRadius: Double = 0, time: Double = 0,
                                    pressure: Double? = nil) {
        switch kind {
        case .pencil:
            // A preview (scrubbing or playing) is view-only.
            guard (drawingTouch == nil || isFingerDrawing) && editor.preview == nil else {
                ignored.insert(id)
                return
            }
            if isFingerDrawing { cancelPencil() }
            // The Pencil wins over navigation; any fingers down now stay ignored.
            navigation = nil
            for finger in fingerOrder { ignored.insert(finger) }
            fingers.removeAll()
            fingerOrder.removeAll()
            tap = nil
            beginPencil(touch: id, at: location, pressure: pressure)
            stillSince = (location, time)

        case .finger:
            if majorRadius > options.palmMajorRadius || (drawingTouch != nil && !isFingerDrawing) {
                ignored.insert(id)
                return
            }
            trackTap(id, at: location, time: time)
            if options.fingerDraws, drawingTouch == nil, fingerOrder.isEmpty, editor.preview == nil {
                // Simulator only: a lone finger draws. It is still tracked as a finger
                // so a second finger can turn the touch into navigation.
                trackFinger(id, at: location)
                beginPencil(touch: id, at: location)
                stillSince = (location, time)
                return
            }
            guard fingerOrder.count < 2 else {
                ignored.insert(id)
                return
            }
            if isFingerDrawing { cancelPencil() }
            trackFinger(id, at: location)
            if fingerOrder.count == 2 { startNavigation() }
        }
    }

    /// `samples` are the coalesced locations since the last call, oldest first, ending
    /// with the current location. `predicted` are the system's predicted locations.
    /// `time` (seconds, as touches report it) lets a Pencil held still trigger QuickShape.
    /// `pressures`, when given, are each sample's force as a fraction (0...1) of the most
    /// the Pencil reports.
    public mutating func touchMoved(id: Int, samples: [Vec2], predicted: [Vec2] = [], time: Double? = nil,
                                    pressures: [Double]? = nil) {
        guard let current = samples.last else { return }
        if var t = tap, let start = t.starts[id] {
            if current.distance(to: start) > options.tapMaxMovement { t.moved = true }
            tap = t
        }
        guard !ignored.contains(id) else { return }

        if id == drawingTouch {
            if var shape = quickShape, var stroke = liveStroke {
                // A snapped line keeps following the Pencil; other shapes stay put.
                if !shape.closed, shape.points.count == 2, shape.points[1].inHandle == .zero {
                    shape.points[1].position = camera.toWorld(current)
                    quickShape = shape
                    stroke.points = Self.preview(of: shape, zoom: camera.zoom)
                    liveStroke = stroke
                }
            } else if var stroke = liveStroke {
                let spacing = options.minSampleSpacing / camera.zoom
                let pressures = pressures?.count == samples.count ? pressures : nil
                for (k, s) in samples.enumerated() {
                    stroke.append(camera.toWorld(s), pressure: pressures?[k], minSpacing: spacing)
                }
                stroke.predicted = predicted.map { camera.toWorld($0) }
                liveStroke = stroke
                if let time, stillSince.map({ current.distance(to: $0.point) > options.quickShapeStillness }) ?? true {
                    stillSince = (current, time)
                }
            } else {
                editor.pencilMoved(to: camera.toWorld(current))
            }
        }

        if fingers[id] != nil {
            fingers[id] = current
            if let nav = navigation, let p0 = fingers[nav.ids.0], let p1 = fingers[nav.ids.1] {
                camera = nav.gesture.camera(current0: p0, current1: p1)
            }
        }
    }

    public mutating func touchEnded(id: Int, location: Vec2? = nil, time: Double = 0) {
        if let location, var t = tap, let start = t.starts[id] {
            if location.distance(to: start) > options.tapMaxMovement { t.moved = true }
            tap = t
        }
        endTap(id, time: time, cancelled: false)
        if ignored.remove(id) != nil { return }
        if id == drawingTouch {
            if let location { touchMoved(id: id, samples: [location]) }
            finishPencil(at: location, time: time)
        }
        releaseFinger(id)
    }

    public mutating func touchCancelled(id: Int) {
        endTap(id, time: 0, cancelled: true)
        if ignored.remove(id) != nil { return }
        if id == drawingTouch { cancelPencil() }
        releaseFinger(id)
    }

    // MARK: Private

    private var isFingerDrawing: Bool {
        guard let drawingTouch else { return false }
        return fingers[drawingTouch] != nil
    }

    private mutating func trackFinger(_ id: Int, at location: Vec2) {
        fingers[id] = location
        fingerOrder.append(id)
    }

    private mutating func releaseFinger(_ id: Int) {
        guard fingers.removeValue(forKey: id) != nil else { return }
        fingerOrder.removeAll { $0 == id }
        if let nav = navigation, nav.ids.0 == id || nav.ids.1 == id {
            navigation = nil
        }
    }

    private mutating func startNavigation() {
        let a = fingerOrder[0], b = fingerOrder[1]
        guard let p0 = fingers[a], let p1 = fingers[b] else { return }
        // Fingers take over from a turn still animating, from where it ends.
        finishTurn()
        navigation = ((a, b), TwoFingerNavigation(startCamera: camera, start0: p0, start1: p1,
                                                  rotates: !isRotationLocked))
    }

    private mutating func beginPencil(touch: Int, at location: Vec2, pressure: Double? = nil) {
        drawingTouch = touch
        quickShape = nil
        let world = camera.toWorld(location)
        switch editor.tool {
        case .pencil:
            // Only the Pencil tool draws freehand; every other tool edits through the editor.
            let style = editor.style
            // The live stroke previews the outline color; a fill-only shape previews its fill.
            let color = style.outlineEnabled || !style.fillEnabled ? style.outline : style.fill
            var stroke = InkStroke(id: nextStrokeID, start: world, brush: Brush(width: style.outlineWidth, color: color))
            if let pressure {
                stroke.pressures = [pressure]
                stroke.showsPressure = editor.pressureWidth
            }
            liveStroke = stroke
            nextStrokeID += 1
        case .pen, .select, .directSelect, .shape, .eraser, .scissors, .text:
            editor.pencilBegan(at: world, zoom: camera.zoom)
        }
    }

    private mutating func finishPencil(at location: Vec2?, time: Double?) {
        if let shape = quickShape {
            editor.addPath(shape)
        } else if let stroke = liveStroke {
            editor.addStroke(stroke.points, pressures: stroke.pressures, zoom: camera.zoom)
        } else if let id = drawingTouch {
            let world = location.map { camera.toWorld($0) } ?? fingers[id].map { camera.toWorld($0) }
            if let world { editor.pencilEnded(at: world, time: time) } else { editor.pencilCancelled() }
        }
        liveStroke = nil
        quickShape = nil
        stillSince = nil
        drawingTouch = nil
    }

    private mutating func cancelPencil() {
        if liveStroke == nil, drawingTouch != nil { editor.pencilCancelled() }
        liveStroke = nil
        quickShape = nil
        stillSince = nil
        drawingTouch = nil
    }

    // MARK: Multi-finger taps

    private struct FingerTap: Sendable {
        var startTime: Double
        var starts: [Int: Vec2] = [:]
        var down: Set<Int> = []
        var maxCount = 0
        var moved = false
        var startCamera: CanvasCamera
    }

    private mutating func trackTap(_ id: Int, at location: Vec2, time: Double) {
        if tap == nil {
            // A tap starts only from a canvas with no fingers down.
            guard fingerOrder.isEmpty else { return }
            tap = FingerTap(startTime: time, startCamera: turn?.end ?? camera)
        }
        tap!.starts[id] = location
        tap!.down.insert(id)
        tap!.maxCount = max(tap!.maxCount, tap!.down.count)
    }

    private mutating func endTap(_ id: Int, time: Double, cancelled: Bool) {
        guard var t = tap, t.down.contains(id) else { return }
        t.down.remove(id)
        if cancelled { t.moved = true }
        tap = t
        guard t.down.isEmpty else { return }
        tap = nil
        guard !t.moved, time - t.startTime <= options.tapMaxDuration else { return }
        let command: TapCommand
        switch t.maxCount {
        case 2: command = .undo
        case 3: command = .redo
        default: return
        }
        // A tap is not a navigation: put back any tiny camera movement.
        camera = t.startCamera
        navigation = nil
        if isFingerDrawing { cancelPencil() }
        // A preview is view-only.
        guard editor.preview == nil else { return }
        switch command {
        case .undo: undo()
        case .redo: redo()
        }
        lastTapCommand = command
        tapCommandCount += 1
    }
}
