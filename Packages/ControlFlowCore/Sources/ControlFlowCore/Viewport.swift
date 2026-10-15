import Foundation

/// The stage a presentation shows: a fixed rectangle in world space, `width` × `height`
/// points with its top-left at the world origin, filled with `background`. The editor
/// keeps the infinite canvas and dims the art outside it; presenting shows only what is
/// inside. It is also the area SVG and PNG export.
public struct Viewport: Hashable, Sendable, Codable {
    /// The viewport's object id, which keyframes use to change its background. 0 until
    /// `Presentation` gives it one.
    public var id = 0
    public var width: Double
    public var height: Double
    public var background: RGBAColor

    public init(width: Double = 1920, height: Double = 1080, background: RGBAColor = .white) {
        self.width = width
        self.height = height
        self.background = background
    }

    /// The smallest size a side can have, in points.
    public static let minimumSide = 1.0

    /// The aspect ratios the viewport panel offers.
    public enum Aspect: String, CaseIterable, Sendable {
        case wide = "16:9"
        case standard = "4:3"
        case square = "1:1"
        case portrait = "9:16"

        /// Width over height.
        public var ratio: Double {
            switch self {
            case .wide: 16.0 / 9
            case .standard: 4.0 / 3
            case .square: 1
            case .portrait: 9.0 / 16
            }
        }
    }

    public var bounds: Rect { Rect(minPoint: .zero, maxPoint: Vec2(width, height)) }

    public var center: Vec2 { Vec2(width / 2, height / 2) }

    /// The preset whose ratio this viewport has, or nil for a custom aspect.
    public var aspect: Aspect? {
        Aspect.allCases.first { abs(width / $0.ratio - height) < 0.5 }
    }

    /// The same viewport at `ratio` (width over height): the width stays and the height
    /// follows. The top-left stays at the origin, and no art moves.
    public func withAspect(_ ratio: Double) -> Viewport {
        guard ratio.isFinite, ratio > 0 else { return self }
        var copy = self
        copy.height = max((width / ratio).rounded(), Viewport.minimumSide)
        return copy
    }

    /// Triangles (three corners each) covering `view` minus the viewport, for the veil
    /// that dims art outside it. Empty when the view is inside the viewport.
    public func veilTriangles(covering view: Rect) -> [Vec2] {
        guard !view.isNull else { return [] }
        let inner = bounds
        // Up to four bands round the viewport: above, below, then left and right of it.
        var bands: [Rect] = []
        let top = min(inner.minPoint.y, view.maxPoint.y), bottom = max(inner.maxPoint.y, view.minPoint.y)
        if view.minPoint.y < top {
            bands.append(Rect(minPoint: view.minPoint, maxPoint: Vec2(view.maxPoint.x, top)))
        }
        if view.maxPoint.y > bottom {
            bands.append(Rect(minPoint: Vec2(view.minPoint.x, bottom), maxPoint: view.maxPoint))
        }
        let midTop = max(view.minPoint.y, inner.minPoint.y), midBottom = min(view.maxPoint.y, inner.maxPoint.y)
        if midBottom > midTop {
            let left = min(inner.minPoint.x, view.maxPoint.x), right = max(inner.maxPoint.x, view.minPoint.x)
            if view.minPoint.x < left {
                bands.append(Rect(minPoint: Vec2(view.minPoint.x, midTop), maxPoint: Vec2(left, midBottom)))
            }
            if view.maxPoint.x > right {
                bands.append(Rect(minPoint: Vec2(right, midTop), maxPoint: Vec2(view.maxPoint.x, midBottom)))
            }
        }
        return bands.flatMap { band in
            let c = band.corners
            return [c[0], c[1], c[2], c[0], c[2], c[3]]
        }
    }
}

extension Drawing {
    /// The shapes the editor shows, with their outlines.
    public var visibleArtBounds: Rect {
        var bounds = Rect.null
        for layer in layers {
            for i in layer.shapes.indices where layer.isShown(i) { bounds = bounds.union(layer.worldShape(i).bounds) }
        }
        return bounds
    }

    /// The area an export covers: the viewport.
    public func exportArea() -> Rect? {
        viewport.bounds
    }
}

/// The viewport and the view options: outline view and ghosting.
extension DrawingEditor {
    /// The shape ids the ghost view keeps at full strength: the selection's shapes and
    /// the pen's path. Nil when ghosting is off or there is nothing to keep, so
    /// everything draws as usual.
    public var ghostFocus: Set<Int>? {
        guard ghostsUnselected else { return nil }
        var ids = Set(drawing.shapeRefs(in: selection).map(\.shape))
        if let pen = penPath { ids.insert(pen.shape) }
        return ids.isEmpty ? nil : ids
    }

    /// Changes the viewport (for numeric edits); sides stay at least `minimumSide`. Edits
    /// with the same `coalescingKey` in a row are one undo step.
    public mutating func updateViewport(coalescingKey: String? = nil, _ change: (inout Viewport) -> Void) {
        var viewport = drawing.viewport
        change(&viewport)
        viewport.width = max(viewport.width, Viewport.minimumSide)
        viewport.height = max(viewport.height, Viewport.minimumSide)
        guard viewport != drawing.viewport else { return }
        cancelGesture()
        let before = drawing
        drawing.viewport = viewport
        commit(from: before, key: coalescingKey.map { "viewport-\($0)" })
    }

    /// Gives the viewport the aspect `ratio` (width over height), keeping its width.
    /// Undoable.
    public mutating func setViewportAspect(_ ratio: Double) {
        updateViewport { $0 = $0.withAspect(ratio) }
    }
}
