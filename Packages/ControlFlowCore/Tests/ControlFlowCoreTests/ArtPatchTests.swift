import XCTest
@testable import ControlFlowCore

/// A layer whose shapes change only their points (a text tweening its tracking or line
/// height, a morph) keeps its steps and writes those shapes' vertices again in place;
/// when the same shapes change again, they move into segments of their own, so each
/// frame uploads only their vertices (smoothness-profile-round2.md, #13). Every warm
/// build must draw what a cold one does.
final class ArtPatchTests: XCTestCase {
    private let base = StressDrawing.make(layers: 6, shapesPerLayer: 8)

    /// One draw as the GPU sees it: what it draws, through which matrix, how it marks or
    /// paints. Segments split differently draw the same list.
    private struct Draw: Equatable {
        var floats: ArraySlice<Float>
        var matrix: Affine2D
        var step: String
        var paint: ArtPaint?
    }

    /// The draws of `batch`, walking each segment as `ArtEncoding` does: `place` the
    /// identity and `moving` off at its start.
    private func draws(_ batch: ArtBatch, live: Affine2D = .identity) -> [Draw] {
        var out: [Draw] = []
        for segment in batch.segments {
            var place = Affine2D.identity
            var moving = false
            func matrix() -> Affine2D { moving ? live * segment.transform * place : segment.transform * place }
            func floats(_ range: Range<Int>) -> ArraySlice<Float> {
                let local = segment.local(range)
                return segment.floats[(local.lowerBound * 2)..<(local.upperBound * 2)]
            }
            for step in batch.steps[segment.steps] {
                switch step {
                case .stencil(let range, let state, let reference):
                    out.append(Draw(floats: floats(range), matrix: matrix(), step: "stencil \(state) \(reference)"))
                case .cover(let range, let paint, let state, let reference):
                    out.append(Draw(floats: floats(range), matrix: matrix(), step: "cover \(state) \(reference)", paint: paint))
                case .stencilView(let state, let reference):
                    out.append(Draw(floats: [], matrix: .identity, step: "view \(state) \(reference)"))
                case .veil:
                    out.append(Draw(floats: [], matrix: .identity, step: "veil"))
                case .moving(let on):
                    moving = on
                case .place(let m):
                    place = m
                }
            }
        }
        return out
    }

    private func assertDrawsLikeCold(_ warm: ArtBatch, _ drawing: Drawing, moving: Set<Int> = [],
                                     file: StaticString = #filePath, line: UInt = #line) {
        var cold = ArtBuilder()
        let batch = cold.build(drawing, isolatedLayer: nil, tolerance: 0.5, moving: moving)
        let live = Affine2D.translation(Vec2(7, -3))
        XCTAssertEqual(draws(warm, live: live), draws(batch, live: live), file: file, line: line)
        ArtLayerCacheTests.assertSegmentsAreConsistent(warm, file: file, line: line)
    }

    /// `base` with a text on top of every layer, and a transition that tweens their
    /// tracking.
    private func trackingTween() -> Timeline {
        let start = StressDrawing.withText(base)
        var end = start
        for l in end.layers.indices {
            for s in end.layers[l].shapes.indices where end.layers[l].shapes[s].text != nil {
                end.layers[l].shapes[s].text!.tracking = 8
                end.layers[l].shapes[s].text!.lineHeight = 1.6
            }
        }
        return StressDrawing.transition(from: start, to: end)
    }

    func testATrackingTweenWritesOnlyTheTextsVertices() {
        var timeline = trackingTween()
        var builder = ArtBuilder()
        var last = builder.build(timeline.state(at: 0), isolatedLayer: nil, tolerance: 0.5)
        for frame in 1...6 {
            let scene = timeline.transition(into: 1, elapsed: Double(frame) / 10)
            let (builds, patches) = (builder.layerBuilds, builder.layerPatches)
            let batch = builder.build(scene, isolatedLayer: nil, tolerance: 0.5)
            assertDrawsLikeCold(batch, scene)
            let uploaded = batch.segmentsToUpload(resident: last.residentIDs)
            if frame >= 3 {
                XCTAssertEqual(builder.layerBuilds, builds, "frame \(frame): nothing is built")
                XCTAssertEqual(builder.layerPatches - patches, base.layers.count, "frame \(frame)")
                // Each layer's text is the last shape, in a segment of its own.
                XCTAssertEqual(batch.segments.count, 2 * base.layers.count)
                XCTAssertEqual(uploaded.count, base.layers.count)
                for segment in uploaded {
                    let steps = batch.steps[segment.steps].filter { if case .place = $0 { false } else { true } }
                    XCTAssertEqual(steps.count, 2, "the text's stencil and cover alone")
                }
            }
            last = batch
        }
    }

    func testATweenedTextFlattensLikeItsOutline() {
        var text = TextContent(string: "Two lines\nof words", size: 30, width: 160)
        text.tracking = 3
        text.lineHeight = 1.4
        text.held = TextMetrics(tracking: 8, lineHeight: 1.1)
        assertFlattensLikeItsOutline(text)
        let previous = TextShaping.shaper
        TextShaping.shaper = RoundShaper()
        defer { TextShaping.shaper = previous }
        assertFlattensLikeItsOutline(text)
        for tolerance in [0.05, 0.5] {
            text.tracking += 1
            XCTAssertEqual(TextShaping.flattenedOutline(text, tolerance: tolerance).count,
                           TextShaping.outline(text).flattened(tolerance: tolerance).count)
        }
    }

    private func assertFlattensLikeItsOutline(_ text: TextContent, file: StaticString = #filePath, line: UInt = #line) {
        for tolerance in [0.05, 0.5, 2] {
            let moved = TextShaping.flattenedOutline(text, tolerance: tolerance)
            let flattened = TextShaping.outline(text).flattened(tolerance: tolerance)
            XCTAssertEqual(moved.count, flattened.count, file: file, line: line)
            for (a, b) in zip(moved, flattened) where !a.isApproximately(b, tolerance: 1e-9) {
                XCTFail("\(a) is not \(b)", file: file, line: line)
                break
            }
        }
        XCTAssertFalse(TextShaping.flattenedOutline(text, tolerance: 0.5).isEmpty, file: file, line: line)
    }

    /// A polygon whose corners move keeps its vertex count: the first change writes its
    /// vertices in place, the second gives it a segment of its own, the third writes only
    /// that segment.
    func testAMorphWritesItsVerticesInPlace() {
        var d = base
        d.layers[2].shapes[3].path = BezierPath(points: [Vec2(0, 0), Vec2(80, 0), Vec2(80, 60), Vec2(0, 60)]
            .map { PathPoint($0, smooth: false) }, closed: true)
        var builder = ArtBuilder()
        var last = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        for step in 1...3 {
            d.layers[2].shapes[3].path.points[2].position += Vec2(5, 3)
            let (builds, patches) = (builder.layerBuilds, builder.layerPatches)
            let batch = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
            assertDrawsLikeCold(batch, d)
            let uploaded = batch.segmentsToUpload(resident: last.residentIDs)
            XCTAssertEqual(Set(uploaded.map(\.layer)), [d.layers[2].id])
            switch step {
            case 1:
                XCTAssertEqual(builder.layerPatches - patches, 1)
                XCTAssertEqual(builder.layerBuilds, builds)
                XCTAssertEqual(batch.segments.count, d.layers.count)
            case 2:
                XCTAssertEqual(builder.layerBuilds - builds, 1, "split")
                XCTAssertEqual(batch.segments.count, d.layers.count + 2)
            default:
                XCTAssertEqual(builder.layerPatches - patches, 1)
                XCTAssertEqual(builder.layerBuilds, builds)
                XCTAssertEqual(uploaded.count, 1)
                // The polygon's own vertices: its fan, its outline and their covers.
                let t = ArtBuilder.tessellate(d.layers[2].shapes[3], tolerance: 0.5)
                XCTAssertEqual(t.fan.count, 2 * 2 * 3, "a fan of two triangles")
                XCTAssertEqual(uploaded[0].floats.count, t.fan.count + t.outline.count + 2 * (t.outline.isEmpty ? 6 : 12))
            }
            last = batch
        }
        // A change of anything but points and paint builds the layer again, as one segment.
        d.layers[2].shapes[3].fill = nil
        let (builds, patches) = (builder.layerBuilds, builder.layerPatches)
        let batch = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        assertDrawsLikeCold(batch, d)
        XCTAssertEqual(builder.layerBuilds - builds, 1)
        XCTAssertEqual(builder.layerPatches, patches)
        XCTAssertEqual(batch.segments.count, d.layers.count)
    }

    /// A curve whose new flattening has another vertex count is built again.
    func testANewVertexCountBuildsTheLayer() {
        var d = base
        var builder = ArtBuilder()
        _ = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        let before = ArtBuilder.tessellate(d.layers[1].shapes[0], tolerance: 0.5).fan.count
        d.layers[1].shapes[0].path.points[0].position += Vec2(60, 40)
        XCTAssertNotEqual(ArtBuilder.tessellate(d.layers[1].shapes[0], tolerance: 0.5).fan.count, before)
        let builds = builder.layerBuilds
        assertDrawsLikeCold(builder.build(d, isolatedLayer: nil, tolerance: 0.5), d)
        XCTAssertEqual(builder.layerBuilds - builds, 1)
    }

    /// A clipped shape's bounds decide where its base clears the clip, so it is built.
    func testAClippedShapeIsBuilt() {
        var d = base
        d.layers[0].shapes[1].isClipped = true
        d.layers[0].shapes[1].path = BezierPath(points: [Vec2(0, 0), Vec2(80, 0), Vec2(80, 60)]
            .map { PathPoint($0, smooth: false) }, closed: true)
        var builder = ArtBuilder()
        _ = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        for _ in 0..<3 {
            d.layers[0].shapes[1].path.points[2].position += Vec2(40, 0)
            let patches = builder.layerPatches
            assertDrawsLikeCold(builder.build(d, isolatedLayer: nil, tolerance: 0.5), d)
            XCTAssertEqual(builder.layerPatches, patches)
        }
    }

    /// A drag drawn through a live transform marks its shapes in every segment, the
    /// split ones included.
    func testALiveTransformAcrossSplitSegments() {
        var timeline = trackingTween()
        let start = timeline.state(at: 0)
        let moving = Set(start.layers.flatMap { [$0.shapes[0].id, $0.shapes.last!.id] })
        var builder = ArtBuilder()
        _ = builder.build(start, isolatedLayer: nil, tolerance: 0.5, moving: moving)
        for frame in 1...4 {
            let scene = timeline.transition(into: 1, elapsed: Double(frame) / 10)
            assertDrawsLikeCold(builder.build(scene, isolatedLayer: nil, tolerance: 0.5, moving: moving), scene, moving: moving)
        }
        XCTAssertGreaterThan(builder.layerPatches, 0)
    }
}

/// The stub's layout with every glyph a circle, so its outline has curves to flatten.
private struct RoundShaper: TextShaper {
    func layout(_ text: TextContent) -> TextLayout {
        var layout = StubTextShaper().layout(text)
        for g in layout.glyphs.indices where !layout.glyphs[g].contours.isEmpty {
            let r = text.size * 0.25
            let k = r * 0.5523
            let c = Vec2(r * 1.2, -r * 1.5)
            let points = [
                PathPoint(c + Vec2(r, 0), in: Vec2(0, -k), out: Vec2(0, k)),
                PathPoint(c + Vec2(0, r), in: Vec2(k, 0), out: Vec2(-k, 0)),
                PathPoint(c + Vec2(-r, 0), in: Vec2(0, k), out: Vec2(0, -k)),
                PathPoint(c + Vec2(0, -r), in: Vec2(-k, 0), out: Vec2(k, 0)),
            ]
            layout.glyphs[g].contours = [BezierPath(points: points, closed: true)]
        }
        return layout
    }
}
