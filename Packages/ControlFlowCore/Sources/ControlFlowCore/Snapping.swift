import Foundation

/// What anchor and transform drags snap to.
public struct SnapSettings: Hashable, Sendable {
    public var isEnabled: Bool
    public var toAnchors: Bool
    public var toGrid: Bool
    /// Grid spacing in world points.
    public var gridSize: Double

    public init(isEnabled: Bool = false, toAnchors: Bool = true, toGrid: Bool = true, gridSize: Double = 10) {
        self.isEnabled = isEnabled
        self.toAnchors = toAnchors
        self.toGrid = toGrid
        self.gridSize = gridSize
    }
}

/// The outcome of snapping one point: where it ended up and which axes moved.
public struct SnapResult: Hashable, Sendable {
    public var point: Vec2
    public var snappedX: Bool
    public var snappedY: Bool
}

/// Snapping to anchors and a grid. `radius` is in world points: the editor passes
/// a fixed number of screen points divided by the zoom.
public enum Snapper {
    /// An anchor within `radius` wins (both axes). Otherwise each axis snaps to the
    /// grid line within `radius`, independently.
    public static func snap(_ p: Vec2, settings: SnapSettings, anchors: [Vec2], radius: Double) -> SnapResult {
        guard settings.isEnabled else { return SnapResult(point: p, snappedX: false, snappedY: false) }
        if settings.toAnchors {
            var best: Vec2?
            var bestDistance = radius
            for a in anchors {
                let d = a.distance(to: p)
                if d <= bestDistance { best = a; bestDistance = d }
            }
            if let best { return SnapResult(point: best, snappedX: true, snappedY: true) }
        }
        var result = SnapResult(point: p, snappedX: false, snappedY: false)
        if settings.toGrid, settings.gridSize > 1e-9 {
            let gx = (p.x / settings.gridSize).rounded() * settings.gridSize
            let gy = (p.y / settings.gridSize).rounded() * settings.gridSize
            if abs(gx - p.x) <= radius { result.point.x = gx; result.snappedX = true }
            if abs(gy - p.y) <= radius { result.point.y = gy; result.snappedY = true }
        }
        return result
    }

    /// Adjusts a drag `delta` so that one of `points` (moved by `delta`) lands on a
    /// snap target. Each axis takes the smallest adjustment among the points.
    public static func snapTranslation(_ delta: Vec2, of points: [Vec2], settings: SnapSettings,
                                       anchors: [Vec2], radius: Double) -> Vec2 {
        guard settings.isEnabled else { return delta }
        var bestX: Double?
        var bestY: Double?
        for point in points {
            let moved = point + delta
            let r = snap(moved, settings: settings, anchors: anchors, radius: radius)
            if r.snappedX {
                let d = r.point.x - moved.x
                if bestX == nil || abs(d) < abs(bestX!) { bestX = d }
            }
            if r.snappedY {
                let d = r.point.y - moved.y
                if bestY == nil || abs(d) < abs(bestY!) { bestY = d }
            }
        }
        return delta + Vec2(bestX ?? 0, bestY ?? 0)
    }
}
