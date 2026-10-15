import XCTest
@testable import ControlFlowCore

/// Direct Select driven the way the app drives it: Pencil touches go through
/// `CanvasSession` (screen space, camera, palm and gesture routing) into
/// `DrawingEditor`, and the assertions look at the resulting drawing.
private struct Rig {
    var s: CanvasSession
    private var nextTouch = 1

    /// A 1000 x 800 view whose center is the world origin, at `zoom`.
    init(zoom: Double = 1) {
        s = CanvasSession(options: InputOptions())
        s.resetView(viewSize: Vec2(1000, 800))
        if zoom != 1 {
            s.camera = CanvasCamera(worldToScreen: Affine2D.translation(Vec2(500, 400)) * Affine2D.scale(zoom))
        }
    }

    /// The open path (0,0) (100,0) (100,100) (0,100), placed with the pen, ready in Direct Select.
    static func withPath(zoom: Double = 1) -> Rig {
        var rig = Rig(zoom: zoom)
        rig.s.editor.tool = .pen
        for p in [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)] { rig.tap(p) }
        rig.s.editor.penFinish()
        rig.s.editor.tool = .directSelect
        // The pen leaves its path selected; start with nothing selected.
        rig.s.editor.selection = .none
        return rig
    }

    var editor: DrawingEditor { s.editor }
    var path: BezierPath { s.editor.drawing.layers[0].shapes[0].path }
    var undoSteps: Int { s.editor.undoStack.undoStates.count }

    func screen(_ world: Vec2) -> Vec2 { s.camera.toScreen(world) }

    /// A Pencil tap at a world point, optionally wobbling by `jitter` screen points.
    mutating func tap(_ world: Vec2, jitter: Vec2 = .zero) {
        let id = nextTouch
        nextTouch += 1
        let p = screen(world)
        s.touchBegan(id: id, kind: .pencil, location: p)
        if jitter != .zero { s.touchMoved(id: id, samples: [p + jitter]) }
        s.touchEnded(id: id, location: p + jitter)
    }

    /// A Pencil drag between two world points in small steps, with predicted samples.
    mutating func drag(from a: Vec2, to b: Vec2, steps: Int = 10) {
        let id = nextTouch
        nextTouch += 1
        let start = screen(a), end = screen(b)
        s.touchBegan(id: id, kind: .pencil, location: start)
        for i in 1...steps {
            let q = Vec2.lerp(start, end, Double(i) / Double(steps))
            s.touchMoved(id: id, samples: [q], predicted: [q + Vec2(3, 3)])
        }
        s.touchEnded(id: id, location: end)
    }
}

private func assertClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b) \(message)", file: file, line: line)
}

final class DirectSelectFlowTests: XCTestCase {
    private let corners = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)]

    // MARK: Selecting

    func testTappingAShapeSelectsItAndShowsItsAnchors() {
        var rig = Rig.withPath()
        XCTAssertEqual(rig.editor.selection, Selection.none)
        let unselected = EditorOverlay.vertices(for: rig.editor, zoom: 1)
        let steps = rig.undoSteps

        // Tap on the line between two anchors.
        rig.tap(Vec2(50, 0))
        let layer = rig.editor.drawing.layers[0]
        XCTAssertEqual(rig.editor.selection, .shape(layer: layer.id, shape: layer.shapes[0].id))
        XCTAssertTrue(rig.editor.selectedAnchors.isEmpty)
        XCTAssertEqual(rig.path.points.count, 4, "the tap that selects must not insert a point")
        XCTAssertEqual(rig.undoSteps, steps, "selecting is not an edit")
        XCTAssertGreaterThan(EditorOverlay.vertices(for: rig.editor, zoom: 1).count, unselected.count, "anchors are drawn")
        XCTAssertFalse(rig.s.isPencilActive)
        XCTAssertFalse(rig.editor.isInGesture)
    }

    func testTappingAnAnchorSelectsIt() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        XCTAssertEqual(rig.editor.selectedAnchors, [1])
        XCTAssertNotNil(rig.editor.activeShape)
        // The selection survives the Pencil lifting.
        rig.tap(Vec2(100, 100))
        XCTAssertEqual(rig.editor.selectedAnchors, [2])
        XCTAssertNotNil(rig.editor.activeShape)
    }

    func testPencilJitterWithinTheSlopIsStillATap() {
        var rig = Rig.withPath()
        let steps = rig.undoSteps
        rig.tap(Vec2(100, 0), jitter: Vec2(3, 3))
        XCTAssertEqual(rig.editor.selectedAnchors, [1])
        XCTAssertEqual(rig.path.points.map(\.position), corners, "a wobbly tap must not nudge the anchor")
        XCTAssertEqual(rig.undoSteps, steps)
    }

    func testHitRadiiAreInScreenPointsAtAnyZoom() {
        // Zoomed in 4x: 12 screen points is 3 world points, still on the anchor.
        var near = Rig.withPath(zoom: 4)
        near.tap(Vec2(100 + 3, 0))
        XCTAssertEqual(near.editor.selectedAnchors, [1])
        // 8 world points is 32 screen points: well outside the anchor, the line and the shape.
        near.tap(Vec2(108, 0))
        XCTAssertTrue(near.editor.selectedAnchors.isEmpty)
        XCTAssertNotEqual(near.editor.selection, Selection.none, "first tap away only drops the anchors")
        near.tap(Vec2(108, 0))
        XCTAssertEqual(near.editor.selection, Selection.none)

        // Zoomed out to half: 10 screen points is 20 world points, still within reach.
        var far = Rig.withPath(zoom: 0.5)
        far.tap(Vec2(50, 0))
        far.tap(Vec2(100 + 20, 0))
        XCTAssertEqual(far.editor.selectedAnchors, [1])
    }

    // MARK: Anchors

    func testDraggingAnAnchorMovesItAndCommitsOneUndoStep() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        let steps = rig.undoSteps
        rig.drag(from: Vec2(100, 0), to: Vec2(130, 40))

        let points = rig.path.points
        assertClose(points[1].position, Vec2(130, 40))
        assertClose(points[0].position, Vec2(0, 0))
        assertClose(points[2].position, Vec2(100, 100))
        XCTAssertEqual(rig.editor.selectedAnchors, [1], "the dragged anchor stays selected")
        XCTAssertNotNil(rig.editor.activeShape)
        XCTAssertEqual(rig.undoSteps, steps + 1)

        rig.s.undo()
        assertClose(rig.path.points[1].position, Vec2(100, 0))
        rig.s.redo()
        assertClose(rig.path.points[1].position, Vec2(130, 40))
    }

    func testDraggingAnAnchorOfAnUnselectedShapeWorksInOnePress() {
        var rig = Rig.withPath()
        // No tap first: the press selects the shape and grabs the anchor.
        rig.drag(from: Vec2(0, 100), to: Vec2(-20, 130))
        assertClose(rig.path.points[3].position, Vec2(-20, 130))
        XCTAssertEqual(rig.editor.selectedAnchors, [3])
    }

    func testAnchorDragIsOneToOneAtAnyZoom() {
        var rig = Rig.withPath(zoom: 2)
        rig.tap(Vec2(100, 0))
        // 60 x 80 screen points at 2x is 30 x 40 world points.
        let from = rig.screen(Vec2(100, 0))
        rig.drag(from: Vec2(100, 0), to: rig.s.camera.toWorld(from + Vec2(60, 80)))
        assertClose(rig.path.points[1].position, Vec2(130, 40), tolerance: 1e-6)
    }

    func testMarqueePicksAnchorsAndTheyMoveTogether() {
        var rig = Rig.withPath()
        rig.tap(Vec2(50, 0))
        rig.drag(from: Vec2(-30, -30), to: Vec2(130, 30))
        XCTAssertEqual(rig.editor.selectedAnchors, [0, 1])
        XCTAssertNil(rig.editor.marquee)

        rig.drag(from: Vec2(100, 0), to: Vec2(100, 30))
        let points = rig.path.points
        assertClose(points[0].position, Vec2(0, 30))
        assertClose(points[1].position, Vec2(100, 30))
        assertClose(points[2].position, Vec2(100, 100))
        XCTAssertEqual(rig.editor.selectedAnchors, [0, 1])
    }

    func testCancelledDragRestoresTheAnchor() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        let steps = rig.undoSteps
        let start = rig.screen(Vec2(100, 0))
        rig.s.touchBegan(id: 90, kind: .pencil, location: start)
        rig.s.touchMoved(id: 90, samples: [start + Vec2(40, 40)])
        assertClose(rig.path.points[1].position, Vec2(140, 40), tolerance: 1e-6)
        rig.s.touchCancelled(id: 90)
        assertClose(rig.path.points[1].position, Vec2(100, 0))
        XCTAssertEqual(rig.undoSteps, steps)
        XCTAssertFalse(rig.s.isPencilActive)
    }

    // MARK: Closing edge

    func testDraggingAnEndAnchorOntoTheOtherEndClosesTheShapeWithAnEdge() {
        var rig = Rig.withPath()
        rig.tap(Vec2(0, 100))
        let steps = rig.undoSteps
        let placed = rig.path.points.map(\.position)
        // A little off the target anchor, but within reach of it.
        rig.drag(from: Vec2(0, 100), to: Vec2(4, 5))

        XCTAssertTrue(rig.path.closed)
        XCTAssertEqual(rig.path.points.map(\.position), placed, "no anchor moved; an edge was added")
        XCTAssertTrue(rig.path.points[3].stroked, "the new edge is outlined")
        XCTAssertNil(rig.editor.closingEdge)
        XCTAssertEqual(rig.undoSteps, steps + 1)

        rig.s.undo()
        XCTAssertFalse(rig.path.closed)
        XCTAssertEqual(rig.path.points.map(\.position), placed)
    }

    func testClosingEdgePreviewsOverTheOtherEndAndLetsGoWhenMovedAway() throws {
        var rig = Rig.withPath()
        let start = rig.screen(Vec2(0, 100))
        rig.s.touchBegan(id: 91, kind: .pencil, location: start)
        rig.s.touchMoved(id: 91, samples: [rig.screen(Vec2(0, 50))])
        assertClose(rig.path.points[3].position, Vec2(0, 50))
        XCTAssertNil(rig.editor.closingEdge)

        rig.s.touchMoved(id: 91, samples: [rig.screen(Vec2(2, 3))])
        let edge = try XCTUnwrap(rig.editor.closingEdge)
        assertClose(edge.from, Vec2(0, 100))
        assertClose(edge.to, Vec2(0, 0))
        assertClose(rig.path.points[3].position, Vec2(0, 100), tolerance: 1e-6, "the anchor waits at its start")

        // Moving away goes back to moving the anchor, and lifting there does not close.
        rig.s.touchMoved(id: 91, samples: [rig.screen(Vec2(-30, 40))])
        XCTAssertNil(rig.editor.closingEdge)
        rig.s.touchEnded(id: 91, location: rig.screen(Vec2(-30, 40)))
        XCTAssertFalse(rig.path.closed)
        assertClose(rig.path.points[3].position, Vec2(-30, 40))
    }

    func testOnlyEndAnchorsOfOpenPathsDrawAClosingEdge() {
        var rig = Rig.withPath()
        // A middle anchor dropped on an end just moves.
        rig.drag(from: Vec2(100, 100), to: Vec2(0, 100))
        XCTAssertFalse(rig.path.closed)
        assertClose(rig.path.points[2].position, Vec2(0, 100))

        // Both ends moving together never close onto each other.
        var both = Rig.withPath()
        both.tap(Vec2(50, 0))
        both.s.editor.selectedAnchors = [0, 3]
        both.drag(from: Vec2(0, 100), to: Vec2(0, 0))
        XCTAssertFalse(both.path.closed)
    }

    func testAShortHandleDoesNotStealThePressFromItsAnchor() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        rig.s.editor.drawing.layers[0].shapes[0].path.points[1] =
            PathPoint(Vec2(100, 0), in: Vec2(-4, 0), out: Vec2(4, 0), mode: .smooth)
        // One point left of the anchor: the anchor is nearer than either handle.
        rig.drag(from: Vec2(99, 0), to: Vec2(99, 30))
        let point = rig.path.points[1]
        assertClose(point.position, Vec2(100, 30))
        XCTAssertEqual(point.inHandle, Vec2(-4, 0))
        XCTAssertEqual(point.outHandle, Vec2(4, 0))
    }

    // MARK: Handles

    private func smoothAnchorWithHandles() -> Rig {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        rig.s.editor.setSelectedAnchorMode(.smooth)
        return rig
    }

    func testDraggingAHandleReshapesWithoutJumpingAndHonoursTheMode() {
        var rig = smoothAnchorWithHandles()
        let before = rig.path.points[1]
        XCTAssertGreaterThan(before.outHandle.length, 1)
        XCTAssertGreaterThan(before.inHandle.length, 1)
        let handle = before.outControl
        let steps = rig.undoSteps

        // Press 5 points off the handle's center; the handle must move by exactly the drag.
        rig.drag(from: handle + Vec2(5, 3), to: handle + Vec2(5, 3 + 40))
        let after = rig.path.points[1]
        assertClose(after.position, Vec2(100, 0))
        assertClose(after.outHandle, before.outHandle + Vec2(0, 40), tolerance: 1e-6)
        // Smooth: the other handle turns to stay opposite and keeps its length.
        assertClose(after.inHandle, -after.outHandle.normalized * before.inHandle.length, tolerance: 1e-6)
        XCTAssertEqual(rig.editor.selectedAnchors, [1])
        XCTAssertEqual(rig.undoSteps, steps + 1)

        rig.s.undo()
        XCTAssertEqual(rig.path.points[1], before)
    }

    func testTappingAHandleChangesNothing() {
        var rig = smoothAnchorWithHandles()
        let before = rig.path
        let steps = rig.undoSteps
        rig.tap(before.points[1].outControl + Vec2(6, 0))
        XCTAssertEqual(rig.path, before, "the handle must not jump to the Pencil tip")
        XCTAssertEqual(rig.undoSteps, steps)
        XCTAssertEqual(rig.editor.selectedAnchors, [1])
    }

    func testSymmetricModeMirrorsTheOtherHandleWhileDragging() {
        var rig = smoothAnchorWithHandles()
        rig.s.editor.setSelectedAnchorMode(.symmetric)
        let handle = rig.path.points[1].inControl
        rig.drag(from: handle, to: handle + Vec2(-10, 25))
        let point = rig.path.points[1]
        assertClose(point.outHandle, -point.inHandle, tolerance: 1e-6)
    }

    // MARK: Segments

    func testDraggingASegmentReshapesTheCurve() {
        var rig = Rig.withPath()
        rig.tap(Vec2(50, 0))
        let steps = rig.undoSteps
        rig.drag(from: Vec2(50, 0), to: Vec2(50, 40))

        XCTAssertEqual(rig.path.points.count, 4, "a drag reshapes; only a tap inserts a point")
        XCTAssertEqual(rig.path.points.map(\.position), corners)
        XCTAssertEqual(rig.path.segment(0).point(at: 0.5).y, 40, accuracy: 0.01)
        XCTAssertEqual(rig.undoSteps, steps + 1)
        XCTAssertNotNil(rig.editor.activeShape)

        rig.s.undo()
        XCTAssertEqual(rig.path.points[0].outHandle, .zero)
        XCTAssertEqual(rig.path.points[1].inHandle, .zero)
    }

    func testDraggingASegmentOfAnUnselectedShapeWorksInOnePress() {
        var rig = Rig.withPath()
        rig.drag(from: Vec2(50, 100), to: Vec2(50, 70))
        XCTAssertEqual(rig.path.points.count, 4)
        XCTAssertEqual(rig.path.segment(2).point(at: 0.5).y, 70, accuracy: 0.01)
    }

    func testTappingASelectedShapesSegmentInsertsAnAnchor() {
        var rig = Rig.withPath()
        rig.tap(Vec2(50, 0))
        rig.tap(Vec2(50, 100))
        XCTAssertEqual(rig.path.points.count, 5)
        XCTAssertEqual(rig.editor.selectedAnchors, [3], "the new anchor is selected, at its index in the path")
        // The split point is found numerically, so allow a hair of error along the line.
        assertClose(rig.path.points[3].position, Vec2(50, 100), tolerance: 0.01)
        XCTAssertEqual(rig.path.points[4].position, Vec2(0, 100))
        // Its position is still where the curve was, so it can be dragged at once.
        rig.drag(from: Vec2(50, 100), to: Vec2(50, 130))
        assertClose(rig.path.points[3].position, Vec2(50, 130), tolerance: 0.01)
    }

    // MARK: Point commands

    func testDeletePointActsOnTheSelectedAnchor() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        XCTAssertTrue(rig.editor.canDeleteSelectedAnchor)
        let steps = rig.undoSteps
        rig.s.editor.deleteSelectedAnchors()
        XCTAssertEqual(rig.path.points.map(\.position), [corners[0], corners[2], corners[3]])
        XCTAssertTrue(rig.editor.selectedAnchors.isEmpty)
        XCTAssertEqual(rig.undoSteps, steps + 1)

        // The remaining anchors still pick by their new indices.
        rig.tap(Vec2(0, 100))
        XCTAssertEqual(rig.editor.selectedAnchors, [2])
        rig.s.undo()
        XCTAssertEqual(rig.path.points.map(\.position), corners)
    }

    func testPointTypeAndBreakHandlesActOnTheSelectedAnchors() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        rig.s.editor.addToSelection = true
        rig.tap(Vec2(100, 100))
        rig.s.editor.addToSelection = false
        XCTAssertEqual(rig.editor.selectedAnchors, [1, 2])

        rig.s.editor.setSelectedAnchorMode(.symmetric)
        XCTAssertEqual(rig.path.points.map(\.mode), [.corner, .symmetric, .symmetric, .corner])
        XCTAssertEqual(rig.editor.selectedAnchorMode, .symmetric)
        XCTAssertGreaterThan(rig.path.points[1].outHandle.length, 1)

        rig.s.editor.breakSelectedAnchorHandles()
        XCTAssertEqual(rig.path.points.map(\.mode), [.corner, .corner, .corner, .corner])
        XCTAssertEqual(rig.path.points[1].outHandle, .zero)
        XCTAssertEqual(rig.path.points[2].inHandle, .zero)
        XCTAssertEqual(rig.editor.selectedAnchors, [1, 2], "commands keep the anchor selection")
    }

    func testNudgeMovesTheSelectedAnchorsNotTheWholeShape() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        let steps = rig.undoSteps
        rig.s.editor.nudge(by: Vec2(1, 0))
        rig.s.editor.nudge(by: Vec2(1, 0))
        XCTAssertEqual(rig.path.points.map(\.position), [corners[0], Vec2(102, 0), corners[2], corners[3]])
        XCTAssertEqual(rig.undoSteps, steps + 1, "repeated nudges are one undo step")
        rig.s.undo()
        XCTAssertEqual(rig.path.points.map(\.position), corners)
    }

    func testSplitAtTheSelectedAnchor() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        XCTAssertTrue(rig.editor.canSplitAtSelectedAnchor)
        rig.s.editor.splitAtSelectedAnchor()
        XCTAssertEqual(rig.editor.drawing.shapeCount, 2)
        XCTAssertEqual(rig.editor.drawing.layers[0].shapes.map(\.path.points.count), [2, 3])
        rig.s.undo()
        XCTAssertEqual(rig.editor.drawing.shapeCount, 1)
    }

    func testTappingEmptyCanvasDropsAnchorsThenSelection() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        rig.tap(Vec2(400, 400))
        XCTAssertTrue(rig.editor.selectedAnchors.isEmpty)
        XCTAssertNotEqual(rig.editor.selection, Selection.none)
        rig.tap(Vec2(400, 400))
        XCTAssertEqual(rig.editor.selection, Selection.none)
    }

    func testFingersDoNotEditPoints() {
        var rig = Rig.withPath()
        rig.tap(Vec2(100, 0))
        let before = rig.path
        let p = rig.screen(Vec2(100, 0))
        rig.s.touchBegan(id: 70, kind: .finger, location: p)
        rig.s.touchMoved(id: 70, samples: [p + Vec2(50, 50)])
        rig.s.touchEnded(id: 70, location: p + Vec2(50, 50))
        XCTAssertEqual(rig.path, before)
    }
}
