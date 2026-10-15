import Foundation

/// QuickShape: turns a hand-drawn stroke into the clean shape it most looks like, when
/// the Pencil is held still at the end of the stroke.
///
/// An open stroke becomes a line or a circular arc; a closed one becomes an ellipse
/// (a circle when nearly round), a rectangle, a triangle, or a polygon of up to six
/// corners. Strokes that fit none of these are left alone. Tolerances are relative to
/// the stroke's size, so recognition works the same at any zoom.
public enum ShapeRecognizer {
    /// The clean path for `points` (world space, in drawing order), or nil when the
    /// stroke is too small or matches no shape.
    public static func recognize(_ points: [Vec2], zoom: Double = 1) -> BezierPath? {
        let pts = deduplicated(points)
        guard pts.count >= 3 else { return nil }
        let bounds = Rect(points: pts)
        let diagonal = bounds.maxPoint.distance(to: bounds.minPoint)
        // Too small to mean a shape: under 12 screen points across.
        guard diagonal * zoom >= 12 else { return nil }
        let length = polylineLength(pts, closed: false)
        let gap = pts[0].distance(to: pts[pts.count - 1])
        if gap < 0.25 * diagonal, length > 1.5 * diagonal {
            return closedShape(pts, bounds: bounds)
        }
        return line(pts, length: length) ?? arc(pts)
    }

    // MARK: Open strokes

    static func line(_ pts: [Vec2], length: Double) -> BezierPath? {
        let a = pts[0], b = pts[pts.count - 1]
        let chord = a.distance(to: b)
        guard chord > 1e-9, length <= chord * 1.15 else { return nil }
        let deviation = pts.map { $0.distance(toSegment: a, b) }.max() ?? 0
        guard deviation <= chord * 0.06 else { return nil }
        return ShapePrimitives.line(a, b)
    }

    /// A circular arc through the stroke's ends and its middle (by length).
    static func arc(_ pts: [Vec2]) -> BezierPath? {
        let a = pts[0], b = pts[pts.count - 1]
        let m = pointAtFraction(pts, 0.5)
        guard let fit = circle(through: a, m, b), fit.radius.isFinite else { return nil }
        let center = fit.center, radius = fit.radius
        let worst = pts.map { abs($0.distance(to: center) - radius) }.max() ?? 0
        guard worst <= radius * 0.12 else { return nil }
        let a0 = angle(a - center)
        let sweep = signedAngle(from: a0, to: angle(m - center)) + signedAngle(from: angle(m - center), to: angle(b - center))
        guard abs(sweep) > 0.05, abs(sweep) < 1.9 * .pi else { return nil }
        return arcPath(center: center, radius: radius, start: a0, sweep: sweep)
    }

    /// An open arc as cubic segments of at most 90 degrees each.
    public static func arcPath(center: Vec2, radius: Double, start: Double, sweep: Double) -> BezierPath {
        let count = max(1, Int((abs(sweep) / (.pi / 2)).rounded(.up)))
        let step = sweep / Double(count)
        let handle = 4.0 / 3.0 * tan(step / 4) * radius
        var points: [PathPoint] = []
        for i in 0...count {
            let t = start + step * Double(i)
            let position = center + ShapePrimitives.direction(t) * radius
            // The tangent in the direction of travel.
            let tangent = Vec2(-sin(t), cos(t))
            var p = PathPoint(position, in: .zero, out: .zero, mode: .smooth)
            if i > 0 { p.inHandle = tangent * -handle }
            if i < count { p.outHandle = tangent * handle }
            if i == 0 || i == count { p.mode = .corner }
            points.append(p)
        }
        return BezierPath(points: points, closed: false)
    }

    // MARK: Closed strokes

    static func closedShape(_ pts: [Vec2], bounds: Rect) -> BezierPath? {
        let size = max(bounds.width, bounds.height)
        let corners = closedCorners(pts, tolerance: size * 0.08)
        // Clear corners win: a round stroke simplifies to five or more points, never to
        // three or to four right angles.
        if corners.count == 3 { return polygon(corners) }
        if corners.count == 4, let rect = rectangle(corners) { return rect }
        if let ellipse = ellipse(resampled(pts, count: 96)) { return ellipse }
        return (4...6).contains(corners.count) ? polygon(corners) : nil
    }

    /// An ellipse with the same area moments as the stroke's outline (exact for a true
    /// ellipse, however the stroke was sampled), accepted when the stroke stays close to
    /// it all the way round.
    static func ellipse(_ ring: [Vec2]) -> BezierPath? {
        guard let m = areaMoments(ring) else { return nil }
        let c = m.centroid, sxx = m.xx, syy = m.yy, sxy = m.xy
        let mean = (sxx + syy) / 2
        let spread = (((sxx - syy) / 2) * ((sxx - syy) / 2) + sxy * sxy).squareRoot()
        let l1 = mean + spread, l2 = max(mean - spread, 0)
        // A filled ellipse has second moments r^2 / 4 along each axis.
        var rx = 2 * l1.squareRoot(), ry = 2 * l2.squareRoot()
        guard ry > rx * 0.08 else { return nil }
        let n = Double(ring.count)
        var theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let toLocal = Affine2D.rotation(-theta) * Affine2D.translation(-c)
        var sum = 0.0
        for p in ring {
            let q = toLocal.apply(p)
            let r = (q.x * q.x / (rx * rx) + q.y * q.y / (ry * ry)).squareRoot()
            sum += (r - 1) * (r - 1)
        }
        guard (sum / n).squareRoot() <= 0.09 else { return nil }
        // Nearly round becomes a circle; nearly level becomes axis-aligned.
        if ry / rx > 0.92 {
            rx = (rx + ry) / 2
            ry = rx
            theta = 0
        }
        let level = ShapePrimitives.snapAngle(theta, step: .pi / 2)
        if abs(theta - level) < 8 * .pi / 180 {
            if abs(level.truncatingRemainder(dividingBy: .pi)) > 1e-9 { swap(&rx, &ry) }
            theta = 0
        }
        var path = ShapePrimitives.ellipse(Rect(minPoint: Vec2(-rx, -ry), maxPoint: Vec2(rx, ry)))
        path.apply(Affine2D.translation(c) * Affine2D.rotation(theta))
        return path
    }

    /// A rectangle when the four corners are all close to right angles: the best-fit
    /// orientation, then the corners' bounds in that frame.
    static func rectangle(_ corners: [Vec2]) -> BezierPath? {
        for i in 0..<4 {
            let a = corners[(i + 3) % 4] - corners[i], b = corners[(i + 1) % 4] - corners[i]
            guard a.length > 1e-9, b.length > 1e-9 else { return nil }
            let cosine = a.dot(b) / (a.length * b.length)
            guard abs(cosine) < sin(20 * .pi / 180) else { return nil }
        }
        // Average edge direction modulo 90 degrees (angles times four, averaged as vectors).
        var sum = Vec2.zero
        for i in 0..<4 {
            let e = corners[(i + 1) % 4] - corners[i]
            sum += ShapePrimitives.direction(4 * angle(e)) * e.length
        }
        var theta = angle(sum) / 4
        if abs(theta - ShapePrimitives.snapAngle(theta, step: .pi / 2)) < 6 * .pi / 180 { theta = 0 }
        let toLocal = Affine2D.rotation(-theta)
        var path = ShapePrimitives.rectangle(Rect(points: corners.map(toLocal.apply)))
        path.apply(Affine2D.rotation(theta))
        return path
    }

    static func polygon(_ corners: [Vec2]) -> BezierPath {
        BezierPath(points: corners.map { PathPoint($0, in: .zero, out: .zero, mode: .corner) }, closed: true)
    }

    /// Corners of the stroke treated as a closed loop (Douglas-Peucker), starting from
    /// the point farthest from the first so the start of the stroke is not a fake corner.
    static func closedCorners(_ pts: [Vec2], tolerance: Double) -> [Vec2] {
        let far = pts.indices.max { pts[$0].distance(to: pts[0]) < pts[$1].distance(to: pts[0]) } ?? 0
        guard far > 0 else { return [] }
        let first = simplify(Array(pts[0...far]), tolerance: tolerance)
        let second = simplify(Array(pts[far...]) + [pts[0]], tolerance: tolerance)
        var corners = Array(first.dropLast()) + Array(second.dropLast())
        // The stroke's start is a corner only if the turn there is real.
        while corners.count > 3 {
            let n = corners.count
            guard let i = corners.indices.first(where: { i in
                corners[i].distance(toSegment: corners[(i + n - 1) % n], corners[(i + 1) % n]) < tolerance
            }) else { break }
            corners.remove(at: i)
        }
        return corners
    }

    /// Douglas-Peucker simplification of an open polyline, keeping both ends.
    static func simplify(_ pts: [Vec2], tolerance: Double) -> [Vec2] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let range = stack.popLast() {
            let (lo, hi) = range
            guard hi > lo + 1 else { continue }
            var worst = 0.0, index = lo
            for i in (lo + 1)..<hi {
                let d = pts[i].distance(toSegment: pts[lo], pts[hi])
                if d > worst { worst = d; index = i }
            }
            if worst > tolerance {
                keep[index] = true
                stack.append((lo, index))
                stack.append((index, hi))
            }
        }
        return pts.indices.filter { keep[$0] }.map { pts[$0] }
    }

    // MARK: Helpers

    static func deduplicated(_ points: [Vec2]) -> [Vec2] {
        var out: [Vec2] = []
        for p in points where out.last.map({ $0.distance(to: p) > 1e-9 }) ?? true { out.append(p) }
        return out
    }

    static func polylineLength(_ pts: [Vec2], closed: Bool) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1..<pts.count { total += pts[i - 1].distance(to: pts[i]) }
        if closed { total += pts[pts.count - 1].distance(to: pts[0]) }
        return total
    }

    /// The point `fraction` of the way along the polyline.
    static func pointAtFraction(_ pts: [Vec2], _ fraction: Double) -> Vec2 {
        var remaining = polylineLength(pts, closed: false) * fraction
        for i in 1..<pts.count {
            let d = pts[i - 1].distance(to: pts[i])
            if d >= remaining, d > 0 { return Vec2.lerp(pts[i - 1], pts[i], remaining / d) }
            remaining -= d
        }
        return pts[pts.count - 1]
    }

    /// `count` points evenly spaced along the stroke closed into a loop.
    static func resampled(_ pts: [Vec2], count: Int) -> [Vec2] {
        let loop = pts + [pts[0]]
        let total = polylineLength(loop, closed: false)
        guard total > 0 else { return pts }
        return (0..<count).map { pointAtFraction(loop, Double($0) / Double(count)) }
    }

    /// Centroid and central second moments (per unit area) of the region a closed
    /// polygon encloses, from Green's theorem. Nil for a polygon with no area.
    static func areaMoments(_ poly: [Vec2]) -> (centroid: Vec2, xx: Double, yy: Double, xy: Double)? {
        var area = 0.0, cx = 0.0, cy = 0.0, ixx = 0.0, iyy = 0.0, ixy = 0.0
        for i in poly.indices {
            let p = poly[i], q = poly[(i + 1) % poly.count]
            let cross = p.cross(q)
            area += cross
            cx += (p.x + q.x) * cross
            cy += (p.y + q.y) * cross
            ixx += (p.x * p.x + p.x * q.x + q.x * q.x) * cross
            iyy += (p.y * p.y + p.y * q.y + q.y * q.y) * cross
            ixy += (p.x * q.y + 2 * p.x * p.y + 2 * q.x * q.y + q.x * p.y) * cross
        }
        area /= 2
        guard abs(area) > 1e-9 else { return nil }
        let centroid = Vec2(cx / (6 * area), cy / (6 * area))
        return (centroid,
                ixx / (12 * area) - centroid.x * centroid.x,
                iyy / (12 * area) - centroid.y * centroid.y,
                ixy / (24 * area) - centroid.x * centroid.y)
    }

    static func circle(through a: Vec2, _ b: Vec2, _ c: Vec2) -> (center: Vec2, radius: Double)? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-9 else { return nil }
        let a2 = a.lengthSquared, b2 = b.lengthSquared, c2 = c.lengthSquared
        let center = Vec2((a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
                          (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
        return (center, center.distance(to: a))
    }

    static func angle(_ v: Vec2) -> Double { atan2(v.y, v.x) }

    /// The turn from angle `a` to angle `b`, in -pi...pi.
    static func signedAngle(from a: Double, to b: Double) -> Double {
        var d = (b - a).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }
}
