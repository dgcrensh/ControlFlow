import Foundation

/// Turns a path's outline into triangles that together cover exactly the outlined
/// area: one quad per segment, a wedge at each corner for the join, and the caps.
/// The pieces overlap, so they are drawn as a union (the canvas marks the stencil
/// with them, then paints the marked area once), which keeps translucent outlines
/// even. Widths may differ at each point; each segment blends between its ends.
/// Segments marked unstroked get no outline; the runs between them end in caps.
///
/// Every triangle is wound counter-clockwise on a y-up plane (positive signed area),
/// so a non-zero fill of all of them is also their union.
public enum Stroker {
    /// More dashes than this on one outline draws it solid instead.
    public static let maxDashes = 5_000

    /// Triangles (three points each) for the outline of `path`. `widthScale` widens
    /// the outline (2 for an inside or outside outline, which is clipped to one side).
    /// `tolerance` is the flattening tolerance in points.
    public static func triangles(for path: BezierPath, style: StrokeStyle, widthScale: Double = 1,
                                 tolerance: Double) -> [Vec2] {
        // Bare segments are skipped: each outlined run is stroked as an open path with caps.
        let runs = path.strokedRuns().map { run in
            var flat = run.flattenedWithWidths(tolerance: tolerance)
            // The widths become radii in place, so no second array is made.
            for i in flat.widths.indices { flat.widths[i] = max(flat.widths[i], 0) * style.width * widthScale / 2 }
            return (points: flat.points, radii: flat.widths, closed: run.closed && flat.points.count > 2)
        }
        var out: [Vec2] = []
        out.reserveCapacity(runs.reduce(0) { total, run in
            total + vertexEstimate(points: run.points.count, closed: run.closed,
                                   radius: run.radii.max() ?? 0, style: style, tolerance: tolerance)
        })
        for run in runs {
            appendTriangles(points: run.points, radii: run.radii, closed: run.closed, style: style,
                            tolerance: tolerance, into: &out)
        }
        return out
    }

    /// About how many vertices stroking a polyline of `points` points makes, for reserving the
    /// output: a quad per segment, a triangle per joint (a round or miter joint at a sharp turn
    /// makes more) and both caps. Dashes add caps per dash, and grow the array past it.
    static func vertexEstimate(points n: Int, closed: Bool, radius: Double, style: StrokeStyle,
                               tolerance: Double) -> Int {
        guard n > 0 else { return 0 }
        let segments = closed ? n : n - 1, joints = closed ? n : max(n - 2, 0)
        var caps = 0
        if !closed {
            switch style.cap {
            case .butt: caps = 0
            case .square: caps = 2 * 6
            case .round: caps = 2 * 3 * arcCount(sweep: .pi, radius: radius, tolerance: tolerance)
            }
        }
        return segments * 6 + joints * 3 + caps
    }

    /// Triangles for a polyline with a half-width (radius) at each point.
    public static func appendTriangles(points: [Vec2], radii: [Double], closed: Bool, style: StrokeStyle,
                                       tolerance: Double, into out: inout [Vec2]) {
        // Repeated points are merged, keeping the wider radius. Most polylines have none, and then
        // `p` and `r` share the caller's arrays instead of copying them. Arrays of different
        // lengths take the merging path from the start, which pairs them up as before.
        var p = points, r = radii
        let firstRepeat = points.count != radii.count ? 0
            : (1..<max(points.count, 1)).first { points[$0 - 1].distance(to: points[$0]) < 1e-9 }
        if let first = firstRepeat {
            p = Array(points[..<first])
            r = Array(radii[..<first])
            for (q, w) in zip(points[first...], radii[first...]) {
                if let last = p.last, last.distance(to: q) < 1e-9 {
                    r[r.count - 1] = max(r[r.count - 1], w)
                    continue
                }
                p.append(q)
                r.append(w)
            }
        }
        var isClosed = closed
        if isClosed, p.count > 1, p[0].distance(to: p[p.count - 1]) < 1e-9 {
            p.removeLast()
            r.removeLast()
        }
        if p.count < 3 { isClosed = false }
        guard !p.isEmpty, r.contains(where: { $0 > 0 }) else { return }

        if let pattern = style.dashPattern {
            if isClosed {
                p.append(p[0])
                r.append(r[0])
            }
            if let pieces = dashes(points: p, radii: r, pattern: pattern, offset: style.dashOffset) {
                for piece in pieces {
                    stroke(piece.points, piece.radii, closed: false, style: style, tolerance: tolerance, into: &out)
                }
                return
            }
            if isClosed {
                p.removeLast()
                r.removeLast()
            }
        }
        stroke(p, r, closed: isClosed, style: style, tolerance: tolerance, into: &out)
    }

    // MARK: Dashes

    /// Cuts an open polyline into dashes. Nil when the pattern would make too many.
    static func dashes(points p: [Vec2], radii r: [Double], pattern: [Double],
                       offset: Double) -> [(points: [Vec2], radii: [Double])]? {
        var lengths = [0.0]
        for i in 1..<max(p.count, 1) { lengths.append(lengths[i - 1] + p[i - 1].distance(to: p[i])) }
        let total = lengths.last ?? 0
        let period = pattern.reduce(0, +)
        guard period > 0, total / period * Double(pattern.count / 2) <= Double(maxDashes) else { return nil }

        /// The point and radius at arc length `s`, and the segment it falls in.
        func sample(_ s: Double, from start: Int) -> (Vec2, Double, Int) {
            var i = start
            while i < p.count - 2, lengths[i + 1] < s { i += 1 }
            let len = lengths[i + 1] - lengths[i]
            let k = len > 0 ? min(max((s - lengths[i]) / len, 0), 1) : 0
            return (Vec2.lerp(p[i], p[i + 1], k), r[i] + (r[i + 1] - r[i]) * k, i)
        }

        if p.count == 1 { return [(p, r)] }
        // Where in the pattern the path starts.
        var phase = offset.truncatingRemainder(dividingBy: period)
        if phase < 0 { phase += period }
        var index = 0
        while phase >= pattern[index] {
            phase -= pattern[index]
            index = (index + 1) % pattern.count
        }
        var pieces: [(points: [Vec2], radii: [Double])] = []
        var s = 0.0
        var segment = 0
        var remaining = pattern[index] - phase
        while s <= total {
            let end = min(s + remaining, total)
            if index % 2 == 0 {
                let (a, ra, i0) = sample(s, from: segment)
                var pts = [a], rs = [ra]
                func add(_ q: Vec2, _ w: Double) {
                    if q.distance(to: pts[pts.count - 1]) < 1e-9 { return }
                    pts.append(q)
                    rs.append(w)
                }
                var j = i0 + 1
                while j < p.count, lengths[j] < end {
                    add(p[j], r[j])
                    j += 1
                }
                let (b, rb, i1) = sample(end, from: i0)
                add(b, rb)
                segment = i1
                pieces.append((pts, rs))
            }
            if s + remaining > total { break }
            s += remaining
            index = (index + 1) % pattern.count
            remaining = pattern[index]
        }
        return pieces
    }

    // MARK: Outline

    private static func stroke(_ p: [Vec2], _ r: [Double], closed: Bool, style: StrokeStyle,
                               tolerance: Double, into out: inout [Vec2]) {
        let n = p.count
        guard n > 0 else { return }
        if n == 1 || (n == 2 && p[0].distance(to: p[1]) < 1e-9) {
            dot(at: p[0], radius: r[0], cap: style.cap, tolerance: tolerance, into: &out)
            return
        }
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let a = p[i], b = p[(i + 1) % n]
            let ra = r[i], rb = r[(i + 1) % n]
            let d = (b - a).normalized
            guard d != .zero else { continue }
            let nrm = d.perpendicular
            quad(a + nrm * ra, b + nrm * rb, b - nrm * rb, a - nrm * ra, into: &out)
        }
        let joints = closed ? Array(0..<n) : Array(1..<(n - 1))
        for i in joints {
            let prev = p[(i - 1 + n) % n], here = p[i], next = p[(i + 1) % n]
            join(at: here, from: (here - prev).normalized, to: (next - here).normalized, radius: r[i],
                 style: style, tolerance: tolerance, into: &out)
        }
        if !closed {
            cap(at: p[0], direction: (p[0] - p[1]).normalized, radius: r[0], cap: style.cap,
                tolerance: tolerance, into: &out)
            cap(at: p[n - 1], direction: (p[n - 1] - p[n - 2]).normalized, radius: r[n - 1], cap: style.cap,
                tolerance: tolerance, into: &out)
        }
    }

    private static func join(at center: Vec2, from d0: Vec2, to d1: Vec2, radius: Double, style: StrokeStyle,
                             tolerance: Double, into out: inout [Vec2]) {
        guard radius > 0, d0 != .zero, d1 != .zero else { return }
        let cross = d0.cross(d1), dot = d0.dot(d1)
        if abs(cross) < 1e-9, dot > 0 { return }
        // The outer side of the turn: the side the path turns away from.
        let side: Double = cross > 0 ? -1 : 1
        let u0 = d0.perpendicular * side, u1 = d1.perpendicular * side
        let a = center + u0 * radius, b = center + u1 * radius
        switch style.join {
        case .bevel:
            triangle(center, a, b, into: &out)
        case .round:
            var sweep = atan2(u0.cross(u1), u0.dot(u1))
            if abs(cross) < 1e-9 {
                // A full reversal: go round the end the path came in through.
                let mid = rotate(u0, by: sweep / 2)
                if mid.dot(d0) < 0 { sweep = -sweep }
            }
            arc(center: center, from: u0, sweep: sweep, radius: radius, tolerance: tolerance, into: &out)
        case .miter:
            let m = (u0 + u1).normalized
            let cosHalf = m.dot(u0)
            if m == .zero || cosHalf < 1e-9 || 1 / cosHalf > style.miterLimit {
                triangle(center, a, b, into: &out)
            } else {
                let tip = center + m * (radius / cosHalf)
                triangle(center, a, tip, into: &out)
                triangle(center, tip, b, into: &out)
            }
        }
    }

    /// A cap at an end point; `direction` points out of the path.
    private static func cap(at end: Vec2, direction d: Vec2, radius: Double, cap: LineCap, tolerance: Double,
                            into out: inout [Vec2]) {
        guard radius > 0, d != .zero else { return }
        let nrm = d.perpendicular
        switch cap {
        case .butt:
            break
        case .square:
            quad(end + nrm * radius, end + nrm * radius + d * radius, end - nrm * radius + d * radius,
                 end - nrm * radius, into: &out)
        case .round:
            arc(center: end, from: nrm, sweep: d.dot(rotate(nrm, by: .pi / 2)) > 0 ? .pi : -.pi,
                radius: radius, tolerance: tolerance, into: &out)
        }
    }

    /// A lone point: a disc for round caps, a square for square caps, nothing for butt.
    private static func dot(at p: Vec2, radius: Double, cap: LineCap, tolerance: Double, into out: inout [Vec2]) {
        guard radius > 0 else { return }
        switch cap {
        case .butt:
            break
        case .square:
            quad(p + Vec2(-radius, -radius), p + Vec2(radius, -radius), p + Vec2(radius, radius),
                 p + Vec2(-radius, radius), into: &out)
        case .round:
            arc(center: p, from: Vec2(1, 0), sweep: 2 * .pi, radius: radius, tolerance: tolerance, into: &out)
        }
    }

    /// A fan from `center` along the arc that starts at direction `u` and turns `sweep` radians.
    private static func arc(center: Vec2, from u: Vec2, sweep: Double, radius: Double, tolerance: Double,
                            into out: inout [Vec2]) {
        guard abs(sweep) > 1e-9 else { return }
        let count = arcCount(sweep: sweep, radius: radius, tolerance: tolerance)
        var previous = center + u * radius
        for k in 1...count {
            let next = center + rotate(u, by: sweep * Double(k) / Double(count)) * radius
            triangle(center, previous, next, into: &out)
            previous = next
        }
    }

    /// How many triangles `arc` makes for a turn of `sweep` radians.
    private static func arcCount(sweep: Double, radius: Double, tolerance: Double) -> Int {
        let step = radius > tolerance ? 2 * acos(max(-1, 1 - tolerance / radius)) : .pi / 2
        return min(max(Int((abs(sweep) / max(step, 1e-3)).rounded(.up)), 1), 128)
    }

    private static func rotate(_ v: Vec2, by angle: Double) -> Vec2 {
        let c = cos(angle), s = sin(angle)
        return Vec2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    private static func quad(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2, into out: inout [Vec2]) {
        triangle(a, b, c, into: &out)
        triangle(a, c, d, into: &out)
    }

    /// Appends a triangle wound counter-clockwise (positive area); degenerate ones are dropped.
    /// Three single appends: `append(contentsOf: [a, b, c])` allocated an array for every triangle.
    private static func triangle(_ a: Vec2, _ b: Vec2, _ c: Vec2, into out: inout [Vec2]) {
        let area = (b - a).cross(c - a)
        guard abs(area) > 1e-12 else { return }
        out.append(a)
        if area > 0 {
            out.append(b)
            out.append(c)
        } else {
            out.append(c)
            out.append(b)
        }
    }
}
