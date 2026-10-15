import Foundation

/// Each shape's tessellation for the art pass, keyed by shape id, so a build only
/// re-tessellates the shapes that changed (see `ArtBuilder`).
///
/// It is a Sendable value, so the renderer can hand a copy to a background job that
/// tessellates the drawing at a new zoom bucket's tolerance (`refinePlan` and
/// `tessellate`) while the main thread keeps drawing the current art, and then `merge`
/// what the job returns. The cache only reads a tessellation's `shape`, `tolerance` and
/// `vertexCount`; what the triangles are made of is `ArtBuilder`'s business.
///
/// Each entry has a second tier: the last tessellation of the same shape at another
/// tolerance. A pinch that settles back and forth across one bucket boundary then
/// swaps between two cached tessellations with only a warm build. The second tier is
/// dropped while the first holds more than `secondTierLimit` vertices.
public struct TessellationCache: Sendable {
    typealias Tessellation = ArtBuilder.Tessellation

    private struct Entry: Sendable {
        var current: Tessellation
        /// The same shape at another tolerance.
        var other: Tessellation?
    }

    private var entries: [Int: Entry] = [:]
    /// Vertices held in the first tier, and in the second.
    public private(set) var vertexCount = 0
    public private(set) var secondTierVertexCount = 0
    /// While the first tier holds more vertices than this, there is no second tier.
    public var secondTierLimit: Int {
        didSet { if vertexCount > secondTierLimit, secondTierVertexCount > 0 { dropSecondTier() } }
    }

    /// About 16 MB of points in the second tier at most.
    public static let defaultSecondTierLimit = 1_000_000

    public init(secondTierLimit: Int = defaultSecondTierLimit) {
        self.secondTierLimit = secondTierLimit
    }

    /// The number of shapes cached.
    public var count: Int { entries.count }

    /// The tessellation of `shape` at exactly `tolerance`, from either tier.
    func tessellation(of shape: VectorShape, tolerance: Double) -> Tessellation? {
        guard let entry = entries[shape.id] else { return nil }
        if entry.current.tolerance == tolerance, entry.current.shape == shape { return entry.current }
        if let other = entry.other, other.tolerance == tolerance, other.shape == shape { return other }
        return nil
    }

    /// Any cached tessellation of `shape`, whatever its tolerance: the first tier's if
    /// it is of this shape, else the second's.
    func anyTessellation(of shape: VectorShape) -> Tessellation? {
        guard let entry = entries[shape.id] else { return nil }
        if entry.current.shape == shape { return entry.current }
        if let other = entry.other, other.shape == shape { return other }
        return nil
    }

    /// The tolerances cached for shape `id`, first tier first (for tests).
    func tolerances(of id: Int) -> [Double] {
        guard let entry = entries[id] else { return [] }
        return [entry.current.tolerance] + (entry.other.map { [$0.tolerance] } ?? [])
    }

    /// As `tessellation(of:tolerance:)`, and a hit in the second tier swaps the tiers,
    /// so the one in use is the one a later tolerance pushes down.
    mutating func use(_ shape: VectorShape, tolerance: Double) -> Tessellation? {
        guard var entry = entries[shape.id] else { return nil }
        if entry.current.tolerance == tolerance, entry.current.shape == shape { return entry.current }
        guard let other = entry.other, other.tolerance == tolerance, other.shape == shape else { return nil }
        vertexCount += other.vertexCount - entry.current.vertexCount
        secondTierVertexCount += entry.current.vertexCount - other.vertexCount
        entry.other = entry.current
        entry.current = other
        entries[shape.id] = entry
        return other
    }

    /// Makes `t` the first tier for its shape. The old first tier moves to the second
    /// when it is the same shape at another tolerance; otherwise the second tier keeps
    /// only a tessellation of this shape at another tolerance.
    mutating func store(_ t: Tessellation) {
        let id = t.shape.id
        var other: Tessellation?
        if let old = entries[id] {
            vertexCount -= old.current.vertexCount
            secondTierVertexCount -= old.other?.vertexCount ?? 0
            other = [old.current, old.other].lazy.compactMap { $0 }
                .first { $0.tolerance != t.tolerance && $0.shape == t.shape }
        }
        vertexCount += t.vertexCount
        if vertexCount > secondTierLimit { other = nil }
        secondTierVertexCount += other?.vertexCount ?? 0
        entries[id] = Entry(current: t, other: other)
        if vertexCount > secondTierLimit, secondTierVertexCount > 0 { dropSecondTier() }
    }

    private mutating func dropSecondTier() {
        for id in entries.keys where entries[id]?.other != nil { entries[id]?.other = nil }
        secondTierVertexCount = 0
    }

    /// Forgets shape `id`.
    mutating func remove(_ id: Int) {
        guard let old = entries.removeValue(forKey: id) else { return }
        vertexCount -= old.current.vertexCount
        secondTierVertexCount -= old.other?.vertexCount ?? 0
    }

    /// Forgets the shapes not in `live`.
    mutating func removeAll(except live: Set<Int>) {
        for id in entries.keys where !live.contains(id) {
            guard let old = entries.removeValue(forKey: id) else { continue }
            vertexCount -= old.current.vertexCount
            secondTierVertexCount -= old.other?.vertexCount ?? 0
        }
    }

    // MARK: Refining in the background

    /// Tessellations made away from the cache, for `merge`.
    public struct Refinement: Sendable {
        public let tolerance: Double
        var tessellations: [Tessellation]

        public var count: Int { tessellations.count }
        public var shapeIDs: [Int] { tessellations.map(\.shape.id) }
    }

    /// The shapes a refine to `tolerance` has to tessellate, in two batches: those whose
    /// `hitBounds` meet `viewRect` grown by a quarter of its larger side, then the rest.
    /// Shapes this cache already holds at `tolerance` (in either tier) and hidden shapes
    /// are left out. With no `viewRect`, every shape is in `rest`. With `wholeParts`, a
    /// part with any shape in view puts all of its shapes in `visible`, so a build
    /// `leavingOutUncached` can show it once the first batch is merged.
    public struct RefinePlan: Sendable {
        public var visible: [VectorShape] = []
        public var rest: [VectorShape] = []
        public var isEmpty: Bool { visible.isEmpty && rest.isEmpty }
    }

    public func refinePlan(for drawing: Drawing, tolerance: Double, viewRect: Rect?,
                           wholeParts: Bool = false) -> RefinePlan {
        var plan = RefinePlan()
        let view = viewRect.map { $0.outset(by: max($0.width, $0.height) / 4) }
        for part in drawing.parts {
            let start = (visible: plan.visible.count, rest: plan.rest.count)
            for index in part.shapes.indices where part.isShown(index) {
                let shape = part.shapes[index]
                guard tessellation(of: shape, tolerance: tolerance) == nil else { continue }
                if let view, shape.hitBounds.intersects(view) {
                    plan.visible.append(shape)
                } else {
                    plan.rest.append(shape)
                }
            }
            if wholeParts, plan.visible.count > start.visible, plan.rest.count > start.rest {
                plan.visible.append(contentsOf: plan.rest[start.rest...])
                plan.rest.removeSubrange(start.rest...)
            }
        }
        return plan
    }

    /// Tessellates `shapes` at `tolerance`. Pure, so it can run off the main thread;
    /// returns nil as soon as `isCancelled` says so (checked between shapes).
    public static func tessellate(_ shapes: [VectorShape], tolerance: Double,
                                  isCancelled: () -> Bool = { false }) -> Refinement? {
        var made: [Tessellation] = []
        made.reserveCapacity(shapes.count)
        for shape in shapes {
            if isCancelled() { return nil }
            made.append(ArtBuilder.tessellate(shape, tolerance: tolerance))
        }
        return Refinement(tolerance: tolerance, tessellations: made)
    }

    /// Keeps each tessellation of `refinement` whose shape is still the one in
    /// `drawing`; one for a shape edited (or deleted) while the job ran is dropped, and
    /// the next build tessellates that shape as usual. Returns how many were kept.
    @discardableResult
    public mutating func merge(_ refinement: Refinement, for drawing: Drawing) -> Int {
        guard !refinement.tessellations.isEmpty else { return 0 }
        var made: [Int: Tessellation] = [:]
        made.reserveCapacity(refinement.tessellations.count)
        for t in refinement.tessellations { made[t.shape.id] = t }
        var kept = 0
        for part in drawing.parts {
            for shape in part.shapes {
                guard let t = made[shape.id], t.shape == shape else { continue }
                store(t)
                kept += 1
            }
        }
        return kept
    }
}
