import Foundation

/// The editable shapes of one drawing, with their bounds in a uniform grid, so hover,
/// taps, the eraser, the scissors and the marquee look at the few shapes near a point
/// instead of scanning the whole drawing.
///
/// It answers exactly what the scans in `Drawing.hitTest` and `DrawingEditor` answer: the
/// grid only narrows the candidates (conservatively), and every candidate then goes
/// through the same tests as before. Entries are kept in `layers` order (the scans'
/// order, which decides ties), and each carries its place in the draw order for hit tests.
/// It holds copies of the shapes, not indices into the drawing, so it stays usable for
/// geometry queries after shapes are removed (see `removing`).
///
/// The editor tags it with the `revision` it was built for and only uses it while that
/// still matches (see `DrawingEditor.freshShapeIndex`).
struct ShapeIndex: Sendable {
    struct Entry: Sendable {
        var ref: ShapeRef
        var group: Int?
        var shape: VectorShape
        var controlBounds: Rect
        var hitBounds: Rect
        /// The shape's position in the draw order, back to front.
        var drawRank: Int
        var clip: Clip
    }

    /// What `Layer.shape(_:contains:tolerance:)` checks after the shape itself: the shapes
    /// it is clipped to must contain the point too.
    enum Clip: Sendable {
        case none
        /// A base is hidden, so the shape can never be hit.
        case never
        case inside([VectorShape])
    }

    /// The editor revision the index was built for (or patched to, by `removing`).
    var revision: Int
    private(set) var entries: [Entry]
    /// Entries erased since the build; skipped by every query.
    private(set) var removed: Set<Int> = []
    /// False once shapes have been removed: removing a shape can change another's clip
    /// base and the draw stack, so `hitTest` needs a rebuild. Geometry queries don't.
    private(set) var supportsHitTest = true
    private let grid: Grid

    init(_ drawing: Drawing, revision: Int) {
        self.revision = revision
        // Shapes are indexed as they are drawn.
        let drawing = drawing.world
        // Each shape's place in the draw stack and its clip bases, by its index in `layers`.
        var layerIndex: [Int: Int] = [:]
        for (i, layer) in drawing.layers.enumerated() where layerIndex[layer.id] == nil { layerIndex[layer.id] = i }
        var ranks = drawing.layers.map { [Int](repeating: -1, count: $0.shapes.count) }
        var clips = drawing.layers.map { [Clip](repeating: .none, count: $0.shapes.count) }
        var rank = 0
        for stackLayer in drawing.layers {
            guard let p = layerIndex[stackLayer.id] else { rank += stackLayer.shapes.count; continue }
            let original = drawing.layers[p]
            let map = Array(original.shapes.indices)
            var groupBases: [Int: Int?] = [:]
            for (j, shape) in stackLayer.shapes.enumerated() {
                defer { rank += 1 }
                guard j < map.count else { continue }
                let s = map[j]
                ranks[p][s] = rank
                guard stackLayer.isEditable(j) else { continue }
                var bases: [Int] = []
                if let base = stackLayer.clipBase(of: j) { bases.append(base) }
                if let group = shape.group {
                    if groupBases[group] == nil { groupBases[group] = .some(stackLayer.clipBase(ofGroup: group)) }
                    if let base = groupBases[group] ?? nil { bases.append(base) }
                }
                if bases.isEmpty {
                    clips[p][s] = .none
                } else if bases.contains(where: { !stackLayer.isShown($0) }) {
                    clips[p][s] = .never
                } else {
                    clips[p][s] = .inside(bases.map { stackLayer.shapes[$0] })
                }
            }
        }
        var entries: [Entry] = []
        var gridBounds: [Rect] = []
        for (p, layer) in drawing.layers.enumerated() {
            for (s, shape) in layer.shapes.enumerated() where layer.isEditable(s) {
                let control = shape.path.controlBounds
                entries.append(Entry(ref: ShapeRef(layer: layer.id, shape: shape.id), group: shape.group, shape: shape,
                                     controlBounds: control, hitBounds: shape.hitBounds, drawRank: ranks[p][s],
                                     clip: clips[p][s]))
                // Covers the hit bounds and the scissors' reach (half the outline width).
                gridBounds.append(control.outset(by: max(shape.outlineReach, (shape.stroke?.width ?? 0) / 2)))
            }
        }
        self.entries = entries
        grid = Grid(gridBounds)
    }

    /// The entries whose bounds may meet `rect` (a superset of those that do), alive and
    /// passing the isolation filters, in `layers` order.
    func candidates(meeting rect: Rect, within: Int?, group: Int?) -> [Int] {
        grid.candidates(meeting: rect).filter { i in
            !removed.contains(i) && (within == nil || entries[i].ref.layer == within) &&
                (group == nil || entries[i].group == group)
        }
    }

    /// The same answer as `Drawing.hitTest(_:tolerance:within:group:)` on the drawing the
    /// index was built from. Only while `supportsHitTest`.
    func hitTest(_ p: Vec2, tolerance: Double, within: Int?, group: Int?) -> ShapeRef? {
        precondition(supportsHitTest, "ShapeIndex.hitTest after removing shapes")
        let query = Rect(from: p, to: p).outset(by: max(tolerance, 0))
        let hits = candidates(meeting: query, within: within, group: group)
            .sorted { entries[$0].drawRank > entries[$1].drawRank }
        for i in hits {
            let entry = entries[i]
            guard entry.shape.contains(p, tolerance: tolerance) else { continue }
            switch entry.clip {
            case .none: return entry.ref
            case .never: continue
            case .inside(let bases): if bases.allSatisfy({ $0.contains(p, tolerance: 0) }) { return entry.ref }
            }
        }
        return nil
    }

    /// The index after `refs` were removed from the drawing (as the eraser does), tagged
    /// with `revision`. Geometry queries stay exact; `hitTest` needs a rebuild.
    func removing(_ refs: [ShapeRef], revision: Int) -> ShapeIndex {
        var copy = self
        let doomed = Set(refs)
        for i in entries.indices where doomed.contains(entries[i].ref) { copy.removed.insert(i) }
        copy.revision = revision
        copy.supportsHitTest = false
        return copy
    }
}

/// A uniform grid of entry indices over their bounds.
private struct Grid: Sendable {
    private var origin = Vec2.zero
    private var cell = 1.0
    private var columns = 0
    private var rows = 0
    private var cells: [[Int]] = []
    /// Entries too large (or with non-finite bounds) to put in cells: always candidates.
    private var everywhere: [Int] = []
    private var extent = Rect.null
    private var count = 0

    /// Shapes covering more cells than this go in `everywhere`.
    private static let maxCellsPerEntry = 64

    init(_ bounds: [Rect]) {
        count = bounds.count
        var sizes: [Double] = []
        for r in bounds where !r.isNull && r.isFinite {
            extent = extent.union(r)
            sizes.append(max(r.width, r.height))
        }
        guard !sizes.isEmpty else {
            everywhere = bounds.indices.filter { !bounds[$0].isNull }
            return
        }
        sizes.sort()
        origin = extent.minPoint
        cell = max(sizes[sizes.count / 2], max(extent.width, extent.height) / 4096, 1e-6)
        // Keep the cell count near the entry count.
        let limit = Double(max(16, 2 * sizes.count))
        while true {
            columns = Int((extent.width / cell).rounded(.down)) + 1
            rows = Int((extent.height / cell).rounded(.down)) + 1
            let total = Double(columns) * Double(rows)
            if total <= limit { break }
            cell *= max((total / limit).squareRoot(), 1.01)
        }
        cells = Array(repeating: [], count: columns * rows)
        for (i, r) in bounds.enumerated() {
            if r.isNull { continue }
            guard r.isFinite else { everywhere.append(i); continue }
            let (c0, c1, r0, r1) = range(of: r)
            if (c1 - c0 + 1) * (r1 - r0 + 1) > Self.maxCellsPerEntry {
                everywhere.append(i)
                continue
            }
            for row in r0...r1 {
                for column in c0...c1 { cells[row * columns + column].append(i) }
            }
        }
    }

    private func range(of r: Rect) -> (Int, Int, Int, Int) {
        func index(_ v: Double, _ o: Double, _ n: Int) -> Int {
            Int(min(max(((v - o) / cell).rounded(.down), 0), Double(n - 1)))
        }
        return (index(r.minPoint.x, origin.x, columns), index(r.maxPoint.x, origin.x, columns),
                index(r.minPoint.y, origin.y, rows), index(r.maxPoint.y, origin.y, rows))
    }

    /// Entry indices, ascending, whose bounds may meet `rect`. The rect is padded a little
    /// so rounding in the callers' own bounds tests never loses a candidate.
    func candidates(meeting rect: Rect) -> [Int] {
        guard !rect.isNull else { return [] }
        guard rect.isFinite else { return Array(0..<count) }
        let scale = max(abs(rect.minPoint.x), abs(rect.minPoint.y), abs(rect.maxPoint.x), abs(rect.maxPoint.y), 1)
        let query = rect.outset(by: scale * 1e-9)
        guard columns > 0, extent.intersects(query) else { return everywhere }
        let (c0, c1, r0, r1) = range(of: query)
        var out = everywhere
        for row in r0...r1 {
            for column in c0...c1 { out.append(contentsOf: cells[row * columns + column]) }
        }
        out.sort()
        var unique: [Int] = []
        unique.reserveCapacity(out.count)
        for i in out where unique.last != i { unique.append(i) }
        return unique
    }
}

extension Rect {
    var isFinite: Bool {
        minPoint.x.isFinite && minPoint.y.isFinite && maxPoint.x.isFinite && maxPoint.y.isFinite
    }
}

extension BezierPath {
    /// `nearestSegment(to:)`, skipping segments that can't come within `limit`: a cubic
    /// lies inside its control points' box, so one whose box is farther than the best
    /// distance so far (or `limit`) can't win. Returns exactly what `nearestSegment(to:)`
    /// returns whenever that is within `limit`; otherwise nil or something farther than
    /// `limit`.
    func nearestSegment(to p: Vec2, within limit: Double) -> (segment: Int, t: Double, distance: Double)? {
        var best: (Int, Double, Double)?
        let slack = 1e-9 * (1 + abs(p.x) + abs(p.y))
        for i in 0..<segmentCount {
            let c = segment(i)
            let bound = min(limit, best?.2 ?? .infinity)
            let dx = max(min(c.p0.x, c.p1.x, c.p2.x, c.p3.x) - p.x, p.x - max(c.p0.x, c.p1.x, c.p2.x, c.p3.x), 0)
            let dy = max(min(c.p0.y, c.p1.y, c.p2.y, c.p3.y) - p.y, p.y - max(c.p0.y, c.p1.y, c.p2.y, c.p3.y), 0)
            if (dx * dx + dy * dy).squareRoot() > bound + slack * (1 + bound) { continue }
            let n = c.nearest(to: p)
            if best == nil || n.distance < best!.2 { best = (i, n.t, n.distance) }
        }
        return best.map { (segment: $0.0, t: $0.1, distance: $0.2) }
    }
}
