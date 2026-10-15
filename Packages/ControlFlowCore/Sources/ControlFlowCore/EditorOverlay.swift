import Foundation

/// Builds the editing overlay (selection frame, transform handles, anchors and
/// Bézier handles) as capsule vertices. Line widths and dot sizes are in screen points
/// (screen-space capsules, which the shader scales with the zoom), so the overlay
/// looks the same at any zoom.
public enum EditorOverlay {
    public static let accent = RGBAColor(r: 0.18, g: 0.49, b: 0.96)
    public static let handleFill = RGBAColor.white
    /// The eraser's ring and the outline of what it would delete.
    public static let eraserColor = RGBAColor(r: 0.9, g: 0.25, b: 0.2)
    public static let symmetryColor = RGBAColor(r: 0.85, g: 0.35, b: 0.75, a: 0.8)
    /// The viewport's border.
    public static let viewportBorderColor = RGBAColor(r: 0.5, g: 0.5, b: 0.54, a: 0.9)

    /// The outline view's wireframe on a light or dark canvas, and the dimmed wireframe of
    /// art outside isolation or the ghost focus. Opaque, since overlapping capsules
    /// would double-blend a translucent line at every joint.
    public static func wireColors(darkMode: Bool) -> (normal: RGBAColor, dimmed: RGBAColor) {
        darkMode
            ? (RGBAColor(r: 0.88, g: 0.88, b: 0.9), RGBAColor(r: 0.34, g: 0.34, b: 0.37))
            : (RGBAColor(r: 0.16, g: 0.16, b: 0.18), RGBAColor(r: 0.74, g: 0.74, b: 0.76))
    }

    /// The whole overlay as one array, in drawing order. The renderer keeps the costly
    /// layers between frames with `layers(for:zoom:viewRect:darkMode:cache:)` instead.
    public static func vertices(for editor: DrawingEditor, zoom: Double, viewRect: Rect? = nil,
                                darkMode: Bool = false) -> [Float] {
        var cache = OverlayCache()
        let layers = layers(for: editor, zoom: zoom, viewRect: viewRect, darkMode: darkMode, cache: &cache)
        return layers.wireframe + layers.guides + layers.selection + layers.top
    }

    /// The overlay in its four layers. `wireframe` and `selection` come from `cache` when
    /// nothing they show changed since it last built them (see `OverlayCache`); the
    /// other two are built on every call.
    ///
    /// `viewRect` (world space) bounds lines that run across the whole view, such as the
    /// symmetry axis.
    public static func layers(for editor: DrawingEditor, zoom: Double, viewRect: Rect? = nil, darkMode: Bool = false,
                              cache: inout OverlayCache) -> OverlayLayers {
        var layers = OverlayLayers()
        let px = 1 / max(zoom, 1e-9)
        let shown = editor.drawing
        // The kept layers depend on the zoom only through flattening and dash lengths, so
        // they are built for the zoom bucket and kept while a pinch stays inside it.
        let bucket = zoomBucket(zoom)

        // Outline view: every shown shape as a thin line, dimmed outside isolation and the
        // ghost focus.
        if editor.outlineView {
            let focus = editor.ghostFocus
            let key = OverlayCache.WireframeKey(revision: editor.revision, bucket: bucket, isolatedLayer: editor.isolatedLayer,
                                                isolatedGroup: editor.isolatedGroup, ghostFocus: focus, darkMode: darkMode)
            if cache.wireframeKey == key {
                layers.wireframe = cache.wireframe
            } else {
                var b = Builder(editor: editor, drawing: shown, px: 1 / bucket)
                b.wireframe(of: shown, focus: focus, darkMode: darkMode)
                layers.wireframe = b.out
                cache.wireframeKey = key
                cache.wireframe = b.out
                cache.generation &+= 1
            }
        } else if cache.wireframeKey != nil || !cache.wireframe.isEmpty {
            cache.wireframeKey = nil
            cache.wireframe = []
            cache.generation &+= 1
        }

        var guides = Builder(editor: editor, drawing: shown, px: px)
        guides.guides(viewRect: viewRect, zoom: zoom)
        layers.guides = guides.out

        // The selection's outlines and anchors, which can be every shape in the drawing.
        let key = OverlayCache.SelectionKey(revision: editor.revision, bucket: bucket, tool: editor.tool,
                                            selection: editor.selection, selectedAnchors: editor.selectedAnchors)
        if cache.selectionKey == key {
            layers.selection = cache.selection
        } else {
            var b = Builder(editor: editor, drawing: editor.drawing, px: 1 / bucket)
            b.selection()
            layers.selection = b.out
            cache.selectionKey = key
            cache.selection = b.out
            cache.generation &+= 1
        }

        var top = Builder(editor: editor, drawing: editor.drawing, px: px)
        top.top()
        layers.top = top.out
        return layers
    }

    /// The zoom rounded up to a power of two (as the art's tessellation is): one point at
    /// the bucket is at most one point on screen, so a layer flattened for the bucket is
    /// never coarser than one flattened for the exact zoom, and at most 2x finer.
    static func zoomBucket(_ zoom: Double) -> Double {
        pow(2, ceil(log2(max(zoom, 1.0 / 64))))
    }
}

/// The editing overlay as capsule vertices, in four layers drawn in this order.
public struct OverlayLayers: Sendable {
    /// The outline view's wireframe of every shown shape. Kept between frames.
    public var wireframe: [Float] = []
    /// The viewport's border, symmetry axis, hover feedback and a layer's pivot.
    public var guides: [Float] = []
    /// The selection's outlines, and in direct select its anchors and handles. Kept
    /// between frames.
    public var selection: [Float] = []
    /// The select tool's frame and handles, the pen path and the marquee.
    public var top: [Float] = []

    public init() {}
}

/// The overlay layers that can cost as much as tessellating the whole drawing, kept
/// between frames: the outline view's wireframe and the selection's outlines and
/// anchors. Each is rebuilt only when the drawing (its `revision`), the zoom bucket
/// (`EditorOverlay.zoomBucket`) or the editor state it shows changed, so hovering, the
/// marquee, the select tool's handles and a pinch within a bucket don't rebuild them.
public struct OverlayCache: Sendable {
    struct WireframeKey: Equatable, Sendable {
        var revision: Int
        var bucket: Double
        var isolatedLayer: Int?
        var isolatedGroup: Int?
        var ghostFocus: Set<Int>?
        var darkMode: Bool
    }

    struct SelectionKey: Equatable, Sendable {
        var revision: Int
        var bucket: Double
        var tool: Tool
        var selection: Selection
        var selectedAnchors: Set<Int>
    }

    var wireframeKey: WireframeKey?
    var wireframe: [Float] = []
    var selectionKey: SelectionKey?
    var selection: [Float] = []
    /// Changes whenever `wireframe` or `selection` is rebuilt, so a renderer that keeps
    /// them in a GPU buffer knows when to upload them again.
    public internal(set) var generation = 0

    public init() {}
}

/// Appends one layer's capsules. Widths and dot sizes are in screen points and written as
/// screen-space capsules; `px` is one point in world units, for flattening tolerances,
/// dash lengths and offsets. The kept layers use the zoom bucket's `px`, which is never
/// larger than the exact zoom's.
private struct Builder {
    typealias Overlay = EditorOverlay
    let editor: DrawingEditor
    let drawing: Drawing
    let px: Double
    var out: [Float] = []

    var accent: RGBAColor { Overlay.accent }

    mutating func line(_ a: Vec2, _ b: Vec2, width: Double = 1.5, color: RGBAColor = Overlay.accent) {
        CapsuleTessellator.append(points: [a, b], width: width, color: color, screenSpace: true, to: &out)
    }
    mutating func dot(_ p: Vec2, radius: Double, color: RGBAColor) {
        CapsuleTessellator.append(points: [p], width: radius * 2, color: color, screenSpace: true, to: &out)
    }
    mutating func ringDot(_ p: Vec2, radius: Double, ring: Double = 1.5) {
        dot(p, radius: radius, color: accent)
        dot(p, radius: radius - ring, color: Overlay.handleFill)
    }

    // Draws one shape's outline, handles and anchors (the anchor state comes from the editor).
    // `active` is the one shape whose anchors can be selected.
    mutating func drawAnchors(of ref: ShapeRef, showHandles: Bool, active: ShapeRef?) {
        guard let shape = drawing.shape(ref) else { return }
        let path = shape.path
        // Highlight the path itself, with edges that have no outline dashed.
        if path.hasUnstrokedSegments {
            for i in 0..<path.segmentCount {
                var poly = [path.points[i].position]
                path.segment(i).flatten(tolerance: 0.5 * px, into: &poly)
                let pieces = path.points[i].stroked ? nil
                    : Stroker.dashes(points: poly, radii: poly.map { _ in 0 }, pattern: [4 * px, 4 * px], offset: 0)
                for piece in pieces?.map({ $0.points }) ?? [poly] {
                    CapsuleTessellator.append(points: piece, width: 1.5, color: accent, screenSpace: true, to: &out)
                }
            }
        } else {
            let poly = path.flattened(tolerance: 0.5 * px)
            let outline = path.closed && poly.count > 2 ? poly + [poly[0]] : poly
            CapsuleTessellator.append(points: outline, width: 1.5, color: accent, screenSpace: true, to: &out)
        }

        if showHandles {
            for h in editor.visibleHandles(of: path) where path.points[h.index].position.distance(to: h.position) > 1e-6 {
                line(path.points[h.index].position, h.position, width: 1)
                dot(h.position, radius: 4, color: accent)
            }
        }
        let selected = active == ref ? editor.selectedAnchors : []
        for (i, point) in path.points.enumerated() {
            if selected.contains(i) {
                dot(point.position, radius: 6.5, color: accent)
            } else if point.mode == .corner {
                // Corner points get a smaller, heavier ring.
                ringDot(point.position, radius: 4.5, ring: 2.5)
            } else {
                ringDot(point.position, radius: 5)
            }
        }
    }

    // Hover: what a touch would hit, the brush size, the eraser's reach, the cut point.
    mutating func outline(of ref: ShapeRef, color: RGBAColor) {
        guard let path = drawing.shape(ref)?.path else { return }
        let poly = path.flattened(tolerance: 0.5 * px)
        CapsuleTessellator.append(points: path.closed && poly.count > 2 ? poly + [poly[0]] : poly,
                                  width: 2, color: color, screenSpace: true, to: &out)
    }
    mutating func ring(_ center: Vec2, radius: Double, color: RGBAColor) {
        let steps = 48
        var points: [Vec2] = []
        for i in 0...steps {
            let angle = 2 * Double.pi * Double(i) / Double(steps)
            points.append(center + Vec2(cos(angle), sin(angle)) * radius)
        }
        CapsuleTessellator.append(points: points, width: 1.5, color: color, screenSpace: true, to: &out)
    }
    mutating func dashedLine(_ a: Vec2, _ b: Vec2, dash: Double, width: Double, color: RGBAColor) {
        let d = b - a, len = d.length
        guard len > 1e-9 else { return }
        var s = 0.0
        while s < len {
            line(a + d * (s / len), a + d * (min(s + dash, len) / len), width: width, color: color)
            s += dash * 2
        }
    }

    /// The outline view's wireframe of `art`.
    mutating func wireframe(of art: Drawing, focus: Set<Int>?, darkMode: Bool) {
        let colors = Overlay.wireColors(darkMode: darkMode)
        for layer in art.layers {
            let away = editor.isolatedLayer.map { $0 != layer.id } ?? false
            for (i, shape) in layer.shapes.enumerated() where layer.isShown(i) {
                let outsideGroup = !away && editor.isolatedGroup.map { $0 != shape.group } ?? false
                let dimmed = away || outsideGroup || (focus.map { !$0.contains(shape.id) } ?? false)
                let poly = shape.path.flattened(tolerance: 0.5 * px)
                guard !poly.isEmpty else { continue }
                CapsuleTessellator.append(points: shape.path.closed && poly.count > 2 ? poly + [poly[0]] : poly,
                                          width: 1, color: dimmed ? colors.dimmed : colors.normal, screenSpace: true,
                                          to: &out)
            }
        }
    }

    /// The viewport's border, symmetry, hover feedback and a layer's pivot.
    mutating func guides(viewRect: Rect?, zoom: Double) {
        let c = drawing.viewport.bounds.corners
        CapsuleTessellator.append(points: c + [c[0]], width: 1, color: Overlay.viewportBorderColor, screenSpace: true,
                                  to: &out)

        // The symmetry axis, and what symmetry will add for a shape or pen path in progress.
        if editor.symmetry.isEnabled {
            let axis = editor.symmetry.axis
            let view = viewRect ?? Rect(points: drawing.layers.map(\.bounds).flatMap { $0.isNull ? [] : $0.corners })
            let pad = 40 * px
            let top = (view.isNull ? -1000 : view.minPoint.y) - pad, bottom = (view.isNull ? 1000 : view.maxPoint.y) + pad
            // Dashed, so it reads as a guide rather than art.
            let dash = 12 * px
            var y = top
            while y < bottom {
                line(Vec2(axis, y), Vec2(axis, min(y + dash, bottom)), width: 1.5, color: Overlay.symmetryColor)
                y += dash * 2
            }
            for path in editor.mirrorPreview {
                let poly = path.flattened(tolerance: 0.5 * px)
                CapsuleTessellator.append(points: path.closed && poly.count > 2 ? poly + [poly[0]] : poly,
                                          width: 1.5, color: Overlay.symmetryColor, screenSpace: true, to: &out)
            }
        }

        // The scissors find the target and the cut point in one search.
        let cut = editor.tool == .scissors ? editor.hoverCut : nil
        let target = editor.tool == .scissors ? cut?.ref : editor.hoverTarget
        if let target, editor.tool == .eraser || !drawing.shapeRefs(in: editor.selection).contains(target) {
            outline(of: target, color: editor.tool == .eraser ? Overlay.eraserColor : accent)
        }
        if let hover = editor.hoverPoint {
            switch editor.tool {
            case .pencil:
                if editor.style.outlineEnabled || !editor.style.fillEnabled {
                    ring(hover, radius: max(editor.style.outlineWidth / 2, 1.5 * px), color: editor.style.outline)
                }
            case .eraser:
                ring(hover, radius: EditorMetrics.eraserRadius * px, color: Overlay.eraserColor)
            case .scissors:
                if let point = cut?.point { ringDot(point, radius: 6) }
            case .pen, .select, .directSelect, .shape:
                break
            }
        }

        // A selected layer's pivot shows in every tool (the select tool draws its own, draggable).
        if editor.tool != .select, case .layer(let id) = editor.selection, let layer = drawing.layer(id), !layer.shapes.isEmpty {
            line(layer.pivot - Vec2(8 * px, 0), layer.pivot + Vec2(8 * px, 0), width: 1.5)
            line(layer.pivot - Vec2(0, 8 * px), layer.pivot + Vec2(0, 8 * px), width: 1.5)
            ringDot(layer.pivot, radius: 3.5)
        }
    }

    /// The selection's outlines (scissors) or outlines, anchors and handles (direct select).
    mutating func selection() {
        switch editor.tool {
        case .scissors:
            for ref in drawing.shapeRefs(in: editor.selection) { outline(of: ref, color: accent) }
        case .directSelect:
            let refs = drawing.shapeRefs(in: editor.selection)
            let active = refs.count == 1 ? refs[0] : nil
            for ref in refs { drawAnchors(of: ref, showHandles: true, active: active) }
        case .pencil, .shape, .eraser, .pen, .select:
            break
        }
    }

    /// The pen path, the select tool's frame and handles, and the marquee.
    mutating func top() {
        switch editor.tool {
        case .pen:
            if let pen = editor.penPath {
                let ref = ShapeRef(layer: pen.layer, shape: pen.shape)
                drawAnchors(of: ref, showHandles: false, active: editor.activeShape)
                if let path = drawing.shape(ref)?.path, let last = pen.fromStart ? path.points.first : path.points.last {
                    // Handles of the point just placed, so the pull is visible.
                    if last.inHandle != .zero { line(last.position, last.inControl, width: 1); dot(last.inControl, radius: 4, color: accent) }
                    if last.outHandle != .zero { line(last.position, last.outControl, width: 1); dot(last.outControl, radius: 4, color: accent) }
                    // A ring on the first point shows that a tap there closes the path.
                    if path.points.count >= 3, let cursor = editor.penCursor {
                        let far = pen.fromStart ? path.points[path.points.count - 1] : path.points[0]
                        if far.position.distance(to: cursor) <= EditorMetrics.anchorHit * px {
                            ringDot(far.position, radius: 9)
                        }
                    }
                }
                if let preview = editor.penPreview {
                    var rubber = [preview.p0]
                    preview.flatten(tolerance: 0.5 * px, into: &rubber)
                    CapsuleTessellator.append(points: rubber, width: 1, color: accent, screenSpace: true, to: &out)
                }
            }

        case .select:
            guard let frame = drawing.frame(of: editor.selection) else { break }
            var isReference = false
            if case .reference = editor.selection { isReference = true }
            let c = frame.corners
            for i in 0..<4 { line(c[i], c[(i + 1) % 4], width: 1.5) }
            let rotate = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset * px)
            line(frame.topCenter, rotate)
            ringDot(rotate, radius: 6.5)
            for corner in c { ringDot(corner, radius: 6.5) }
            if !isReference {
                for mid in frame.edgeMidpoints { ringDot(mid, radius: 5) }
                if let pivot = editor.pivot {
                    // A crosshair in a ring, so it reads differently from the handles.
                    line(pivot - Vec2(10 * px, 0), pivot + Vec2(10 * px, 0), width: 1.5)
                    line(pivot - Vec2(0, 10 * px), pivot + Vec2(0, 10 * px), width: 1.5)
                    ringDot(pivot, radius: 4.5)
                }
            }

        case .directSelect:
            // An end anchor dragged over the other end: the edge that will close the shape,
            // and a ring on the end it closes to.
            if let edge = editor.closingEdge {
                line(edge.from, edge.to, width: 1.5)
                ringDot(edge.to, radius: 9)
            }

        case .pencil, .shape, .eraser, .scissors:
            break
        }

        if let marquee = editor.marquee {
            let c = marquee.corners
            for i in 0..<4 { line(c[i], c[(i + 1) % 4], width: 1) }
        }
    }
}
