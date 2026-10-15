import XCTest
@testable import ControlFlowCore

/// A 50-point square with its top-left corner at (`x`, 0).
private func square(_ x: Double) -> BezierPath {
    ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, 0), maxPoint: Vec2(x + 50, 50)))
}

private let red = RGBAColor(r: 1, g: 0, b: 0)

/// An editor with a Head layer of four squares (0 and 2 red, 1 and 3 white; 0-1 outlined
/// 2 wide, 2 outlined 4 wide, 3 not outlined), squares 1 and 2 grouped as "Eye", and a
/// Hair layer with one red square.
private func editor() -> DrawingEditor {
    var d = Drawing()
    let fills: [RGBAColor] = [red, .white, red, .white]
    let strokes: [StrokeStyle?] = [StrokeStyle(color: .ink, width: 2), StrokeStyle(color: .ink, width: 2),
                                   StrokeStyle(color: .ink, width: 4), nil]
    let shapes = (0..<4).map { i in
        VectorShape(id: d.makeID(), path: square(Double(i) * 100), fill: fills[i], stroke: strokes[i])
    }
    var head = Layer(id: d.makeID(), name: "Head", shapes: shapes)
    let eye = d.makeID()
    head.groups = [ShapeGroup(id: eye, name: "Eye")]
    head.shapes[1].group = eye
    head.shapes[2].group = eye
    d.layers.append(head)
    d.layers.append(Layer(id: d.makeID(), name: "Hair", shapes: [VectorShape(id: d.makeID(), path: square(500), fill: red)]))
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

private func refs(_ e: DrawingEditor, _ indices: [Int], layer: Int = 0) -> Set<ShapeRef> {
    let p = e.drawing.layers[layer]
    return Set(indices.map { ShapeRef(layer: p.id, shape: p.shapes[$0].id) })
}

private func titles(_ e: DrawingEditor) -> [String] {
    e.selectionCrumbs.map { $0.isCurrent ? "[\($0.title)]" : $0.title }
}

final class SelectMenuTests: XCTestCase {
    func testCrumbsWalkFromAShapeOutToTheLayer() {
        var e = editor()
        let head = e.drawing.layers[0].id, hair = e.drawing.layers[1].id
        let eye = e.drawing.layers[0].groups[0].id

        e.isolate(group: eye, inLayer: head)
        e.selection = .covering(refs(e, [1]))
        XCTAssertEqual(titles(e), ["Head", "Eye", "[Shape]"])

        e.selectParent()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [1, 2]))
        XCTAssertNil(e.isolatedGroup, "selecting the group leaves it")
        XCTAssertEqual(titles(e), ["Head", "[Eye]"])

        e.selectParent()
        XCTAssertEqual(e.selection, .layer(head))
        XCTAssertFalse(e.canSelectParent)

        e.selection = .covering(refs(e, [0], layer: 1))
        XCTAssertEqual(titles(e), ["Hair", "[Shape]"])
        e.selectParent()
        XCTAssertEqual(e.selection, .layer(hair))
        XCTAssertEqual(titles(e), ["[Hair]"])
        XCTAssertFalse(e.canSelectParent)
    }

    func testShapesInSeveralGroupsOrLayersHaveFewerCrumbs() {
        var e = editor()
        e.selection = .covering(refs(e, [0, 1]))
        XCTAssertEqual(titles(e), ["Head", "[2 Shapes]"])
        e.selection = .covering(refs(e, [0]).union(refs(e, [0], layer: 1)))
        XCTAssertEqual(titles(e), [])
        XCTAssertFalse(e.canSelectParent)
    }

    func testCrumbsShowTheIsolationWithNothingSelected() {
        var e = editor()
        let head = e.drawing.layers[0].id
        e.isolate(group: e.drawing.layers[0].groups[0].id, inLayer: head)
        e.selection = .none
        XCTAssertEqual(titles(e), ["Head", "Eye"])
        e.selectParent()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [1, 2]))
    }

    func testSelectAllInLayerAndInvertStayInTheLayerOrGroup() {
        var e = editor()
        e.selection = .covering(refs(e, [0]))
        XCTAssertEqual(e.selectionScopeLayer, e.drawing.layers[0].id)
        e.selectAllInLayer()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [0, 1, 2, 3]))
        if case .layer = e.selection { XCTFail("selects shapes, not the layer") }

        e.selection = .covering(refs(e, [0, 1]))
        e.invertSelection()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [2, 3]))

        e.isolate(group: e.drawing.layers[0].groups[0].id, inLayer: e.drawing.layers[0].id)
        e.selection = .covering(refs(e, [1]))
        e.invertSelection()
        XCTAssertEqual(e.selection, .shape(layer: e.drawing.layers[0].id, shape: e.drawing.layers[0].shapes[2].id))
        e.selection = .none
        e.selectAllInLayer()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [1, 2]))
    }

    func testSelectAllInLayerUsesTheActiveLayerWithNothingSelected() {
        var e = editor()
        XCTAssertFalse(e.canSelectAllInLayer)
        e.setActiveLayer(e.drawing.layers[1].id)
        e.selectAllInLayer()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [0], layer: 1))
    }

    func testSelectSameFillAcrossLayersSkipsLockedShapes() {
        var e = editor()
        e.drawing.layers[0].shapes[3].fill = red
        e.drawing.layers[0].shapes[3].isLocked = true
        e.selection = .covering(refs(e, [0]))
        e.selectSameFill()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [0, 2]).union(refs(e, [0], layer: 1)))

        // Inside an isolated layer it stays there.
        e.isolate(layer: e.drawing.layers[0].id)
        e.selection = .covering(refs(e, [0]))
        e.selectSameFill()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [0, 2]))
    }

    func testSelectSameOutlineMatchesWidthAndNoOutline() {
        var e = editor()
        e.selection = .covering(refs(e, [0]))
        e.selectSameOutline()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [0, 1]))

        e.selection = .covering(refs(e, [3]))
        e.selectSameOutline()
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [3]).union(refs(e, [0], layer: 1)))
    }

    func testSelectCommandsAreNotUndoSteps() {
        var e = editor()
        e.selection = .covering(refs(e, [0]))
        e.selectSameFill()
        e.invertSelection()
        e.selectParent()
        XCTAssertFalse(e.canUndo)
    }
}
