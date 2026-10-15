import Foundation
@testable import ControlFlowCore

/// A large, deterministic character for the performance tests: a grid of parts, each
/// a stack of wobbly closed shapes with fills and outlines, some dashed outlines, a
/// clipped group per few parts, and accessories. The same arguments always make the
/// same drawing, so timings are comparable from run to run.
enum StressDrawing {
    /// The size the performance audit asks for, 40 parts × 60 shapes × 24 anchors, when
    /// the environment sets `STRESS_DRAWING=full`. Otherwise a quarter of the parts and
    /// shapes, so the debug build `swift test` runs on every CI job stays quick.
    static let isFull = ProcessInfo.processInfo.environment["STRESS_DRAWING"] == "full"
    static let parts = isFull ? 40 : 10
    static let shapesPerPart = isFull ? 60 : 15
    static let anchorsPerShape = 24
    /// Spacing of the part grid, in points.
    static let cell = 220.0
    static let columns = 8

    static func make(parts: Int = parts, shapesPerPart: Int = shapesPerPart,
                     anchorsPerShape: Int = anchorsPerShape) -> Drawing {
        var random = SeededRandom(seed: 0x5EED)
        var d = Drawing()
        d.name = "Stress"
        for p in 0..<parts {
            let center = Vec2(Double(p % columns) * cell, Double(p / columns) * cell)
            var part = Part(id: d.makeID(), name: "Part \(p + 1)", pivot: center)
            for s in 0..<shapesPerPart {
                let radius = 25 + random.next() * 70
                let offset = Vec2(random.next() - 0.5, random.next() - 0.5) * 60
                let path = blob(center: center + offset, radius: radius, anchors: anchorsPerShape, random: &random)
                let fill = RGBAColor(r: random.next(), g: random.next(), b: random.next())
                var stroke: StrokeStyle?
                if s % 3 != 2 {
                    stroke = StrokeStyle(color: .ink, width: 1 + random.next() * 4)
                    if s % 10 == 0 { stroke!.dash = [6, 4] }
                }
                part.shapes.append(VectorShape(id: d.makeID(), path: path, fill: fill, stroke: stroke))
            }
            // Every fourth part ends in a group of three: a base and two shapes clipped to it.
            if p % 4 == 0, part.shapes.count >= 3 {
                let group = ShapeGroup(id: d.makeID(), name: "Group 1")
                part.groups = [group]
                for i in part.shapes.count - 3..<part.shapes.count { part.shapes[i].group = group.id }
                part.shapes[part.shapes.count - 2].isClipped = true
                part.shapes[part.shapes.count - 1].isClipped = true
            }
            d.parts.append(part)
        }
        return d
    }

    /// The middle of the part grid's bounds, on top of plenty of shapes.
    static func busyPoint(parts: Int = parts) -> Vec2 { Vec2(cell * 2, cell * Double(max(parts / columns - 1, 0)) / 2) }

    /// Well outside every shape.
    static let emptyPoint = Vec2(-1000, -1000)

    /// A closed smooth path of `anchors` points on a wobbly circle.
    private static func blob(center: Vec2, radius: Double, anchors: Int, random: inout SeededRandom) -> BezierPath {
        let step = 2 * Double.pi / Double(anchors)
        // The handle length that makes a circle from `anchors` cubic segments.
        let handle = 4.0 / 3 * tan(step / 4)
        let points = (0..<anchors).map { i -> PathPoint in
            let angle = Double(i) * step
            let r = radius * (0.85 + random.next() * 0.3)
            let direction = Vec2(cos(angle), sin(angle))
            let tangent = Vec2(-sin(angle), cos(angle)) * (r * handle)
            return PathPoint(center + direction * r, in: tangent * -1, out: tangent)
        }
        return BezierPath(points: points, closed: true)
    }
}

/// A small linear congruential generator, so the stress drawing doesn't depend on the
/// platform's random numbers.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    /// A number in 0..<1.
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
}
