import XCTest
@testable import ControlFlowCore

final class SmartGuideTests: XCTestCase {
    private let a = Rect(minPoint: Vec2(100, 100), maxPoint: Vec2(200, 200))

    // MARK: Matching

    func testABoxNearAnotherEdgeSnapsThatAxisOnly() {
        let targets = GuideTargets(boxes: [a], viewport: nil)
        let box = Rect(minPoint: Vec2(300, 500), maxPoint: Vec2(350, 550))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(-197, 0), targets: targets, radius: 6)
        XCTAssertEqual(r.delta, Vec2(-200, 0))
        XCTAssertEqual(r.x, 100)
        XCTAssertNil(r.y)
        let lines = SmartGuides.lines(box: box.offset(r.delta), x: r.x, y: r.y, targets: targets)
        XCTAssertEqual(lines, [GuideLine(from: Vec2(100, 100), to: Vec2(100, 550), isCenter: false)])
    }

    func testMiddlesLineUpAsCenters() {
        let targets = GuideTargets(boxes: [a], viewport: nil)
        let box = Rect(minPoint: Vec2(0, 500), maxPoint: Vec2(50, 550))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(122, 0), targets: targets, radius: 6)
        XCTAssertEqual(r.delta, Vec2(125, 0))
        XCTAssertEqual(r.x, 150)
        let lines = SmartGuides.lines(box: box.offset(r.delta), x: r.x, y: nil, targets: targets)
        // From middle to middle.
        XCTAssertEqual(lines, [GuideLine(from: Vec2(150, 150), to: Vec2(150, 525), isCenter: true)])
    }

    func testNothingSnapsJustOutsideTheRadius() {
        let targets = GuideTargets(boxes: [a], viewport: nil)
        let box = Rect(minPoint: Vec2(300, 500), maxPoint: Vec2(350, 550))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(-193.5, 0), targets: targets, radius: 6)
        XCTAssertEqual(r.delta, Vec2(-193.5, 0))
        XCTAssertNil(r.x)
        XCTAssertNil(r.y)
    }

    func testEachAxisSnapsOnItsOwn() {
        let targets = GuideTargets(boxes: [a], viewport: nil)
        let box = Rect(minPoint: Vec2(300, 300), maxPoint: Vec2(350, 350))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(-198, -103), targets: targets, radius: 6)
        XCTAssertEqual(r.delta, Vec2(-200, -100))
        XCTAssertEqual(r.x, 100)
        XCTAssertEqual(r.y, 200)
        // An axis left alone (a constrained move) doesn't snap.
        let across = SmartGuides.snapMove(box: box, delta: Vec2(-198, -103), targets: targets, radius: 6, snapY: false)
        XCTAssertEqual(across.delta, Vec2(-200, -103))
        XCTAssertNil(across.y)
    }

    func testTheViewportCenterLineSpansTheViewport() {
        let viewport = Viewport().bounds
        let targets = GuideTargets(boxes: [], viewport: viewport)
        let box = Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(100, 100))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(908, 300), targets: targets, radius: 6)
        XCTAssertEqual(r.delta.x, 910)
        XCTAssertEqual(r.x, 960)
        let lines = SmartGuides.lines(box: box.offset(r.delta), x: r.x, y: r.y, targets: targets)
        XCTAssertEqual(lines.first, GuideLine(from: Vec2(960, 0), to: Vec2(960, 1080), isCenter: true))
    }

    func testTheLineReachesEveryBoxOnTheCoordinate() {
        let c = Rect(minPoint: Vec2(100, 600), maxPoint: Vec2(300, 700))
        let targets = GuideTargets(boxes: [a, c], viewport: nil)
        let box = Rect(minPoint: Vec2(400, 300), maxPoint: Vec2(450, 350))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(-298, 0), targets: targets, radius: 6)
        let lines = SmartGuides.lines(box: box.offset(r.delta), x: r.x, y: r.y, targets: targets)
        XCTAssertEqual(lines, [GuideLine(from: Vec2(100, 100), to: Vec2(100, 700), isCenter: false)])
    }

    func testOnATieAnEdgeBeatsAMiddle() {
        let targets = GuideTargets(boxes: [Rect(minPoint: Vec2(53, 0), maxPoint: Vec2(253, 10)),
                                           Rect(minPoint: Vec2(103, 50), maxPoint: Vec2(105, 60))], viewport: nil)
        let box = Rect(minPoint: Vec2(0, 500), maxPoint: Vec2(100, 510))
        let r = SmartGuides.snapMove(box: box, delta: Vec2(100, 0), targets: targets, radius: 6)
        // Middle to middle (150 to 153) and edge to edge (100 to 103) are both 3 away.
        XCTAssertEqual(r.x, 103)
    }

    func testADraggedEdgeSnaps() {
        let targets = GuideTargets(boxes: [a], viewport: nil)
        let hit = SmartGuides.snapPoint(Vec2(203, 50), targets: targets, radius: 6)
        XCTAssertEqual(hit.x, 200)
        XCTAssertNil(hit.y)
        XCTAssertNil(SmartGuides.snapPoint(Vec2(203, 50), targets: targets, radius: 6, snapX: false).x)
    }

    // MARK: Dragging in the editor

    /// Shapes A (100,100)-(200,200), B (400,400)-(480,480), C (206,700)-(300,800) and
    /// D (500,0)-(600,50), each on its own layer, with B selected in Select.
    private func editor() -> DrawingEditor {
        var d = Drawing()
        for r in [a, Rect(minPoint: Vec2(400, 400), maxPoint: Vec2(480, 480)),
                  Rect(minPoint: Vec2(206, 700), maxPoint: Vec2(300, 800)), Rect(minPoint: Vec2(500, 0), maxPoint: Vec2(600, 50))] {
            let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: .ink, stroke: nil)
            d.layers.append(Layer(id: d.makeID(), name: "Layer", shapes: [shape]))
        }
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        e.selection = .shape(layer: d.layers[1].id, shape: d.layers[1].shapes[0].id)
        return e
    }

    private func boxOfB(_ e: DrawingEditor) -> Rect { e.drawing.geometryBounds(of: e.selection)! }

    /// Clear of B's pivot (its middle) and handles.
    private let grab = Vec2(420, 455)

    func testADragLinesUpWithAnEdgeAndTheViewportMiddle() {
        var e = editor()
        let steps = e.undoStack.undoStates.count
        e.pencilBegan(at: grab, zoom: 1)
        e.pencilMoved(to: Vec2(300, 480))
        // B's left edge 3 from A's, and its middle 2 from the viewport's.
        let end = grab + Vec2(-297, 98)
        e.pencilMoved(to: end)
        XCTAssertEqual(boxOfB(e), Rect(minPoint: Vec2(100, 500), maxPoint: Vec2(180, 580)))
        XCTAssertEqual(e.guideLines.count, 2)
        XCTAssertTrue(e.guideLines.contains(GuideLine(from: Vec2(100, 100), to: Vec2(100, 580), isCenter: false)))
        XCTAssertTrue(e.guideLines.contains(GuideLine(from: Vec2(0, 540), to: Vec2(1920, 540), isCenter: true)))
        var cache = OverlayCache()
        let withLines = EditorOverlay.layers(for: e, zoom: 1, cache: &cache).guides.count
        e.pencilEnded(at: end)
        XCTAssertEqual(boxOfB(e), Rect(minPoint: Vec2(100, 500), maxPoint: Vec2(180, 580)))
        XCTAssertTrue(e.guideLines.isEmpty)
        XCTAssertLessThan(EditorOverlay.layers(for: e, zoom: 1, cache: &cache).guides.count, withLines, "the overlay drew them")
        XCTAssertEqual(e.undoStack.undoStates.count, steps + 1, "one drag, one undo step")
        e.undo()
        XCTAssertEqual(boxOfB(e), Rect(minPoint: Vec2(400, 400), maxPoint: Vec2(480, 480)))
    }

    func testTurnedOffNothingSnaps() {
        var e = editor()
        e.snap.smartGuides = false
        let end = grab + Vec2(-297, 98)
        e.pencilBegan(at: grab, zoom: 1)
        e.pencilMoved(to: end)
        XCTAssertTrue(e.guideLines.isEmpty)
        e.pencilEnded(at: end)
        XCTAssertEqual(boxOfB(e).minPoint, Vec2(103, 498))
    }

    func testTheRadiusIsInScreenPoints() {
        var e = editor()
        // At 4x zoom 6 screen points are 1.5 world points, so 3 away doesn't snap.
        let end = grab + Vec2(-297, 0)
        e.pencilBegan(at: grab, zoom: 4)
        e.pencilMoved(to: end)
        e.pencilEnded(at: end)
        XCTAssertEqual(boxOfB(e).minPoint.x, 103)
    }

    func testAnAnchorSnapBeatsAGuide() {
        var e = editor()
        e.snap = SnapSettings(isEnabled: true, toAnchors: true, toGrid: false)
        // B's top-left corner 5 from A's bottom-right anchor (200, 200); on its own, the
        // guides would take B's left edge to C's (206).
        let end = grab + Vec2(-196, -197)
        e.pencilBegan(at: grab, zoom: 1)
        e.pencilMoved(to: end)
        XCTAssertTrue(e.guideLines.isEmpty)
        e.pencilEnded(at: end)
        XCTAssertEqual(boxOfB(e).minPoint, Vec2(200, 200))

        var guided = editor()
        guided.pencilBegan(at: grab, zoom: 1)
        guided.pencilMoved(to: end)
        guided.pencilEnded(at: end)
        XCTAssertEqual(boxOfB(guided).minPoint, Vec2(206, 200))
    }

    func testANearerGridLineTakesTheAxis() {
        var e = editor()
        e.snap = SnapSettings(isEnabled: true, toAnchors: false, toGrid: true, gridSize: 7)
        // B's left edge at 104: 4 from A's edge, 1 from the grid line at 105.
        let end = grab + Vec2(-296, 0)
        e.pencilBegan(at: grab, zoom: 1)
        e.pencilMoved(to: end)
        e.pencilEnded(at: end)
        XCTAssertEqual(boxOfB(e).minPoint.x, 105, accuracy: 1e-9)
    }

    func testAStretchSnapsItsMovingEdge() {
        var e = editor()
        // B's right edge handle, dragged to 3 short of D's left edge.
        e.pencilBegan(at: Vec2(480, 440), zoom: 1)
        e.pencilMoved(to: Vec2(490, 440))
        e.pencilMoved(to: Vec2(497, 440))
        XCTAssertEqual(e.guideLines, [GuideLine(from: Vec2(500, 0), to: Vec2(500, 480), isCenter: false)])
        e.pencilEnded(at: Vec2(497, 440))
        let box = boxOfB(e)
        XCTAssertEqual(box.minPoint.x, 400, accuracy: 1e-9)
        XCTAssertEqual(box.maxPoint.x, 500, accuracy: 1e-9)
        XCTAssertEqual(box.height, 80, accuracy: 1e-9)
    }

    func testACornerScaleSnapsTheDraggedCorner() {
        var e = editor()
        // B's bottom-right corner, dragged out to 3 short of D's left edge.
        e.pencilBegan(at: Vec2(480, 480), zoom: 1)
        e.pencilMoved(to: Vec2(490, 490))
        e.pencilMoved(to: Vec2(497, 497))
        XCTAssertFalse(e.guideLines.isEmpty)
        e.pencilEnded(at: Vec2(497, 497))
        let box = boxOfB(e)
        XCTAssertEqual(box.minPoint.x, 400, accuracy: 1e-9)
        XCTAssertEqual(box.maxPoint.x, 500, accuracy: 1e-9)
        XCTAssertEqual(box.height, 100, accuracy: 1e-9, "the scale stays uniform")
    }

    func testRotatingShowsNoGuides() {
        var e = editor()
        // The rotate handle, 28 points above the top edge's middle.
        e.pencilBegan(at: Vec2(440, 372), zoom: 1)
        e.pencilMoved(to: Vec2(470, 380))
        XCTAssertTrue(e.guideLines.isEmpty)
        e.pencilEnded(at: Vec2(470, 380))
    }

    func testTargetsLeaveOutTheDraggedShapesAndKeepHiddenOnesOut() {
        var e = editor()
        e.drawing.layers[2].isHidden = true
        let targets = e.makeGuideTargets(in: e.drawing, excluding: e.selection)
        let xs = Set(targets.xs.map(\.value))
        XCTAssertTrue(xs.isSuperset(of: [100, 150, 200, 500, 550, 600, 0, 960, 1920]))
        XCTAssertFalse(xs.contains(400), "B is the one moving")
        XCTAssertFalse(xs.contains(206), "C is hidden")
    }

    func testAGroupIsATargetAsAWhole() {
        var d = Drawing()
        let one = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(10, 10))),
                              fill: .ink, stroke: nil)
        let two = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(90, 0), maxPoint: Vec2(100, 10))),
                              fill: .ink, stroke: nil)
        let three = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(300, 0), maxPoint: Vec2(310, 10))),
                                fill: .ink, stroke: nil)
        var layer = Layer(id: d.makeID(), name: "Layer", shapes: [one, two, three])
        let group = ShapeGroup(id: d.makeID(), name: "Group")
        layer.groups = [group]
        layer.shapes[0].group = group.id
        layer.shapes[1].group = group.id
        d.layers = [layer]
        let e = DrawingEditor(drawing: d)
        // The group's middle (50) is a target when the loose shape moves...
        let loose = e.makeGuideTargets(in: d, excluding: .shape(layer: layer.id, shape: three.id))
        XCTAssertTrue(loose.xs.contains { $0.value == 50 && $0.kind == .center })
        // ...but not when one of its own shapes does.
        let member = e.makeGuideTargets(in: d, excluding: .shape(layer: layer.id, shape: one.id))
        XCTAssertFalse(member.xs.contains { $0.value == 50 })
    }
}

private extension Rect {
    func offset(_ d: Vec2) -> Rect { Rect(minPoint: minPoint + d, maxPoint: maxPoint + d) }
}
