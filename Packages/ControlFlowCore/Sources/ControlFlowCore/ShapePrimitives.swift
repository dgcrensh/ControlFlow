import Foundation

/// What the shape tool draws.
public enum ShapeKind: String, Hashable, Sendable, CaseIterable {
    case rectangle
    case ellipse
    case polygon
    case star
    case line
}

/// Settings for the shape tool.
public struct ShapeToolOptions: Hashable, Sendable {
    /// Rounds a rectangle's corners, in world points.
    public var cornerRadius: Double
    /// A polygon's sides, or a star's points.
    public var sides: Int
    /// A star's inner radius as a fraction of its outer radius.
    public var innerRatio: Double

    public init(cornerRadius: Double = 0, sides: Int = 5, innerRatio: Double = 0.5) {
        self.cornerRadius = cornerRadius
        self.sides = sides
        self.innerRatio = innerRatio
    }
}

/// Builders for primitive shapes as ordinary editable Bézier paths, so they can be
/// point-edited like anything drawn by hand. Paths run clockwise on screen.
public enum ShapePrimitives {
    /// Handle length for a quarter circle of radius 1.
    public static let kappa = 0.552_284_749_831

    /// A rectangle, with round corners when `cornerRadius` is above zero.
    public static func rectangle(_ r: Rect, cornerRadius: Double = 0) -> BezierPath {
        let radius = min(max(cornerRadius, 0), r.width / 2, r.height / 2)
        let x0 = r.minPoint.x, y0 = r.minPoint.y, x1 = r.maxPoint.x, y1 = r.maxPoint.y
        guard radius > 1e-9 else {
            let corners = [Vec2(x0, y0), Vec2(x1, y0), Vec2(x1, y1), Vec2(x0, y1)]
            return BezierPath(points: corners.map { PathPoint($0, in: .zero, out: .zero, mode: .corner) }, closed: true)
        }
        let k = radius * kappa
        // Each corner is a quarter arc between two points; the straight edges join them.
        let points = [
            PathPoint(Vec2(x0 + radius, y0), in: Vec2(-k, 0), out: .zero, mode: .smooth),
            PathPoint(Vec2(x1 - radius, y0), in: .zero, out: Vec2(k, 0), mode: .smooth),
            PathPoint(Vec2(x1, y0 + radius), in: Vec2(0, -k), out: .zero, mode: .smooth),
            PathPoint(Vec2(x1, y1 - radius), in: .zero, out: Vec2(0, k), mode: .smooth),
            PathPoint(Vec2(x1 - radius, y1), in: Vec2(k, 0), out: .zero, mode: .smooth),
            PathPoint(Vec2(x0 + radius, y1), in: .zero, out: Vec2(-k, 0), mode: .smooth),
            PathPoint(Vec2(x0, y1 - radius), in: Vec2(0, k), out: .zero, mode: .smooth),
            PathPoint(Vec2(x0, y0 + radius), in: .zero, out: Vec2(0, -k), mode: .smooth),
        ]
        return BezierPath(points: mergingCoincident(points), closed: true)
    }

    /// An ellipse filling `r`, as four symmetric points at the top, right, bottom and left.
    public static func ellipse(_ r: Rect) -> BezierPath {
        let c = r.center, rx = r.width / 2, ry = r.height / 2
        let kx = rx * kappa, ky = ry * kappa
        return BezierPath(points: [
            PathPoint(Vec2(c.x, c.y - ry), in: Vec2(-kx, 0), out: Vec2(kx, 0), mode: .symmetric),
            PathPoint(Vec2(c.x + rx, c.y), in: Vec2(0, -ky), out: Vec2(0, ky), mode: .symmetric),
            PathPoint(Vec2(c.x, c.y + ry), in: Vec2(kx, 0), out: Vec2(-kx, 0), mode: .symmetric),
            PathPoint(Vec2(c.x - rx, c.y), in: Vec2(0, ky), out: Vec2(0, -ky), mode: .symmetric),
        ], closed: true)
    }

    /// A regular polygon with its first corner straight up from `center` when `rotation` is 0.
    public static func polygon(center: Vec2, radius: Double, sides: Int, rotation: Double = 0) -> BezierPath {
        let n = max(sides, 3)
        let corners = (0..<n).map { i in
            center + direction(-.pi / 2 + rotation + 2 * .pi * Double(i) / Double(n)) * radius
        }
        return BezierPath(points: corners.map { PathPoint($0, in: .zero, out: .zero, mode: .corner) }, closed: true)
    }

    /// A star with `points` tips, the first straight up from `center` when `rotation` is 0.
    public static func star(center: Vec2, outerRadius: Double, innerRadius: Double, points: Int,
                            rotation: Double = 0) -> BezierPath {
        let n = max(points, 3)
        let corners = (0..<(2 * n)).map { i in
            let angle = -.pi / 2 + rotation + .pi * Double(i) / Double(n)
            return center + direction(angle) * (i.isMultiple(of: 2) ? outerRadius : innerRadius)
        }
        return BezierPath(points: corners.map { PathPoint($0, in: .zero, out: .zero, mode: .corner) }, closed: true)
    }

    /// A straight open path from `a` to `b`.
    public static func line(_ a: Vec2, _ b: Vec2) -> BezierPath {
        BezierPath(points: [PathPoint(a, in: .zero, out: .zero, mode: .corner),
                            PathPoint(b, in: .zero, out: .zero, mode: .corner)])
    }

    /// The shape tool's path for a drag from `start` to `end`, or nil while the drag is
    /// shorter than `minimumSize`. Rectangles and ellipses span the drag (from its
    /// middle with `.alternate`, square with `.constrain`); polygons and stars grow from
    /// `start` with a corner toward the Pencil (rotation in 15-degree steps with
    /// `.constrain`); lines snap to 45 degrees with `.constrain`.
    public static func path(_ kind: ShapeKind, from start: Vec2, to end: Vec2, options: ShapeToolOptions,
                            modifiers: EditorModifiers = [], minimumSize: Double = 0) -> BezierPath? {
        var d = end - start
        switch kind {
        case .rectangle, .ellipse:
            if modifiers.contains(.constrain) {
                let side = max(abs(d.x), abs(d.y))
                d = Vec2(d.x < 0 ? -side : side, d.y < 0 ? -side : side)
            }
            let rect = modifiers.contains(.alternate) ? Rect(from: start - d, to: start + d) : Rect(from: start, to: start + d)
            guard rect.width > minimumSize || rect.height > minimumSize else { return nil }
            let flat = Rect(minPoint: rect.minPoint, maxPoint: Vec2(max(rect.maxPoint.x, rect.minPoint.x + 1e-3),
                                                                     max(rect.maxPoint.y, rect.minPoint.y + 1e-3)))
            return kind == .rectangle ? rectangle(flat, cornerRadius: options.cornerRadius) : ellipse(flat)
        case .polygon, .star:
            let radius = d.length
            guard radius > minimumSize else { return nil }
            var rotation = atan2(d.y, d.x) + .pi / 2
            if modifiers.contains(.constrain) { rotation = snapAngle(rotation, step: .pi / 12) }
            if kind == .polygon {
                return polygon(center: start, radius: radius, sides: options.sides, rotation: rotation)
            }
            let inner = radius * min(max(options.innerRatio, 0.05), 0.95)
            return star(center: start, outerRadius: radius, innerRadius: inner, points: options.sides, rotation: rotation)
        case .line:
            guard d.length > minimumSize else { return nil }
            if modifiers.contains(.constrain) {
                let angle = snapAngle(atan2(d.y, d.x), step: .pi / 4)
                d = direction(angle) * d.length
            }
            return line(start, start + d)
        }
    }

    /// `angle` rounded to the nearest multiple of `step`.
    public static func snapAngle(_ angle: Double, step: Double) -> Double {
        (angle / step).rounded() * step
    }

    static func direction(_ angle: Double) -> Vec2 { Vec2(cos(angle), sin(angle)) }

    /// Drops points that sit on the previous one, keeping the first's incoming handle
    /// and the second's outgoing handle, so a fully rounded side has no zero-length edge.
    static func mergingCoincident(_ points: [PathPoint]) -> [PathPoint] {
        var out: [PathPoint] = []
        for p in points {
            if let last = out.last, last.position.distance(to: p.position) < 1e-9 {
                out[out.count - 1].outHandle = p.outHandle
            } else {
                out.append(p)
            }
        }
        if out.count > 1, let first = out.first, let last = out.last, first.position.distance(to: last.position) < 1e-9 {
            out[0].inHandle = last.inHandle
            out.removeLast()
        }
        return out
    }
}
