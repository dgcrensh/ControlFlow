import Foundation

/// One cubic Bézier segment.
public struct CubicBezier: Hashable, Sendable {
    public var p0: Vec2, p1: Vec2, p2: Vec2, p3: Vec2

    public init(_ p0: Vec2, _ p1: Vec2, _ p2: Vec2, _ p3: Vec2) {
        self.p0 = p0; self.p1 = p1; self.p2 = p2; self.p3 = p3
    }

    public func point(at t: Double) -> Vec2 {
        let mt = 1 - t
        return p0 * (mt * mt * mt) + p1 * (3 * mt * mt * t) + p2 * (3 * mt * t * t) + p3 * (t * t * t)
    }

    /// Grows `r`, which must already hold both ends, to hold the whole segment.
    func include(in r: inout Rect) {
        // The curve stays inside its control points' hull.
        guard !(r.contains(p1) && r.contains(p2)) else { return }
        // Where a coordinate's derivative is zero: (a - 2b + c)t² + 2(b - a)t + a = 0,
        // with a, b, c the control polygon's edges.
        func turningPoints(_ v0: Double, _ v1: Double, _ v2: Double, _ v3: Double) {
            let a = v1 - v0, b = v2 - v1, c = v3 - v2
            let qa = a - 2 * b + c, qb = 2 * (b - a)
            func visit(_ t: Double) { if t > 0, t < 1 { r.include(point(at: t)) } }
            if abs(qa) < 1e-12 {
                if abs(qb) > 1e-12 { visit(-a / qb) }
                return
            }
            let disc = qb * qb - 4 * qa * a
            guard disc >= 0 else { return }
            let root = disc.squareRoot()
            visit((-qb + root) / (2 * qa))
            visit((-qb - root) / (2 * qa))
        }
        turningPoints(p0.x, p1.x, p2.x, p3.x)
        turningPoints(p0.y, p1.y, p2.y, p3.y)
    }

    public func derivative(at t: Double) -> Vec2 {
        let mt = 1 - t
        return (p1 - p0) * (3 * mt * mt) + (p2 - p1) * (6 * mt * t) + (p3 - p2) * (3 * t * t)
    }

    public func secondDerivative(at t: Double) -> Vec2 {
        (p2 - p1 * 2 + p0) * (6 * (1 - t)) + (p3 - p2 * 2 + p1) * (6 * t)
    }

    /// De Casteljau split into the parts before and after `t`.
    public func split(at t: Double) -> (CubicBezier, CubicBezier) {
        let a = Vec2.lerp(p0, p1, t), b = Vec2.lerp(p1, p2, t), c = Vec2.lerp(p2, p3, t)
        let d = Vec2.lerp(a, b, t), e = Vec2.lerp(b, c, t)
        let f = Vec2.lerp(d, e, t)
        return (CubicBezier(p0, a, d, f), CubicBezier(f, e, c, p3))
    }

    /// About how many points `flatten` appends at `tolerance`, for reserving its output: Wang's
    /// bound for evenly spaced points.
    func flattenedCountEstimate(tolerance: Double) -> Int {
        let bend = max((p0 - p1 * 2 + p2).length, (p1 - p2 * 2 + p3).length)
        let n = (0.75 * bend / max(tolerance, 1e-6)).squareRoot().rounded(.up)
        return Int(min(max(n, 1), 65_536))
    }

    /// Appends points approximating the curve to `out`, excluding `p0`, so that no
    /// point of the curve is further than about `tolerance` from the polyline.
    public func flatten(tolerance: Double, into out: inout [Vec2]) {
        flatten(tolerance: max(tolerance, 1e-6), depth: 0, into: &out)
    }

    private func flatten(tolerance: Double, depth: Int, into out: inout [Vec2]) {
        let flat = p1.distance(toSegment: p0, p3) <= tolerance && p2.distance(toSegment: p0, p3) <= tolerance
        if flat || depth >= 16 {
            out.append(p3)
            return
        }
        let (l, r) = split(at: 0.5)
        l.flatten(tolerance: tolerance, depth: depth + 1, into: &out)
        r.flatten(tolerance: tolerance, depth: depth + 1, into: &out)
    }

    /// Like `flatten`, also appending each point's curve parameter to `params`.
    public func flatten(tolerance: Double, into out: inout [Vec2], params: inout [Double]) {
        flatten(tolerance: max(tolerance, 1e-6), depth: 0, t0: 0, t1: 1, into: &out, params: &params)
    }

    private func flatten(tolerance: Double, depth: Int, t0: Double, t1: Double, into out: inout [Vec2],
                         params: inout [Double]) {
        let flat = p1.distance(toSegment: p0, p3) <= tolerance && p2.distance(toSegment: p0, p3) <= tolerance
        if flat || depth >= 16 {
            out.append(p3)
            params.append(t1)
            return
        }
        let (l, r) = split(at: 0.5)
        let mid = (t0 + t1) / 2
        l.flatten(tolerance: tolerance, depth: depth + 1, t0: t0, t1: mid, into: &out, params: &params)
        r.flatten(tolerance: tolerance, depth: depth + 1, t0: mid, t1: t1, into: &out, params: &params)
    }

    /// The curve parameter closest to `p`, and the distance there.
    public func nearest(to p: Vec2) -> (t: Double, distance: Double) {
        let samples = 24
        var bestT = 0.0
        var best = Double.infinity
        for i in 0...samples {
            let t = Double(i) / Double(samples)
            let d = point(at: t).distance(to: p)
            if d < best { best = d; bestT = t }
        }
        // Golden-section refinement around the best sample.
        var lo = max(0, bestT - 1 / Double(samples))
        var hi = min(1, bestT + 1 / Double(samples))
        let g = 0.618_033_988_75
        for _ in 0..<20 {
            let m1 = hi - (hi - lo) * g
            let m2 = lo + (hi - lo) * g
            if point(at: m1).distance(to: p) < point(at: m2).distance(to: p) { hi = m2 } else { lo = m1 }
        }
        let t = (lo + hi) / 2
        let d = point(at: t).distance(to: p)
        return d < best ? (t, d) : (bestT, best)
    }
}

/// How a point's two handles relate when one of them moves.
public enum HandleMode: Hashable, Sendable, Codable {
    /// The handles move independently.
    case corner
    /// The handles stay collinear; the other keeps its length.
    case smooth
    /// The handles stay collinear and equally long.
    case symmetric
}

/// An anchor on a path. Handles are offsets from the anchor, matching the file
/// format's `in` and `out`. `mode` says how the handles follow each other.
public struct PathPoint: Hashable, Sendable, Codable {
    public var position: Vec2
    public var inHandle: Vec2
    public var outHandle: Vec2
    public var mode: HandleMode
    /// The outline's width here, as a multiple of the stroke width (the file's `w`).
    /// Widths blend linearly along each segment; 1 everywhere is a uniform outline.
    public var width: Double = 1
    /// Whether the segment leaving this point is outlined (the file's `stroked`).
    /// False leaves that edge bare while the fill still covers it. Ignored on the
    /// last point of an open path, which has no segment leaving it.
    public var stroked = true

    public init(_ position: Vec2, in inHandle: Vec2 = .zero, out outHandle: Vec2 = .zero, smooth: Bool = true) {
        self.position = position
        self.inHandle = inHandle
        self.outHandle = outHandle
        self.mode = smooth ? .smooth : .corner
    }

    public init(_ position: Vec2, in inHandle: Vec2, out outHandle: Vec2, mode: HandleMode) {
        self.position = position
        self.inHandle = inHandle
        self.outHandle = outHandle
        self.mode = mode
    }

    /// True for smooth and symmetric points. Setting it true keeps a symmetric mode.
    public var isSmooth: Bool {
        get { mode != .corner }
        set {
            if !newValue {
                mode = .corner
            } else if mode == .corner {
                mode = .smooth
            }
        }
    }

    public var inControl: Vec2 { position + inHandle }
    public var outControl: Vec2 { position + outHandle }
}

public enum HandleSide: Hashable, Sendable {
    case incoming
    case outgoing
}

/// One end of an open path.
public enum PathEnd: Hashable, Sendable {
    case start
    case end
}

/// An editable cubic Bézier path, open or closed.
public struct BezierPath: Hashable, Sendable, Codable {
    public var points: [PathPoint]
    public var closed: Bool

    public init(points: [PathPoint] = [], closed: Bool = false) {
        self.points = points
        self.closed = closed
    }

    public var segmentCount: Int {
        let n = points.count
        guard n >= 2 else { return 0 }
        return closed ? n : n - 1
    }

    /// Segment `i` runs from point `i` to point `i + 1` (wrapping for closed paths).
    public func segment(_ i: Int) -> CubicBezier {
        let a = points[i]
        let b = points[(i + 1) % points.count]
        return CubicBezier(a.position, a.outControl, b.inControl, b.position)
    }

    /// Whether point `i` has a segment arriving at it, and one leaving it.
    public func hasIncomingSegment(_ i: Int) -> Bool { segmentCount > 0 && (closed || i > 0) }
    public func hasOutgoingSegment(_ i: Int) -> Bool { segmentCount > 0 && (closed || i < points.count - 1) }

    /// A polyline through the path. Closed paths do not repeat the first point.
    public func flattened(tolerance: Double) -> [Vec2] {
        guard let first = points.first else { return [] }
        var out: [Vec2] = []
        out.reserveCapacity(flattenedCountEstimate(tolerance: tolerance))
        out.append(first.position)
        for i in 0..<segmentCount {
            segment(i).flatten(tolerance: tolerance, into: &out)
        }
        if closed, segmentCount > 0, out.count > 1 { out.removeLast() }
        return out
    }

    /// A polyline through the path with the outline width multiple at each point,
    /// blended linearly along each segment. Closed paths do not repeat the first point.
    public func flattenedWithWidths(tolerance: Double) -> (points: [Vec2], widths: [Double]) {
        guard let first = points.first else { return ([], []) }
        let estimate = flattenedCountEstimate(tolerance: tolerance)
        var out: [Vec2] = [], widths: [Double] = []
        out.reserveCapacity(estimate)
        widths.reserveCapacity(estimate)
        out.append(first.position)
        widths.append(first.width)
        var params: [Double] = []
        for i in 0..<segmentCount {
            params.removeAll(keepingCapacity: true)
            segment(i).flatten(tolerance: tolerance, into: &out, params: &params)
            let w0 = points[i].width, w1 = points[(i + 1) % points.count].width
            for t in params { widths.append(w0 + (w1 - w0) * t) }
        }
        if closed, segmentCount > 0, out.count > 1 {
            out.removeLast()
            widths.removeLast()
        }
        return (out, widths)
    }

    /// A capacity for `flattened(tolerance:)`'s output, from the segments' control points: the
    /// segments' estimates plus a quarter, since the halving lands a little above them as often as
    /// not. On the stress drawing no path needed more.
    func flattenedCountEstimate(tolerance: Double) -> Int {
        var count = 1
        for i in 0..<segmentCount { count += segment(i).flattenedCountEstimate(tolerance: tolerance) }
        return count + count / 4
    }

    /// True when some segment of the path is left without an outline.
    public var hasUnstrokedSegments: Bool {
        (0..<segmentCount).contains { !points[$0].stroked }
    }

    /// The outlined parts of the path as open paths, in order, each running over
    /// consecutive stroked segments. The whole path when every segment is stroked.
    public func strokedRuns() -> [BezierPath] {
        let count = segmentCount
        guard count > 0, hasUnstrokedSegments else { return [self] }
        let n = points.count
        // A closed path is walked from just after a bare segment, so no run wraps past its start.
        let start = closed ? ((0..<count).first { !points[$0].stroked }! + 1) % n : 0
        var runs: [BezierPath] = []
        var current: [PathPoint] = []
        for k in 0..<count {
            let i = (start + k) % n
            if points[i].stroked {
                if current.isEmpty { current.append(points[i]) }
                current.append(points[(i + 1) % n])
            } else if !current.isEmpty {
                runs.append(BezierPath(points: current))
                current = []
            }
        }
        if !current.isEmpty { runs.append(BezierPath(points: current)) }
        return runs
    }

    /// True when some anchor's width is not 1.
    public var hasVariableWidth: Bool { points.contains { $0.width != 1 } }

    /// The largest anchor width multiple (1 for an empty path).
    public var maxWidth: Double { points.map(\.width).max() ?? 1 }

    /// The exact bounds of the curve, from each segment's ends and turning points, so it
    /// needs no flattening.
    public func bounds() -> Rect {
        var r = Rect.null
        for point in points { r.include(point.position) }
        for i in 0..<segmentCount { segment(i).include(in: &r) }
        return r
    }

    /// The bounds of the path flattened at `tolerance`, which sit inside `bounds()`.
    public func bounds(tolerance: Double) -> Rect {
        Rect(points: flattened(tolerance: tolerance))
    }

    /// The bounds of the anchors and their handles' control points. A cubic stays inside
    /// its control points' hull, so this contains the curve without flattening it; it can
    /// be larger than `bounds()`, so use it for rejecting, not for showing.
    public var controlBounds: Rect {
        var r = Rect.null
        for point in points {
            r.include(point.position)
            r.include(point.inControl)
            r.include(point.outControl)
        }
        return r
    }

    public mutating func apply(_ t: Affine2D) {
        for i in points.indices {
            points[i].position = t.apply(points[i].position)
            points[i].inHandle = t.applyToVector(points[i].inHandle)
            points[i].outHandle = t.applyToVector(points[i].outHandle)
        }
    }

    /// The closest point on the path to `p`.
    public func nearestSegment(to p: Vec2) -> (segment: Int, t: Double, distance: Double)? {
        var best: (Int, Double, Double)?
        for i in 0..<segmentCount {
            let n = segment(i).nearest(to: p)
            if best == nil || n.distance < best!.2 { best = (i, n.t, n.distance) }
        }
        return best.map { (segment: $0.0, t: $0.1, distance: $0.2) }
    }

    /// Splits segment `i` at `t` without changing the path's shape. Returns the new point's index.
    @discardableResult
    public mutating func insertPoint(segment i: Int, t: Double) -> Int {
        let (l, r) = segment(i).split(at: t)
        let a = i, b = (i + 1) % points.count
        points[a].outHandle = l.p1 - l.p0
        points[b].inHandle = r.p2 - r.p3
        var new = PathPoint(l.p3, in: l.p2 - l.p3, out: r.p1 - r.p0, smooth: true)
        new.width = points[a].width + (points[b].width - points[a].width) * t
        // Both halves of a bare segment stay bare.
        new.stroked = points[a].stroked
        points.insert(new, at: a + 1)
        return a + 1
    }

    /// Removes point `i`. Interior points are healed: the neighbours keep their handle
    /// directions and the handles facing the gap are lengthened so the joined curve
    /// follows the old shape (splitting it again would give back the old handles).
    public mutating func removePoint(at i: Int) {
        let n = points.count
        guard points.indices.contains(i) else { return }
        guard n >= 3, closed || (i > 0 && i < n - 1) else {
            points.remove(at: i)
            return
        }
        let prev = (i - 1 + n) % n, next = (i + 1) % n
        let here = points[i].position
        let d1 = points[prev].position.distance(to: here)
        let d2 = here.distance(to: points[next].position)
        let t = d1 + d2 > 1e-12 ? min(max(d1 / (d1 + d2), 0.2), 0.8) : 0.5
        points[prev].outHandle = points[prev].outHandle / t
        points[next].inHandle = points[next].inHandle / (1 - t)
        // One handle changed length, so equal-length handles no longer hold.
        if points[prev].mode == .symmetric { points[prev].mode = .smooth }
        if points[next].mode == .symmetric { points[next].mode = .smooth }
        points.remove(at: i)
    }

    /// Removes several points, each healed in turn.
    public mutating func removePoints(at indices: Set<Int>) {
        for i in indices.sorted(by: >) { removePoint(at: i) }
    }

    public mutating func moveAnchor(_ i: Int, to p: Vec2) {
        points[i].position = p
    }

    /// Moves one handle to the absolute point `q`. The opposite handle follows
    /// according to the point's mode: nothing for a corner, the opposite direction
    /// (keeping its length) for smooth, the exact mirror for symmetric.
    public mutating func setHandle(_ i: Int, _ side: HandleSide, to q: Vec2) {
        let offset = q - points[i].position
        switch side {
        case .incoming: points[i].inHandle = offset
        case .outgoing: points[i].outHandle = offset
        }
        guard offset.length > 1e-9 else { return }
        switch points[i].mode {
        case .corner:
            break
        case .smooth:
            switch side {
            case .incoming: points[i].outHandle = -offset.normalized * points[i].outHandle.length
            case .outgoing: points[i].inHandle = -offset.normalized * points[i].inHandle.length
            }
        case .symmetric:
            switch side {
            case .incoming: points[i].outHandle = -offset
            case .outgoing: points[i].inHandle = -offset
            }
        }
    }

    /// Switches a point between smooth and corner.
    public mutating func toggleSmooth(_ i: Int) {
        setMode(i, points[i].isSmooth ? .corner : .smooth)
    }

    /// Sets a point's handle mode. Turning a point smooth or symmetric lines its
    /// handles up; if it has no handles yet they are derived from its neighbours.
    public mutating func setMode(_ i: Int, _ mode: HandleMode) {
        points[i].mode = mode
        switch mode {
        case .corner: break
        case .smooth: alignHandles(i, equalLength: false)
        case .symmetric: alignHandles(i, equalLength: true)
        }
    }

    /// Retracts both handles, leaving a sharp corner between straight segments.
    public mutating func breakHandles(_ i: Int) {
        points[i].mode = .corner
        points[i].inHandle = .zero
        points[i].outHandle = .zero
    }

    private mutating func alignHandles(_ i: Int, equalLength: Bool) {
        let pt = points[i]
        let inLen = pt.inHandle.length, outLen = pt.outHandle.length
        if inLen > 1e-9, outLen > 1e-9 {
            let dir = (pt.outHandle.normalized - pt.inHandle.normalized).normalized
            guard dir != .zero else { return }
            let average = (inLen + outLen) / 2
            points[i].outHandle = dir * (equalLength ? average : outLen)
            points[i].inHandle = -dir * (equalLength ? average : inLen)
            return
        }
        let prev = neighbor(of: i, offset: -1)
        let next = neighbor(of: i, offset: 1)
        let dir = ((next ?? pt.position) - (prev ?? pt.position)).normalized
        guard dir != .zero else { return }
        var inNew = prev.map { pt.position.distance(to: $0) / 3 }
        var outNew = next.map { pt.position.distance(to: $0) / 3 }
        if equalLength, let a = inNew, let b = outNew {
            inNew = (a + b) / 2
            outNew = inNew
        }
        if let inNew, hasIncomingSegment(i) { points[i].inHandle = -dir * inNew }
        if let outNew, hasOutgoingSegment(i) { points[i].outHandle = dir * outNew }
    }

    private func neighbor(of i: Int, offset: Int) -> Vec2? {
        let n = points.count
        guard n >= 2 else { return nil }
        let j = i + offset
        if closed { return points[(j % n + n) % n].position }
        return points.indices.contains(j) ? points[j].position : nil
    }

    /// Reshapes segment `i` by dragging the curve near parameter `t` by `delta`: the
    /// two handles that shape the segment move so that point of the curve follows.
    /// Handle modes of the end points are honoured.
    public mutating func reshapeSegment(_ i: Int, t: Double, by delta: Vec2) {
        guard i >= 0, i < segmentCount else { return }
        // Near the ends the weights vanish, so keep t away from them.
        let tt = min(max(t, 0.15), 0.85)
        let mt = 1 - tt
        let b1 = 3 * mt * mt * tt, b2 = 3 * mt * tt * tt
        let denom = b1 * b1 + b2 * b2
        let a = i, b = (i + 1) % points.count
        let seg = segment(i)
        setHandle(a, .outgoing, to: seg.p1 + delta * (b1 / denom))
        setHandle(b, .incoming, to: seg.p2 + delta * (b2 / denom))
    }

    /// The path traversed backwards: points reversed and each point's handles swapped.
    public func reversed() -> BezierPath {
        let n = points.count
        var flipped = points.reversed().map { point -> PathPoint in
            var p = point
            let tmp = p.inHandle
            p.inHandle = p.outHandle
            p.outHandle = tmp
            return p
        }
        // Segment j now runs from old point n-1-j to old point n-2-j, whose flag it carries.
        for j in flipped.indices { flipped[j].stroked = points[((n - 2 - j) % n + n) % n].stroked }
        if !closed, n > 0 { flipped[n - 1].stroked = true }
        return BezierPath(points: flipped, closed: closed)
    }

    /// The anchor at one end of an open path.
    public func endPoint(_ end: PathEnd) -> Vec2? {
        (end == .start ? points.first : points.last)?.position
    }

    /// Joins two open paths so that `aEnd` of `a` meets `bEnd` of `b`. Endpoints that
    /// coincide merge into one corner point; otherwise a segment connects them.
    public static func joined(_ a: BezierPath, _ aEnd: PathEnd, _ b: BezierPath, _ bEnd: PathEnd,
                              mergeWithin tolerance: Double = 1e-6) -> BezierPath? {
        guard !a.closed, !b.closed, !a.points.isEmpty, !b.points.isEmpty else { return nil }
        var points = (aEnd == .end ? a : a.reversed()).points
        var rest = (bEnd == .start ? b : b.reversed()).points
        if let last = points.last, let head = rest.first, last.position.distance(to: head.position) <= tolerance {
            var merged = last
            merged.outHandle = head.outHandle
            merged.stroked = head.stroked
            merged.mode = .corner
            points[points.count - 1] = merged
            rest.removeFirst()
        } else if !points.isEmpty {
            // The new connecting segment is outlined.
            points[points.count - 1].stroked = true
        }
        return BezierPath(points: points + rest, closed: false)
    }

    /// The open path closed by joining its two ends, or nil with fewer than three
    /// points. Ends that coincide merge.
    public func closedByJoiningEnds(mergeWithin tolerance: Double = 1e-6) -> BezierPath? {
        guard !closed, points.count >= 3 else { return nil }
        var result = self
        result.closed = true
        if let first = points.first, let last = points.last, first.position.distance(to: last.position) <= tolerance {
            guard points.count >= 4 else { return nil }
            result.points[0].inHandle = last.inHandle
            result.points[0].mode = .corner
            result.points.removeLast()
        } else {
            // The closing segment is outlined.
            result.points[result.points.count - 1].stroked = true
        }
        return result
    }

    /// The open path closed by a straight edge from its last point back to its first,
    /// both ends now corners with no handle on that edge. Nil when that would enclose
    /// nothing: under two points, ends that coincide, or a single straight segment.
    public func closedWithStraightEdge() -> BezierPath? {
        guard !closed, points.count >= 2, let first = points.first, let last = points.last,
              first.position.distance(to: last.position) > 1e-6 else { return nil }
        if points.count == 2, first.outHandle == .zero, last.inHandle == .zero { return nil }
        var result = self
        result.closed = true
        let n = points.count
        result.points[0].inHandle = .zero
        result.points[0].mode = .corner
        result.points[n - 1].outHandle = .zero
        result.points[n - 1].mode = .corner
        // The new edge is outlined.
        result.points[n - 1].stroked = true
        return result
    }

    /// Cuts the path at point `i`. An open path becomes two open paths that both keep
    /// point `i` (as a corner with no handle on the cut side); a closed path opens
    /// into one path that starts and ends at `i`. Nil when a piece would be too short.
    public func split(at i: Int) -> [BezierPath]? {
        guard points.indices.contains(i) else { return nil }
        if closed {
            let n = points.count
            guard n >= 2 else { return nil }
            var pts = (0...n).map { points[(i + $0) % n] }
            pts[0].inHandle = .zero
            pts[0].mode = .corner
            pts[n].outHandle = .zero
            pts[n].mode = .corner
            pts[n].stroked = true
            return [BezierPath(points: pts, closed: false)]
        }
        guard i > 0, i < points.count - 1 else { return nil }
        var head = Array(points[0...i])
        head[i].outHandle = .zero
        head[i].mode = .corner
        head[i].stroked = true
        var tail = Array(points[i...])
        tail[0].inHandle = .zero
        tail[0].mode = .corner
        return [BezierPath(points: head), BezierPath(points: tail)]
    }
}
