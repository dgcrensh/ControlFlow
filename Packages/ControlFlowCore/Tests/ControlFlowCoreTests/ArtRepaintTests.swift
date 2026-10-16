import XCTest
@testable import ControlFlowCore

/// A change of paint alone (a fade, a recolour) keeps a layer's vertices and their buffer
/// and paints its covers again (smoothness-profile-round2.md, #3): the warm build must
/// equal a cold one, and the renderer gets new paints but no new vertices.
final class ArtRepaintTests: XCTestCase {
    private let base = StressDrawing.make(layers: 6, shapesPerLayer: 8)
    private let teal = RGBAColor(r: 0.1, g: 0.6, b: 0.6)

    private struct Result {
        var first: ArtBatch
        var second: ArtBatch
        var rebuilt: Int
        var repainted: Int
    }

    /// Builds `before`, then `after` with the same builder, and checks the second build
    /// against a cold one of `after`: same vertices, steps and segment ranges.
    @discardableResult
    private func build(from before: Drawing, to after: Drawing, ghostFocus: Set<Int>? = nil, tolerance: Double = 0.5,
                       file: StaticString = #filePath, line: UInt = #line) -> Result {
        var warm = ArtBuilder()
        let first = warm.build(before, isolatedLayer: nil, tolerance: tolerance, ghostFocus: ghostFocus)
        let (builds, repaints) = (warm.layerBuilds, warm.layerRepaints)
        let second = warm.build(after, isolatedLayer: nil, tolerance: tolerance, ghostFocus: ghostFocus)
        var cold = ArtBuilder()
        let coldBatch = cold.build(after, isolatedLayer: nil, tolerance: tolerance, ghostFocus: ghostFocus)
        XCTAssertEqual(second.vertices, coldBatch.vertices, file: file, line: line)
        XCTAssertEqual(second.steps, coldBatch.steps, file: file, line: line)
        XCTAssertEqual(second.segments.map(\.vertices), coldBatch.segments.map(\.vertices), file: file, line: line)
        XCTAssertEqual(second.segments.map(\.steps), coldBatch.segments.map(\.steps), file: file, line: line)
        ArtLayerCacheTests.assertSegmentsAreConsistent(second, file: file, line: line)
        return Result(first: first, second: second, rebuilt: warm.layerBuilds - builds,
                      repainted: warm.layerRepaints - repaints)
    }

    /// Checks that only the layers at `indices` take new paints, and nothing new vertices.
    private func assertRepaints(_ r: Result, layers indices: Set<Int>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.rebuilt, 0, "nothing is built again", file: file, line: line)
        XCTAssertEqual(r.repainted, indices.count, file: file, line: line)
        XCTAssertEqual(r.second.segments.map(\.id), r.first.segments.map(\.id), "the vertices stay", file: file, line: line)
        XCTAssertTrue(r.second.segmentsToUpload(resident: r.first.residentIDs).isEmpty, file: file, line: line)
        let repaint = r.second.segmentsToRepaint(resident: r.first.residentPaintIDs)
        XCTAssertEqual(Set(repaint.map(\.layer)), Set(indices.map { base.layers[$0].id }), file: file, line: line)
        for (old, new) in zip(r.first.segments, r.second.segments) {
            let changed = indices.contains { base.layers[$0].id == new.layer }
            XCTAssertEqual(old.paintID != new.paintID, changed, file: file, line: line)
            if changed {
                XCTAssertFalse(r.first.residentIDs.contains(new.paintID), "paint ids never name vertices",
                               file: file, line: line)
            }
        }
    }

    func testRecolouringAFillKeepsTheVertices() {
        var after = base
        after.layers[2].shapes[3].fill = teal
        assertRepaints(build(from: base, to: after), layers: [2])
    }

    func testEveryFillChanging() {
        var after = base
        for l in after.layers.indices {
            for s in after.layers[l].shapes.indices where after.layers[l].shapes[s].fill != nil {
                after.layers[l].shapes[s].fill = teal
            }
        }
        assertRepaints(build(from: base, to: after), layers: Set(base.layers.indices))
    }

    func testFadingALayerAndRecolouringOutlines() {
        var after = base
        for s in after.layers[1].shapes.indices { after.layers[1].shapes[s].opacity = 0.3 }
        for s in after.layers[4].shapes.indices { after.layers[4].shapes[s].stroke?.color = teal }
        assertRepaints(build(from: base, to: after), layers: [1, 4])
    }

    func testFadingUnderTheGhostView() {
        let focus: Set<Int> = [base.layers[3].shapes[0].id, base.layers[3].shapes[2].id]
        var after = base
        for s in after.layers[3].shapes.indices { after.layers[3].shapes[s].opacity = 0.5 }
        assertRepaints(build(from: base, to: after, ghostFocus: focus), layers: [3])
    }

    func testAPaintChangeTheArtDoesNotDrawKeepsThePaints() {
        // A global colour link isn't drawn: the layer's paints are the same.
        var after = base
        after.layers[2].shapes[0].fillGlobal = 7
        let r = build(from: base, to: after)
        XCTAssertEqual(r.rebuilt, 0)
        XCTAssertEqual(r.repainted, 0)
        XCTAssertEqual(r.second.segments.map(\.paintID), r.first.segments.map(\.paintID))
        XCTAssertTrue(r.second.segmentsToRepaint(resident: r.first.residentPaintIDs).isEmpty)
    }

    func testPaintThatChangesTheStepsRebuilds() {
        // Adding or removing a fill, a gradient or a picture changes which steps there are.
        var noFill = base
        noFill.layers[2].shapes[0].fill = nil
        XCTAssertEqual(build(from: base, to: noFill).rebuilt, 1)
        var gradient = base
        gradient.layers[3].shapes[0].gradient = ShapeGradient(kind: .linear, start: .zero, end: Vec2(10, 0),
                                                              stops: [GradientStop(offset: 0, color: teal),
                                                                      GradientStop(offset: 1, color: .black)])
        XCTAssertEqual(build(from: base, to: gradient).rebuilt, 1)
        var noOutline = base
        noOutline.layers[4].shapes[1].stroke = nil
        XCTAssertEqual(build(from: base, to: noOutline).rebuilt, 1)
    }

    /// Gradients, a stretched outline baked into its points, clipping, groups and text,
    /// each recoloured: the repainted covers are what a fresh build paints.
    func testRepaintingEveryKindOfShape() {
        var d = Drawing()
        let square = ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(20, 20)))
        var gradient = VectorShape(id: d.makeID(), path: square, fill: teal)
        gradient.gradient = ShapeGradient(kind: .radial, start: Vec2(10, 10), end: Vec2(20, 10),
                                          stops: [GradientStop(offset: 0, color: teal), GradientStop(offset: 1, color: .black)])
        // A stretch: the gradient is baked into the points, so its paint is in their space.
        gradient.transform = Transform(position: Vec2(5, 0), rotation: 20, scale: Vec2(2, 0.6), pivot: Vec2(10, 10))
        var clipped = VectorShape(id: d.makeID(), path: square, fill: .black,
                                  stroke: StrokeStyle(color: teal, width: 2, alignment: .inside))
        clipped.isClipped = true
        var stretched = VectorShape(id: d.makeID(), path: square, fill: .black, stroke: StrokeStyle(color: .black, width: 3))
        stretched.transform = Transform(position: Vec2(30, 0), rotation: 0, scale: Vec2(1.5, 0.5), pivot: .zero)
        let text = VectorShape(id: d.makeID(), text: TextContent(string: "Hi", size: 20),
                               transform: Transform(position: Vec2(0, 40)))
        let picture = VectorShape(id: d.makeID(), image: ShapeImage(src: "a.png"), origin: Vec2(60, 0), size: Vec2(40, 20))
        var layer = Layer(id: d.makeID(), name: "Layer", shapes: [gradient, clipped, stretched, text, picture])
        layer.transform = Transform(position: Vec2(3, 4), rotation: 0, scale: Vec2(1, 2), pivot: .zero)
        d.layers = [layer]

        var after = d
        after.layers[0].shapes[0].gradient?.stops[1].color = RGBAColor(r: 1, g: 1, b: 0)
        after.layers[0].shapes[0].gradient?.end = Vec2(30, 10)
        after.layers[0].shapes[1].stroke?.color = .black
        after.layers[0].shapes[2].fill = teal
        after.layers[0].shapes[2].opacity = 0.4
        after.layers[0].shapes[3].fill = teal
        after.layers[0].shapes[4].image = ShapeImage(src: "b.png")
        let r = build(from: d, to: after)
        XCTAssertEqual(r.rebuilt, 0)
        XCTAssertEqual(r.repainted, 1)
        XCTAssertEqual(r.second.segments.map(\.id), r.first.segments.map(\.id))
        XCTAssertNotEqual(r.second.segments.map(\.paintID), r.first.segments.map(\.paintID))
    }

    /// `VectorShape.hasSameGeometry(as:)` names every property that changes the art's
    /// vertices or steps and leaves out the paint. A new property must be placed on one
    /// side: add it there if it changes the triangles or which steps there are, or to
    /// `coverPaint` if only the paint reads it, then here.
    func testEveryShapePropertyIsPlaced() {
        let shape = VectorShape(id: 1, path: BezierPath(closed: true), fill: .black,
                                stroke: StrokeStyle(color: .black, width: 1))
        XCTAssertEqual(Mirror(reflecting: shape).children.compactMap(\.label),
                       ["id", "path", "text", "textFrame", "image", "fill", "gradient", "fillGlobal", "stroke", "opacity",
                        "isClipped", "isHidden", "isLocked", "group", "transform"])
        XCTAssertEqual(Mirror(reflecting: shape.stroke!).children.compactMap(\.label),
                       ["color", "width", "cap", "join", "miterLimit", "dash", "dashOffset", "alignment", "global"])
        // Paint only:
        var paint = shape
        paint.fill = teal
        XCTAssertTrue(shape.hasSameGeometry(as: paint))
        paint.opacity = 0.2
        paint.fillGlobal = 3
        paint.stroke?.color = teal
        paint.stroke?.global = 2
        XCTAssertTrue(shape.hasSameGeometry(as: paint))
        // Everything else:
        let changes: [(inout VectorShape) -> Void] = [
            { $0.id = 2 }, { $0.path.closed = false }, { $0.text = TextContent(string: "A", size: 10) },
            { $0.image = ShapeImage(src: "a.png") },
            { $0.gradient = ShapeGradient(kind: .linear, start: .zero, end: Vec2(1, 0), stops: []) },
            { $0.stroke = nil }, { $0.stroke?.width = 2 }, { $0.stroke?.cap = .butt }, { $0.stroke?.join = .bevel },
            { $0.stroke?.miterLimit = 2 }, { $0.stroke?.dash = [1, 1] }, { $0.stroke?.dashOffset = 1 },
            { $0.stroke?.alignment = .inside }, { $0.isClipped = true }, { $0.isHidden = true }, { $0.isLocked = true },
            { $0.group = 4 }, { $0.transform.position = Vec2(1, 0) }, { $0.fill = nil },
        ]
        for (i, change) in changes.enumerated() {
            var changed = shape
            change(&changed)
            XCTAssertFalse(shape.hasSameGeometry(as: changed), "change \(i)")
        }
    }

    /// Paint ids stay unique when a layer is repainted and then rebuilt.
    func testIDsAreNeverReused() {
        var builder = ArtBuilder()
        var d = base
        var last = Set(builder.build(d, isolatedLayer: nil, tolerance: 0.5).segments.flatMap { [$0.id, $0.paintID] })
        var seen = last
        for i in 0..<6 {
            if i % 2 == 0 {
                d.layers[1].shapes[0].fill = RGBAColor(r: Double(i + 1) / 6, g: 0, b: 0)
            } else {
                d.layers[1].shapes[0].path.points[0].position += Vec2(1, 0)
            }
            let all = builder.build(d, isolatedLayer: nil, tolerance: 0.5).segments.flatMap { [$0.id, $0.paintID] }
            XCTAssertEqual(Set(all).count, all.count, "no id names two things")
            let new = Set(all).subtracting(last)
            if i % 2 == 0 {
                XCTAssertEqual(new.count, 1, "a repaint takes a paint id")
            } else {
                // A rebuild takes both; writing the moved shape's vertices in place, a vertex id.
                XCTAssertTrue((1...2).contains(new.count))
            }
            XCTAssertTrue(new.isDisjoint(with: seen))
            seen.formUnion(new)
            last = Set(all)
        }
    }
}
