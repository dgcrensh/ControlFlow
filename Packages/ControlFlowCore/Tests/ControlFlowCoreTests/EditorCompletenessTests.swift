import XCTest
@testable import ControlFlowCore

private func tap(_ e: inout DrawingEditor, _ p: Vec2, time: Double? = nil) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p, time: time)
}

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2) {
    e.pencilBegan(at: a, zoom: 1)
    e.pencilMoved(to: Vec2.lerp(a, b, 0.5))
    e.pencilEnded(at: b)
}

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b) \(message)", file: file, line: line)
}

/// An editor with one filled square part per rectangle, back to front.
private func editor(_ rects: [Rect]) -> DrawingEditor {
    var d = Drawing()
    for (i, r) in rects.enumerated() {
        let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink,
                                stroke: StrokeStyle(color: .ink, width: 2))
        d.parts.append(Part(id: d.makeID(), name: "Part \(i + 1)", shapes: [shape], pivot: r.center))
    }
    return DrawingEditor(drawing: d)
}

private func square(_ x: Double, _ y: Double, _ size: Double = 100) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + size, y + size))
}

/// Adds a filled square shape to part `index`.
private func addSquare(_ e: inout DrawingEditor, part index: Int, _ r: Rect) -> ShapeRef {
    let id = e.drawing.makeID()
    e.drawing.parts[index].shapes.append(VectorShape(id: id, path: ShapePrimitives.rectangle(r), fill: .ink))
    return ShapeRef(part: e.drawing.parts[index].id, shape: id)
}

/// Points around a circle, as a hand might draw it.
private func circleStroke(center: Vec2, radius: Double, count: Int = 80, wobble: Double = 0) -> [Vec2] {
    (0...count).map { i in
        let a = 2 * Double.pi * Double(i) / Double(count)
        let r = radius * (1 + wobble * sin(7 * a))
        return center + Vec2(cos(a), sin(a)) * r
    }
}

/// Points along a polyline through `corners`, `perEdge` per edge.
private func polylineStroke(_ corners: [Vec2], perEdge: Int = 20) -> [Vec2] {
    var out: [Vec2] = []
    for k in 0..<(corners.count - 1) {
        for i in 0..<perEdge { out.append(Vec2.lerp(corners[k], corners[k + 1], Double(i) / Double(perEdge))) }
    }
    out.append(corners[corners.count - 1])
    return out
}

final class ShapePrimitiveTests: XCTestCase {
    func testRectangleAndRoundedRectangle() {
        let r = Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(100, 50))
        let plain = ShapePrimitives.rectangle(r)
        XCTAssertTrue(plain.closed)
        XCTAssertEqual(plain.points.map(\.position), [Vec2(0, 0), Vec2(100, 0), Vec2(100, 50), Vec2(0, 50)])
        XCTAssertTrue(plain.points.allSatisfy { $0.mode == .corner })

        let rounded = ShapePrimitives.rectangle(r, cornerRadius: 10)
        XCTAssertEqual(rounded.points.count, 8)
        let bounds = rounded.bounds(tolerance: 0.01)
        assertClose(bounds.minPoint, Vec2(0, 0), tolerance: 0.05)
        assertClose(bounds.maxPoint, Vec2(100, 50), tolerance: 0.05)

        // A radius of half the height leaves no straight vertical edges: those points merge.
        let pill = ShapePrimitives.rectangle(r, cornerRadius: 40)
        XCTAssertEqual(pill.points.count, 6)
        let circle = ShapePrimitives.rectangle(square(0, 0), cornerRadius: 50)
        XCTAssertEqual(circle.points.count, 4)
    }

    func testEllipseFillsItsRect() {
        let e = ShapePrimitives.ellipse(Rect(minPoint: Vec2(-50, -20), maxPoint: Vec2(50, 20)))
        XCTAssertEqual(e.points.count, 4)
        XCTAssertTrue(e.points.allSatisfy { $0.mode == .symmetric })
        let b = e.bounds(tolerance: 0.01)
        assertClose(b.minPoint, Vec2(-50, -20), tolerance: 0.05)
        assertClose(b.maxPoint, Vec2(50, 20), tolerance: 0.05)
        // The curve at 45 degrees is within a fraction of a point of a true ellipse.
        let mid = e.segment(0).point(at: 0.5)
        let r = (mid.x * mid.x / 2500 + mid.y * mid.y / 400).squareRoot()
        XCTAssertEqual(r, 1, accuracy: 0.001)
    }

    func testPolygonAndStar() {
        let hex = ShapePrimitives.polygon(center: .zero, radius: 10, sides: 6)
        XCTAssertEqual(hex.points.count, 6)
        assertClose(hex.points[0].position, Vec2(0, -10), tolerance: 1e-9)
        let star = ShapePrimitives.star(center: .zero, outerRadius: 10, innerRadius: 4, points: 5)
        XCTAssertEqual(star.points.count, 10)
        XCTAssertEqual(star.points[1].position.length, 4, accuracy: 1e-9)
        XCTAssertEqual(ShapePrimitives.polygon(center: .zero, radius: 1, sides: 1).points.count, 3)
    }

    func testDragModifiers() {
        let options = ShapeToolOptions()
        let square = ShapePrimitives.path(.rectangle, from: .zero, to: Vec2(40, 10), options: options, modifiers: .constrain)!
        XCTAssertEqual(square.bounds().width, 40, accuracy: 1e-9)
        XCTAssertEqual(square.bounds().height, 40, accuracy: 1e-9)
        let centered = ShapePrimitives.path(.ellipse, from: .zero, to: Vec2(30, 20), options: options, modifiers: .alternate)!
        assertClose(centered.bounds(tolerance: 0.01).center, .zero, tolerance: 1e-6)
        XCTAssertEqual(centered.bounds(tolerance: 0.01).width, 60, accuracy: 0.05)
        let line = ShapePrimitives.path(.line, from: .zero, to: Vec2(100, 10), options: options, modifiers: .constrain)!
        assertClose(line.points[1].position, Vec2(100.4988, 0), tolerance: 1e-3)
        XCTAssertNil(ShapePrimitives.path(.polygon, from: .zero, to: Vec2(1, 0), options: options, minimumSize: 6))
        // The polygon's first corner points at the Pencil.
        let tri = ShapePrimitives.path(.polygon, from: .zero, to: Vec2(30, 0), options: ShapeToolOptions(sides: 3))!
        assertClose(tri.points[0].position, Vec2(30, 0), tolerance: 1e-9)
    }
}

final class ShapeToolTests: XCTestCase {
    func testDraggingMakesOneShapeInANewPartAsOneUndoStep() {
        var e = DrawingEditor()
        e.tool = .shape
        e.shapeKind = .ellipse
        e.pencilBegan(at: Vec2(0, 0), zoom: 1)
        e.pencilMoved(to: Vec2(50, 50))
        e.pencilMoved(to: Vec2(100, 60))
        e.pencilEnded(at: Vec2(100, 60))
        XCTAssertEqual(e.drawing.parts.count, 1)
        let shape = e.drawing.parts[0].shapes[0]
        XCTAssertEqual(shape.path.points.count, 4)
        XCTAssertNotNil(shape.fill)
        assertClose(e.drawing.parts[0].pivot, Vec2(50, 30), tolerance: 0.05)
        XCTAssertEqual(e.selection, .shape(part: e.drawing.parts[0].id, shape: shape.id))
        e.undo()
        XCTAssertTrue(e.drawing.parts.isEmpty)
        XCTAssertFalse(e.canUndo)
    }

    func testATapDrawsNothingAndLinesAreOutlined() {
        var e = DrawingEditor()
        e.tool = .shape
        tap(&e, Vec2(10, 10))
        XCTAssertTrue(e.drawing.parts.isEmpty)
        e.shapeKind = .line
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        let line = e.drawing.parts[0].shapes[0]
        XCTAssertFalse(line.path.closed)
        XCTAssertNotNil(line.stroke)
    }

    func testCancellingKeepsIDsUsed() {
        var e = DrawingEditor()
        e.tool = .shape
        e.pencilBegan(at: Vec2(0, 0), zoom: 1)
        e.pencilMoved(to: Vec2(50, 50))
        let used = e.drawing.nextID
        e.pencilCancelled()
        XCTAssertTrue(e.drawing.parts.isEmpty)
        XCTAssertGreaterThanOrEqual(e.drawing.nextID, used)
    }
}

final class QuickShapeTests: XCTestCase {
    func testStraightStrokeBecomesALine() {
        let pts = (0...40).map { Vec2(Double($0) * 5, sin(Double($0)) * 1.5) }
        let path = ShapeRecognizer.recognize(pts)
        XCTAssertEqual(path?.points.count, 2)
        XCTAssertEqual(path?.closed, false)
    }

    func testRoundStrokeBecomesACircle() throws {
        let path = try XCTUnwrap(ShapeRecognizer.recognize(circleStroke(center: Vec2(200, 100), radius: 50, wobble: 0.03)))
        XCTAssertTrue(path.closed)
        XCTAssertEqual(path.points.count, 4)
        let b = path.bounds(tolerance: 0.01)
        XCTAssertEqual(b.width, b.height, accuracy: 1e-6)
        XCTAssertEqual(b.width, 100, accuracy: 6)
        assertClose(b.center, Vec2(200, 100), tolerance: 2)
    }

    func testFlatLoopBecomesAnEllipse() throws {
        let pts = circleStroke(center: .zero, radius: 1).map { Vec2($0.x * 80, $0.y * 30) }
        let path = try XCTUnwrap(ShapeRecognizer.recognize(pts))
        let b = path.bounds(tolerance: 0.01)
        XCTAssertEqual(b.width, 160, accuracy: 4)
        XCTAssertEqual(b.height, 60, accuracy: 4)
    }

    func testBoxyLoopBecomesARectangle() throws {
        let corners = [Vec2(0, 0), Vec2(120, 2), Vec2(121, 80), Vec2(1, 79), Vec2(0, 3)]
        let path = try XCTUnwrap(ShapeRecognizer.recognize(polylineStroke(corners)))
        XCTAssertTrue(path.closed)
        XCTAssertEqual(path.points.count, 4)
        let b = path.bounds()
        XCTAssertEqual(b.width, 120, accuracy: 3)
        XCTAssertEqual(b.height, 80, accuracy: 3)
    }

    func testThreeCornersBecomeATriangle() throws {
        let corners = [Vec2(0, 100), Vec2(50, 0), Vec2(100, 100), Vec2(2, 98)]
        let path = try XCTUnwrap(ShapeRecognizer.recognize(polylineStroke(corners)))
        XCTAssertEqual(path.points.count, 3)
    }

    func testBentStrokeBecomesAnArc() throws {
        // A quarter of a circle of radius 100.
        let pts = (0...30).map { i -> Vec2 in
            let a = Double.pi / 2 * Double(i) / 30
            return Vec2(cos(a), sin(a)) * 100
        }
        let path = try XCTUnwrap(ShapeRecognizer.recognize(pts))
        XCTAssertFalse(path.closed)
        assertClose(path.points.first!.position, Vec2(100, 0), tolerance: 1e-6)
        assertClose(path.points.last!.position, Vec2(0, 100), tolerance: 1e-6)
        let mid = path.segment(0).point(at: 0.5)
        XCTAssertEqual(mid.length, 100, accuracy: 0.1)
    }

    func testScribblesAndTinyStrokesStayAsDrawn() {
        let zigzag = (0...20).map { Vec2(Double($0) * 10, $0.isMultiple(of: 2) ? 0 : 40) }
        XCTAssertNil(ShapeRecognizer.recognize(zigzag))
        XCTAssertNil(ShapeRecognizer.recognize([Vec2(0, 0), Vec2(2, 1), Vec2(4, 0)]))
    }

    func testHoldingThePencilSnapsTheLiveStroke() {
        var s = CanvasSession(options: InputOptions())
        s.resetView(viewSize: Vec2(1000, 800))
        let pts = circleStroke(center: Vec2(500, 400), radius: 80)
        s.touchBegan(id: 1, kind: .pencil, location: pts[0], time: 0)
        for (i, p) in pts.enumerated().dropFirst() {
            s.touchMoved(id: 1, samples: [p], time: Double(i) * 0.01)
        }
        XCTAssertFalse(s.checkQuickShape(time: 0.9), "not held long enough")
        XCTAssertTrue(s.checkQuickShape(time: 1.4))
        XCTAssertNotNil(s.quickShape)
        s.touchEnded(id: 1, location: pts.last!, time: 1.5)
        let shape = s.editor.drawing.parts[0].shapes[0]
        XCTAssertEqual(shape.path.points.count, 4)
        XCTAssertTrue(shape.path.closed)
        XCTAssertNil(s.quickShape)
        s.undo()
        XCTAssertTrue(s.editor.drawing.parts.isEmpty)
    }

    func testASnappedLineFollowsThePencil() {
        var s = CanvasSession(options: InputOptions())
        s.resetView(viewSize: Vec2(1000, 800))
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(100, 100), time: 0)
        for i in 1...20 { s.touchMoved(id: 1, samples: [Vec2(100 + Double(i) * 10, 100)], time: Double(i) * 0.01) }
        XCTAssertTrue(s.checkQuickShape(time: 1))
        s.touchMoved(id: 1, samples: [Vec2(300, 200)], time: 1.1)
        s.touchEnded(id: 1, location: Vec2(300, 200), time: 1.2)
        let end = s.editor.drawing.parts[0].shapes[0].path.points[1].position
        assertClose(s.camera.toScreen(end), Vec2(300, 200), tolerance: 1e-6)
    }
}

final class EraserAndScissorsTests: XCTestCase {
    func testEraserDeletesCrossedShapesInOneUndoStep() {
        var e = editor([square(0, 0), square(200, 0), square(400, 0)])
        e.tool = .eraser
        e.pencilBegan(at: Vec2(-20, 50), zoom: 1)
        e.pencilMoved(to: Vec2(150, 50))
        e.pencilMoved(to: Vec2(250, 50))
        e.pencilEnded(at: Vec2(250, 50))
        XCTAssertEqual(e.drawing.parts.count, 1, "the first two squares are gone")
        e.undo()
        XCTAssertEqual(e.drawing.parts.count, 3)
    }

    func testEraserSkipsLockedAndHiddenArt() {
        var e = editor([square(0, 0), square(200, 0)])
        e.setPartLocked(e.drawing.parts[0].id, true)
        e.setPartHidden(e.drawing.parts[1].id, true)
        e.tool = .eraser
        drag(&e, Vec2(-20, 50), Vec2(320, 50))
        XCTAssertEqual(e.drawing.parts.count, 2)
    }

    func testScissorsOpenAClosedShape() throws {
        var e = editor([square(0, 0)])
        e.tool = .scissors
        tap(&e, Vec2(50, 0))
        let shapes = e.drawing.parts[0].shapes
        XCTAssertEqual(shapes.count, 1)
        XCTAssertFalse(shapes[0].path.closed)
        assertClose(shapes[0].path.points.first!.position, Vec2(50, 0))
        assertClose(shapes[0].path.points.last!.position, Vec2(50, 0))
        XCTAssertNotNil(shapes[0].stroke)
        e.undo()
        XCTAssertTrue(e.drawing.parts[0].shapes[0].path.closed)
    }

    func testScissorsSplitAnOpenPath() {
        var e = DrawingEditor()
        e.tool = .shape
        e.shapeKind = .line
        drag(&e, Vec2(0, 0), Vec2(100, 0))
        e.tool = .scissors
        XCTAssertNil(e.scissorsPreview, "no hover yet")
        e.pencilHovered(at: Vec2(40, 3), zoom: 1)
        assertClose(e.scissorsPreview ?? .zero, Vec2(40, 0), tolerance: 1e-3)
        tap(&e, Vec2(40, 3))
        let shapes = e.drawing.parts[0].shapes
        XCTAssertEqual(shapes.count, 2)
        assertClose(shapes[0].path.points.last!.position, Vec2(40, 0), tolerance: 1e-3)
        assertClose(shapes[1].path.points.first!.position, Vec2(40, 0), tolerance: 1e-3)
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)).count, 2)
        // Cutting at an open path's end does nothing.
        tap(&e, Vec2(100, 0))
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 2)
    }
}

final class HideLockIsolateTests: XCTestCase {
    func testHiddenAndLockedArtCannotBeHitOrSelected() {
        var e = editor([square(0, 0), square(0, 0)])
        let back = e.drawing.parts[0].id, front = e.drawing.parts[1].id
        e.tool = .select
        tap(&e, Vec2(50, 50))
        XCTAssertEqual(e.selection, .layer(front))
        e.lockSelection()
        XCTAssertEqual(e.selection, Selection.none)
        tap(&e, Vec2(50, 50))
        XCTAssertEqual(e.selection, .layer(back), "taps go through the locked part")
        e.selectPart(front)
        XCTAssertEqual(e.selection, .layer(back), "a locked part can't be picked from the layers")
        e.hideSelection()
        tap(&e, Vec2(50, 50))
        XCTAssertEqual(e.selection, Selection.none)
        XCTAssertTrue(e.hasHiddenArt)
        XCTAssertTrue(e.hasLockedArt)
        e.showAll()
        e.unlockAll()
        XCTAssertFalse(e.hasHiddenArt || e.hasLockedArt)
        e.undo()
        XCTAssertTrue(e.hasLockedArt)
    }

    func testHidingSingleShapes() {
        var e = editor([square(0, 0)])
        let ref = addSquare(&e, part: 0, square(200, 0))
        e.selection = .shape(part: ref.part, shape: ref.shape)
        e.hideSelection()
        XCTAssertTrue(e.drawing.shape(ref)!.isHidden)
        XCTAssertFalse(e.drawing.parts[0].isHidden)
        XCTAssertNil(e.drawing.hitTest(Vec2(250, 50), tolerance: 1))
        XCTAssertTrue(LayerTree(drawing: e.drawing).parts.last!.hasHiddenOrLockedShapes)
    }

    func testHideAndLockRoundTripThroughTheFile() throws {
        var e = editor([square(0, 0), square(200, 0)])
        let ref = addSquare(&e, part: 0, square(0, 200))
        e.drawing.parts[1].isHidden = true
        e.drawing.parts[1].isLocked = true
        e.selection = .shape(part: ref.part, shape: ref.shape)
        e.lockSelection()
        let text = CharacterFormat.encode(e.drawing).formatted()
        XCTAssertTrue(text.contains("\"locked\": true"))
        let back = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertTrue(back.parts[1].isHidden && back.parts[1].isLocked)
        XCTAssertTrue(back.parts[0].shapes[1].isLocked)
        XCTAssertFalse(back.parts[0].shapes[0].isLocked || back.parts[0].isHidden)
    }

    func testDoubleTapIsolatesAPartAndNewArtJoinsIt() {
        var e = editor([square(0, 0), square(200, 0)])
        let first = e.drawing.parts[0].id
        e.tool = .select
        tap(&e, Vec2(50, 50), time: 1)
        tap(&e, Vec2(52, 50), time: 1.2)
        XCTAssertEqual(e.isolatedPart, first)
        // The other part can't be touched now.
        tap(&e, Vec2(250, 50), time: 5)
        XCTAssertEqual(e.selection, Selection.none)
        e.tool = .pencil
        e.addStroke([Vec2(300, 300), Vec2(320, 310), Vec2(340, 300)], zoom: 1)
        XCTAssertEqual(e.drawing.parts.count, 2)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 2)
        // Double-tapping empty canvas leaves isolation.
        e.tool = .select
        tap(&e, Vec2(600, 600), time: 10)
        tap(&e, Vec2(600, 600), time: 10.1)
        XCTAssertNil(e.isolatedPart)
    }

    func testSlowTapsAreNotADoubleTap() {
        var e = editor([square(0, 0)])
        e.tool = .select
        tap(&e, Vec2(50, 50), time: 1)
        tap(&e, Vec2(50, 50), time: 2)
        XCTAssertNil(e.isolatedPart)
    }

    func testIsolationEndsWhenItsPartGoes() {
        var e = editor([square(0, 0), square(200, 0)])
        let first = e.drawing.parts[0].id
        e.isolate(part: first)
        e.setPartHidden(first, true)
        XCTAssertNil(e.isolatedPart)
        e.isolate(part: first)
        e.deletePart(first)
        XCTAssertNil(e.isolatedPart)
        e.isolate(part: e.drawing.parts[0].id)
        e.selectPart(e.drawing.parts[0].id)
        XCTAssertNotNil(e.isolatedPart)
    }
}

final class ArrangeTests: XCTestCase {
    func testArrangingShapesWithinAPart() {
        var e = editor([square(0, 0)])
        let a = ShapeRef(part: e.drawing.parts[0].id, shape: e.drawing.parts[0].shapes[0].id)
        let b = addSquare(&e, part: 0, square(10, 0))
        let c = addSquare(&e, part: 0, square(20, 0))
        func order() -> [Int] { e.drawing.parts[0].shapes.map(\.id) }
        e.selection = .shape(part: a.part, shape: a.shape)
        e.arrange(.bringForward)
        XCTAssertEqual(order(), [b.shape, a.shape, c.shape])
        e.arrange(.bringToFront)
        XCTAssertEqual(order(), [b.shape, c.shape, a.shape])
        e.arrange(.sendBackward)
        XCTAssertEqual(order(), [b.shape, a.shape, c.shape])
        e.arrange(.sendToBack)
        XCTAssertEqual(order(), [a.shape, b.shape, c.shape])
        e.selection = .covering([a, b])
        e.arrange(.bringForward)
        XCTAssertEqual(order(), [c.shape, a.shape, b.shape])
        e.undo()
        XCTAssertEqual(order(), [a.shape, b.shape, c.shape])
    }

    func testArrangingAndReorderingParts() {
        var e = editor([square(0, 0), square(10, 0), square(20, 0)])
        let ids = e.drawing.parts.map(\.id)
        e.selection = .layer(ids[0])
        e.arrange(.bringToFront)
        XCTAssertEqual(e.drawing.parts.map(\.id), [ids[1], ids[2], ids[0]])
        e.setPartOrder(frontToBack: [ids[2], ids[1], ids[0]])
        XCTAssertEqual(e.drawing.parts.map(\.id), [ids[0], ids[1], ids[2]])
        e.setPartOrder(frontToBack: [ids[2]])
        XCTAssertEqual(e.drawing.parts.count, 3, "an incomplete order is ignored")
    }

    func testMergeDownAndMoveToNewPart() {
        var e = editor([square(0, 0), square(200, 0)])
        let lower = e.drawing.parts[0].id, upper = e.drawing.parts[1].id
        XCTAssertFalse(e.canMergePartDown(lower))
        e.mergePartDown(upper)
        XCTAssertEqual(e.drawing.parts.count, 1)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 2)
        XCTAssertEqual(e.selection, .layer(lower))

        let moved = e.drawing.parts[0].shapes[1].id
        e.selection = .shape(part: lower, shape: moved)
        e.moveSelectionToNewPart()
        XCTAssertEqual(e.drawing.parts.count, 2)
        XCTAssertEqual(e.drawing.parts[1].shapes.map(\.id), [moved])
        assertClose(e.drawing.parts[1].pivot, Vec2(250, 50), tolerance: 0.5)
    }

    func testMovingShapesToAnotherPart() {
        var e = editor([square(0, 0), square(200, 0), square(400, 0)])
        let ids = e.drawing.parts.map(\.id)
        let shape = e.drawing.parts[2].shapes[0].id
        e.selection = .shape(part: ids[2], shape: shape)
        e.moveSelection(toPart: ids[0])
        XCTAssertEqual(e.drawing.parts.map(\.id), [ids[0], ids[1]], "the emptied part goes")
        XCTAssertEqual(e.drawing.parts[0].shapes.last?.id, shape)
        XCTAssertEqual(e.selection, .shape(part: ids[0], shape: shape))
        e.selection = .layer(ids[1])
        e.moveSelection(toPart: ids[0])
        XCTAssertEqual(e.drawing.parts.count, 1)
        XCTAssertEqual(e.drawing.parts[0].shapes.count, 3)
    }
}

final class DuplicateAndClipboardTests: XCTestCase {
    func testDuplicatingAPart() {
        var e = editor([square(0, 0), square(200, 0)])
        e.selection = .layer(e.drawing.parts[0].id)
        e.duplicateSelection()
        XCTAssertEqual(e.drawing.parts.count, 3)
        let copy = e.drawing.parts[1]
        XCTAssertEqual(copy.name, "Part 1 2")
        XCTAssertEqual(e.selection, .layer(copy.id))
        assertClose(copy.shapes[0].path.points[0].position, Vec2(10, 10))
        assertClose(copy.pivot, Vec2(60, 60))
        e.undo()
        XCTAssertEqual(e.drawing.parts.count, 2)
    }

    func testDuplicatingShapesKeepsThemAboveTheOriginals() {
        var e = editor([square(0, 0)])
        let a = ShapeRef(part: e.drawing.parts[0].id, shape: e.drawing.parts[0].shapes[0].id)
        let b = addSquare(&e, part: 0, square(200, 0))
        e.selection = .shape(part: a.part, shape: a.shape)
        e.duplicateSelection(offset: .zero)
        let ids = e.drawing.parts[0].shapes.map(\.id)
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[0], a.shape)
        XCTAssertEqual(ids[2], b.shape)
        XCTAssertEqual(e.selection, .shape(part: a.part, shape: ids[1]))
    }

    func testOptionDragMovesACopy() {
        var e = editor([square(0, 0)])
        e.tool = .select
        e.modifiers = .alternate
        drag(&e, Vec2(50, 50), Vec2(250, 50))
        XCTAssertEqual(e.drawing.parts.count, 2)
        assertClose(e.drawing.parts[0].shapes[0].path.points[0].position, Vec2(0, 0))
        assertClose(e.drawing.parts[1].shapes[0].path.points[0].position, Vec2(200, 0))
        e.undo()
        XCTAssertEqual(e.drawing.parts.count, 1, "copy and move are one step")
    }

    func testShiftDragMovesAlongOneAxis() {
        var e = editor([square(0, 0)])
        e.tool = .select
        e.modifiers = .constrain
        drag(&e, Vec2(50, 50), Vec2(150, 70))
        assertClose(e.drawing.parts[0].shapes[0].path.points[0].position, Vec2(100, 0))
    }

    func testCopyAndPasteParts() throws {
        var e = editor([square(0, 0)])
        e.drawing.parts[0].name = "Hand.L"
        e.selection = .layer(e.drawing.parts[0].id)
        let text = try XCTUnwrap(e.copySelection())
        XCTAssertTrue(text.contains("\"clipboard\": \"parts\""))
        XCTAssertTrue(e.paste(text))
        XCTAssertEqual(e.drawing.parts.count, 2)
        XCTAssertEqual(e.drawing.parts[1].name, "Hand.L 2")
        assertClose(e.drawing.parts[1].shapes[0].path.points[0].position, Vec2(10, 10), tolerance: 1e-3)
        XCTAssertEqual(e.selection, .layer(e.drawing.parts[1].id))

        // Into another character, in place.
        var other = DrawingEditor()
        XCTAssertTrue(other.paste(text))
        assertClose(other.drawing.parts[0].shapes[0].path.points[0].position, Vec2(0, 0), tolerance: 1e-3)
        XCTAssertFalse(other.paste("not json"))
        XCTAssertFalse(other.paste("{\"formatVersion\": \"0.1.0\"}"))
    }

    func testCopiedShapesPasteIntoTheSelectedPart() throws {
        var e = editor([square(0, 0), square(200, 0)])
        let source = e.drawing.parts[0]
        e.selection = .shape(part: source.id, shape: source.shapes[0].id)
        let text = try XCTUnwrap(e.copySelection())
        e.selection = .layer(e.drawing.parts[1].id)
        XCTAssertTrue(e.paste(text))
        XCTAssertEqual(e.drawing.parts.count, 2)
        XCTAssertEqual(e.drawing.parts[1].shapes.count, 2)
        // Cut removes the original.
        e.selection = .layer(e.drawing.parts[0].id)
        XCTAssertNotNil(e.cutSelection())
        XCTAssertEqual(e.drawing.parts.count, 1)
    }
}

final class PencilControlTests: XCTestCase {
    func testDoubleTapToolSwitching() {
        var e = DrawingEditor()
        e.tool = .pen
        e.tool = .select
        e.switchToPreviousTool()
        XCTAssertEqual(e.tool, .pen)
        e.toggleEraser()
        XCTAssertEqual(e.tool, .eraser)
        e.toggleEraser()
        XCTAssertEqual(e.tool, .pen)
    }

    func testHoverHighlightsWhatATouchWouldHit() {
        var e = editor([square(0, 0)])
        e.tool = .select
        e.pencilHovered(at: Vec2(50, 50), zoom: 1)
        XCTAssertEqual(e.hoverTarget?.part, e.drawing.parts[0].id)
        let overlay = EditorOverlay.vertices(for: e, zoom: 1)
        XCTAssertFalse(overlay.isEmpty)
        e.pencilHovered(at: Vec2(500, 500), zoom: 1)
        XCTAssertNil(e.hoverTarget)
        e.tool = .pencil
        e.pencilHovered(at: Vec2(500, 500), zoom: 1)
        XCTAssertFalse(EditorOverlay.vertices(for: e, zoom: 1).isEmpty, "the brush size shows")
    }

    func testAPickerDragAddsOneRecentColor() {
        var e = DrawingEditor()
        for g in stride(from: 0.0, through: 1, by: 0.25) {
            e.setFill(RGBAColor(r: 1, g: g, b: 0), continuous: true)
        }
        XCTAssertEqual(e.recentColors, [RGBAColor(r: 1, g: 1, b: 0)])
        e.addStroke([Vec2(0, 0), Vec2(10, 10), Vec2(20, 0)], zoom: 1)
        e.setFill(RGBAColor(r: 0, g: 0, b: 1), continuous: true)
        e.setOutline(.ink)
        XCTAssertEqual(e.recentColors.count, 3)
        XCTAssertEqual(e.recentColors.first, .ink)
    }
}
