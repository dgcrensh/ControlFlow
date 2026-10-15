import XCTest
@testable import ControlFlowCore

private func tap(_ e: inout DrawingEditor, _ p: Vec2) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p)
}

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2) {
    e.pencilBegan(at: a, zoom: 1)
    e.pencilMoved(to: Vec2.lerp(a, b, 0.5))
    e.pencilEnded(at: b)
}

private func penPath(_ points: [Vec2], in e: inout DrawingEditor) {
    e.tool = .pen
    for p in points { tap(&e, p) }
    e.penFinish()
}

/// Every vertex id in the drawing, in draw order.
private func allIDs(_ d: Drawing) -> [Int] {
    d.layers.flatMap { $0.shapes.flatMap { $0.path.points.map(\.id) } }
}

private func ids(_ shape: VectorShape) -> [Int] { shape.path.points.map(\.id) }

/// An editor with one open pen path through four corners, in Direct Select.
private func fourPointPath() -> DrawingEditor {
    var e = DrawingEditor()
    penPath([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)], in: &e)
    e.tool = .directSelect
    return e
}

/// An editor with one filled square layer, from the shape primitives.
private func squareEditor() -> DrawingEditor {
    var d = Drawing()
    let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(100, 100))),
                            fill: .ink, stroke: StrokeStyle(color: .ink, width: 2))
    d.layers.append(Layer(id: d.makeID(), name: "Layer 1", shapes: [shape], pivot: Vec2(50, 50)))
    return DrawingEditor(drawing: d)
}

/// Vertex ids: every operation that makes points gives them fresh ids, and every
/// operation that keeps points keeps theirs (animation-app.md §4).
final class VertexIDTests: XCTestCase {
    private func assertValid(_ e: DrawingEditor, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(e.drawing.vertexIDsAreValid, "every vertex has a unique id", file: file, line: line)
    }

    func testAssignNumbersNewAndCopiedPointsOnly() {
        var d = Drawing()
        var path = ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(10, 10)))
        d.layers = [Layer(id: d.makeID(), name: "A", shapes: [VectorShape(id: d.makeID(), path: path)])]
        d.assignVertexIDs()
        XCTAssertTrue(d.vertexIDsAreValid)
        let first = allIDs(d)
        // A copy of the shape repeats the ids; the copy, later in draw order, is renumbered.
        path = d.layers[0].shapes[0].path
        d.layers[0].shapes.append(VectorShape(id: d.makeID(), path: path))
        d.assignVertexIDs()
        XCTAssertTrue(d.vertexIDsAreValid)
        XCTAssertEqual(ids(d.layers[0].shapes[0]), first)
        XCTAssertTrue(Set(ids(d.layers[0].shapes[1])).isDisjoint(with: first))
        // Already valid: nothing changes.
        let valid = d
        d.assignVertexIDs()
        XCTAssertEqual(d, valid)
    }

    func testOpeningADrawingAssignsIDs() {
        assertValid(squareEditor())
    }

    func testFittedStrokesGetIDs() {
        var e = DrawingEditor()
        e.addStroke((0...40).map { Vec2(Double($0) * 5, sin(Double($0) / 5) * 30) }, zoom: 1)
        XCTAssertEqual(e.drawing.shapeCount, 1)
        assertValid(e)
    }

    func testPenPointsGetIDsAndKeepThemAsThePathGrows() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        tap(&e, Vec2(100, 0))
        assertValid(e)
        let start = ids(e.drawing.layers[0].shapes[0])
        tap(&e, Vec2(100, 100))
        e.penFinish()
        assertValid(e)
        XCTAssertEqual(Array(ids(e.drawing.layers[0].shapes[0]).prefix(2)), start)
    }

    func testShapeToolGetsIDs() {
        var e = DrawingEditor()
        e.tool = .shape
        e.shapeKind = .ellipse
        drag(&e, Vec2(0, 0), Vec2(100, 80))
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.count, 4)
        assertValid(e)
    }

    func testInsertingAPointGivesOnlyItANewID() {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        let before = ids(e.drawing.layers[0].shapes[0])
        tap(&e, Vec2(50, 0))
        let after = ids(e.drawing.layers[0].shapes[0])
        XCTAssertEqual(after.count, 5)
        XCTAssertEqual([after[0]] + after[2...], before, "the neighbours keep their ids")
        XCTAssertFalse(before.contains(after[1]))
        assertValid(e)
    }

    func testMovingAnchorsHandlesAndShapesKeepsIDs() {
        var e = fourPointPath()
        let original = ids(e.drawing.layers[0].shapes[0])
        tap(&e, Vec2(100, 0))
        drag(&e, Vec2(100, 0), Vec2(120, 20))
        e.setSelectedAnchorMode(.symmetric)
        e.nudge(by: Vec2(1, 0))
        drag(&e, Vec2(50, 50 * 0 + 10), Vec2(60, 10))
        e.tool = .select
        e.selection = .layer(e.drawing.layers[0].id)
        drag(&e, Vec2(110, 10), Vec2(200, 200))
        e.rotateSelection(byDegrees: 30)
        e.flipSelection(horizontal: true)
        XCTAssertEqual(ids(e.drawing.layers[0].shapes[0]), original)
        assertValid(e)
    }

    func testDeletingAnchorsKeepsTheOthers() {
        var e = fourPointPath()
        let original = ids(e.drawing.layers[0].shapes[0])
        tap(&e, Vec2(100, 0))
        e.deleteSelectedAnchors()
        XCTAssertEqual(ids(e.drawing.layers[0].shapes[0]), [original[0], original[2], original[3]])
    }

    func testSplitKeepsIDsAndTheSplitPointIsNew() {
        var e = fourPointPath()
        let original = ids(e.drawing.layers[0].shapes[0])
        tap(&e, Vec2(100, 0))
        e.splitAtSelectedAnchor()
        let pieces = e.drawing.layers[0].shapes.map(ids)
        XCTAssertEqual(pieces[0], [original[0], original[1]])
        XCTAssertEqual(Array(pieces[1].dropFirst()), [original[2], original[3]])
        XCTAssertFalse(original.contains(pieces[1][0]), "the split point's second copy is a new vertex")
        assertValid(e)
    }

    func testScissorsOnAClosedShape() {
        var e = squareEditor()
        let original = ids(e.drawing.layers[0].shapes[0])
        e.tool = .scissors
        tap(&e, Vec2(50, 0))
        let cut = ids(e.drawing.layers[0].shapes[0])
        XCTAssertEqual(cut.count, original.count + 2, "the cut adds a point at each new end")
        XCTAssertEqual(Set(cut).intersection(original), Set(original), "the corners keep their ids")
        assertValid(e)
    }

    func testJoiningKeepsEveryPointsID() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        penPath([Vec2(500, 0), Vec2(120, 0)], in: &e)
        let before = Set(allIDs(e.drawing))
        e.selection = .covering(Set(e.drawing.layers.flatMap { layer in
            layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) }
        }))
        e.joinSelection()
        XCTAssertEqual(e.drawing.shapeCount, 1)
        XCTAssertEqual(Set(allIDs(e.drawing)), before)
        assertValid(e)
    }

    func testDuplicatesPastesAndMirrorsGetNewIDs() throws {
        var e = squareEditor()
        let original = ids(e.drawing.layers[0].shapes[0])
        let ref = ShapeRef(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)

        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        e.duplicateSelection()
        assertValid(e)

        e.selection = .layer(ref.layer)
        e.duplicateSelection()
        assertValid(e)

        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        XCTAssertTrue(e.paste(try XCTUnwrap(e.copySelection())))
        assertValid(e)

        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        e.duplicateMirrored()
        assertValid(e)

        XCTAssertEqual(ids(try XCTUnwrap(e.drawing.shape(ref))), original, "the original keeps its ids")
        XCTAssertGreaterThan(e.drawing.shapeCount, 4)
    }

    func testIDsAreNeverReusedAfterUndo() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        let first = Set(allIDs(e.drawing))
        while e.canUndo { e.undo() }
        XCTAssertEqual(e.drawing.shapeCount, 0)
        penPath([Vec2(0, 50), Vec2(100, 50)], in: &e)
        XCTAssertTrue(Set(allIDs(e.drawing)).isDisjoint(with: first))
    }
}
