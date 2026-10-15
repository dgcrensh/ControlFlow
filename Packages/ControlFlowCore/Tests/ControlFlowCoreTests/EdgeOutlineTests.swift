import XCTest
@testable import ControlFlowCore

/// True when `p` is inside one of the triangles (three points each).
private func covers(_ triangles: [Vec2], _ p: Vec2) -> Bool {
    stride(from: 0, to: triangles.count, by: 3).contains { i in
        let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
        let d1 = (b - a).cross(p - a), d2 = (c - b).cross(p - b), d3 = (a - c).cross(p - c)
        return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0))
    }
}

/// A 100-point square from (0, 0), corners clockwise on screen from the top left,
/// with the listed segments left bare. Segment 0 is the top edge.
private func square(bare: Set<Int> = []) -> BezierPath {
    var path = ShapePrimitives.rectangle(Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(100, 100)))
    for i in bare { path.points[i].stroked = false }
    return path
}

private let red = RGBAColor(r: 1, g: 0, b: 0)

final class EdgeOutlineTests: XCTestCase {
    func testStrokedRunsSkipBareSegments() {
        XCTAssertEqual(square().strokedRuns(), [square()])
        // One bare edge: the rest is one open run starting after it.
        let one = square(bare: [0]).strokedRuns()
        XCTAssertEqual(one.count, 1)
        XCTAssertFalse(one[0].closed)
        XCTAssertEqual(one[0].points.map(\.position), [Vec2(100, 0), Vec2(100, 100), Vec2(0, 100), Vec2(0, 0)])
        // Two opposite bare edges leave two runs.
        let two = square(bare: [0, 2]).strokedRuns()
        XCTAssertEqual(two.map { $0.points.map(\.position) },
                       [[Vec2(100, 0), Vec2(100, 100)], [Vec2(0, 100), Vec2(0, 0)]])
        XCTAssertTrue(square(bare: [0, 1, 2, 3]).strokedRuns().isEmpty)
        // The last point of an open path has no segment, so its flag means nothing.
        var open = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0)), PathPoint(Vec2(20, 0))])
        open.points[2].stroked = false
        XCTAssertFalse(open.hasUnstrokedSegments)
        open.points[0].stroked = false
        XCTAssertEqual(open.strokedRuns().map { $0.points.map(\.position) }, [[Vec2(10, 0), Vec2(20, 0)]])
    }

    func testBareEdgeHasNoOutlineButTheRestDoes() {
        let style = StrokeStyle(color: .ink, width: 4, cap: .butt)
        let tris = Stroker.triangles(for: square(bare: [0]), style: style, tolerance: 0.1)
        XCTAssertFalse(covers(tris, Vec2(50, -1)))
        XCTAssertFalse(covers(tris, Vec2(50, 1)))
        XCTAssertTrue(covers(tris, Vec2(101, 50)))
        XCTAssertTrue(covers(tris, Vec2(50, 101)))
        XCTAssertTrue(covers(tris, Vec2(-1, 50)))
        // The joins between outlined edges are kept.
        XCTAssertTrue(covers(tris, Vec2(101, 101)))
        XCTAssertTrue(Stroker.triangles(for: square(bare: [0, 1, 2, 3]), style: style, tolerance: 0.1).isEmpty)
    }

    func testPathEditsKeepBareEdgesInPlace() throws {
        let path = square(bare: [0])
        // Reversing moves the flag so the same edge stays bare.
        let back = path.reversed()
        let bare = (0..<back.segmentCount).filter { !back.points[$0].stroked }
        XCTAssertEqual(bare.count, 1)
        let edge = back.segment(bare[0])
        XCTAssertEqual(Set([edge.p0, edge.p3]), Set([Vec2(0, 0), Vec2(100, 0)]))
        XCTAssertEqual(back.reversed(), path)
        // Splitting a bare edge leaves both halves bare.
        var split = path
        let i = split.insertPoint(segment: 0, t: 0.5)
        XCTAssertFalse(split.points[0].stroked)
        XCTAssertFalse(split.points[i].stroked)
        XCTAssertTrue(split.points[i + 1].stroked)
        // Opening a closed path at a point keeps the bare edge.
        let opened = try XCTUnwrap(path.split(at: 2)?.first)
        XCTAssertEqual(opened.strokedRuns().map { $0.points.map(\.position) },
                       [[Vec2(100, 100), Vec2(0, 100), Vec2(0, 0)], [Vec2(100, 0), Vec2(100, 100)]])
    }

    func testDirectSelectHidesTheOutlineBetweenSelectedAnchors() {
        var d = Drawing()
        let shape = VectorShape(id: d.makeID(), path: square(), fill: red, stroke: StrokeStyle(color: .ink, width: 2))
        d.layers.append(Layer(id: d.makeID(), name: "Body", shapes: [shape]))
        var e = DrawingEditor(drawing: d)
        e.tool = .directSelect
        e.selection = .shape(layer: d.layers[0].id, shape: shape.id)
        e.selectedAnchors = [0]
        XCTAssertEqual(e.selectedEdges, [])
        XCTAssertNil(e.selectedEdgesStroked)
        e.selectedAnchors = [0, 2]
        XCTAssertNil(e.selectedEdgesStroked)
        // Anchors 3 and 0 bound the closing edge.
        e.selectedAnchors = [3, 0]
        XCTAssertEqual(e.selectedEdges, [3])
        XCTAssertEqual(e.selectedEdgesStroked, true)
        e.toggleSelectedEdgesStroked()
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.stroked), [true, true, true, false])
        XCTAssertEqual(e.selectedEdgesStroked, false)
        e.undo()
        XCTAssertFalse(e.drawing.layers[0].shapes[0].path.hasUnstrokedSegments)
        e.redo()
        // With every anchor selected, a mixed set is outlined again in one step.
        e.selectedAnchors = [0, 1, 2, 3]
        XCTAssertEqual(e.selectedEdges, [0, 1, 2, 3])
        XCTAssertEqual(e.selectedEdgesStroked, true)
        e.setSelectedEdgesStroked(false)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.stroked), [false, false, false, false])
        e.toggleSelectedEdgesStroked()
        XCTAssertFalse(e.drawing.layers[0].shapes[0].path.hasUnstrokedSegments)
    }

    func testFileKeepsBareEdges() throws {
        var d = Drawing()
        d.layers.append(Layer(id: d.makeID(), name: "Body", shapes: [
            VectorShape(id: d.makeID(), path: square(bare: [1]), fill: red, stroke: StrokeStyle(color: .ink, width: 2)),
        ]))
        let text = PresentationFormat.encode(d).formatted()
        XCTAssertTrue(text.contains("\"stroked\": false"), text)
        let back = try PresentationFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(back.layers[0].shapes[0].path.points.map(\.stroked), [true, false, true, true])
        XCTAssertEqual(PresentationFormat.encode(back).formatted(), text)
    }

    func testSVGWritesTheOutlineWithoutBareEdges() throws {
        var d = Drawing()
        d.layers.append(Layer(id: d.makeID(), name: "Body", shapes: [
            VectorShape(id: d.makeID(), path: square(bare: [0]), fill: red, stroke: StrokeStyle(color: .black, width: 2)),
        ]))
        let svg = try XCTUnwrap(SVGWriter.document(for: d))
        // The fill covers the whole square; the outline is an open path round the other three sides.
        XCTAssertTrue(svg.contains("<path d=\"M0 0L100 0L100 100L0 100Z\" fill=\"#FF0000\"/>"), svg)
        XCTAssertTrue(svg.contains("<path d=\"M100 0L100 100L0 100L0 0\" fill=\"none\" stroke=\"#000000\""), svg)
    }
}
