import XCTest
@testable import ControlFlowCore

/// The art's tessellation cache and the background refine that `CanvasRenderer` runs
/// when a pinch crosses a zoom bucket (plan step 1).
final class TessellationCacheTests: XCTestCase {
    private static func circle(_ center: Vec2, _ r: Double) -> BezierPath {
        let k = 0.5523 * r
        return BezierPath(points: [
            PathPoint(center + Vec2(r, 0), in: Vec2(0, -k), out: Vec2(0, k)),
            PathPoint(center + Vec2(0, r), in: Vec2(k, 0), out: Vec2(-k, 0)),
            PathPoint(center + Vec2(-r, 0), in: Vec2(0, k), out: Vec2(0, -k)),
            PathPoint(center + Vec2(0, -r), in: Vec2(-k, 0), out: Vec2(k, 0)),
        ], closed: true)
    }

    /// A row of circles 100 points apart, alternately filled and outlined, with the
    /// first two shapes of the second layer clipped (a base and a clipped shape).
    private static func row(count: Int = 8) -> Drawing {
        var d = Drawing()
        var layers = [Layer(id: d.makeID(), name: "A"), Layer(id: d.makeID(), name: "B")]
        for i in 0..<count {
            let colors = [RGBAColor(r: 1, g: 0, b: 0), RGBAColor(r: 0, g: 0, b: 1), RGBAColor(r: 0, g: 0.6, b: 0)]
            var shape = VectorShape(id: d.makeID(), path: circle(Vec2(Double(i) * 100, 0), 40),
                                    fill: colors[i % 3],
                                    stroke: i % 2 == 0 ? StrokeStyle(color: .ink, width: 6) : nil)
            if i == count / 2 + 1 { shape.isClipped = true }
            layers[i < count / 2 ? 0 : 1].shapes.append(shape)
        }
        // The clipped shape overlaps its base.
        layers[1].shapes[1].path = circle(Vec2(Double(count / 2) * 100 + 30, 0), 40)
        d.layers = layers
        return d
    }

    private static func ids(_ d: Drawing) -> [Int] { d.layers.flatMap { $0.shapes.map(\.id) } }

    /// The same vertices and steps; segment ids are per builder, so they aren't compared.
    private func assertSameArt(_ a: ArtBatch, _ b: ArtBatch, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.vertices, b.vertices, file: file, line: line)
        XCTAssertEqual(a.steps, b.steps, file: file, line: line)
    }

    // MARK: Merge

    func testMergeKeepsUnchangedShapesAndTheWarmBuildTessellatesNothing() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        let plan = builder.tessellations.refinePlan(for: drawing, tolerance: 0.1, viewRect: nil)
        XCTAssertEqual(plan.rest.count, drawing.shapeCount)
        let result = TessellationCache.tessellate(plan.rest, tolerance: 0.1)!
        XCTAssertEqual(builder.tessellations.merge(result, for: drawing), drawing.shapeCount)

        builder.tessellationCount = 0
        let warm = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1)
        XCTAssertEqual(builder.tessellationCount, 0)
        var cold = ArtBuilder()
        assertSameArt(warm, cold.build(drawing, isolatedLayer: nil, tolerance: 0.1))
    }

    func testMergeDropsAShapeEditedWhileTheJobRan() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        let job = builder.tessellations
        let result = TessellationCache.tessellate(job.refinePlan(for: drawing, tolerance: 0.1, viewRect: nil).rest,
                                                  tolerance: 0.1)!

        // Meanwhile on the main thread: one shape is edited, another deleted, and the
        // edit is built at the old tolerance.
        var edited = drawing
        edited.layers[0].shapes[1].path = Self.circle(Vec2(100, 0), 20)
        let deleted = edited.layers[1].shapes.removeLast().id
        _ = builder.build(edited, isolatedLayer: nil, tolerance: 1)

        XCTAssertEqual(builder.tessellations.merge(result, for: edited), edited.shapeCount - 1)
        let shape = edited.layers[0].shapes[1]
        XCTAssertNil(builder.tessellations.tessellation(of: shape, tolerance: 0.1))
        XCTAssertNotNil(builder.tessellations.tessellation(of: shape, tolerance: 1))
        XCTAssertTrue(builder.tessellations.tolerances(of: deleted).isEmpty)
        XCTAssertNotNil(builder.tessellations.tessellation(of: edited.layers[0].shapes[0], tolerance: 0.1))

        // The next build at the new tolerance tessellates only the edited shape.
        builder.tessellationCount = 0
        let warm = builder.build(edited, isolatedLayer: nil, tolerance: 0.1)
        XCTAssertEqual(builder.tessellationCount, 1)
        var cold = ArtBuilder()
        assertSameArt(warm, cold.build(edited, isolatedLayer: nil, tolerance: 0.1))
    }

    func testACancelledJobReturnsNothing() {
        let drawing = Self.row()
        let shapes = drawing.layers.flatMap(\.shapes)
        var calls = 0
        XCTAssertNil(TessellationCache.tessellate(shapes, tolerance: 0.1) {
            calls += 1
            return calls > 3
        })
        XCTAssertEqual(calls, 4)
    }

    // MARK: Visible first

    func testThePlanPutsTheShapesMeetingTheViewFirst() {
        let drawing = Self.row(count: 12)
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        // 160 × 80 around x = 300: grown by a quarter of 160, it reaches x = 180...420.
        let view = Rect(minPoint: Vec2(220, -40), maxPoint: Vec2(380, 40))
        let plan = builder.tessellations.refinePlan(for: drawing, tolerance: 0.1, viewRect: view)
        let grown = view.outset(by: 40)
        let meeting = drawing.layers.flatMap(\.shapes).filter { $0.hitBounds.intersects(grown) }.map(\.id)
        XCTAssertEqual(plan.visible.map(\.id), meeting)
        XCTAssertEqual(Set(meeting), Set(drawing.layers.flatMap(\.shapes).filter {
            let x = $0.path.points[2].position.x + 40 // the circle's center
            return x > 100 && x < 500
        }.map(\.id)))
        XCTAssertEqual(Set(plan.visible.map(\.id) + plan.rest.map(\.id)), Set(Self.ids(drawing)))
        XCTAssertTrue(Set(plan.visible.map(\.id)).isDisjoint(with: plan.rest.map(\.id)))

        // The first result is exactly those shapes.
        let first = TessellationCache.tessellate(plan.visible, tolerance: 0.1)!
        XCTAssertEqual(first.shapeIDs, meeting)
    }

    func testThePlanSkipsHiddenShapesAndShapesAlreadyAtTheTolerance() {
        var drawing = Self.row()
        drawing.layers[0].shapes[0].isHidden = true
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        var plan = builder.tessellations.refinePlan(for: drawing, tolerance: 1, viewRect: nil)
        XCTAssertTrue(plan.isEmpty)
        plan = builder.tessellations.refinePlan(for: drawing, tolerance: 0.1, viewRect: nil)
        XCTAssertEqual(plan.rest.count, drawing.shapeCount - 1)
        XCTAssertFalse(plan.rest.contains { $0.id == drawing.layers[0].shapes[0].id })
    }

    // MARK: Mixed tolerances

    /// While a refine is under way, the renderer builds with some shapes at the new
    /// tolerance and the rest at the old one. That draws the same picture as an all-fine
    /// build, except within the coarse flattening's error of an edge.
    func testAMixedToleranceBuildDrawsLikeAnAllFineBuild() {
        let drawing = Self.row(count: 8)
        let coarse = 4.0, fine = 0.1
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: coarse)
        // Refine the shapes around x = 300...500 (both layers, including the clip base
        // and its clipped shape), as the job's first result would.
        let view = Rect(minPoint: Vec2(330, -40), maxPoint: Vec2(470, 40))
        let plan = builder.tessellations.refinePlan(for: drawing, tolerance: fine, viewRect: view)
        XCTAssertFalse(plan.visible.isEmpty)
        XCTAssertFalse(plan.rest.isEmpty)
        builder.tessellations.merge(TessellationCache.tessellate(plan.visible, tolerance: fine)!, for: drawing)

        builder.tessellationCount = 0
        let mixed = builder.build(drawing, isolatedLayer: nil, tolerance: fine, reusingOtherTolerances: true)
        XCTAssertEqual(builder.tessellationCount, 0, "a mixed build reuses the coarse shapes")
        for shape in plan.visible {
            XCTAssertEqual(builder.tessellations.tolerances(of: shape.id).first, fine)
        }
        for shape in plan.rest {
            XCTAssertEqual(builder.tessellations.tolerances(of: shape.id), [coarse])
        }
        var allFine = ArtBuilder()
        let expected = allFine.build(drawing, isolatedLayer: nil, tolerance: fine)
        XCTAssertNotEqual(mixed, expected)

        // Points near an edge (within the coarse error and the outline) may differ.
        let polygons = drawing.layers.flatMap(\.shapes).map { $0.path.flattened(tolerance: 0.25) }
        func nearAnEdge(_ p: Vec2) -> Bool {
            polygons.contains { poly in
                (0..<poly.count).contains { i in p.distance(toSegment: poly[i], poly[(i + 1) % poly.count]) < coarse + 4.5 }
            }
        }
        var compared = 0
        for x in stride(from: -50.0, through: 750, by: 10) {
            for y in stride(from: -50.0, through: 50, by: 10) {
                let p = Vec2(x, y)
                guard !nearAnEdge(p) else { continue }
                let a = StencilSimulator.run(mixed, at: p), b = StencilSimulator.run(expected, at: p)
                XCTAssertTrue(a.isColor(RGBAColor(r: b.color.r, g: b.color.g, b: b.color.b)), "at \(p)")
                compared += 1
            }
        }
        XCTAssertGreaterThan(compared, 300)
    }

    // MARK: First frame after opening

    /// The renderer's first build after opening has nothing cached: leaving out the
    /// uncached layers, it draws nothing and tessellates nothing.
    func testAColdBuildLeavingOutUncachedTessellatesNothing() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        let batch = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1, reusingOtherTolerances: true,
                                  leavingOutUncached: true)
        XCTAssertTrue(batch.steps.isEmpty)
        XCTAssertTrue(batch.segments.isEmpty)
        XCTAssertEqual(batch.layersLeftOut, drawing.layers.count)
        XCTAssertEqual(builder.tessellationCount, 0)
        XCTAssertEqual(builder.cachedShapeCount, 0)
    }

    /// With `wholeLayers`, the job's first batch is every layer in view, whole, so each
    /// merge shows complete layers: first those in view, then the rest. Neither build
    /// tessellates anything, and the last draws what a cold build draws.
    func testTheFirstFrameShowsWholeLayersAsTheJobMerges() {
        var drawing = Self.row()
        // A hidden shape never gets a tessellation, and doesn't hold its layer back.
        drawing.layers[0].shapes[3].isHidden = true
        // Around the first two circles of layer A only.
        let view = Rect(minPoint: Vec2(-40, -40), maxPoint: Vec2(60, 40))
        var builder = ArtBuilder()
        let byShape = builder.tessellations.refinePlan(for: drawing, tolerance: 0.1, viewRect: view)
        XCTAssertEqual(byShape.visible.count, 2)
        let plan = builder.tessellations.refinePlan(for: drawing, tolerance: 0.1, viewRect: view, wholeLayers: true)
        XCTAssertEqual(plan.visible.map(\.id), drawing.layers[0].shapes.prefix(3).map(\.id))
        XCTAssertEqual(plan.rest.map(\.id), drawing.layers[1].shapes.map(\.id))

        builder.tessellations.merge(TessellationCache.tessellate(plan.visible, tolerance: 0.1)!, for: drawing)
        let first = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1, reusingOtherTolerances: true,
                                  leavingOutUncached: true)
        XCTAssertEqual(first.layersLeftOut, 1)
        var onlyA = drawing
        onlyA.layers.removeLast()
        var reference = ArtBuilder()
        assertSameArt(first, reference.build(onlyA, isolatedLayer: nil, tolerance: 0.1))

        builder.tessellations.merge(TessellationCache.tessellate(plan.rest, tolerance: 0.1)!, for: drawing)
        let all = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1, reusingOtherTolerances: true,
                                leavingOutUncached: true)
        XCTAssertEqual(all.layersLeftOut, 0)
        XCTAssertEqual(builder.tessellationCount, 0)
        var cold = ArtBuilder()
        assertSameArt(all, cold.build(drawing, isolatedLayer: nil, tolerance: 0.1))
    }

    /// A layer waiting for the job keeps the slot and tessellations it had, so an edit
    /// made before the job finishes is built as usual once the renderer stops leaving out.
    func testAnEditedLayerWaitsAndIsBuiltOnceTheJobIsDone() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        let plan = builder.tessellations.refinePlan(for: drawing, tolerance: 0.1, viewRect: nil, wholeLayers: true)
        builder.tessellations.merge(TessellationCache.tessellate(plan.rest, tolerance: 0.1)!, for: drawing)
        var edited = drawing
        edited.layers[0].shapes[1].path = Self.circle(Vec2(100, 0), 20)
        let waiting = builder.build(edited, isolatedLayer: nil, tolerance: 0.1, reusingOtherTolerances: true,
                                    leavingOutUncached: true)
        XCTAssertEqual(waiting.layersLeftOut, 1)
        XCTAssertEqual(builder.tessellationCount, 0)

        let done = builder.build(edited, isolatedLayer: nil, tolerance: 0.1)
        XCTAssertEqual(done.layersLeftOut, 0)
        XCTAssertEqual(builder.tessellationCount, 1)
        var cold = ArtBuilder()
        assertSameArt(done, cold.build(edited, isolatedLayer: nil, tolerance: 0.1))
    }

    // MARK: Second tier

    func testASecondTierMakesABucketBackAndForthWarm() {
        let drawing = Self.row()
        let n = drawing.shapeCount
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2)
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1)
        XCTAssertEqual(builder.tessellationCount, 2 * n)
        XCTAssertGreaterThan(builder.tessellations.secondTierVertexCount, 0)
        let back = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2)
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1)
        XCTAssertEqual(builder.tessellationCount, 2 * n)
        var cold = ArtBuilder()
        assertSameArt(back, cold.build(drawing, isolatedLayer: nil, tolerance: 0.2))

        // A third tolerance pushes out the least recently used one.
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.05)
        XCTAssertEqual(builder.tessellations.tolerances(of: drawing.layers[0].shapes[0].id), [0.05, 0.1])
        XCTAssertEqual(builder.tessellationCount, 3 * n)
    }

    func testTheSecondTierIsDroppedAboveTheVertexLimit() {
        let drawing = Self.row()
        let n = drawing.shapeCount
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.05)
        XCTAssertGreaterThan(builder.tessellations.secondTierVertexCount, 0)

        // Lowering the limit below what the first tier holds drops the second tier.
        builder.tessellations.secondTierLimit = builder.tessellations.vertexCount - 1
        XCTAssertEqual(builder.tessellations.secondTierVertexCount, 0)
        for id in Self.ids(drawing) { XCTAssertEqual(builder.tessellations.tolerances(of: id), [0.05]) }

        // A coarser tolerance holds fewer vertices, so it can keep the fine one below it...
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        XCTAssertEqual(builder.tessellationCount, 3 * n)
        XCTAssertGreaterThan(builder.tessellations.secondTierVertexCount, 0)
        // ...but no limit leaves room for none.
        builder.tessellations.secondTierLimit = 0
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.05)
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 1)
        XCTAssertEqual(builder.tessellationCount, 5 * n)
        XCTAssertEqual(builder.tessellations.secondTierVertexCount, 0)
    }

    func testVertexCountsFollowDeletedShapes() {
        var drawing = Self.row()
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2)
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1)
        drawing.layers.removeLast()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.1)
        var expected = ArtBuilder()
        _ = expected.build(drawing, isolatedLayer: nil, tolerance: 0.2)
        _ = expected.build(drawing, isolatedLayer: nil, tolerance: 0.1)
        XCTAssertEqual(builder.tessellations.count, drawing.shapeCount)
        XCTAssertEqual(builder.tessellations.vertexCount, expected.tessellations.vertexCount)
        XCTAssertEqual(builder.tessellations.secondTierVertexCount, expected.tessellations.secondTierVertexCount)
    }

    // MARK: Geometry-only matching

    /// Fill, gradient, opacity and outline color are paint: changing them, as a color
    /// fade does every frame, reuses every tessellation, and the art is what a cold
    /// builder makes.
    func testPaintChangesFlattenNothing() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        var painted = drawing
        for l in painted.layers.indices {
            for s in painted.layers[l].shapes.indices {
                painted.layers[l].shapes[s].fill = RGBAColor(r: 0.2, g: 0.4, b: 0.6)
                painted.layers[l].shapes[s].opacity = 0.5
                painted.layers[l].shapes[s].stroke?.color = RGBAColor(r: 0, g: 1, b: 0)
            }
        }
        painted.layers[0].shapes[0].gradient = ShapeGradient(kind: .linear, start: Vec2(-40, 0), end: Vec2(40, 0),
                                                             stops: [GradientStop(offset: 0, color: .black),
                                                                     GradientStop(offset: 1, color: .ink)])
        builder.tessellationCount = 0
        let art = builder.build(painted, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(builder.tessellationCount, 0)
        var cold = ArtBuilder()
        assertSameArt(art, cold.build(painted, isolatedLayer: nil, tolerance: 0.5))
    }

    /// The outline's width, dashes and alignment shape its triangles: changing one
    /// flattens that shape again.
    func testOutlineGeometryChangesFlattenAgain() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        for change: (inout StrokeStyle) -> Void in [{ $0.width = 9 }, { $0.dash = [4, 4] }, { $0.alignment = .inside },
                                                   { $0.cap = .butt }, { $0.join = .miter }] {
            var edited = drawing
            change(&edited.layers[0].shapes[0].stroke!)
            builder.tessellationCount = 0
            let art = builder.build(edited, isolatedLayer: nil, tolerance: 0.5)
            XCTAssertEqual(builder.tessellationCount, 1)
            var cold = ArtBuilder()
            assertSameArt(art, cold.build(edited, isolatedLayer: nil, tolerance: 0.5))
        }
    }

    /// The renderer builds a preview (a scrub or playback) with a copy of the art
    /// builder, so when it ends the keyframe's own art is still cached: nothing is
    /// flattened or rebuilt.
    func testAPreviewBuiltWithACopyLeavesTheArtWarm() {
        let drawing = Self.row()
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        var moved = drawing
        for l in moved.layers.indices { moved.layers[l].transform.position = Vec2(30, 0) }
        var preview = builder
        preview.tessellationCount = 0
        _ = preview.build(moved, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(preview.tessellationCount, drawing.shapeCount, "every shape moved")
        builder.tessellationCount = 0
        let layerBuilds = builder.layerBuilds
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(builder.tessellationCount, 0)
        XCTAssertEqual(builder.layerBuilds, layerBuilds)
    }
}
