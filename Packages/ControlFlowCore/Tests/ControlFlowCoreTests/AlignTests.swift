import XCTest
@testable import ControlFlowCore

/// A `size`-point square with its top-left corner at (`x`, `y`).
private func square(_ x: Double, _ y: Double = 0, size: Double = 50) -> BezierPath {
    ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + size, y + size)))
}

/// An editor with the Select tool and one layer holding `paths`, on a 1000 by 500 viewport.
private func editor(_ paths: [BezierPath]) -> DrawingEditor {
    var d = Drawing()
    d.viewport = Viewport(width: 1000, height: 500)
    let shapes = paths.map { VectorShape(id: d.makeID(), path: $0, fill: .ink) }
    d.layers.append(Layer(id: d.makeID(), name: "Art", shapes: shapes))
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

private func refs(_ e: DrawingEditor, _ indices: [Int], layer: Int = 0) -> Set<ShapeRef> {
    let p = e.drawing.layers[layer]
    return Set(indices.map { ShapeRef(layer: p.id, shape: p.shapes[$0].id) })
}

/// The world box of shape `i` of layer `layer`.
private func box(_ e: DrawingEditor, _ i: Int, layer: Int = 0) -> Rect {
    e.drawing.layers[layer].worldShape(i).geometryBounds
}

final class AlignTests: XCTestCase {
    // MARK: Units

    func testLayersAreEachAUnit() {
        var e = editor([square(0)])
        e.drawing.layers.append(Layer(id: e.drawing.makeID(), name: "B", shapes: [VectorShape(id: e.drawing.makeID(), path: square(200, 100), fill: .ink)]))
        let ids = Set(e.drawing.layers.map(\.id))
        e.selection = .coveringLayers(ids)
        XCTAssertEqual(e.alignmentUnits(), e.drawing.layers.map { .layer($0.id) })
        e.align(.top, to: .selection)
        XCTAssertEqual(box(e, 0, layer: 1).minPoint.y, 0)
        XCTAssertEqual(e.drawing.layers[1].transform.position, Vec2(0, -100), "the layer moved, not its shapes")
        XCTAssertEqual(e.drawing.layers[1].shapes[0].transform, .identity)
    }

    func testAWholeGroupIsOneUnitAndMovesByItsTransform() {
        var e = editor([square(0), square(100), square(300, 200)])
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let group = e.drawing.layers[0].groups[0].id
        e.selection = .covering(refs(e, [0, 1, 2]))
        XCTAssertEqual(e.alignmentUnits().count, 2)
        e.align(.bottom, to: .selection)
        let layer = e.drawing.layers[0]
        XCTAssertEqual(layer.group(group)?.transform.position, Vec2(0, 200))
        XCTAssertEqual(layer.members(ofGroup: group).map { layer.shapes[$0].transform }, [.identity, .identity])
        XCTAssertEqual(layer.shapes.indices.map { layer.worldShape($0).geometryBounds.maxPoint.y }, [250, 250, 250])
    }

    func testPartOfAGroupIsEachShape() {
        var e = editor([square(0), square(100), square(300)])
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.groupSelection()
        e.selection = .covering(refs(e, [0, 1]))
        XCTAssertEqual(e.alignmentUnits().count, 2)
    }

    func testTheIsolatedGroupsShapesAreEachAUnit() {
        var e = editor([square(0), square(100)])
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let layer = e.drawing.layers[0]
        e.isolate(group: layer.groups[0].id, inLayer: layer.id)
        e.selection = .covering(refs(e, [0, 1]))
        XCTAssertEqual(e.alignmentUnits().count, 2)
    }

    func testDirectSelectPicksEachShapeInsideAGroup() {
        var e = editor([square(0), square(100)])
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        e.tool = .directSelect
        e.selection = .covering(refs(e, [0, 1]))
        XCTAssertEqual(e.alignmentUnits().count, 2)
    }

    // MARK: Align

    func testOneShapeCentersOnTheViewport() {
        var e = editor([square(10, 20)])
        e.selection = .covering(refs(e, [0]))
        XCTAssertTrue(e.alignsToViewportOnly)
        e.align(.centerX, to: .selection)
        e.align(.centerY, to: .selection)
        XCTAssertEqual(box(e, 0).center, Vec2(500, 250))
    }

    func testOneLayerAlignsToTheViewport() {
        var e = editor([square(10, 20), square(100, 40)])
        e.selection = .layer(e.drawing.layers[0].id)
        e.align(.right, to: .selection)
        XCTAssertEqual(box(e, 1).maxPoint.x, 1000)
        XCTAssertEqual(box(e, 0).maxPoint.x, 910, "the layer moves as one")
    }

    func testAlignLeftMovesOnlyTransforms() {
        var e = editor([square(30, 0), square(10, 100), square(200, 300, size: 80)])
        let paths = e.drawing.layers[0].shapes.map(\.path)
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.align(.left, to: .selection)
        XCTAssertEqual((0..<3).map { box(e, $0).minPoint.x }, [10, 10, 10])
        XCTAssertEqual(e.drawing.layers[0].shapes.map(\.path), paths, "points are untouched")
        XCTAssertEqual(e.drawing.layers[0].shapes.map(\.transform.position), [Vec2(-20, 0), .zero, Vec2(-190, 0)])
    }

    func testATurnedShapeAlignsByItsWorldBox() {
        var e = editor([square(0), square(300, 300)])
        e.selection = .covering(refs(e, [1]))
        e.rotateSelection(byDegrees: 45)
        e.selection = .covering(refs(e, [0, 1]))
        e.align(.top, to: .selection)
        XCTAssertEqual(box(e, 1).minPoint.y, 0, accuracy: 1e-9)
        XCTAssertEqual(box(e, 0).minPoint.y, 0, accuracy: 1e-9)
    }

    func testTextAlignsByItsBox() {
        var d = Drawing()
        d.viewport = Viewport(width: 1000, height: 500)
        let a = VectorShape(id: d.makeID(), text: TextContent(string: "Wide", size: 20), transform: Transform(position: Vec2(100, 0)))
        let b = VectorShape(id: d.makeID(), text: TextContent(string: "jig", size: 20), transform: Transform(position: Vec2(300, 100)))
        d.layers.append(Layer(id: d.makeID(), name: "Words", shapes: [a, b]))
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        e.selection = .covering(refs(e, [0, 1]))
        e.align(.left, to: .selection)
        XCTAssertEqual(box(e, 1).minPoint.x, box(e, 0).minPoint.x, accuracy: 1e-9)
        XCTAssertEqual(e.drawing.layers[0].shapes[1].transform.position.x, 100, accuracy: 1e-9)
    }

    func testEachUnitAlignsToTheViewportOnItsOwn() {
        var e = editor([square(30, 10), square(100, 100), square(200, 300, size: 80)])
        e.selection = .covering(refs(e, [0, 1, 2]))
        XCTAssertFalse(e.alignsToViewportOnly)
        e.align(.bottom, to: .viewport)
        XCTAssertEqual((0..<3).map { box(e, $0).maxPoint.y }, [500, 500, 500])
        XCTAssertEqual((0..<3).map { box(e, $0).minPoint.x }, [30, 100, 200], "x is untouched")
    }

    // MARK: Distribute

    func testDistributeSpacingKeepsTheOuterShapes() {
        var e = editor([square(0), square(70), square(400), square(600)])
        e.selection = .covering(refs(e, [0, 1, 2, 3]))
        e.distribute(.spacingX, to: .selection)
        XCTAssertEqual((0..<4).map { box(e, $0).minPoint.x }, [0, 200, 400, 600])

        e = editor([square(0), square(300, 30), square(400)])
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.distribute(.spacingX, to: .selection)
        XCTAssertEqual((0..<3).map { box(e, $0).minPoint.x }, [0, 200, 400])
        XCTAssertEqual(box(e, 1).minPoint.y, 30)
    }

    func testDistributeToTheViewportTouchesItsEdges() {
        var e = editor([square(100), square(150), square(300)])
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.distribute(.spacingX, to: .viewport)
        XCTAssertEqual((0..<3).map { box(e, $0).minPoint.x }, [0, 475, 950])
    }

    // MARK: Points

    func testDirectSelectAlignsAndDistributesTheSelectedAnchors() {
        let path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 30)), PathPoint(Vec2(50, 20)), PathPoint(Vec2(60, 90))])
        var e = editor([path])
        e.tool = .directSelect
        e.selection = .covering(refs(e, [0]))
        e.selectedAnchors = [0, 1, 2]
        XCTAssertTrue(e.canAlign)
        XCTAssertTrue(e.canDistribute)
        XCTAssertFalse(e.alignsToViewportOnly)
        e.align(.centerY, to: .viewport)
        let points = e.drawing.layers[0].shapes[0].path.points.map(\.position)
        XCTAssertEqual(points, [Vec2(0, 15), Vec2(10, 15), Vec2(50, 15), Vec2(60, 90)])

        e.distribute(.spacingX, to: .selection)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position.x), [0, 25, 50, 60])
    }

    // MARK: Undo and keyframes

    func testOneUndoRestoresEverythingAndANoOpAddsNoStep() {
        var e = editor([square(30), square(10, 100), square(200, 300)])
        let start = e.drawing
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.align(.left, to: .selection)
        XCTAssertNotEqual(e.drawing, start)
        let aligned = e.drawing
        e.align(.left, to: .selection)
        XCTAssertEqual(e.drawing, aligned)
        e.undo()
        XCTAssertEqual(e.drawing, start, "the second align added no step")
    }

    func testAligningAtAKeyframeIsAKeyedMove() {
        var e = editor([square(30), square(10, 100), square(200, 300)])
        let opening = e.drawing
        let k = e.setKeyframe()
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.align(.left, to: .selection)
        XCTAssertEqual(e.timeline.state(at: 0).layers, opening.layers, "the opening state is unchanged")
        let changes = e.timeline.presentation.keyframe(k)?.changes ?? []
        XCTAssertEqual(changes.count, 2, "the two shapes that moved are keyed")
        XCTAssertEqual((0..<3).map { box(e, $0).minPoint.x }, [10, 10, 10])
    }

    // MARK: Availability

    func testWhatEachSelectionCanDo() {
        var e = editor([square(0), square(100), square(200)])
        XCTAssertFalse(e.canAlign)
        e.selection = .covering(refs(e, [0]))
        XCTAssertTrue(e.canAlign)
        XCTAssertFalse(e.canDistribute)
        XCTAssertTrue(e.alignsToViewportOnly)
        e.selection = .covering(refs(e, [0, 1]))
        XCTAssertTrue(e.canAlign)
        XCTAssertFalse(e.canDistribute)
        XCTAssertFalse(e.alignsToViewportOnly)
        e.selection = .covering(refs(e, [0, 1, 2]))
        XCTAssertTrue(e.canDistribute)
        e.groupSelection()
        e.selection = .covering(refs(e, [0, 1, 2]))
        XCTAssertEqual(e.alignmentUnitCount, 1, "a whole group is one unit")
        XCTAssertTrue(e.alignsToViewportOnly)
        XCTAssertFalse(e.canDistribute)
        e.selection = .layer(e.drawing.layers[0].id)
        XCTAssertTrue(e.alignsToViewportOnly)
        e.tool = .directSelect
        e.selection = .covering(refs(e, [0]))
        e.selectedAnchors = [0]
        XCTAssertTrue(e.alignsToViewportOnly, "one anchor: the shape itself is the unit")
    }
}
