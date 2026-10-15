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

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b) \(message)", file: file, line: line)
}

private func assertClose(_ a: [Vec2], _ b: [Vec2], tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, message, file: file, line: line)
    for (p, q) in zip(a, b) { assertClose(p, q, tolerance: tolerance, message, file: file, line: line) }
}

private func square(_ x: Double, _ y: Double, _ size: Double = 100) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + size, y + size))
}

/// An editor with one layer per rectangle, each one filled square, back to front.
private func editor(_ rects: [Rect]) -> DrawingEditor {
    var d = Drawing()
    for (i, r) in rects.enumerated() {
        let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink,
                                stroke: StrokeStyle(color: .ink, width: 2))
        d.layers.append(Layer(id: d.makeID(), name: "Layer \(i + 1)", shapes: [shape], pivot: r.center))
    }
    return DrawingEditor(drawing: d)
}

/// Shape `s` of layer `l` as drawn: its anchors in world space.
private func world(_ e: DrawingEditor, _ l: Int, _ s: Int) -> [Vec2] {
    e.drawing.layers[l].worldShape(s).path.points.map(\.position)
}

private func local(_ e: DrawingEditor, _ l: Int, _ s: Int) -> [Vec2] {
    e.drawing.layers[l].shapes[s].path.points.map(\.position)
}

private func turn(_ degrees: Double, about c: Vec2) -> Affine2D {
    Affine2D.translation(c) * Affine2D.rotation(degrees * .pi / 180) * Affine2D.translation(-c)
}

/// Layer, group and shape transforms (animation-app.md §4).
final class ObjectTransformTests: XCTestCase {
    // MARK: The transform itself

    func testMatrixTurnsAndScalesAboutThePivotThenMoves() {
        let t = Transform(position: Vec2(10, 0), rotation: 90, scale: Vec2(2, 1), pivot: Vec2(100, 100))
        assertClose(t.matrix.apply(Vec2(100, 100)), Vec2(110, 100), "the pivot only moves by position")
        // (110, 100) is 10 right of the pivot: scaled to 20, then a quarter turn clockwise
        // puts it 20 below.
        assertClose(t.matrix.apply(Vec2(110, 100)), Vec2(110, 120))
        XCTAssertEqual(Transform.identity.matrix, .identity)
        XCTAssertTrue(Transform(pivot: Vec2(5, 5)).isIdentity, "a pivot alone moves nothing")
    }

    func testDecomposingGivesTheSameMatrix() throws {
        let t = Transform(position: Vec2(3, -4), rotation: 30, scale: Vec2(2, 0.5), pivot: Vec2(10, 20))
        let back = try XCTUnwrap(Transform(matrix: t.matrix, pivot: t.pivot, near: 0))
        XCTAssertEqual(back.rotation, 30, accuracy: 1e-9)
        assertClose(back.scale, Vec2(2, 0.5), tolerance: 1e-9)
        assertClose(back.position, Vec2(3, -4), tolerance: 1e-9)
        XCTAssertTrue(back.matrix.isApproximately(t.matrix, tolerance: 1e-9))
    }

    func testRotationKeepsCountingAndFlipsAreNegativeScales() throws {
        let spun = try XCTUnwrap(Transform(matrix: Affine2D.rotation(-170 * .pi / 180), pivot: .zero, near: 170))
        XCTAssertEqual(spun.rotation, 190, accuracy: 1e-9, "a turn past 180 keeps counting from where it was")
        let flipped = try XCTUnwrap(Transform(matrix: .scale(x: -1, y: 1), pivot: .zero, near: 0))
        XCTAssertEqual(flipped.rotation, 0)
        XCTAssertEqual(flipped.scale, Vec2(-1, 1))
    }

    func testSkewAndCollapseAreNotTransforms() {
        let skew = Affine2D(a: 1, b: 0, c: 0.5, d: 1, tx: 0, ty: 0)
        XCTAssertNil(Transform(matrix: skew, pivot: .zero))
        XCTAssertNil(Transform(matrix: .scale(x: 1, y: 0), pivot: .zero))
    }

    func testMovingThePivotKeepsTheMatrix() {
        let t = Transform(position: Vec2(5, 5), rotation: 40, scale: Vec2(1.5, 2), pivot: Vec2(0, 0))
        let moved = t.withPivot(Vec2(50, -20))
        XCTAssertEqual(moved.pivot, Vec2(50, -20))
        XCTAssertTrue(moved.matrix.isApproximately(t.matrix, tolerance: 1e-9))
    }

    // MARK: Composition

    func testLayerGroupAndShapeTransformsCompose() {
        var e = editor([square(0, 0)])
        let group = ShapeGroup(id: e.drawing.makeID(), name: "G", transform: Transform(position: Vec2(0, 50)))
        e.drawing.layers[0].groups = [group]
        e.drawing.layers[0].shapes[0].group = group.id
        e.drawing.layers[0].shapes[0].transform = Transform(scale: Vec2(2, 2))
        e.drawing.layers[0].transform = Transform(position: Vec2(100, 0))
        // Shape (scale 2 about the origin), then group (down 50), then layer (right 100).
        assertClose(world(e, 0, 0), [Vec2(100, 50), Vec2(300, 50), Vec2(300, 250), Vec2(100, 250)])
        XCTAssertEqual(e.drawing.layers[0].worldShape(0).stroke?.width, 4, "outlines scale with the art")
        let flat = e.drawing.world
        XCTAssertFalse(flat.layers[0].hasTransforms)
        assertClose(flat.layers[0].shapes[0].path.points.map(\.position), world(e, 0, 0))
    }

    // MARK: Select edits transforms

    func testDraggingALayerMovesItsTransformNotItsPoints() {
        var e = editor([square(0, 0)])
        let points = local(e, 0, 0)
        e.tool = .select
        drag(&e, Vec2(50, 50), Vec2(80, 90))
        XCTAssertEqual(e.selection, .layer(e.drawing.layers[0].id))
        XCTAssertEqual(local(e, 0, 0), points, "the points stay")
        assertClose(e.drawing.layers[0].transform.position, Vec2(30, 40))
        assertClose(world(e, 0, 0)[0], Vec2(30, 40))
        assertClose(e.drawing.layers[0].worldPivot, Vec2(80, 90), "the pivot moves with the layer")
        e.undo()
        XCTAssertEqual(e.drawing.layers[0].transform, Transform(pivot: Vec2(50, 50)))
    }

    func testRotatingALayerTurnsItsTransformAboutItsPivot() {
        var e = editor([square(0, 0)])
        e.tool = .select
        tap(&e, Vec2(50, 50))
        e.rotateSelection(byDegrees: 90)
        e.rotateSelection(byDegrees: 90)
        e.rotateSelection(byDegrees: 90)
        let layer = e.drawing.layers[0]
        XCTAssertEqual(layer.transform.rotation, 270, accuracy: 1e-9, "turns add up rather than wrapping")
        assertClose(layer.transform.position, .zero)
        XCTAssertEqual(local(e, 0, 0), ShapePrimitives.rectangle(square(0, 0)).points.map(\.position))
        assertClose(world(e, 0, 0), local(e, 0, 0).map(turn(270, about: Vec2(50, 50)).apply))
    }

    func testRotateHandleOnAShapeSetsItsPivotToTheCenter() throws {
        var e = editor([square(0, 0)])
        let ref = ShapeRef(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        e.tool = .select
        let frame = try XCTUnwrap(e.drawing.frame(of: e.selection))
        let handle = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset)
        drag(&e, handle, frame.center + Vec2(handle.distance(to: frame.center), 0))
        let t = e.drawing.layers[0].shapes[0].transform
        XCTAssertEqual(t.rotation, 90, accuracy: 1e-6)
        assertClose(t.pivot, Vec2(50, 50), tolerance: 1e-6, "turned about its middle")
        assertClose(t.position, .zero, tolerance: 1e-6)
        // The frame turns with the shape: its first corner, a stroke's half width outside
        // the top left, is now at the top right.
        let turned = try XCTUnwrap(e.drawing.frame(of: e.selection))
        assertClose(turned.corners[0], Vec2(101, -1), tolerance: 1e-6)
    }

    func testScalingAShapeScalesItsTransform() {
        var e = editor([square(0, 0)])
        let ref = ShapeRef(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        e.tool = .select
        // The bottom-right handle, from 101 (the outline reaches 1 past the square) to 201.
        drag(&e, Vec2(101, 101), Vec2(203, 203))
        let t = e.drawing.layers[0].shapes[0].transform
        XCTAssertEqual(t.scale.x, 2, accuracy: 1e-6)
        XCTAssertEqual(t.scale.y, 2, accuracy: 1e-6)
        assertClose(world(e, 0, 0)[2], Vec2(201, 201), tolerance: 1e-6)
    }

    func testAWholeGroupTakesTheTransformAndPartsOfItTheirShapes() {
        var e = editor([square(0, 0)])
        let id = e.drawing.makeID()
        e.drawing.layers[0].shapes.append(VectorShape(id: id, path: ShapePrimitives.rectangle(square(200, 0)), fill: .ink))
        let group = ShapeGroup(id: e.drawing.makeID(), name: "G")
        e.drawing.layers[0].groups = [group]
        for s in 0..<2 { e.drawing.layers[0].shapes[s].group = group.id }
        let layer = e.drawing.layers[0].id
        e.selection = .covering(Set(e.drawing.layers[0].shapes.map { ShapeRef(layer: layer, shape: $0.id) }))
        e.nudge(by: Vec2(5, 0))
        assertClose(e.drawing.layers[0].groups[0].transform.position, Vec2(5, 0))
        XCTAssertTrue(e.drawing.layers[0].shapes.allSatisfy { $0.transform.isIdentity })

        e.selection = .shape(layer: layer, shape: id)
        e.nudge(by: Vec2(0, 7))
        assertClose(e.drawing.layers[0].shapes[1].transform.position, Vec2(0, 7))
        assertClose(world(e, 0, 1)[0], Vec2(205, 7))
    }

    func testAStretchAcrossATurnedShapeGoesIntoThePoints() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].shapes[0].transform = Transform(rotation: 45, pivot: Vec2(50, 50))
        let ref = ShapeRef(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        let before = world(e, 0, 0)
        // A world-axis stretch of a turned square skews it: no transform can hold that.
        e.setSelectionSize(width: (e.selectionGeometry?.width ?? 0) * 2)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].transform.rotation, 45, "the transform stays")
        let after = world(e, 0, 0)
        let minX = before.map(\.x).min()!
        assertClose(after, before.map { Vec2(minX + ($0.x - minX) * 2, $0.y) }, tolerance: 1e-6)
    }

    // MARK: Apply Transform

    func testApplyTransformBakesWithoutMovingAnything() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(position: Vec2(10, 0), rotation: 30, scale: Vec2(2, 1), pivot: Vec2(50, 50))
        e.drawing.layers[0].shapes[0].transform = Transform(rotation: 10, pivot: Vec2(50, 50))
        let before = world(e, 0, 0)
        let pivot = e.drawing.layers[0].worldPivot
        e.selection = .layer(e.drawing.layers[0].id)
        XCTAssertTrue(e.canApplyTransform)
        e.applyTransform()
        XCTAssertFalse(e.drawing.layers[0].hasTransforms)
        assertClose(local(e, 0, 0), before, tolerance: 1e-9)
        assertClose(e.drawing.layers[0].pivot, pivot, tolerance: 1e-9)
        XCTAssertFalse(e.canApplyTransform)
        e.undo()
        XCTAssertTrue(e.drawing.layers[0].hasTransforms)
    }

    func testApplyTransformOnAShapeKeepsItsLayers() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(position: Vec2(10, 0))
        e.drawing.layers[0].shapes[0].transform = Transform(scale: Vec2(2, 2))
        let before = world(e, 0, 0)
        e.selection = .shape(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)
        e.applyTransform()
        XCTAssertTrue(e.drawing.layers[0].shapes[0].transform.isIdentity)
        assertClose(e.drawing.layers[0].transform.position, Vec2(10, 0))
        assertClose(world(e, 0, 0), before)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].stroke?.width, 4)
    }

    // MARK: Tools work where the art is drawn

    func testHitTestingAndFramesFollowTheTransform() throws {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(position: Vec2(500, 0))
        e.tool = .select
        tap(&e, Vec2(50, 50))
        XCTAssertEqual(e.selection, .none, "nothing is left where the points are")
        tap(&e, Vec2(550, 50))
        XCTAssertEqual(e.selection, .layer(e.drawing.layers[0].id))
        let frame = try XCTUnwrap(e.drawing.frame(of: e.selection))
        assertClose(frame.center, Vec2(550, 50))
    }

    func testDirectSelectDragsAnAnchorToWhereThePencilIs() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(rotation: 90, pivot: Vec2(50, 50))
        e.tool = .directSelect
        // The square's top-left corner (0, 0) is drawn at (100, 0) after the turn.
        tap(&e, Vec2(100, 0))
        XCTAssertEqual(e.selectedAnchors, [0])
        drag(&e, Vec2(100, 0), Vec2(120, -10))
        assertClose(world(e, 0, 0)[0], Vec2(120, -10))
        assertClose(local(e, 0, 0)[0], Vec2(-10, -20), "stored in the layer's own space")
    }

    func testNewArtInATransformedLayerLandsWhereItIsDrawn() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(rotation: 90, scale: Vec2(2, 2), pivot: Vec2(50, 50))
        e.setActiveLayer(e.drawing.layers[0].id)
        e.tool = .pen
        tap(&e, Vec2(300, 300))
        tap(&e, Vec2(400, 300))
        e.penFinish()
        XCTAssertEqual(e.drawing.layers.count, 1)
        assertClose(world(e, 0, 1), [Vec2(300, 300), Vec2(400, 300)])
    }

    func testMovingShapesBetweenLayersKeepsThemInPlace() {
        var e = editor([square(0, 0), square(200, 0)])
        e.drawing.layers[0].transform = Transform(position: Vec2(0, 100), rotation: 20, pivot: Vec2(50, 50))
        e.drawing.layers[1].transform = Transform(scale: Vec2(0.5, 0.5))
        let before = world(e, 0, 0)
        e.selection = .shape(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)
        e.moveSelection(toLayer: e.drawing.layers[1].id)
        XCTAssertEqual(e.drawing.layers.count, 1)
        assertClose(world(e, 0, 1), before, tolerance: 1e-9)

        e.selection = .shape(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[1].id)
        e.moveSelectionToNewLayer()
        assertClose(world(e, 1, 0), before, tolerance: 1e-9)
    }

    func testMergingDownKeepsTheUpperLayerInPlace() {
        var e = editor([square(0, 0), square(200, 0)])
        e.drawing.layers[1].transform = Transform(position: Vec2(30, 0), rotation: 45, pivot: Vec2(250, 50))
        let before = world(e, 1, 0)
        e.mergeLayerDown(e.drawing.layers[1].id)
        assertClose(world(e, 0, 1), before, tolerance: 1e-9)
    }

    func testDuplicatingAndPastingKeepTransforms() throws {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(rotation: 30, pivot: Vec2(50, 50))
        e.selection = .layer(e.drawing.layers[0].id)
        e.duplicateSelection()
        XCTAssertEqual(e.drawing.layers[1].transform.rotation, 30)
        assertClose(world(e, 1, 0), world(e, 0, 0).map { $0 + Vec2(10, 10) })

        let text = try XCTUnwrap(e.copySelection())
        var other = DrawingEditor()
        XCTAssertTrue(other.paste(text))
        XCTAssertEqual(other.drawing.layers[0].transform.rotation, 30)
        assertClose(world(other, 0, 0), world(e, 1, 0), tolerance: 1e-3)
    }

    func testMirroredCopiesMirrorTheDrawnShape() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].shapes[0].transform = Transform(position: Vec2(50, 0), rotation: 20, pivot: Vec2(50, 50))
        e.symmetry.axis = 300
        e.selection = .shape(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[0].id)
        e.duplicateMirrored()
        assertClose(world(e, 0, 1), world(e, 0, 0).map { Vec2(600 - $0.x, $0.y) }, tolerance: 1e-9)
    }

    // MARK: Saving

    func testTransformsSurviveTheFile() throws {
        var e = editor([square(0, 0)])
        let group = ShapeGroup(id: e.drawing.makeID(), name: "G", transform: Transform(rotation: -15, pivot: Vec2(10, 10)))
        e.drawing.layers[0].groups = [group]
        e.drawing.layers[0].shapes[0].group = group.id
        e.drawing.layers[0].shapes[0].transform = Transform(position: Vec2(1, 2), rotation: 720, scale: Vec2(-1, 2),
                                                            pivot: Vec2(50, 50))
        e.drawing.layers[0].transform = Transform(position: Vec2(5, 6), rotation: 12.5, scale: Vec2(1.5, 1.5),
                                                  pivot: Vec2(50, 50))
        let text = CharacterFormat.encode(e.drawing).formatted()
        XCTAssertFalse(CharacterFormat.encode(editor([square(0, 0)]).drawing).formatted().contains("transform"),
                       "nothing is written without transforms")
        let read = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(read.layers[0].transform, e.drawing.layers[0].transform)
        XCTAssertEqual(read.layers[0].groups[0].transform, group.transform)
        XCTAssertEqual(read.layers[0].shapes[0].transform, e.drawing.layers[0].shapes[0].transform)
    }

    func testRenderingDrawsTheWorldShapes() {
        var e = editor([square(0, 0)])
        e.drawing.layers[0].transform = Transform(position: Vec2(500, 0), rotation: 10, pivot: Vec2(50, 50))
        var builder = ArtBuilder()
        var flatBuilder = ArtBuilder()
        let art = builder.build(e.drawing, isolatedLayer: nil, tolerance: 0.25)
        let flat = flatBuilder.build(e.drawing.world, isolatedLayer: nil, tolerance: 0.25)
        XCTAssertEqual(art.vertices, flat.vertices)
        XCTAssertEqual(SVGWriter.document(for: e.drawing), SVGWriter.document(for: e.drawing.world))
    }
}
