import XCTest
@testable import ControlFlowCore

/// The art tessellates each shape in its own space and draws it through its layer, group
/// and shape transforms (smoothness-profile.md, step 4).
final class LocalSpaceArtTests: XCTestCase {
    private let red = RGBAColor(r: 1, g: 0, b: 0)
    private let blue = RGBAColor(r: 0, g: 0, b: 1)
    private let green = RGBAColor(r: 0, g: 0.6, b: 0)

    private func square(_ x: Double, _ y: Double, _ size: Double) -> BezierPath {
        ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + size, y + size)))
    }

    /// A layer with a group, clipping, a gradient, inside outlines and every kind of
    /// transform: turns and uniform scales (drawn through `place`), a stretch of an
    /// outlined shape (baked) and of a filled one (drawn through `place`).
    private func transformed(layer: Transform) -> Drawing {
        var d = Drawing()
        var shapes: [VectorShape] = []
        var gradient = VectorShape(id: d.makeID(), path: square(0, 0, 20), fill: red)
        gradient.gradient = ShapeGradient(kind: .linear, start: Vec2(0, 0), end: Vec2(20, 0),
                                          stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 1, color: blue)])
        gradient.transform = Transform(position: Vec2(5, 0), rotation: 30, scale: Vec2(1.5, 1.5), pivot: Vec2(10, 10))
        shapes.append(gradient)
        var clipped = VectorShape(id: d.makeID(), path: ShapePrimitives.ellipse(Rect(minPoint: Vec2(10, 10),
                                                                                      maxPoint: Vec2(40, 30))),
                                  fill: green)
        clipped.isClipped = true
        clipped.transform = Transform(position: .zero, rotation: -20, pivot: Vec2(25, 20))
        shapes.append(clipped)
        var outlined = VectorShape(id: d.makeID(), path: ShapePrimitives.ellipse(Rect(minPoint: Vec2(40, 0),
                                                                                       maxPoint: Vec2(70, 20))),
                                   stroke: StrokeStyle(color: blue, width: 3, alignment: .inside))
        outlined.transform = Transform(position: Vec2(0, 10), rotation: 45, pivot: Vec2(55, 10))
        shapes.append(outlined)
        var stretched = VectorShape(id: d.makeID(), path: square(0, 40, 15), fill: green,
                                    stroke: StrokeStyle(color: red, width: 2))
        stretched.transform = Transform(position: .zero, rotation: 10, scale: Vec2(2, 0.7), pivot: Vec2(7, 47))
        shapes.append(stretched)
        let group = ShapeGroup(id: d.makeID(), name: "Group",
                               transform: Transform(position: Vec2(-4, 6), rotation: 15, pivot: Vec2(60, 50)))
        var skewed = VectorShape(id: d.makeID(), path: square(50, 40, 18), fill: blue)
        skewed.group = group.id
        skewed.transform = Transform(position: .zero, rotation: 0, scale: Vec2(1.8, 0.6), pivot: Vec2(59, 49))
        shapes.append(skewed)
        var member = VectorShape(id: d.makeID(), path: square(70, 45, 10), stroke: StrokeStyle(color: .ink, width: 2))
        member.group = group.id
        shapes.append(member)
        var l = Layer(id: d.makeID(), name: "Layer", shapes: shapes)
        l.groups = [group]
        l.transform = layer
        d.layers.append(l)
        return d
    }

    /// Paints `a` and `b` over `region` and returns the share of samples that differ:
    /// only samples within the flattening tolerance of an edge may.
    private func difference(_ a: ArtBatch, _ b: ArtBatch, over region: Rect, step: Double = 1.37) -> Double {
        var samples = 0, different = 0
        for x in stride(from: region.minPoint.x, through: region.maxPoint.x, by: step) {
            for y in stride(from: region.minPoint.y, through: region.maxPoint.y, by: step * 1.07) {
                let p = Vec2(x, y)
                let s = StencilSimulator.run(a, at: p), t = StencilSimulator.run(b, at: p)
                samples += 1
                XCTAssertEqual(s.stencil & 0x7F, 0, "\(p)")
                if abs(s.color.r - t.color.r) > 0.02 || abs(s.color.g - t.color.g) > 0.02 || abs(s.color.b - t.color.b) > 0.02 {
                    different += 1
                }
            }
        }
        return Double(different) / Double(samples)
    }

    private func worldArt(_ d: Drawing, tolerance: Double = 0.15) -> ArtBatch {
        var builder = ArtBuilder()
        return builder.build(d.world, isolatedLayer: nil, tolerance: tolerance)
    }

    func testTransformedShapesDrawLikeTheWorldDrawing() {
        let layer = Transform(position: Vec2(30, -10), rotation: -25, scale: Vec2(1.25, 1.25), pivot: Vec2(40, 30))
        let d = transformed(layer: layer)
        var builder = ArtBuilder()
        let art = builder.build(d, isolatedLayer: nil, tolerance: 0.15)
        XCTAssertEqual(art.segments.map(\.transform), [layer.matrix])
        let places = art.steps.filter { if case .place = $0 { true } else { false } }
        XCTAssertGreaterThan(places.count, 3)
        let region = Rect(points: d.world.layers[0].shapes.flatMap { $0.bounds.corners }).outset(by: 4)
        XCTAssertLessThan(difference(art, worldArt(d), over: region), 0.01)
    }

    /// A stretched layer with outlines or gradients takes its transform into the points,
    /// so they look as they do baked; one with only flat fills is drawn through it.
    func testAStretchedLayerWithOutlinesIsBaked() {
        let stretch = Transform(position: Vec2(10, 0), rotation: 20, scale: Vec2(2, 0.8), pivot: Vec2(30, 30))
        let d = transformed(layer: stretch)
        var builder = ArtBuilder()
        let art = builder.build(d, isolatedLayer: nil, tolerance: 0.15)
        XCTAssertEqual(art.segments.map(\.transform), [.identity])
        let region = Rect(points: d.world.layers[0].shapes.flatMap { $0.bounds.corners }).outset(by: 4)
        XCTAssertLessThan(difference(art, worldArt(d), over: region), 0.01)

        var fills = d
        for s in fills.layers[0].shapes.indices {
            fills.layers[0].shapes[s].stroke = nil
            fills.layers[0].shapes[s].gradient = nil
        }
        var fillBuilder = ArtBuilder()
        let fillArt = fillBuilder.build(fills, isolatedLayer: nil, tolerance: 0.15)
        XCTAssertEqual(fillArt.segments.map(\.transform), [stretch.matrix])
        XCTAssertLessThan(difference(fillArt, worldArt(fills), over: region), 0.01)
    }

    /// An image's picture is mapped from the space its vertices are in.
    func testAnImageIsMappedFromItsOwnSpace() throws {
        var d = Drawing()
        var shape = VectorShape(id: d.makeID(), path: square(0, 0, 40), fill: nil)
        shape.image = ShapeImage(src: "images/a.png")
        shape.transform = Transform(position: Vec2(100, 50), rotation: 30, pivot: Vec2(20, 20))
        d.layers.append(Layer(id: d.makeID(), name: "Layer", shapes: [shape]))
        var builder = ArtBuilder()
        let art = builder.build(d, isolatedLayer: nil, tolerance: 0.1)
        let image = try XCTUnwrap(art.steps.lazy.compactMap { step -> ArtImage? in
            if case .cover(_, let paint, _, _) = step { paint.image } else { nil }
        }.first)
        XCTAssertTrue(art.steps.contains(.place(shape.transform.matrix)))
        // The far corner of the square, in its own space, is the picture's far corner.
        let corner = image.worldToImage.apply(Vec2(40, 40))
        XCTAssertEqual(corner.x, 1, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 1, accuracy: 1e-9)
    }

    /// Sliding and turning every layer, as a whole-stage transition does each frame,
    /// flattens nothing and rebuilds no layer: only the segments' transforms change, and
    /// their ids (so the renderer's buffers) stay.
    func testMovingLayersFlattensAndRebuildsNothing() {
        let drawing = StressDrawing.make(layers: 4, shapesPerLayer: 6)
        var builder = ArtBuilder()
        let first = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        let (count, builds) = (builder.tessellationCount, builder.layerBuilds)
        var moved = drawing
        for l in moved.layers.indices {
            moved.layers[l].transform.position = Vec2(Double(l) * 40, 25)
            moved.layers[l].transform.rotation = 33
        }
        let next = builder.build(moved, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(builder.tessellationCount, count)
        XCTAssertEqual(builder.layerBuilds, builds)
        XCTAssertEqual(next.segments.map(\.id), first.segments.map(\.id))
        XCTAssertEqual(next.vertices, first.vertices)
        XCTAssertEqual(next.segments.map(\.transform), moved.layers.map(\.transform.matrix))
    }

    /// Moving one shape rebuilds its layer's steps from the cached triangles.
    func testMovingAShapeFlattensNothing() {
        let drawing = StressDrawing.make(layers: 3, shapesPerLayer: 6)
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        let (count, builds) = (builder.tessellationCount, builder.layerBuilds)
        var moved = drawing
        moved.layers[1].shapes[2].transform = Transform(position: Vec2(12, -3), rotation: 70,
                                                        pivot: moved.layers[1].shapes[2].bounds.center)
        let art = builder.build(moved, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(builder.tessellationCount, count)
        XCTAssertEqual(builder.layerBuilds, builds + 1)
        XCTAssertTrue(art.steps.contains(.place(moved.layers[1].shapes[2].transform.matrix)))
    }

    /// A shape is flattened finely enough for how much its transforms enlarge it, in
    /// powers of two: scaling it up flattens it again only past each doubling.
    func testScalingFlattensAgainOnlyPastAPowerOfTwo() throws {
        let drawing = StressDrawing.make(layers: 1, shapesPerLayer: 6)
        let id = try XCTUnwrap(drawing.layers[0].shapes.first?.id)
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        var flattened: [Int] = []
        for scale in [1.0, 1.3, 1.9, 2.0, 2.4, 0.7] {
            var d = drawing
            d.layers[0].transform.scale = Vec2(scale, scale)
            let before = builder.tessellationCount
            _ = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
            flattened.append(builder.tessellationCount - before)
        }
        let n = drawing.layers[0].shapes.count
        XCTAssertEqual(flattened, [0, n, 0, 0, n, n])
        XCTAssertEqual(builder.tessellations.tolerances(of: id).first, 0.5)
    }

    func testDetailIsTheLargestStretchRoundedUpToAPowerOfTwo() {
        XCTAssertEqual(ArtBuilder.detail(of: .identity), 1)
        XCTAssertEqual(ArtBuilder.detail(of: .rotation(0.7)), 1)
        XCTAssertEqual(ArtBuilder.detail(of: .rotation(0.7) * .scale(1.5)), 2)
        XCTAssertEqual(ArtBuilder.detail(of: .scale(2)), 2)
        XCTAssertEqual(ArtBuilder.detail(of: .scale(0.5)), 0.5)
        XCTAssertEqual(ArtBuilder.detail(of: .scale(0.6)), 1)
        XCTAssertEqual(ArtBuilder.detail(of: .scale(x: 3, y: 0.1)), 4)
        XCTAssertEqual(ArtBuilder.detail(of: .scale(0)), 1, "collapsed")
    }

    /// A refine plans each shape at its own tolerance, and finds what is in view by where
    /// the shape is drawn.
    func testARefinePlansShapesAtTheirOwnTolerance() {
        var d = Drawing()
        let near = VectorShape(id: d.makeID(), path: square(0, 0, 10), fill: red)
        let far = VectorShape(id: d.makeID(), path: square(500, 0, 10), fill: red)
        var layer = Layer(id: d.makeID(), name: "Layer", shapes: [near, far])
        // Doubles the layer and slides the far square into view at (-10...10, 0...20).
        layer.transform = Transform(position: Vec2(-1010, 0), scale: Vec2(2, 2))
        d.layers.append(layer)
        let plan = TessellationCache().refinePlan(for: d, tolerance: 0.2, viewRect: Rect(minPoint: Vec2(-10, 0),
                                                                                         maxPoint: Vec2(10, 20)))
        XCTAssertEqual(plan.visible.map(\.id), [far.id])
        XCTAssertEqual(plan.rest.map(\.id), [near.id])
        XCTAssertEqual(plan.visible.map(\.tolerance), [0.1])
    }
}
