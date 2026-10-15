import Foundation

/// A shape's points at both ends of a transition, lined up one to one so they can be
/// interpolated: vertices are matched by id, and vertices that exist at only one end
/// get a stand-in at the other.
///
/// - A vertex *born* on a segment between two matched vertices starts on the old curve:
///   the old segment is split at the vertex's `t`, as inserting a point does, so the
///   shape looks unchanged at the start. Several born on one segment split it in turn,
///   each `t` measured on what is left of the segment after the one before.
/// - A vertex *dying* on a segment is mirrored: the new (healed) segment is split at its
///   `t`, so it rides along the curve and vanishes at the end.
/// - At an open path's ends, a vertex born or dying past the last matched one sits on
///   that matched vertex, with no handles, at the other end of the transition.
///
/// When that can't be done (no vertex in common, `closed` changed, the common vertices
/// changed order, or one segment both gains and loses vertices) there is no merge, and
/// the shape takes its new points at the start with only the matched vertices moving
/// (see `fallback`).
struct VertexMerge {
    /// The points at the start of the transition and at its end, the same length.
    var from: [PathPoint]
    var to: [PathPoint]
    /// The `t` used for each vertex born or dying on a segment, by id.
    var parameters: [Int: Double] = [:]

    /// `parameter(id, segment, position)` gives the `t` for a born or dying vertex on
    /// `segment` (what is left of it), or nil to give up; `position` is where the vertex
    /// is in the state it exists in.
    init?(from a: BezierPath, to b: BezierPath, parameter: (Int, CubicBezier, Vec2) -> Double?) {
        guard a.closed == b.closed else { return nil }
        let A = a.points, B = b.points
        var aIndex: [Int: Int] = [:], bIDs = Set<Int>()
        for (i, p) in A.enumerated() { guard aIndex.updateValue(i, forKey: p.id) == nil else { return nil } }
        for p in B { guard bIDs.insert(p.id).inserted else { return nil } }
        let matchedB = B.indices.filter { aIndex[B[$0].id] != nil }
        guard !matchedB.isEmpty else { return nil }
        let matchedA = matchedB.map { aIndex[B[$0].id]! }
        let m = matchedB.count
        // The common vertices keep their order (cyclically, on a closed path).
        let descents = (0..<m).filter { i in
            let next = i + 1 < m ? matchedA[i + 1] : (b.closed ? matchedA[0] : Int.max)
            return next <= matchedA[i]
        }.count
        guard b.closed ? (m == 1 || descents == 1) : descents == 0 else { return nil }

        var fromB: [PathPoint?] = B.map { aIndex[$0.id].map { A[$0] } }
        var toB = B
        // Dying vertices go after the B index they follow (-1: before everything).
        var dyingAfter: [Int: [(PathPoint, PathPoint)]] = [:]
        var parameters: [Int: Double] = [:]

        func between(_ start: Int, _ end: Int, count n: Int) -> [Int] {
            var out: [Int] = []
            var i = (start + 1) % n
            while i != end {
                out.append(i)
                i = (i + 1) % n
            }
            return out
        }

        // Segments between consecutive matched vertices.
        for g in 0..<(b.closed ? m : m - 1) {
            let jS = matchedB[g], jE = matchedB[(g + 1) % m]
            let iS = matchedA[g], iE = matchedA[(g + 1) % m]
            let born = m == 1 ? Array(B.indices).filter { $0 != jS }.sorted { ($0 - jS + B.count) % B.count < ($1 - jS + B.count) % B.count }
                : between(jS, jE, count: B.count)
            let dying = m == 1 ? Array(A.indices).filter { $0 != iS }.sorted { ($0 - iS + A.count) % A.count < ($1 - iS + A.count) % A.count }
                : between(iS, iE, count: A.count)
            if !born.isEmpty, !dying.isEmpty { return nil }
            if !born.isEmpty {
                var segment = CubicBezier(A[iS].position, A[iS].outControl, A[iE].inControl, A[iE].position)
                var previous = jS
                for j in born {
                    guard let raw = parameter(B[j].id, segment, B[j].position) else { return nil }
                    let t = min(max(raw, 0), 1)
                    parameters[B[j].id] = t
                    let (l, r) = segment.split(at: t)
                    fromB[previous]!.outHandle = l.p1 - l.p0
                    var point = PathPoint(l.p3, in: l.p2 - l.p3, out: r.p1 - r.p0, mode: B[j].mode)
                    point.id = B[j].id
                    point.width = fromB[previous]!.width + (A[iE].width - fromB[previous]!.width) * t
                    point.stroked = B[j].stroked
                    fromB[j] = point
                    segment = r
                    previous = j
                }
                fromB[jE]!.inHandle = segment.p2 - segment.p3
            } else if !dying.isEmpty {
                var segment = CubicBezier(B[jS].position, B[jS].outControl, B[jE].inControl, B[jE].position)
                var entries: [(PathPoint, PathPoint)] = []
                var previousWidth = B[jS].width
                for i in dying {
                    guard let raw = parameter(A[i].id, segment, A[i].position) else { return nil }
                    let t = min(max(raw, 0), 1)
                    parameters[A[i].id] = t
                    let (l, r) = segment.split(at: t)
                    if entries.isEmpty { toB[jS].outHandle = l.p1 - l.p0 } else { entries[entries.count - 1].1.outHandle = l.p1 - l.p0 }
                    var point = PathPoint(l.p3, in: l.p2 - l.p3, out: r.p1 - r.p0, mode: A[i].mode)
                    point.id = A[i].id
                    point.width = previousWidth + (B[jE].width - previousWidth) * t
                    point.stroked = A[i].stroked
                    previousWidth = point.width
                    entries.append((A[i], point))
                    segment = r
                }
                toB[jE].inHandle = segment.p2 - segment.p3
                dyingAfter[jS] = entries
            }
        }

        if !b.closed {
            // Past the matched vertices at either end, vertices grow out of or shrink into
            // the end one.
            func stub(_ point: PathPoint, at anchor: PathPoint) -> PathPoint {
                var p = PathPoint(anchor.position, in: .zero, out: .zero, mode: point.mode)
                p.id = point.id
                p.width = anchor.width
                p.stroked = point.stroked
                return p
            }
            let j0 = matchedB[0], i0 = matchedA[0], jL = matchedB[m - 1], iL = matchedA[m - 1]
            let leadBorn = Array(0..<j0), leadDying = Array(0..<i0)
            let tailBorn = Array((jL + 1)..<B.count), tailDying = Array((iL + 1)..<A.count)
            if !leadBorn.isEmpty, !leadDying.isEmpty { return nil }
            if !tailBorn.isEmpty, !tailDying.isEmpty { return nil }
            for j in leadBorn + tailBorn { fromB[j] = stub(B[j], at: A[j < j0 ? i0 : iL]) }
            if !leadDying.isEmpty { dyingAfter[-1] = leadDying.map { (A[$0], stub(A[$0], at: B[j0])) } }
            if !tailDying.isEmpty { dyingAfter[jL, default: []] += tailDying.map { (A[$0], stub(A[$0], at: B[jL])) } }
        }

        var from: [PathPoint] = [], to: [PathPoint] = []
        for (a, b) in dyingAfter[-1] ?? [] {
            from.append(a)
            to.append(b)
        }
        for j in B.indices {
            from.append(fromB[j]!)
            to.append(toB[j])
            for (a, b) in dyingAfter[j] ?? [] {
                from.append(a)
                to.append(b)
            }
        }
        self.from = from
        self.to = to
        self.parameters = parameters
    }

    /// The `t` for every vertex born or dying on a segment between `a` and `b`, measured by
    /// projecting the vertex onto the segment; empty when the points can't be merged.
    static func parameters(from a: BezierPath, to b: BezierPath) -> [Int: Double] {
        VertexMerge(from: a, to: b) { _, segment, position in segment.nearest(to: position).t }?.parameters ?? [:]
    }

    /// No merge: the new points, each matched vertex starting from where it was.
    static func fallback(from a: BezierPath, to b: BezierPath) -> (from: [PathPoint], to: [PathPoint]) {
        let old = Dictionary(a.points.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (b.points.map { old[$0.id] ?? $0 }, b.points)
    }
}
