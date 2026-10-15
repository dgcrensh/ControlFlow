import Foundation

/// Whether a guide coordinate is a box's edge or its middle.
public enum GuideKind: Sendable {
    case edge, center
}

/// One coordinate a dragged box can line up with: an x line (for `GuideTargets.xs`)
/// or a y line (`ys`), with the box it belongs to.
public struct GuideTarget: Hashable, Sendable {
    public var value: Double
    public var kind: GuideKind
    public var box: Rect
    /// True for the viewport's own lines, which span the whole viewport.
    public var isViewport: Bool

    public init(value: Double, kind: GuideKind, box: Rect, isViewport: Bool = false) {
        self.value = value
        self.kind = kind
        self.box = box
        self.isViewport = isViewport
    }
}

/// Everything a smart-guide drag can snap to, collected once when the drag starts:
/// each box's left, middle and right x and top, middle and bottom y, sorted so each
/// lookup is a binary search.
public struct GuideTargets: Sendable {
    public private(set) var xs: [GuideTarget]
    public private(set) var ys: [GuideTarget]

    public init(boxes: [Rect], viewport: Rect?) {
        var xs: [GuideTarget] = [], ys: [GuideTarget] = []
        xs.reserveCapacity(boxes.count * 3 + 3)
        ys.reserveCapacity(boxes.count * 3 + 3)
        func add(_ box: Rect, isViewport: Bool) {
            guard !box.isNull else { return }
            xs.append(GuideTarget(value: box.minPoint.x, kind: .edge, box: box, isViewport: isViewport))
            xs.append(GuideTarget(value: box.center.x, kind: .center, box: box, isViewport: isViewport))
            xs.append(GuideTarget(value: box.maxPoint.x, kind: .edge, box: box, isViewport: isViewport))
            ys.append(GuideTarget(value: box.minPoint.y, kind: .edge, box: box, isViewport: isViewport))
            ys.append(GuideTarget(value: box.center.y, kind: .center, box: box, isViewport: isViewport))
            ys.append(GuideTarget(value: box.maxPoint.y, kind: .edge, box: box, isViewport: isViewport))
        }
        if let viewport { add(viewport, isViewport: true) }
        for box in boxes { add(box, isViewport: false) }
        self.xs = xs.sorted { $0.value < $1.value }
        self.ys = ys.sorted { $0.value < $1.value }
    }

    public var isEmpty: Bool { xs.isEmpty }

    /// The targets with a value in `low...high`, from a sorted list.
    static func range(_ list: [GuideTarget], _ low: Double, _ high: Double) -> ArraySlice<GuideTarget> {
        var lo = 0, hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].value < low { lo = mid + 1 } else { hi = mid }
        }
        var end = lo
        while end < list.count, list[end].value <= high { end += 1 }
        return list[lo..<end]
    }
}

/// A guide line to draw while dragging, in world space.
public struct GuideLine: Hashable, Sendable {
    public var from: Vec2
    public var to: Vec2
    /// True when a middle lined up, which the overlay marks with a cross at each end.
    public var isCenter: Bool

    public init(from: Vec2, to: Vec2, isCenter: Bool) {
        self.from = from
        self.to = to
        self.isCenter = isCenter
    }
}

/// The outcome of a smart-guide snap: the adjusted value, and the coordinate each axis
/// lined up on (nil when that axis didn't snap).
public struct GuideSnap: Hashable, Sendable {
    public var delta: Vec2
    public var x: Double?
    public var y: Double?
}

/// Snapping a dragged box to other boxes' edges and middles. `radius` is in world
/// points: the editor passes a fixed number of screen points divided by the zoom.
public enum SmartGuides {
    /// Two coordinates closer than this are the same line.
    static let same = 1e-6

    /// Adjusts `delta` so one of `box`'s three x lines (and independently its three y
    /// lines), moved by `delta`, lands on a target within `radius`. Each axis takes the
    /// smallest adjustment; on a tie an edge-to-edge match beats one with a middle, then
    /// the viewport beats other boxes. `snapX` and `snapY` leave an axis alone.
    public static func snapMove(box: Rect, delta: Vec2, targets: GuideTargets, radius: Double,
                                snapX: Bool = true, snapY: Bool = true) -> GuideSnap {
        var result = GuideSnap(delta: delta, x: nil, y: nil)
        guard !box.isNull else { return result }
        let moved = Rect(minPoint: box.minPoint + delta, maxPoint: box.maxPoint + delta)
        if snapX, let hit = nearest([(moved.minPoint.x, .edge), (moved.center.x, .center), (moved.maxPoint.x, .edge)],
                                    in: targets.xs, radius: radius) {
            result.delta.x += hit.adjustment
            result.x = hit.value
        }
        if snapY, let hit = nearest([(moved.minPoint.y, .edge), (moved.center.y, .center), (moved.maxPoint.y, .edge)],
                                    in: targets.ys, radius: radius) {
            result.delta.y += hit.adjustment
            result.y = hit.value
        }
        return result
    }

    /// Snaps a dragged edge or corner at `p`: its x when `snapX`, its y when `snapY`.
    /// Returns the coordinates it lined up on.
    public static func snapPoint(_ p: Vec2, targets: GuideTargets, radius: Double,
                                 snapX: Bool = true, snapY: Bool = true) -> (x: Double?, y: Double?) {
        let x = snapX ? nearest([(p.x, .edge)], in: targets.xs, radius: radius)?.value : nil
        let y = snapY ? nearest([(p.y, .edge)], in: targets.ys, radius: radius)?.value : nil
        return (x, y)
    }

    /// The nearest target to any of `lines` within `radius`, and how far that line moves.
    static func nearest(_ lines: [(value: Double, kind: GuideKind)], in list: [GuideTarget],
                        radius: Double) -> (value: Double, adjustment: Double)? {
        var best: (value: Double, adjustment: Double, rank: Int)?
        for line in lines {
            for target in GuideTargets.range(list, line.value - radius, line.value + radius) {
                let adjustment = target.value - line.value
                // Lower ranks win ties: edge to edge first, then the viewport.
                let rank = (line.kind == .edge && target.kind == .edge ? 0 : 2) + (target.isViewport ? 0 : 1)
                if let b = best {
                    let d = abs(adjustment), bd = abs(b.adjustment)
                    if d > bd + same || (abs(d - bd) <= same && rank >= b.rank) { continue }
                }
                best = (target.value, adjustment, rank)
            }
        }
        return best.map { ($0.value, $0.adjustment) }
    }

    /// The lines that show `box` lined up at x `x` and y `y`. Each runs along the
    /// coordinate from the box to the farthest target on it, so three lined-up objects
    /// show one long line. A middle contributes its middle point, an edge its whole
    /// side, and the viewport its whole width or height.
    public static func lines(box: Rect, x: Double?, y: Double?, targets: GuideTargets) -> [GuideLine] {
        guard !box.isNull else { return [] }
        var out: [GuideLine] = []
        if let x, let line = line(at: x, box: box, along: targets.xs, vertical: true) { out.append(line) }
        if let y, let line = line(at: y, box: box, along: targets.ys, vertical: false) { out.append(line) }
        return out
    }

    private static func line(at c: Double, box: Rect, along list: [GuideTarget], vertical: Bool) -> GuideLine? {
        // Across the line: y for a vertical line, x for a horizontal one.
        func across(_ v: Vec2) -> Double { vertical ? v.y : v.x }
        func along(_ v: Vec2) -> Double { vertical ? v.x : v.y }
        let matches = GuideTargets.range(list, c - same, c + same)
        guard !matches.isEmpty else { return nil }
        let boxIsCenter = abs(along(box.center) - c) <= same
        var isCenter = boxIsCenter
        var low = Double.infinity, high = -Double.infinity
        func cover(_ a: Double, _ b: Double) { low = min(low, a); high = max(high, b) }
        if boxIsCenter {
            cover(across(box.center), across(box.center))
        } else {
            cover(across(box.minPoint), across(box.maxPoint))
        }
        for target in matches {
            if target.kind == .center { isCenter = true }
            if target.isViewport || target.kind == .edge {
                cover(across(target.box.minPoint), across(target.box.maxPoint))
            } else {
                cover(across(target.box.center), across(target.box.center))
            }
        }
        let from = vertical ? Vec2(c, low) : Vec2(low, c)
        let to = vertical ? Vec2(c, high) : Vec2(high, c)
        return GuideLine(from: from, to: to, isCenter: isCenter)
    }
}
