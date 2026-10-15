import Foundation

/// The edge or middle line Align lines things up on.
public enum AlignEdge: Sendable, CaseIterable {
    case left, centerX, right, top, centerY, bottom

    /// True for the edges that move things along x.
    public var isHorizontal: Bool {
        switch self {
        case .left, .centerX, .right: true
        case .top, .centerY, .bottom: false
        }
    }
}

/// How Distribute spaces things: equal gaps between boxes, or equal steps between
/// their centers, along x or y.
public enum DistributeMode: Sendable, CaseIterable {
    case spacingX, spacingY, centersX, centersY

    public var isHorizontal: Bool { self == .spacingX || self == .centersX }
    var isSpacing: Bool { self == .spacingX || self == .spacingY }
}

/// Align: the translations that line boxes or points up on an edge or middle line.
public enum Aligner {
    /// One translation per box so its `edge` matches `reference`'s.
    public static func offsets(boxes: [Rect], edge: AlignEdge, reference: Rect) -> [Vec2] {
        boxes.map { box in
            let target = line(of: reference, edge), own = line(of: box, edge)
            return cleaned(edge.isHorizontal ? Vec2(target - own, 0) : Vec2(0, target - own))
        }
    }

    /// The same for points (Direct Select): each point's x or y goes to the points'
    /// min, middle or max (the middle of their bounding box for centers).
    public static func offsets(points: [Vec2], edge: AlignEdge) -> [Vec2] {
        guard !points.isEmpty else { return [] }
        let target = line(of: Rect(points: points), edge)
        return points.map { p in
            cleaned(edge.isHorizontal ? Vec2(target - p.x, 0) : Vec2(0, target - p.y))
        }
    }

    static func line(of box: Rect, _ edge: AlignEdge) -> Double {
        switch edge {
        case .left: box.minPoint.x
        case .centerX: box.center.x
        case .right: box.maxPoint.x
        case .top: box.minPoint.y
        case .centerY: box.center.y
        case .bottom: box.maxPoint.y
        }
    }
}

/// Distribute: the translations that space three or more boxes or points evenly.
public enum Distributor {
    /// One translation per box. Boxes are ordered by center along the axis (ties keep
    /// input order). With `within` nil, the first and last stay put; with a rect (the
    /// viewport), the first and last move to its edges and the rest spread between.
    /// Fewer than three boxes don't move.
    public static func offsets(boxes: [Rect], mode: DistributeMode, within: Rect?) -> [Vec2] {
        var out = Array(repeating: Vec2.zero, count: boxes.count)
        guard boxes.count >= 3 else { return out }
        let x = mode.isHorizontal
        func lo(_ r: Rect) -> Double { x ? r.minPoint.x : r.minPoint.y }
        func hi(_ r: Rect) -> Double { x ? r.maxPoint.x : r.maxPoint.y }
        let order = sortedIndices(boxes.map { (lo($0) + hi($0)) / 2 })
        let first = boxes[order[0]], last = boxes[order[order.count - 1]]
        let start = within.map(lo) ?? lo(first), end = within.map(hi) ?? hi(last)
        let steps = Double(boxes.count - 1)
        // Where each box's low edge goes, in order.
        var targets: [Double] = []
        if mode.isSpacing {
            let sizes = order.map { hi(boxes[$0]) - lo(boxes[$0]) }
            // Negative when the boxes overlap: they then overlap equally.
            let gap = (end - start - sizes.reduce(0, +)) / steps
            var cursor = start
            for size in sizes {
                targets.append(cursor)
                cursor += size + gap
            }
        } else {
            let firstCenter = start + (hi(first) - lo(first)) / 2
            let lastCenter = end - (hi(last) - lo(last)) / 2
            for (k, i) in order.enumerated() {
                let center = firstCenter + (lastCenter - firstCenter) * Double(k) / steps
                targets.append(center - (hi(boxes[i]) - lo(boxes[i])) / 2)
            }
        }
        for (k, i) in order.enumerated() {
            let d = targets[k] - lo(boxes[i])
            out[i] = cleaned(x ? Vec2(d, 0) : Vec2(0, d))
        }
        return out
    }

    /// The same for points: ordered along the axis, the first and last stay put and the
    /// rest get equal steps between them (spacing and centers are the same for points).
    public static func offsets(points: [Vec2], mode: DistributeMode) -> [Vec2] {
        var out = Array(repeating: Vec2.zero, count: points.count)
        guard points.count >= 3 else { return out }
        let x = mode.isHorizontal
        let values = points.map { x ? $0.x : $0.y }
        let order = sortedIndices(values)
        let a = values[order[0]], b = values[order[order.count - 1]]
        let steps = Double(points.count - 1)
        for (k, i) in order.enumerated() {
            let d = a + (b - a) * Double(k) / steps - values[i]
            out[i] = cleaned(x ? Vec2(d, 0) : Vec2(0, d))
        }
        return out
    }

    /// Indices of `values` from smallest to largest, ties in input order.
    private static func sortedIndices(_ values: [Double]) -> [Int] {
        values.indices.sorted { values[$0] != values[$1] ? values[$0] < values[$1] : $0 < $1 }
    }
}

/// Offsets below 1e-9 are zero, so callers can skip what doesn't move.
private func cleaned(_ v: Vec2) -> Vec2 {
    Vec2(abs(v.x) < 1e-9 ? 0 : v.x, abs(v.y) < 1e-9 ? 0 : v.y)
}
