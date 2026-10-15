import XCTest
@testable import ControlFlowCore

/// A drawing of a body layer of two shapes (with a hat on top), and a separate arm.
private func editor() -> DrawingEditor {
    var d = Drawing()
    func shape(_ r: Rect) -> VectorShape {
        VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink, stroke: StrokeStyle(color: .ink, width: 2))
    }
    func add(_ name: String, _ shapes: [VectorShape], pivot: Vec2) {
        d.layers.append(Layer(id: d.makeID(), name: name, shapes: shapes, pivot: pivot))
    }
    let body = Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(100, 100))
    add("Body", [shape(body), shape(Rect(minPoint: Vec2(20, -20), maxPoint: Vec2(80, 0)))], pivot: body.center)
    let arm = Rect(minPoint: Vec2(200, 0), maxPoint: Vec2(220, 100))
    add("Arm", [shape(arm)], pivot: arm.center)
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

final class LiveTransformTests: XCTestCase {
    func testAMoveDragReportsItsTransformUntilItEnds() throws {
        var e = editor()
        let body = e.drawing.layers[0]
        e.selection = .layer(body.id)
        let before = e.drawing
        // Off the pivot, which sits in the middle.
        e.pencilBegan(at: Vec2(30, 60), zoom: 1)
        XCTAssertNil(e.liveTransform, "a press is not a drag yet")
        e.pencilMoved(to: Vec2(40, 65))
        let first = try XCTUnwrap(e.liveTransform)
        XCTAssertEqual(first.base, before)
        XCTAssertEqual(first.shapes, Set(body.shapes.map(\.id)))
        XCTAssertEqual(first.transform, .translation(Vec2(10, 5)))
        XCTAssertTrue(first.movesTessellation)
        // The drawing still moves on every sample, for everything but the art.
        XCTAssertEqual(e.drawing, before.applying(first.transform, to: .layer(body.id)))

        e.pencilMoved(to: Vec2(60, 60))
        let second = try XCTUnwrap(e.liveTransform)
        XCTAssertEqual(second.id, first.id, "one drag, one base")
        XCTAssertEqual(second.transform, .translation(Vec2(30, 0)))
        e.pencilEnded(at: Vec2(60, 60))
        XCTAssertNil(e.liveTransform)

        e.pencilBegan(at: Vec2(60, 60), zoom: 1)
        e.pencilMoved(to: Vec2(70, 60))
        XCTAssertNotEqual(e.liveTransform?.id, first.id, "the next drag starts over")
        XCTAssertEqual(e.liveTransform?.base, e.drawing.applying(.translation(Vec2(-10, 0)), to: .layer(body.id)))
        e.pencilCancelled()
        XCTAssertNil(e.liveTransform)
    }

    func testOnlyShapeDragsAreLive() {
        var e = editor()
        let arm = e.drawing.layers[1]
        e.selection = .shape(layer: arm.id, shape: arm.shapes[0].id)
        e.pencilBegan(at: Vec2(210, 20), zoom: 1)
        e.pencilMoved(to: Vec2(215, 20))
        XCTAssertEqual(e.liveTransform?.shapes, [arm.shapes[0].id])
        e.pencilEnded(at: Vec2(215, 20))

        // Other drags, such as a marquee, have none.
        e.selection = .none
        e.pencilBegan(at: Vec2(150, 150), zoom: 1)
        e.pencilMoved(to: Vec2(170, 170))
        XCTAssertNil(e.liveTransform)
        e.pencilEnded(at: Vec2(170, 170))
    }

    func testWhichTransformsMoveTheTessellation() {
        func live(_ t: Affine2D) -> LiveTransform {
            LiveTransform(id: 1, base: Drawing(), shapes: [1], transform: t)
        }
        XCTAssertTrue(live(.translation(Vec2(5, 5))).movesTessellation)
        XCTAssertTrue(live(.rotation(1.2) * .scale(1.5)).movesTessellation)
        XCTAssertTrue(live(.scale(0.1)).movesTessellation, "shrinking keeps the flattening fine enough")
        XCTAssertTrue(live(.scale(x: -1, y: 1)).movesTessellation, "a mirror image")
        XCTAssertFalse(live(.scale(3)).movesTessellation, "too coarse when enlarged that much")
        XCTAssertFalse(live(.scale(x: 2, y: 1)).movesTessellation, "a stretch thins and thickens outlines")
        XCTAssertFalse(live(.scale(0)).movesTessellation)
    }
}

/// When a live drag ends, `ArtBuilder.carry` moves the dragged shapes' tessellations
/// instead of dropping them (performance-next.md, recommendation 3).
final class CarryTessellationTests: XCTestCase {
    private let base = StressDrawing.make(layers: 4, shapesPerLayer: 6)
    private let tolerance = 0.5

    /// Layer 1 moved by `t`, as a drag of that layer leaves it.
    private func drag(_ t: Affine2D, from drawing: Drawing? = nil) -> LiveTransform {
        let d = drawing ?? base
        let selection = Selection.layer(d.layers[1].id)
        return LiveTransform(id: 1, base: d, shapes: LiveTransform.shapes(of: selection, in: d)!, transform: t)
    }

    private func moved(_ live: LiveTransform) -> Drawing {
        live.base.applying(live.transform, to: .layer(live.base.layers[1].id))
    }

    /// Builds the drag's base, carries, and builds the moved drawing. Returns the builder
    /// and that build, and how many shapes the build tessellated.
    private func carryAndBuild(_ live: LiveTransform, to after: Drawing, reusing: Bool = false)
        -> (builder: ArtBuilder, carry: ArtBuilder.Carry, batch: ArtBatch, tessellated: Int) {
        var builder = ArtBuilder()
        _ = builder.build(live.base, isolatedLayer: nil, tolerance: tolerance, moving: live.shapes)
        let count = builder.tessellationCount
        let carry = builder.carry(live, to: after)
        let batch = builder.build(after, isolatedLayer: nil, tolerance: tolerance, reusingOtherTolerances: reusing)
        return (builder, carry, batch, builder.tessellationCount - count)
    }

    /// The carried build draws the same steps as a cold build of the moved drawing, with
    /// every vertex within `slack` of the cold one.
    private func assertMatchesColdBuild(_ batch: ArtBatch, of drawing: Drawing, slack: Float,
                                        file: StaticString = #filePath, line: UInt = #line) {
        var cold = ArtBuilder()
        let fresh = cold.build(drawing, isolatedLayer: nil, tolerance: tolerance)
        XCTAssertEqual(batch.vertices.count, fresh.vertices.count, file: file, line: line)
        guard batch.vertices.count == fresh.vertices.count else { return }
        let worst = zip(batch.vertices, fresh.vertices).map { abs($0 - $1) }.max() ?? 0
        XCTAssertLessThanOrEqual(worst, slack, file: file, line: line)
        XCTAssertEqual(batch.segments.map(\.vertices), fresh.segments.map(\.vertices), file: file, line: line)
        XCTAssertEqual(batch.steps, fresh.steps, file: file, line: line)
    }

    func testAMoveCarriesEveryMovedShape() {
        let live = drag(.translation(Vec2(37.25, -12.5)))
        let after = moved(live)
        let (_, carry, batch, tessellated) = carryAndBuild(live, to: after)
        XCTAssertEqual(carry.carried, live.shapes.count)
        XCTAssertEqual(carry.coarse, 0)
        XCTAssertEqual(tessellated, 0, "nothing is flattened again on lift")
        assertMatchesColdBuild(batch, of: after, slack: 1e-3)
    }

    func testARotationCarriesEveryMovedShape() {
        let pivot = base.layers[1].pivot
        let turn = Affine2D.translation(pivot) * .rotation(0.7) * .translation(Vec2(-pivot.x, -pivot.y))
        let live = drag(turn)
        let after = moved(live)
        let (_, carry, batch, tessellated) = carryAndBuild(live, to: after)
        XCTAssertEqual(carry.carried, live.shapes.count)
        XCTAssertEqual(tessellated, 0)
        // A turned curve may flatten into a slightly different polygon, but no further
        // from the curve than the tolerance; the triangles stay where the shapes are.
        var cold = ArtBuilder()
        let fresh = cold.build(after, isolatedLayer: nil, tolerance: tolerance)
        XCTAssertEqual(batch.segments.count, fresh.segments.count)
        assertBoundsMatch(batch, fresh, slack: tolerance * 2)
    }

    func testShrinkingKeepsTheToleranceAndEnlargingMarksTheShapesCoarse() throws {
        let shrink = drag(.scale(0.5))
        let small = carryAndBuild(shrink, to: moved(shrink))
        XCTAssertEqual(small.carry.coarse, 0)
        XCTAssertEqual(small.tessellated, 0)

        let grow = drag(.scale(1.5))
        let after = moved(grow)
        var result = carryAndBuild(grow, to: after, reusing: true)
        XCTAssertEqual(result.carry.carried, grow.shapes.count)
        XCTAssertEqual(result.carry.coarse, grow.shapes.count)
        XCTAssertEqual(result.tessellated, 0, "a build reusing other tolerances keeps the coarse triangles")
        let id = try XCTUnwrap(grow.shapes.first)
        XCTAssertEqual(result.builder.tessellations.tolerances(of: id), [tolerance * 1.5])
        // A refine at the art's tolerance picks up exactly the enlarged shapes.
        let plan = result.builder.tessellations.refinePlan(for: after, tolerance: tolerance, viewRect: nil)
        XCTAssertEqual(Set(plan.rest.map(\.id)), grow.shapes)
        // Without reusing, the next build flattens them at the art's tolerance.
        result = carryAndBuild(grow, to: after)
        XCTAssertEqual(result.tessellated, grow.shapes.count)
    }

    func testAStretchIsNotCarried() {
        let live = drag(.scale(x: 2, y: 1))
        let after = moved(live)
        let (_, carry, batch, tessellated) = carryAndBuild(live, to: after)
        XCTAssertEqual(carry, ArtBuilder.Carry())
        XCTAssertEqual(tessellated, live.shapes.count)
        assertMatchesColdBuild(batch, of: after, slack: 0)
    }

    func testAShapeTheLiftChangedIsTessellatedAgain() throws {
        let live = drag(.translation(Vec2(10, 0)))
        var after = moved(live)
        after.layers[1].shapes[2].fill = RGBAColor(r: 0, g: 0, b: 1)
        let (_, carry, batch, tessellated) = carryAndBuild(live, to: after)
        XCTAssertEqual(carry.carried, live.shapes.count - 1)
        XCTAssertEqual(tessellated, 1)
        assertMatchesColdBuild(batch, of: after, slack: 1e-3)
    }

    func testRepeatedCarriesFlattenAgainAfterTheLimit() {
        var builder = ArtBuilder()
        var drawing = base
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: tolerance)
        var carried: [Int] = []
        for _ in 0...ArtBuilder.maximumCarries {
            let live = drag(.translation(Vec2(3, 1)), from: drawing)
            drawing = moved(live)
            carried.append(builder.carry(live, to: drawing).carried)
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: tolerance)
        }
        let n = drag(.identity).shapes.count
        XCTAssertEqual(carried, Array(repeating: n, count: ArtBuilder.maximumCarries) + [0])
    }

    private func assertBoundsMatch(_ a: ArtBatch, _ b: ArtBatch, slack: Double,
                                   file: StaticString = #filePath, line: UInt = #line) {
        func bounds(_ v: [Float]) -> Rect {
            Rect(points: stride(from: 0, to: v.count - 1, by: 2).map { Vec2(Double(v[$0]), Double(v[$0 + 1])) })
        }
        for (x, y) in zip(a.segments, b.segments) {
            let p = bounds(x.floats), q = bounds(y.floats)
            XCTAssertEqual(p.minPoint.x, q.minPoint.x, accuracy: slack, file: file, line: line)
            XCTAssertEqual(p.minPoint.y, q.minPoint.y, accuracy: slack, file: file, line: line)
            XCTAssertEqual(p.maxPoint.x, q.maxPoint.x, accuracy: slack, file: file, line: line)
            XCTAssertEqual(p.maxPoint.y, q.maxPoint.y, accuracy: slack, file: file, line: line)
        }
    }
}
