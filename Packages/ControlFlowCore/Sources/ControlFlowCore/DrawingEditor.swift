import Foundation

/// The Pencil tools.
public enum Tool: String, Hashable, Sendable, CaseIterable {
    /// Draw freehand strokes that are fitted to Bézier shapes.
    case pencil
    /// Place anchors one by one; drag after placing to pull a handle.
    case pen
    /// Select layers and shapes; move, scale, rotate and flip them with handles.
    case select
    /// Edit the anchors and handles of the tapped shapes.
    case directSelect
    /// Drag out rectangles, ellipses, polygons, stars and lines.
    case shape
    /// Delete every shape the Pencil passes over.
    case eraser
    /// Tap an outline to cut the path there.
    case scissors
}

/// Live symmetry: new strokes, shapes and pen paths get a mirrored copy across a
/// vertical axis.
public struct SymmetrySettings: Hashable, Sendable {
    public var isEnabled: Bool
    /// The mirror line's x in world points.
    public var axis: Double

    public init(isEnabled: Bool = false, axis: Double = 0) {
        self.isEnabled = isEnabled
        self.axis = axis
    }

    /// Mirrors world space across the axis.
    public var transform: Affine2D {
        Affine2D.translation(Vec2(axis, 0)) * Affine2D.scale(x: -1, y: 1) * Affine2D.translation(Vec2(-axis, 0))
    }

    public func mirror(_ p: Vec2) -> Vec2 { Vec2(2 * axis - p.x, p.y) }
}

/// Modifier keys, from a hardware keyboard or the on-screen modifier strip.
public struct EditorModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Shift: square and circle shapes, 45-degree lines, moves along one axis, 15-degree rotation.
    public static let constrain = EditorModifiers(rawValue: 1)
    /// Option: shapes grow from their center, and dragging a selection drags a copy.
    public static let alternate = EditorModifiers(rawValue: 2)
}

/// Style for new shapes, and the style controls applied to the selection.
public struct ShapeStyle: Hashable, Sendable {
    public var fill: RGBAColor
    public var fillEnabled: Bool
    public var outline: RGBAColor
    public var outlineWidth: Double
    public var outlineEnabled: Bool
    public var outlineCap: LineCap = .round
    public var outlineJoin: LineJoin = .round
    public var miterLimit: Double = 4
    /// Dash and gap lengths in points; empty for a solid outline.
    public var outlineDash: [Double] = []
    public var outlineAlignment: StrokeAlignment = .center

    public init(fill: RGBAColor = RGBAColor(hex: "#F2A65A")!, fillEnabled: Bool = true,
                outline: RGBAColor = .ink, outlineWidth: Double = 3, outlineEnabled: Bool = true) {
        self.fill = fill
        self.fillEnabled = fillEnabled
        self.outline = outline
        self.outlineWidth = outlineWidth
        self.outlineEnabled = outlineEnabled
    }

    /// An outline in this style.
    public func makeStroke(color: RGBAColor? = nil) -> StrokeStyle {
        StrokeStyle(color: color ?? outline, width: outlineWidth, cap: outlineCap, join: outlineJoin,
                    miterLimit: miterLimit, dash: outlineDash, alignment: outlineAlignment)
    }
}

/// Hit sizes, in screen points, so they feel the same at any zoom.
public enum EditorMetrics {
    public static let tapSlop = 6.0
    public static let shapeHit = 8.0
    public static let transformHandleHit = 22.0
    public static let rotateHandleOffset = 28.0
    public static let anchorHit = 16.0
    public static let curveHit = 12.0
    public static let pivotHit = 14.0
    /// The eraser's reach around the Pencil tip.
    public static let eraserRadius = 10.0
    /// Two taps closer than this in time (seconds) and space (screen points) are a double tap.
    public static let doubleTapTime = 0.4
    public static let doubleTapDistance = 20.0
    /// How close a drag must come to an anchor or grid line to snap, in screen points.
    public static let snapRadius = 8.0
}

/// The open path the Pen tool is extending. The active end is the last point, except
/// right after continuing a path from its start, when the path is reversed on the
/// next placement.
public struct PenPath: Hashable, Sendable {
    public var layer: Int
    public var shape: Int
    public var fromStart: Bool
    /// The pen made the layer, so its pivot follows the path.
    public var createdLayer: Bool
}

/// The vector editing state: the drawing, selection, tools, styles and undo.
///
/// Pencil gestures for the pen, select and direct-select tools arrive here in world
/// space. Pencil strokes are captured by `CanvasSession` and handed over with
/// `addStroke`. Every change made by a finished gesture or command is one undo step.
public struct DrawingEditor: Sendable {
    public var drawing = Drawing() {
        didSet {
            revision &+= 1
            // Isolation ends when its layer goes (deleted, erased, merged or undone away).
            if let id = isolatedLayer, drawing.layerIndex(id) == nil { isolatedLayer = nil }
            if let id = isolatedGroup, isolatedLayer.flatMap({ drawing.layer($0)?.group(id) }) == nil { isolatedGroup = nil }
            if let id = targetLayer, drawing.layerIndex(id) == nil { targetLayer = nil }
        }
    }
    /// Increments on every change to `drawing`, so renderers know to rebuild.
    public private(set) var revision = 0
    /// Changing the selection adopts the selected shape's style, so the style
    /// controls show it and new strokes continue in it.
    public var selection: Selection = .none {
        didSet {
            guard selection != oldValue else { return }
            selectedAnchors = []
            customPivot = nil
            if let selected = selectionStyle { style = selected }
        }
    }
    /// The selected anchor indices of the one shape the direct-select tool is editing.
    public var selectedAnchors: Set<Int> = []
    /// The selected anchor when exactly one is selected.
    public var selectedAnchor: Int? {
        get { selectedAnchors.count == 1 ? selectedAnchors.first : nil }
        set { selectedAnchors = newValue.map { [$0] } ?? [] }
    }
    public var tool: Tool = .pencil {
        didSet {
            guard tool != oldValue else { return }
            cancelGesture()
            if oldValue == .pen { penFinish() }
            penCursor = nil
            previousTool = oldValue
            lastTap = nil
        }
    }
    /// The tool before the current one, for the Pencil's double tap.
    public private(set) var previousTool: Tool?
    /// Draws every shape as a thin wireframe instead of its fill and outline.
    public var outlineView = false
    /// Dims everything but the selection (see `ghostFocus`).
    public var ghostsUnselected = false
    public var symmetry = SymmetrySettings()
    /// What the shape tool draws, and its settings.
    public var shapeKind: ShapeKind = .rectangle
    public var shapeOptions = ShapeToolOptions()
    /// Held modifier keys (hardware keyboard or the modifier strip).
    public var modifiers: EditorModifiers = []
    /// The layer being edited on its own: everything else is dimmed and can't be touched,
    /// and new shapes join this layer.
    public internal(set) var isolatedLayer: Int?
    /// The group of `isolatedLayer` being edited on its own, one level further in: only
    /// its shapes can be picked, and new shapes join it.
    public internal(set) var isolatedGroup: Int?
    /// The layer made active in the layers panel: new strokes, pen paths, shapes and
    /// pasted shapes go into it (see `activeLayer`). Nil means each new piece of art
    /// starts a new layer, unless isolation or auto-join says otherwise.
    public internal(set) var targetLayer: Int?
    /// Fill and outline colors used lately, newest first, for the squeeze palette.
    public internal(set) var recentColors: [RGBAColor] = []
    /// Set by a run of color changes from one control, so a picker drag adds one recent color.
    var recentColorSource: String?
    public var style = ShapeStyle()
    /// 0 keeps strokes close to the Pencil path; 1 smooths them a lot.
    public var smoothing = 0.4
    /// When on, Pencil pressure sets the outline width along new freehand strokes.
    /// Off by default: outlines are uniform.
    public var pressureWidth = false
    /// When on, a new freehand stroke or pen path joins the selected layer instead of
    /// starting a new one. Freehand strokes also need to overlap that layer.
    public var autoJoinSelectedLayer = false
    /// When on, tapping or marquee-dragging adds to (or removes from) the selection.
    public var addToSelection = false
    public var snap = SnapSettings()
    /// A short message for the user about an edit that was refused. The app shows it and
    /// clears it with `clearNotice()`.
    public internal(set) var notice: String?
    public private(set) var undoStack = UndoStack<Drawing>()

    /// A pivot the user dragged for a selection that is not a layer. Layers keep theirs in `Layer.pivot`.
    public internal(set) var customPivot: Vec2?
    /// The marquee rectangle while one is being dragged.
    public private(set) var marquee: Rect?
    /// The path the pen is extending, if any.
    public private(set) var penPath: PenPath?
    /// Where the Pencil hovers, for the pen's rubber band.
    public private(set) var penCursor: Vec2?
    /// Where the Pencil hovers in any tool, and the zoom then, for hover feedback.
    public private(set) var hoverPoint: Vec2?
    public private(set) var hoverZoom = 1.0

    private var gesture: Gesture? {
        didSet {
            if case .transform = gesture {} else if liveTransform != nil { liveTransform = nil }
            if case .anchors = gesture {} else if closingEdge != nil { closingEdge = nil }
        }
    }
    /// While an end anchor of an open path is dragged over the path's other end: the
    /// straight edge that lifting the Pencil adds to close the shape.
    public private(set) var closingEdge: (from: Vec2, to: Vec2)?
    /// The transform drag in progress, if it moves shapes. See `LiveTransform`.
    public private(set) var liveTransform: LiveTransform?
    /// Numbers the drags' live transforms.
    var liveTransformCount = 0
    var gestureZoom = 1.0
    /// The last tap with a time, for spotting a double tap.
    private var lastTap: (point: Vec2, time: Double)?
    /// The state to undo back to when the gesture's own `before` is not it: an
    /// Option-drag copies the selection first, and undo removes the copy too.
    private var undoBase: Drawing?
    /// The editable shapes in a grid, for hover, taps, the eraser, the scissors and the
    /// marquee. Used only while its revision is `revision` (see `freshShapeIndex`).
    var shapeIndex: ShapeIndex?

    public init() {}

    /// An editor for an opened document, with empty undo history.
    public init(drawing: Drawing) {
        var drawing = drawing
        drawing.assignVertexIDs()
        self.drawing = drawing
    }

    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }
    public var isInGesture: Bool { gesture != nil }
    public var isPenActive: Bool { penPath != nil }

    /// The shape the shape tool's drag is making, if any.
    var shapeBeingDrawn: ShapeRef? {
        if case .shapeDraw(_, let ref, _) = gesture { return ref }
        return nil
    }

    /// The one shape the selection covers, when it covers exactly one.
    public var activeShape: ShapeRef? {
        let refs = drawing.shapeRefs(in: selection)
        return refs.count == 1 ? refs[0] : nil
    }

    /// The layer new shapes would join: the isolated layer, the active layer, the
    /// selected layer, or the first selected shape's.
    var selectedLayerID: Int? {
        if let id = isolatedLayer ?? usableTargetLayer { return id }
        return switch selection {
        case .layer(let id), .shape(let id, _): id
        case .shapes(let refs): refs.min()?.layer
        case .none, .layers, .reference: nil
        }
    }

    /// The point rotation turns about: a dragged pivot, a layer's own pivot, or the
    /// middle of the selection.
    public var pivot: Vec2? {
        if let customPivot { return customPivot }
        if case .layer(let id) = selection, let i = drawing.layerIndex(id), !drawing.layers[i].shapes.isEmpty {
            return drawing.layers[i].worldPivot
        }
        return drawing.frame(of: selection)?.center
    }

    /// Screen-space snap radius in world points at the current gesture's zoom.
    var snapRadius: Double { EditorMetrics.snapRadius / gestureZoom }

    // MARK: Gestures

    private enum Pending: Sendable {
        case selectionBody
        case shape(ShapeRef)
        case pivot
        case anchor(ShapeRef, Int)
        /// A Bézier handle of the selected anchor. Like every press it needs to leave
        /// the tap slop before it moves, so a tap on a handle changes nothing.
        case handle(ShapeRef, index: Int, side: HandleSide)
        case curve(ShapeRef, segment: Int, t: Double, insertsOnTap: Bool)
        case penFinish
        case penClose
        case penJoin(ShapeRef, PathEnd)
        /// A scissors press on an outline.
        case cut(ShapeRef, segment: Int, t: Double)
        case empty
    }

    private enum TransformKind: Sendable {
        case move
        case scale(anchor: Vec2)
        /// Scales along one axis from an edge handle; the opposite edge stays put.
        case stretch(anchor: Vec2, horizontal: Bool)
        case rotate(center: Vec2)
    }

    private enum Gesture: Sendable {
        case pending(Pending, start: Vec2)
        case transform(TransformKind, target: Selection, before: Drawing, start: Vec2)
        case pivot(target: Selection, before: Drawing, grab: Vec2, originalCustom: Vec2?)
        case anchors(ShapeRef, primary: Int, before: Drawing, grab: Vec2)
        case segment(ShapeRef, index: Int, t: Double, before: Drawing, start: Vec2)
        /// `grab` is the handle's offset from the press, so it does not jump to the Pencil tip.
        case handle(ShapeRef, index: Int, side: HandleSide, before: Drawing, grab: Vec2)
        case marquee(start: Vec2, additive: Bool, baseShapes: Set<ShapeRef>, baseAnchors: Set<Int>)
        case penPlace(ShapeRef, index: Int, before: Drawing, penBefore: PenPath?)
        /// The shape tool's drag; `ref` is the shape once the drag has made one.
        case shapeDraw(start: Vec2, ref: ShapeRef?, before: Drawing)
        case erase(before: Drawing, last: Vec2)
        /// A drag that does nothing (for example, from a pen shortcut target).
        case idle
    }

    public mutating func pencilBegan(at p: Vec2, zoom: Double) {
        gestureZoom = max(zoom, 1e-9)
        hoverPoint = nil
        if tool.usesShapeIndex { refreshShapeIndex() }
        let px = 1 / gestureZoom
        switch tool {
        case .pencil:
            gesture = nil
        case .pen:
            gesture = beginPen(at: p, px: px)
        case .select:
            gesture = beginSelect(at: p, px: px)
        case .directSelect:
            gesture = beginDirectSelect(at: p, px: px)
        case .shape:
            gesture = .shapeDraw(start: snapped(p), ref: nil, before: drawing)
        case .eraser:
            gesture = .erase(before: drawing, last: p)
            eraseAlong(p, p)
        case .scissors:
            if let cut = cutTarget(at: p, zoom: gestureZoom) {
                gesture = .pending(.cut(cut.ref, segment: cut.segment, t: cut.t), start: p)
            } else {
                gesture = .pending(.empty, start: p)
            }
        }
    }

    /// The Pencil hovering above the screen (or `nil` once it leaves), at `zoom`. The pen
    /// draws its rubber band to it; other tools highlight what a touch there would hit.
    public mutating func pencilHovered(at p: Vec2?, zoom: Double = 1) {
        penCursor = tool == .pen ? p : nil
        hoverPoint = p
        hoverZoom = max(zoom, 1e-9)
        if p != nil, gesture == nil, tool.usesShapeIndex { refreshShapeIndex() }
    }

    /// The shape a Pencil touch at the hover point would select, erase or cut.
    public var hoverTarget: ShapeRef? {
        guard gesture == nil, let p = hoverPoint else { return nil }
        switch tool {
        case .select, .directSelect, .eraser:
            let reach = (tool == .eraser ? EditorMetrics.eraserRadius : EditorMetrics.shapeHit) / hoverZoom
            return hitShape(at: p, tolerance: reach)
        case .scissors:
            return hoverCut?.ref
        case .pencil, .pen, .shape:
            return nil
        }
    }

    /// Where the scissors would cut if the Pencil touched down at the hover point.
    public var scissorsPreview: Vec2? { hoverCut?.point }

    /// The outline the scissors would cut at the hover point, and where, from one search
    /// (the overlay needs both).
    public var hoverCut: (ref: ShapeRef, point: Vec2)? {
        guard tool == .scissors, gesture == nil, let p = hoverPoint, let cut = cutTarget(at: p, zoom: hoverZoom)
        else { return nil }
        return (cut.ref, cut.path.segment(cut.segment).point(at: cut.t))
    }

    public mutating func pencilMoved(to p: Vec2) {
        guard let gesture else { return }
        switch gesture {
        case .pending(let pending, let start):
            guard p.distance(to: start) > EditorMetrics.tapSlop / gestureZoom else { return }
            self.gesture = startDrag(pending, from: start)
            pencilMoved(to: p)

        case .transform(let kind, let target, let before, let start):
            let nextID = drawing.nextID
            let t = transform(kind, from: start, to: p, target: target, before: before)
            // Shapes and groups take the turn's center (or the frame's) as their pivot.
            var center = before.frame(of: target)?.center
            if case .rotate(let c) = kind { center = c }
            drawing = before.applying(t, to: target, pivot: center)
            if var live = liveTransform {
                live.transform = t
                liveTransform = live
            } else if let shapes = LiveTransform.shapes(of: target, in: before) {
                liveTransformCount &+= 1
                liveTransform = LiveTransform(id: liveTransformCount, base: before, shapes: shapes, transform: t)
            }
            // A duplicating drag made ids `before` does not know about.
            drawing.nextID = max(drawing.nextID, nextID)

        case .pivot(let target, _, let grab, _):
            var layer: Int?
            if case .layer(let id) = target { layer = id }
            let q = pivotSnapped(p + grab, layer: layer)
            if case .layer(let id) = target, let i = drawing.layerIndex(id) {
                drawing.layers[i].setWorldPivot(q)
            } else {
                customPivot = q
            }

        case .anchors(let ref, let primary, let before, let grab):
            guard let idx = drawing.indices(ref), let original = before.worldShape(ref)?.path,
                  original.points.indices.contains(primary) else { return }
            if let edge = edgeClosing(original, dragging: primary, to: p) {
                // Over the other end: the anchor stays put and the closing edge shows.
                closingEdge = edge
                drawing.setWorldPath(original, at: idx)
                return
            }
            closingEdge = nil
            let target = snapped(p + grab, movingAnchors: (ref, selectedAnchors))
            let delta = target - original.points[primary].position
            var path = original
            for i in selectedAnchors where path.points.indices.contains(i) {
                path.moveAnchor(i, to: original.points[i].position + delta)
            }
            drawing.setWorldPath(path, at: idx)

        case .segment(let ref, let index, let t, let before, let start):
            guard let idx = drawing.indices(ref), var path = before.worldShape(ref)?.path else { return }
            path.reshapeSegment(index, t: t, by: p - start)
            drawing.setWorldPath(path, at: idx)

        case .handle(let ref, let index, let side, _, let grab):
            guard let idx = drawing.indices(ref),
                  drawing.layers[idx.0].shapes[idx.1].path.points.indices.contains(index) else { return }
            drawing.updateWorldPath(at: idx) { $0.setHandle(index, side, to: p + grab) }

        case .marquee(let start, _, _, _):
            marquee = Rect(from: start, to: p)

        case .penPlace(let ref, let index, _, _):
            guard let idx = drawing.indices(ref),
                  drawing.layers[idx.0].shapes[idx.1].path.points.indices.contains(index) else { return }
            var point = drawing.layers[idx.0].worldShape(idx.1).path.points[index]
            let drag = p - point.position
            if drag.length > EditorMetrics.tapSlop / gestureZoom {
                // Pulling out of a fresh anchor makes a symmetric handle: out follows the drag.
                point.outHandle = drag
                point.inHandle = -drag
                point.mode = .symmetric
            } else {
                point.outHandle = .zero
                point.inHandle = .zero
                point.mode = .corner
            }
            drawing.updateWorldPath(at: idx) { $0.points[index] = point }

        case .shapeDraw(let start, let ref, let before):
            self.gesture = .shapeDraw(start: start, ref: drawShape(from: start, to: p, ref: ref), before: before)

        case .erase(let before, let last):
            eraseAlong(last, p)
            self.gesture = .erase(before: before, last: p)

        case .idle:
            break
        }
    }

    /// The Pencil lifted at `p`. `time` (seconds) lets two quick taps count as a double
    /// tap; without it every tap is a single tap.
    public mutating func pencilEnded(at p: Vec2, time: Double? = nil) {
        pencilMoved(to: p)
        guard let gesture else { return }
        let closing = closingEdge
        self.gesture = nil
        if case .pending = gesture {} else { lastTap = nil }
        switch gesture {
        case .pending(let pending, let start):
            let isDouble = isDoubleTap(at: start, time: time)
            tap(pending, at: start)
            if isDouble {
                doubleTap(at: start)
                lastTap = nil
            } else {
                lastTap = time.map { (point: start, time: $0) }
            }
            return
        case .shapeDraw(_, let ref, let before):
            if let ref { addMirrorImage(of: ref) }
            commit(from: before)
        case .anchors(let ref, _, let before, _):
            if closing != nil, let idx = drawing.indices(ref),
               let closed = drawing.layers[idx.0].shapes[idx.1].path.closedWithStraightEdge() {
                drawing.layers[idx.0].shapes[idx.1].path = closed
            }
            commit(from: undoBase ?? before)
            undoBase = nil
        case .transform(_, _, let before, _), .pivot(_, let before, _, _),
             .segment(_, _, _, let before, _), .handle(_, _, _, let before, _), .penPlace(_, _, let before, _),
             .erase(let before, _):
            commit(from: undoBase ?? before)
            undoBase = nil
        case .marquee(_, let additive, let baseShapes, let baseAnchors):
            if let rect = marquee { finishMarquee(rect, additive: additive, baseShapes: baseShapes, baseAnchors: baseAnchors) }
            marquee = nil
        case .idle:
            break
        }
    }

    public mutating func pencilCancelled() {
        cancelGesture()
    }

    mutating func cancelGesture() {
        guard let gesture else { return }
        self.gesture = nil
        // Ids handed out by the cancelled gesture stay used.
        let nextID = drawing.nextID
        defer { drawing.nextID = max(drawing.nextID, nextID) }
        switch gesture {
        case .transform(_, _, let before, _), .anchors(_, _, let before, _), .segment(_, _, _, let before, _),
             .handle(_, _, _, let before, _), .shapeDraw(_, _, let before), .erase(let before, _):
            drawing = undoBase ?? before
            undoBase = nil
            validateSelection()
        case .pivot(_, let before, _, let original):
            drawing = before
            customPivot = original
        case .penPlace(_, _, let before, let penBefore):
            drawing = before
            penPath = penBefore
        case .marquee:
            marquee = nil
        case .pending, .idle:
            break
        }
    }

    // MARK: Select

    private func beginSelect(at p: Vec2, px: Double) -> Gesture {
        if let frame = drawing.frame(of: selection) {
            var isReference = false
            if case .reference = selection { isReference = true }
            let reach = EditorMetrics.transformHandleHit * px
            let center = pivot ?? frame.center
            if !isReference, p.distance(to: center) <= EditorMetrics.pivotHit * px {
                return .pending(.pivot, start: p)
            }
            let rotate = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset * px)
            if p.distance(to: rotate) <= reach {
                return .transform(.rotate(center: center), target: selection, before: drawing, start: p)
            }
            if let i = frame.corners.indices.min(by: { frame.corners[$0].distance(to: p) < frame.corners[$1].distance(to: p) }),
               frame.corners[i].distance(to: p) <= reach {
                let opposite = frame.corners[(i + 2) % 4]
                return .transform(.scale(anchor: opposite), target: selection, before: drawing, start: p)
            }
            // Edge handles scale along one axis. Reference images only scale uniformly.
            if !isReference {
                let mids = frame.edgeMidpoints
                if let k = mids.indices.min(by: { mids[$0].distance(to: p) < mids[$1].distance(to: p) }),
                   mids[k].distance(to: p) <= reach {
                    return .transform(.stretch(anchor: mids[(k + 2) % 4], horizontal: k % 2 == 1),
                                      target: selection, before: drawing, start: p)
                }
            }
            if frame.contains(p) {
                return .pending(.selectionBody, start: p)
            }
        }
        if let hit = hitShape(at: p, tolerance: EditorMetrics.shapeHit * px) {
            return .pending(.shape(ShapeRef(layer: hit.layer, shape: hit.shape)), start: p)
        }
        return .pending(.empty, start: p)
    }

    private func isDoubleTap(at p: Vec2, time: Double?) -> Bool {
        guard let time, let last = lastTap else { return false }
        return time - last.time <= EditorMetrics.doubleTapTime &&
            p.distance(to: last.point) <= EditorMetrics.doubleTapDistance / gestureZoom
    }

    /// With the select tool, double-tapping goes one level in: into a grouped shape's
    /// group, or else into the shape's layer (isolating it). Double-tapping empty canvas
    /// goes one level out.
    private mutating func doubleTap(at p: Vec2) {
        guard tool == .select else { return }
        if let hit = hitShape(at: p, tolerance: EditorMetrics.shapeHit / gestureZoom) {
            let ref = ShapeRef(layer: hit.layer, shape: hit.shape)
            if let group = tapGroup(of: ref) {
                isolate(group: group, inLayer: hit.layer)
                selection = .shape(layer: hit.layer, shape: hit.shape)
            } else if isolatedLayer != hit.layer {
                isolate(layer: hit.layer)
            }
        } else if isolatedLayer != nil {
            stepOutOfIsolation()
        }
    }

    /// The group a select-tool tap on `ref` picks: the shape's group, unless that is the
    /// group being edited on its own (then the tap reaches the shape).
    func tapGroup(of ref: ShapeRef) -> Int? {
        guard let group = drawing.shape(ref)?.group, group != isolatedGroup else { return nil }
        return group
    }

    /// What a select-tool tap on `ref` picks once its layer is selected: the shape's whole
    /// group, or the shape itself.
    func tapTarget(_ ref: ShapeRef) -> Selection {
        guard let group = tapGroup(of: ref), let p = drawing.layerIndex(ref.layer) else {
            return .shape(layer: ref.layer, shape: ref.shape)
        }
        let layer = drawing.layers[p]
        let refs = layer.members(ofGroup: group).filter(layer.isEditable).map { ShapeRef(layer: layer.id, shape: layer.shapes[$0].id) }
        return .covering(Set(refs).union([ref]))
    }

    /// True when the selection is layer `id`, or a shape or one group inside it, so the
    /// next tap there goes one level down. Inside an isolated group taps always reach shapes.
    private func selectionIsInside(layer id: Int) -> Bool {
        if isolatedGroup != nil { return true }
        return switch selection {
        case .layer(let p), .shape(let p, _): p == id
        case .shapes(let refs): refs.allSatisfy { $0.layer == id } && drawing.selectedGroup(selection) != nil
        case .none, .layers, .reference: false
        }
    }

    /// Tapping a shape selects its layer; tapping again inside the selected layer selects
    /// the shape's group, or the single shape when it has none. Tapping empty canvas
    /// clears the selection. With `addToSelection`, tapping toggles the shape (or its
    /// whole group) in and out of the selection.
    private mutating func tapSelect(at p: Vec2) {
        guard let hit = hitShape(at: p, tolerance: EditorMetrics.shapeHit / gestureZoom) else {
            if !addToSelection { selection = .none }
            return
        }
        let ref = ShapeRef(layer: hit.layer, shape: hit.shape)
        if addToSelection {
            toggleInSelection(Set(drawing.shapeRefs(in: tapTarget(ref))))
            return
        }
        selection = selectionIsInside(layer: hit.layer) ? tapTarget(ref) : .layer(hit.layer)
    }

    private mutating func toggleInSelection(_ ref: ShapeRef) {
        toggleInSelection([ref])
    }

    /// Adds `toggled` to the selection, or removes them when they are all selected.
    private mutating func toggleInSelection(_ toggled: Set<ShapeRef>) {
        var refs = Set(drawing.shapeRefs(in: selection))
        if toggled.isSubset(of: refs) { refs.subtract(toggled) } else { refs.formUnion(toggled) }
        selection = .covering(refs)
    }

    /// Applies a finished marquee. In the direct-select tool with one shape selected it
    /// picks that shape's anchors; otherwise it picks the shapes the rectangle touches.
    private mutating func finishMarquee(_ rect: Rect, additive: Bool, baseShapes: Set<ShapeRef>, baseAnchors: Set<Int>) {
        if tool == .directSelect, let ref = activeShape, let path = drawing.worldShape(ref)?.path {
            let inside = Set(path.points.indices.filter { rect.contains(path.points[$0].position) })
            if !inside.isEmpty || additive {
                selectedAnchors = additive ? baseAnchors.union(inside) : inside
                return
            }
        }
        refreshShapeIndex(forHitTest: false)
        var refs = Set(shapes(meeting: rect) { Self.marqueeTouches($0, rect) })
        if additive { refs.formUnion(baseShapes) }
        if tool == .select {
            // A marquee touching a grouped shape takes its whole group.
            for ref in refs { refs.formUnion(drawing.shapeRefs(in: tapTarget(ref))) }
            selection = promotedToLayer(refs)
        } else {
            selection = Selection.covering(refs)
        }
    }

    /// `.layer` when `refs` is every shape of exactly one layer, so a marquee around a
    /// whole layer selects the layer the way tapping it does.
    private func promotedToLayer(_ refs: Set<ShapeRef>) -> Selection {
        let layers = Set(refs.map(\.layer))
        if layers.count == 1, let id = layers.first, let i = drawing.layerIndex(id), drawing.layers[i].shapes.count == refs.count {
            return .layer(id)
        }
        return .covering(refs)
    }

    static func marqueeTouches(_ shape: VectorShape, _ rect: Rect) -> Bool {
        guard shape.hitBounds.intersects(rect) else { return false }
        let poly = shape.path.flattened(tolerance: 0.5)
        if poly.contains(where: { rect.contains($0) }) { return true }
        guard poly.count > 1 else { return false }
        for i in 1..<poly.count where rect.intersectsSegment(poly[i - 1], poly[i]) { return true }
        return shape.path.closed && rect.intersectsSegment(poly[poly.count - 1], poly[0])
    }

    // MARK: Direct select

    private mutating func beginDirectSelect(at p: Vec2, px: Double) -> Gesture {
        // The selected anchor's handles come first.
        if let ref = activeShape, let path = drawing.worldShape(ref)?.path {
            // A handle folded into its anchor (a corner with no handle) can't be grabbed,
            // so the anchor underneath stays draggable.
            let handles = visibleHandles(of: path).filter { path.points[$0.index].position.distance(to: $0.position) > 1e-6 }
            if let h = handles.min(by: { $0.position.distance(to: p) < $1.position.distance(to: p) }),
               h.position.distance(to: p) <= EditorMetrics.anchorHit * px {
                // A short handle sits close to its anchor; a press nearer the anchor than
                // the handle means the anchor, so it can still be grabbed.
                let anchorDistance = path.points.map { $0.position.distance(to: p) }.min() ?? .infinity
                if h.position.distance(to: p) <= anchorDistance {
                    return .pending(.handle(ref, index: h.index, side: h.side), start: p)
                }
            }
        }
        let refs = drawing.shapeRefs(in: selection)
        if let picked = pickAnchorOrCurve(at: p, among: refs, px: px) {
            return .pending(picked, start: p)
        }
        guard let hit = hitShape(at: p, tolerance: EditorMetrics.shapeHit * px) else {
            return .pending(.empty, start: p)
        }
        let ref = ShapeRef(layer: hit.layer, shape: hit.shape)
        if addToSelection || refs.contains(ref) {
            return .pending(.shape(ref), start: p)
        }
        // A shape that was not selected shows its anchors at once, so the same press
        // can already grab one of them or drag a segment.
        selection = .shape(layer: ref.layer, shape: ref.shape)
        if let picked = pickAnchorOrCurve(at: p, among: [ref], px: px) {
            if case .curve(let r, let segment, let t, _) = picked {
                return .pending(.curve(r, segment: segment, t: t, insertsOnTap: false), start: p)
            }
            return .pending(picked, start: p)
        }
        return .pending(.shape(ref), start: p)
    }

    /// The anchor nearest `p`, else the outline segment nearest `p`, among `refs`.
    private func pickAnchorOrCurve(at p: Vec2, among refs: [ShapeRef], px: Double) -> Pending? {
        var bestAnchor: (ref: ShapeRef, index: Int, distance: Double)?
        for ref in refs {
            guard let shape = drawing.worldShape(ref) else { continue }
            for (i, point) in shape.path.points.enumerated() {
                let d = point.position.distance(to: p)
                if d <= EditorMetrics.anchorHit * px, d < (bestAnchor?.distance ?? .infinity) {
                    bestAnchor = (ref, i, d)
                }
            }
        }
        if let a = bestAnchor { return .anchor(a.ref, a.index) }

        var bestCurve: (ref: ShapeRef, segment: Int, t: Double, distance: Double)?
        for ref in refs {
            guard let shape = drawing.worldShape(ref), let near = shape.path.nearestSegment(to: p),
                  near.distance <= EditorMetrics.curveHit * px + (shape.stroke?.width ?? 0) / 2,
                  near.distance < (bestCurve?.distance ?? .infinity) else { continue }
            bestCurve = (ref, near.segment, near.t, near.distance)
        }
        guard let c = bestCurve else { return nil }
        return Pending.curve(c.ref, segment: c.segment, t: c.t, insertsOnTap: true)
    }

    /// The straight edge that closes `path` when its end anchor `i` is dragged to `p`,
    /// over the path's other end, or nil. The other end must not be moving with it.
    private func edgeClosing(_ path: BezierPath, dragging i: Int, to p: Vec2) -> (from: Vec2, to: Vec2)? {
        let last = path.points.count - 1
        guard !path.closed, last >= 1, i == 0 || i == last else { return nil }
        let other = i == 0 ? last : 0
        guard !selectedAnchors.contains(other),
              path.points[other].position.distance(to: p) <= EditorMetrics.anchorHit / gestureZoom,
              path.closedWithStraightEdge() != nil else { return nil }
        return (path.points[i].position, path.points[other].position)
    }

    // MARK: Pen

    private mutating func beginPen(at p: Vec2, px: Double) -> Gesture {
        let reach = EditorMetrics.anchorHit * px
        var activeRef: ShapeRef?
        if let pen = penPath, let shape = drawing.worldShape(ShapeRef(layer: pen.layer, shape: pen.shape)), !shape.path.points.isEmpty {
            activeRef = ShapeRef(layer: pen.layer, shape: pen.shape)
            let points = shape.path.points
            let active = pen.fromStart ? 0 : points.count - 1
            let far = pen.fromStart ? points.count - 1 : 0
            // Tapping the end again (the second tap of a double tap) finishes the path.
            if points[active].position.distance(to: p) <= reach { return .pending(.penFinish, start: p) }
            if points.count >= 3, points[far].position.distance(to: p) <= reach { return .pending(.penClose, start: p) }
        }
        if let hit = openEndpoint(near: p, reach: reach, excluding: activeRef) {
            return .pending(.penJoin(hit.ref, hit.end), start: p)
        }
        return placePenAnchor(at: p)
    }

    /// The nearest end of any open path other than `excluded`.
    private func openEndpoint(near p: Vec2, reach: Double, excluding excluded: ShapeRef?) -> (ref: ShapeRef, end: PathEnd)? {
        var best: (ref: ShapeRef, end: PathEnd, distance: Double)?
        for ref in drawing.editableShapeRefs(within: isolatedLayer, group: isolatedGroup) where ref != excluded {
            guard let shape = drawing.worldShape(ref), !shape.path.closed, !shape.path.points.isEmpty else { continue }
            for end in [PathEnd.start, .end] {
                guard let position = shape.path.endPoint(end) else { continue }
                let d = position.distance(to: p)
                if d <= reach, d < (best?.distance ?? .infinity) { best = (ref, end, d) }
            }
        }
        return best.map { (ref: $0.ref, end: $0.end) }
    }

    /// Appends a corner anchor at `p` (starting a new path if none is active). The
    /// gesture then turns a drag into a symmetric handle for it.
    private mutating func placePenAnchor(at p: Vec2) -> Gesture {
        let before = drawing
        let penBefore = penPath
        let point = PathPoint(snapped(p), in: .zero, out: .zero, mode: .corner)
        let ref: ShapeRef
        if var pen = penPath, let idx = drawing.indices(layer: pen.layer, shape: pen.shape) {
            if pen.fromStart {
                drawing.layers[idx.0].shapes[idx.1].path = drawing.layers[idx.0].shapes[idx.1].path.reversed()
                pen.fromStart = false
                penPath = pen
            }
            drawing.updateWorldPath(at: idx) { $0.points.append(point) }
            ref = ShapeRef(layer: pen.layer, shape: pen.shape)
            if pen.createdLayer { drawing.layers[idx.0].setWorldPivot(drawing.layers[idx.0].bounds.center) }
        } else {
            ref = startPenShape(with: point)
        }
        // Selecting the shape lets the style controls restyle it while it grows, but
        // must not rewrite the style the user has set.
        let saved = style
        selection = .shape(layer: ref.layer, shape: ref.shape)
        style = saved
        let count = drawing.worldShape(ref)?.path.points.count ?? 1
        return .penPlace(ref, index: count - 1, before: before, penBefore: penBefore)
    }

    private mutating func startPenShape(with point: PathPoint) -> ShapeRef {
        var shape = VectorShape(id: drawing.makeID(), path: BezierPath(points: [point], closed: false))
        shape.fill = style.fillEnabled ? style.fill : nil
        // Outlined while open so the path is visible; closing may drop the outline.
        shape.stroke = style.makeStroke()
        if let target = activeLayer, let p = drawing.layerIndex(target) {
            addToActiveLayer(&shape, layer: p)
            penPath = PenPath(layer: target, shape: shape.id, fromStart: false, createdLayer: false)
            return ShapeRef(layer: target, shape: shape.id)
        }
        let id = drawing.makeID()
        let name = drawing.uniqueLayerName("Layer \(drawing.layers.count + 1)")
        drawing.layers.append(Layer(id: id, name: name, shapes: [shape], pivot: point.position))
        penPath = PenPath(layer: id, shape: shape.id, fromStart: false, createdLayer: true)
        return ShapeRef(layer: id, shape: shape.id)
    }

    /// Ends the open path (the Done action). A path of one anchor is discarded.
    public mutating func penFinish() {
        guard let pen = penPath else { return }
        penPath = nil
        let ref = ShapeRef(layer: pen.layer, shape: pen.shape)
        guard let shape = drawing.shape(ref) else { return }
        if shape.path.points.count >= 2 {
            // A finished open path gets its mirror image now that it is whole.
            let before = drawing
            addMirrorImage(of: ref)
            commit(from: before)
            return
        }
        let before = drawing
        removeShape(ref)
        selection = .none
        commit(from: before)
    }

    private mutating func closePenPath() {
        guard let pen = penPath, let idx = drawing.indices(layer: pen.layer, shape: pen.shape),
              drawing.layers[idx.0].shapes[idx.1].path.points.count >= 3 else { return }
        let before = drawing
        drawing.layers[idx.0].shapes[idx.1].path.closed = true
        if !style.outlineEnabled, drawing.layers[idx.0].shapes[idx.1].fill != nil {
            drawing.layers[idx.0].shapes[idx.1].stroke = nil
        }
        penPath = nil
        addMirrorImage(of: ShapeRef(layer: pen.layer, shape: pen.shape))
        commit(from: before)
    }

    /// Tapping the end of an open path: continues it when the pen is idle, or joins
    /// it to the path being drawn.
    private mutating func joinOrContinuePen(_ ref: ShapeRef, _ end: PathEnd) {
        guard let other = drawing.worldShape(ref), !other.path.closed else { return }
        guard let pen = penPath else {
            penPath = PenPath(layer: ref.layer, shape: ref.shape, fromStart: end == .start, createdLayer: false)
            let saved = style
            selection = .shape(layer: ref.layer, shape: ref.shape)
            style = saved
            return
        }
        let active = ShapeRef(layer: pen.layer, shape: pen.shape)
        let before = drawing
        guard joinShapes(active, pen.fromStart ? .start : .end, ref, end) else { return }
        penPath = nil
        let saved = style
        selection = .shape(layer: active.layer, shape: active.shape)
        style = saved
        commit(from: before)
    }

    /// The segment the pen would add next, from the active end to the hovering Pencil.
    public var penPreview: CubicBezier? {
        guard let cursor = penCursor, let pen = penPath, gesture == nil,
              let points = drawing.worldShape(ShapeRef(layer: pen.layer, shape: pen.shape))?.path.points,
              let end = pen.fromStart ? points.first : points.last else { return nil }
        let control = pen.fromStart ? end.inControl : end.outControl
        return CubicBezier(end.position, control, cursor, cursor)
    }

    // MARK: Drag and tap

    private mutating func startDrag(_ pending: Pending, from start: Vec2) -> Gesture {
        switch pending {
        case .selectionBody:
            return beginMove(from: start)
        case .shape(let ref):
            guard tool == .select || tool == .directSelect else { return .idle }
            if !drawing.shapeRefs(in: selection).contains(ref) {
                if tool == .select {
                    selection = selectionIsInside(layer: ref.layer) ? tapTarget(ref) : .layer(ref.layer)
                } else {
                    selection = .shape(layer: ref.layer, shape: ref.shape)
                }
            }
            return beginMove(from: start)
        case .pivot:
            return .pivot(target: selection, before: drawing, grab: (pivot ?? start) - start, originalCustom: customPivot)
        case .anchor(let ref, let i):
            guard let shape = drawing.worldShape(ref), shape.path.points.indices.contains(i) else { return .idle }
            narrowSelection(to: ref)
            if !selectedAnchors.contains(i) { selectedAnchors = addToSelection ? selectedAnchors.union([i]) : [i] }
            return .anchors(ref, primary: i, before: drawing, grab: shape.path.points[i].position - start)
        case .handle(let ref, let index, let side):
            guard let points = drawing.worldShape(ref)?.path.points, points.indices.contains(index) else { return .idle }
            let position = side == .incoming ? points[index].inControl : points[index].outControl
            return .handle(ref, index: index, side: side, before: drawing, grab: position - start)
        case .curve(let ref, let segment, let t, _):
            narrowSelection(to: ref)
            return .segment(ref, index: segment, t: t, before: drawing, start: start)
        case .cut:
            return .idle
        case .empty:
            guard tool == .select || tool == .directSelect else { return .idle }
            marquee = Rect(from: start, to: start)
            return .marquee(start: start, additive: addToSelection,
                            baseShapes: Set(drawing.shapeRefs(in: selection)), baseAnchors: selectedAnchors)
        case .penFinish, .penClose, .penJoin:
            return .idle
        }
    }

    /// Moves the selection, or with the alternate modifier (Option) a copy of it, which
    /// stays selected. Copy and move are one undo step.
    private mutating func beginMove(from start: Vec2) -> Gesture {
        var isReference = false
        if case .reference = selection { isReference = true }
        if modifiers.contains(.alternate), !isReference {
            let original = drawing
            if duplicateInPlace(offset: .zero) { undoBase = original }
        }
        return .transform(.move, target: selection, before: drawing, start: start)
    }

    /// Makes `ref` the only selected shape, keeping the anchor selection if it already was.
    private mutating func narrowSelection(to ref: ShapeRef) {
        let narrowed = Selection.shape(layer: ref.layer, shape: ref.shape)
        if selection != narrowed { selection = narrowed }
    }

    private mutating func tap(_ pending: Pending, at p: Vec2) {
        switch tool {
        case .pencil:
            break
        case .pen:
            switch pending {
            case .penFinish: penFinish()
            case .penClose: closePenPath()
            case .penJoin(let ref, let end): joinOrContinuePen(ref, end)
            default: break
            }
        case .select:
            tapSelect(at: p)
        case .directSelect:
            switch pending {
            case .anchor(let ref, let i):
                if addToSelection, selection == .shape(layer: ref.layer, shape: ref.shape) {
                    if selectedAnchors.contains(i) { selectedAnchors.remove(i) } else { selectedAnchors.insert(i) }
                } else {
                    narrowSelection(to: ref)
                    selectedAnchors = [i]
                }
            case .curve(let ref, let segment, let t, let insertsOnTap):
                // A press that just selected the shape only selects it.
                guard insertsOnTap else { break }
                narrowSelection(to: ref)
                var inserted: Int?
                editShape(ref) { inserted = $0.path.insertPoint(segment: segment, t: t) }
                selectedAnchors = inserted.map { [$0] } ?? []
            case .shape(let ref):
                if addToSelection {
                    toggleInSelection(ref)
                } else {
                    narrowSelection(to: ref)
                }
            case .handle:
                break
            case .empty, .selectionBody, .pivot, .penFinish, .penClose, .penJoin, .cut:
                if !selectedAnchors.isEmpty {
                    selectedAnchors = []
                } else if !addToSelection {
                    selection = .none
                }
            }
        case .scissors:
            if case .cut(let ref, let segment, let t) = pending { cut(ref, segment: segment, t: t) }
        case .shape, .eraser:
            break
        }
    }

    private func transform(_ kind: TransformKind, from start: Vec2, to p: Vec2, target: Selection, before: Drawing) -> Affine2D {
        let moving = Set(before.shapeRefs(in: target))
        switch kind {
        case .move:
            var delta = p - start
            // Constrained moves follow the axis the drag leans to.
            if modifiers.contains(.constrain) { delta = abs(delta.x) >= abs(delta.y) ? Vec2(delta.x, 0) : Vec2(0, delta.y) }
            if snap.isEnabled, let frame = before.frame(of: target) {
                delta = Snapper.snapTranslation(delta, of: frame.corners + [frame.center], settings: snap,
                                                anchors: snapAnchors(excluding: moving, moving: nil), radius: snapRadius)
            }
            return .translation(delta)
        case .scale(let anchor):
            let v0 = start - anchor, v1 = snapped(p, excluding: moving) - anchor
            guard v0.lengthSquared > 1e-12 else { return .identity }
            let k = max(v1.dot(v0) / v0.lengthSquared, 0.02)
            return Affine2D.translation(anchor) * Affine2D.scale(k) * Affine2D.translation(-anchor)
        case .stretch(let anchor, let horizontal):
            let q = snapped(p, excluding: moving)
            let span = horizontal ? start.x - anchor.x : start.y - anchor.y
            guard abs(span) > 1e-9 else { return .identity }
            let k = max((horizontal ? q.x - anchor.x : q.y - anchor.y) / span, 0.02)
            let scale = horizontal ? Affine2D.scale(x: k, y: 1) : Affine2D.scale(x: 1, y: k)
            return Affine2D.translation(anchor) * scale * Affine2D.translation(-anchor)
        case .rotate(let center):
            let v0 = start - center, v1 = p - center
            guard v0.lengthSquared > 1e-12, v1.lengthSquared > 1e-12 else { return .identity }
            var angle = atan2(v1.y, v1.x) - atan2(v0.y, v0.x)
            if modifiers.contains(.constrain) { angle = ShapePrimitives.snapAngle(angle, step: .pi / 12) }
            return Affine2D.translation(center) * Affine2D.rotation(angle) * Affine2D.translation(-center)
        }
    }

    // MARK: Snapping

    /// Anchor positions snapping can target, leaving out whole shapes in `excluding`
    /// and the anchors being dragged.
    private func snapAnchors(excluding: Set<ShapeRef>, moving: (ShapeRef, Set<Int>)?) -> [Vec2] {
        guard snap.isEnabled, snap.toAnchors else { return [] }
        var out: [Vec2] = []
        for layer in drawing.layers {
            for (index, shape) in layer.shapes.enumerated() where layer.isShown(index) {
                let ref = ShapeRef(layer: layer.id, shape: shape.id)
                if excluding.contains(ref) { continue }
                for (i, point) in layer.worldShape(index).path.points.enumerated() {
                    if let moving, moving.0 == ref, moving.1.contains(i) { continue }
                    out.append(point.position)
                }
            }
        }
        return out
    }

    /// `p` snapped to anchors and the grid when snapping is on.
    func snapped(_ p: Vec2, excluding: Set<ShapeRef> = [], movingAnchors: (ShapeRef, Set<Int>)? = nil) -> Vec2 {
        guard snap.isEnabled else { return p }
        return Snapper.snap(p, settings: snap, anchors: snapAnchors(excluding: excluding, moving: movingAnchors),
                            radius: snapRadius).point
    }

    /// Handles shown in the direct-select tool: the selected anchor's own handles and the
    /// handles of its neighbours that shape the segments touching it.
    public func visibleHandles(of path: BezierPath) -> [(index: Int, side: HandleSide, position: Vec2)] {
        guard let a = selectedAnchor, path.points.indices.contains(a) else { return [] }
        let n = path.points.count
        var out: [(index: Int, side: HandleSide, position: Vec2)] = []
        if path.hasIncomingSegment(a) {
            out.append((a, .incoming, path.points[a].inControl))
            let prev = (a - 1 + n) % n
            out.append((prev, .outgoing, path.points[prev].outControl))
        }
        if path.hasOutgoingSegment(a) {
            out.append((a, .outgoing, path.points[a].outControl))
            let next = (a + 1) % n
            out.append((next, .incoming, path.points[next].inControl))
        }
        return out
    }

    // MARK: Strokes

    /// Fits a finished pencil stroke and adds it as a shape. A closed stroke becomes
    /// a filled shape. With `autoJoinSelectedLayer` on and a layer selected, a stroke that
    /// overlaps it joins that layer; otherwise it starts a new layer.
    ///
    /// `pressures` (0...1, one per point) set the outline width at each anchor when
    /// `pressureWidth` is on; otherwise the outline is uniform.
    public mutating func addStroke(_ points: [Vec2], pressures: [Double] = [], zoom: Double) {
        guard !points.isEmpty else { return }
        var path = CurveFitter.fit(points, options: .forSmoothing(smoothing, zoom: zoom))
        if pressureWidth, pressures.count == points.count {
            PressureWidth.apply(pressures, samples: points, to: &path)
        }
        addPath(path)
    }

    /// Adds a finished path (a fitted stroke or a QuickShape) in the current style as
    /// one undo step, placed as `addStroke` places strokes.
    public mutating func addPath(_ path: BezierPath) {
        guard !path.points.isEmpty else { return }
        let before = drawing
        let ref = insertNewShape(styledShape(path), joinNeedsOverlap: true)
        addMirrorImage(of: ref)
        commit(from: before)
    }

    /// A new shape with `path` in the current style. A closed path is filled; an open
    /// one, or one with fill off, is outlined so it stays visible.
    mutating func styledShape(_ path: BezierPath) -> VectorShape {
        let outline = style.makeStroke()
        var shape = VectorShape(id: drawing.makeID(), path: path)
        if path.closed {
            shape.fill = style.fillEnabled ? style.fill : nil
            shape.stroke = style.outlineEnabled || !style.fillEnabled ? outline : nil
        } else {
            shape.stroke = outline
        }
        return shape
    }

    /// Adds `shape` to the isolated layer or the active layer, or with auto-join to the
    /// selected layer (when `joinNeedsOverlap`, only if it overlaps it), or else to a new
    /// layer on top. Does not record undo.
    @discardableResult
    mutating func insertNewShape(_ shape: VectorShape, joinNeedsOverlap: Bool) -> ShapeRef {
        if let target = isolatedLayer ?? usableTargetLayer, let p = drawing.layerIndex(target) {
            var shape = shape
            addToActiveLayer(&shape, layer: p)
            return ShapeRef(layer: target, shape: shape.id)
        }
        if autoJoinSelectedLayer, let target = selectedLayerID, let p = drawing.layerIndex(target),
           !joinNeedsOverlap || drawing.layers[p].bounds.intersects(shape.bounds) {
            drawing.layers[p].insertWorldShape(shape)
            return ShapeRef(layer: target, shape: shape.id)
        }
        let id = drawing.makeID()
        let name = drawing.uniqueLayerName("Layer \(drawing.layers.count + 1)")
        drawing.layers.append(Layer(id: id, name: name, shapes: [shape], pivot: shape.bounds.center))
        return ShapeRef(layer: id, shape: shape.id)
    }

    // MARK: Shape tool

    /// Builds the shape for a drag from `start` to `p`, creating it on the first call.
    private mutating func drawShape(from start: Vec2, to p: Vec2, ref: ShapeRef?) -> ShapeRef? {
        let end = snapped(p, excluding: ref.map { [$0] } ?? [])
        guard let path = ShapePrimitives.path(shapeKind, from: start, to: end, options: shapeOptions,
                                              modifiers: modifiers, minimumSize: EditorMetrics.tapSlop / gestureZoom)
        else { return ref }
        if let ref, let idx = drawing.indices(ref) {
            drawing.setWorldPath(path, at: idx)
            // A layer made by this drag keeps its pivot in the middle; one it joined keeps its own.
            if drawing.layers[idx.0].shapes.count == 1 {
                drawing.layers[idx.0].setWorldPivot(drawing.layers[idx.0].bounds.center)
            }
            return ref
        }
        let new = insertNewShape(styledShape(path), joinNeedsOverlap: false)
        let saved = style
        selection = .shape(layer: new.layer, shape: new.shape)
        style = saved
        return new
    }

    // MARK: Eraser

    /// Deletes every editable shape within the eraser's reach of the segment `a` to `b`.
    /// Does not record undo.
    private mutating func eraseAlong(_ a: Vec2, _ b: Vec2) {
        let radius = EditorMetrics.eraserRadius / gestureZoom
        let steps = max(1, Int((a.distance(to: b) / (radius / 2)).rounded(.up)))
        let samples = (0...steps).map { Vec2.lerp(a, b, Double($0) / Double(steps)) }
        let swept = Rect(points: [a, b]).outset(by: radius)
        refreshShapeIndex(forHitTest: false)
        let doomed = shapes(meeting: swept) { $0.hitBounds.intersects(swept) && $0.containsAny(of: samples, tolerance: radius) }
        guard !doomed.isEmpty else { return }
        for ref in doomed { removeShape(ref) }
        // The rest of the stroke keeps the index: only the erased shapes left it.
        shapeIndex = shapeIndex?.removing(doomed, revision: revision)
        validateSelection()
        if let pen = penPath, drawing.indices(layer: pen.layer, shape: pen.shape) == nil { penPath = nil }
    }

    // MARK: Commands

    /// Clears `notice` once the app has shown it.
    public mutating func clearNotice() { notice = nil }

    public mutating func undo() {
        cancelGesture()
        guard let state = undoStack.undo(current: drawing) else { return }
        restore(state)
    }

    public mutating func redo() {
        cancelGesture()
        guard let state = undoStack.redo(current: drawing) else { return }
        restore(state)
    }

    /// Removes all art (reference images stay). Undoable.
    public mutating func clearArt() {
        cancelGesture()
        let before = drawing
        drawing.layers.removeAll()
        penPath = nil
        if case .reference = selection {} else { selection = .none }
        commit(from: before)
    }

    public mutating func deleteSelection() {
        cancelGesture()
        let before = drawing
        switch selection {
        case .none:
            return
        case .layer(let id):
            drawing.layers.removeAll { $0.id == id }
        case .layers(let ids):
            drawing.layers.removeAll { ids.contains($0.id) }
        case .shape(let pid, let sid):
            guard drawing.indices(layer: pid, shape: sid) != nil else { return }
            removeShape(ShapeRef(layer: pid, shape: sid))
        case .shapes(let refs):
            for ref in refs { removeShape(ref) }
        case .reference(let id):
            drawing.references.removeAll { $0.id == id }
        }
        selection = .none
        commit(from: before)
    }

    // MARK: Style

    /// The style of the first selected shape, for showing in the style controls.
    public var selectionStyle: ShapeStyle? {
        guard let first = drawing.shapeIndices(in: selection).first else { return nil }
        let shape = drawing.layers[first.0].shapes[first.1]
        var result = style
        if let fill = shape.fill { result.fill = fill }
        result.fillEnabled = shape.fill != nil
        if let stroke = shape.stroke {
            result.outline = stroke.color
            result.outlineWidth = stroke.width
            result.outlineCap = stroke.cap
            result.outlineJoin = stroke.join
            result.miterLimit = stroke.miterLimit
            result.outlineDash = stroke.dash
            result.outlineAlignment = stroke.alignment
        }
        result.outlineEnabled = shape.stroke != nil
        return result
    }

    /// `continuous` marks a change from a control that sends many (a color picker drag),
    /// so the run adds one recent color, not one per step.
    public mutating func setFill(_ color: RGBAColor, continuous: Bool = false) {
        noteRecentColor(color, source: continuous ? "fill" : nil)
        style.fill = color
        style.fillEnabled = true
        restyleSelection(key: "fill") { shape in
            guard shape.path.closed else { return }
            shape.fill = color
            shape.fillGlobal = nil
            // A gradient's first stop is its plain fill, so the two stay in step.
            if shape.gradient != nil { shape.gradient!.stops[0].color = color }
        }
    }

    public mutating func setFillEnabled(_ enabled: Bool) {
        style.fillEnabled = enabled
        let color = style.fill
        restyleSelection(key: "fillEnabled") { shape in
            guard shape.path.closed else { return }
            if enabled {
                if shape.fill == nil { shape.fill = color }
            } else if shape.stroke != nil {
                shape.fill = nil
                shape.gradient = nil
                shape.fillGlobal = nil
            }
        }
    }

    public mutating func setOutline(_ color: RGBAColor, continuous: Bool = false) {
        noteRecentColor(color, source: continuous ? "outline" : nil)
        style.outline = color
        style.outlineEnabled = true
        let template = style
        restyleSelection(key: "outline") { shape in
            if shape.stroke == nil {
                shape.stroke = template.makeStroke(color: color)
            } else {
                shape.stroke!.color = color
                shape.stroke!.global = nil
            }
        }
    }

    public mutating func setOutlineWidth(_ width: Double) {
        style.outlineWidth = width
        let template = style
        restyleSelection(key: "outlineWidth") { shape in
            if shape.stroke == nil { shape.stroke = template.makeStroke() }
            shape.stroke!.width = width
        }
    }

    public mutating func setOutlineEnabled(_ enabled: Bool) {
        style.outlineEnabled = enabled
        let outline = style.makeStroke()
        restyleSelection(key: "outlineEnabled") { shape in
            if enabled {
                if shape.stroke == nil { shape.stroke = outline }
            } else if shape.visibleFill != nil {
                // Open paths and unfilled shapes keep their outline so they stay visible.
                shape.stroke = nil
            }
        }
    }

    private mutating func noteRecentColor(_ color: RGBAColor, source: String?) {
        if let source, source == recentColorSource, !recentColors.isEmpty {
            recentColors.removeFirst()
        }
        recentColorSource = source
        recentColors.removeAll { $0 == color }
        recentColors.insert(color, at: 0)
        if recentColors.count > 8 { recentColors.removeLast(recentColors.count - 8) }
    }

    public mutating func addToPalette(_ color: RGBAColor) {
        guard !drawing.palette.contains(color) else { return }
        let before = drawing
        drawing.palette.append(color)
        commit(from: before)
    }

    public mutating func removeFromPalette(at index: Int) {
        guard drawing.palette.indices.contains(index) else { return }
        let before = drawing
        drawing.palette.remove(at: index)
        commit(from: before)
    }

    // MARK: Layers

    /// Renames a layer. Names are trimmed and kept unique; an empty name is ignored.
    public mutating func renameLayer(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.layerIndex(id) else { return }
        let before = drawing
        drawing.layers[i].name = drawing.uniqueLayerName(trimmed, excluding: id)
        commit(from: before)
    }

    public mutating func renamePresentation(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let before = drawing
        drawing.name = trimmed
        commit(from: before)
    }

    /// Selects a whole layer, as tapping it with the select tool does.
    /// Hidden and locked layers can't be selected; selecting a layer outside isolation ends it.
    public mutating func selectLayer(_ id: Int) {
        guard let i = drawing.layerIndex(id), !drawing.layers[i].isHidden, !drawing.layers[i].isLocked else { return }
        cancelGesture()
        if let isolated = isolatedLayer, isolated != id { exitIsolation() }
        isolatedGroup = nil
        selection = .layer(id)
    }

    public mutating func deleteLayer(_ id: Int) {
        guard drawing.layerIndex(id) != nil else { return }
        cancelGesture()
        selection = .layer(id)
        deleteSelection()
    }

    /// Replaces the whole drawing (for example, with a version of the file changed
    /// outside the editor). Undoable.
    public mutating func replaceDrawing(_ newDrawing: Drawing) {
        cancelGesture()
        let before = drawing
        restore(newDrawing)
        commit(from: before)
    }

    // MARK: Reference images

    @discardableResult
    public mutating func addReference(name: String, size: Vec2, center: Vec2, scale: Double) -> Int {
        let before = drawing
        let id = drawing.makeID()
        drawing.references.append(ReferenceImage(id: id, name: name, size: size, center: center, scale: scale))
        commit(from: before)
        return id
    }

    public mutating func updateReference(_ id: Int, coalescingKey: String? = nil, _ change: (inout ReferenceImage) -> Void) {
        guard let i = drawing.referenceIndex(id) else { return }
        let before = drawing
        change(&drawing.references[i])
        commit(from: before, key: coalescingKey.map { "reference-\(id)-\($0)" })
    }

    /// Selects a reference image so the select tool's handles move, scale and rotate it.
    public mutating func adjustReference(_ id: Int) {
        guard drawing.referenceIndex(id) != nil else { return }
        selection = .reference(id)
        tool = .select
    }

    // MARK: Private

    /// Applies `change` to one shape as a single undo step.
    mutating func editShape(_ ref: ShapeRef, key: String? = nil, _ change: (inout VectorShape) -> Void) {
        guard let idx = drawing.indices(ref) else { return }
        let before = drawing
        change(&drawing.layers[idx.0].shapes[idx.1])
        commit(from: before, key: key)
    }

    /// Removes a shape, and its layer if that leaves it empty. Does not record undo.
    mutating func removeShape(_ ref: ShapeRef) {
        guard let idx = drawing.indices(ref) else { return }
        drawing.layers[idx.0].shapes.remove(at: idx.1)
        if drawing.layers[idx.0].shapes.isEmpty { drawing.layers.remove(at: idx.0) }
    }

    /// Joins shape `b` onto shape `a` at the given ends, keeping `a`'s style and
    /// removing `b`. Does not record undo.
    mutating func joinShapes(_ a: ShapeRef, _ aEnd: PathEnd, _ b: ShapeRef, _ bEnd: PathEnd) -> Bool {
        guard a != b, let ai = drawing.indices(a), let shapeB = drawing.worldShape(b),
              let pathA = drawing.worldShape(a)?.path,
              let pa = pathA.endPoint(aEnd), let pb = shapeB.path.endPoint(bEnd)
        else { return false }
        // Ends that touch merge into one anchor.
        let tolerance = pa.distance(to: pb) <= 1e-6 ? Double.infinity : -1
        guard let joined = BezierPath.joined(pathA, aEnd, shapeB.path, bEnd, mergeWithin: tolerance) else { return false }
        drawing.setWorldPath(joined, at: ai)
        removeShape(b)
        return true
    }

    mutating func restyleSelection(key: String, _ change: (inout VectorShape) -> Void) {
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return }
        let before = drawing
        for (p, s) in targets { change(&drawing.layers[p].shapes[s]) }
        commit(from: before, key: "\(key)-\(selection)")
    }

    /// Records the change since `before` as an undo step.
    mutating func commit(from before: Drawing, key: String? = nil) {
        // Any other edit ends a run of color changes.
        if key == nil { recentColorSource = nil }
        // Groups stay whole: no empty groups, and each one's shapes together.
        if !drawing.groupsAreValid { drawing.repairGroups() }
        // New points get ids, and copied points fresh ones.
        drawing.assignVertexIDs()
        guard before != drawing else { return }
        undoStack.record(before, coalescingKey: key)
    }

    /// Switches to another state of the drawing. Ids are never handed out twice in a
    /// session, so the app can key cached pixels and textures by id.
    private mutating func restore(_ state: Drawing) {
        let nextID = drawing.nextID
        drawing = state
        drawing.nextID = max(state.nextID, nextID)
        validateSelection()
        if let pen = penPath, drawing.indices(layer: pen.layer, shape: pen.shape) == nil { penPath = nil }
    }

    mutating func validateSelection() {
        if !drawing.exists(selection) { selection = .none }
        let count = activeShape.flatMap { drawing.shape($0)?.path.points.count } ?? 0
        let valid = selectedAnchors.filter { $0 < count }
        if valid != selectedAnchors { selectedAnchors = valid }
    }
}
