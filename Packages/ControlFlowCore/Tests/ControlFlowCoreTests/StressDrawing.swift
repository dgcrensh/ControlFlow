import Foundation
@testable import ControlFlowCore

/// A large, deterministic character for the performance tests: a grid of layers, each
/// a stack of wobbly closed shapes with fills and outlines, some dashed outlines, a
/// clipped group per few layers, and accessories. The same arguments always make the
/// same drawing, so timings are comparable from run to run. Every vertex has an id, as in
/// a real document (`assignVertexIDs` runs on every commit): without them interpolation
/// treats every shape as reshaped and takes the slow vertex-merge fallback.
enum StressDrawing {
    /// The size the performance audit asks for, 40 layers × 60 shapes × 24 anchors, when
    /// the environment sets `STRESS_DRAWING=full`. Otherwise a quarter of the layers and
    /// shapes, so the debug build `swift test` runs on every CI job stays quick.
    static let isFull = ProcessInfo.processInfo.environment["STRESS_DRAWING"] == "full"
    static let layers = isFull ? 40 : 10
    static let shapesPerLayer = isFull ? 60 : 15
    static let anchorsPerShape = 24
    /// Spacing of the layer grid, in points.
    static let cell = 220.0
    static let columns = 8

    static func make(layers: Int = layers, shapesPerLayer: Int = shapesPerLayer,
                     anchorsPerShape: Int = anchorsPerShape) -> Drawing {
        var random = SeededRandom(seed: 0x5EED)
        var d = Drawing()
        d.name = "Stress"
        for p in 0..<layers {
            let center = Vec2(Double(p % columns) * cell, Double(p / columns) * cell)
            var layer = Layer(id: d.makeID(), name: "Layer \(p + 1)", pivot: center)
            for s in 0..<shapesPerLayer {
                let radius = 25 + random.next() * 70
                let offset = Vec2(random.next() - 0.5, random.next() - 0.5) * 60
                let path = blob(center: center + offset, radius: radius, anchors: anchorsPerShape, random: &random)
                let fill = RGBAColor(r: random.next(), g: random.next(), b: random.next())
                var stroke: StrokeStyle?
                if s % 3 != 2 {
                    stroke = StrokeStyle(color: .ink, width: 1 + random.next() * 4)
                    if s % 10 == 0 { stroke!.dash = [6, 4] }
                }
                layer.shapes.append(VectorShape(id: d.makeID(), path: path, fill: fill, stroke: stroke))
            }
            // Every fourth layer ends in a group of three: a base and two shapes clipped to it.
            if p % 4 == 0, layer.shapes.count >= 3 {
                let group = ShapeGroup(id: d.makeID(), name: "Group 1")
                layer.groups = [group]
                for i in layer.shapes.count - 3..<layer.shapes.count { layer.shapes[i].group = group.id }
                layer.shapes[layer.shapes.count - 2].isClipped = true
                layer.shapes[layer.shapes.count - 1].isClipped = true
            }
            d.layers.append(layer)
        }
        d.assignVertexIDs()
        return d
    }

    /// A presentation of `drawing` with `keyframes` keyframes after the opening state, each
    /// moving one layer (a layer transform) and recoloring one shape of another, as a deck
    /// of build-up slides would.
    static func presentation(_ drawing: Drawing, keyframes: Int) -> Presentation {
        var timeline = Timeline(Presentation(opening: drawing))
        var state = drawing
        for k in 1...keyframes {
            _ = timeline.insertKeyframe(after: k - 1)
            state.layers[k % state.layers.count].transform.position = Vec2(Double(k) * 3, 0)
            let recolored = (k * 7) % state.layers.count
            let shape = k % state.layers[recolored].shapes.count
            state.layers[recolored].shapes[shape].fill = RGBAColor(r: 0.1, g: Double(k % 10) / 10, b: 0.4)
            timeline.record(state, at: k)
        }
        return timeline.presentation
    }

    /// A presentation of `drawing` with one keyframe whose transition, 1 second long,
    /// leads to `end`.
    static func transition(from drawing: Drawing, to end: Drawing) -> Timeline {
        var timeline = Timeline(Presentation(opening: drawing))
        _ = timeline.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .easeInOut))
        timeline.record(end, at: 1)
        return timeline
    }

    /// The middle of the layer grid's bounds, on top of plenty of shapes.
    static func busyPoint(layers: Int = layers) -> Vec2 { Vec2(cell * 2, cell * Double(max(layers / columns - 1, 0)) / 2) }

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
