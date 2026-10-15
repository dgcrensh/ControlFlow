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

/// A pen path through `points`, finished, in the pen tool.
private func penPath(_ points: [Vec2], in e: inout DrawingEditor) {
    e.tool = .pen
    for p in points { tap(&e, p) }
    e.penFinish()
}

/// An editor holding one closed 100 x 100 square drawn with the pencil.
private func editorWithSquare() -> DrawingEditor {
    var e = DrawingEditor()
    e.smoothing = 0
    var pts: [Vec2] = []
    let corners = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100), Vec2(0, 0)]
    for k in 0..<4 {
        for i in 0..<25 { pts.append(Vec2.lerp(corners[k], corners[k + 1], Double(i) / 25)) }
    }
    pts.append(Vec2(0, 1))
    e.addStroke(pts, zoom: 1)
    return e
}

final class HandleModeTests: XCTestCase {
    private func path() -> BezierPath {
        BezierPath(points: [
            PathPoint(Vec2(0, 0)),
            PathPoint(Vec2(50, 0), in: Vec2(-10, 0), out: Vec2(30, 0), mode: .symmetric),
            PathPoint(Vec2(100, 0)),
        ])
    }

    func testSymmetricHandlesMirrorExactly() {
        var p = path()
        p.setHandle(1, .outgoing, to: Vec2(50, 30))
        assertClose(p.points[1].outHandle, Vec2(0, 30))
        assertClose(p.points[1].inHandle, Vec2(0, -30))
        p.setHandle(1, .incoming, to: Vec2(40, 0))
        assertClose(p.points[1].outHandle, Vec2(10, 0))
    }

    func testCornerHandlesMoveIndependently() {
        var p = path()
        p.setMode(1, .corner)
        p.setHandle(1, .outgoing, to: Vec2(50, 30))
        assertClose(p.points[1].outHandle, Vec2(0, 30))
        assertClose(p.points[1].inHandle, Vec2(-10, 0))
    }

    func testSmoothKeepsTheOtherHandlesLength() {
        var p = path()
        p.setMode(1, .smooth)
        p.setHandle(1, .outgoing, to: Vec2(50, 30))
        assertClose(p.points[1].inHandle, Vec2(0, -10))
    }

    func testSettingSymmetricEqualizesLengths() {
        var p = path()
        p.points[1].mode = .smooth
        p.points[1].outHandle = Vec2(30, 0)
        p.setMode(1, .symmetric)
        XCTAssertEqual(p.points[1].outHandle.length, 20, accuracy: 1e-9)
        XCTAssertEqual(p.points[1].inHandle.length, 20, accuracy: 1e-9)
        assertClose(p.points[1].outHandle, -p.points[1].inHandle)
    }

    func testSymmetricFromNoHandlesDerivesFromNeighbours() {
        var p = BezierPath(points: [PathPoint(Vec2(0, 0), smooth: false), PathPoint(Vec2(60, 60), smooth: false),
                                    PathPoint(Vec2(120, 0), smooth: false)])
        p.setMode(1, .symmetric)
        XCTAssertEqual(p.points[1].mode, .symmetric)
        assertClose(p.points[1].outHandle, -p.points[1].inHandle)
        XCTAssertGreaterThan(p.points[1].outHandle.length, 1)
    }

    func testBreakHandlesRetractsToACorner() {
        var p = path()
        p.breakHandles(1)
        XCTAssertEqual(p.points[1].mode, .corner)
        XCTAssertEqual(p.points[1].inHandle, .zero)
        XCTAssertEqual(p.points[1].outHandle, .zero)
    }

    func testIsSmoothKeepsSymmetric() {
        var pt = PathPoint(Vec2(0, 0), in: .zero, out: .zero, mode: .symmetric)
        pt.isSmooth = true
        XCTAssertEqual(pt.mode, .symmetric)
        pt.isSmooth = false
        XCTAssertEqual(pt.mode, .corner)
        pt.isSmooth = true
        XCTAssertEqual(pt.mode, .smooth)
    }

    func testSymmetricModeSurvivesTheFileFormat() throws {
        var d = Drawing()
        var path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(50, 0), in: Vec2(-5, 5), out: Vec2(5, -5), mode: .symmetric),
                                       PathPoint(Vec2(100, 0), smooth: false)])
        path.closed = false
        d.layers = [Layer(id: 1, name: "A", shapes: [VectorShape(id: 2, path: path, stroke: StrokeStyle(color: .ink, width: 2))])]
        d.nextID = 3
        let text = PresentationFormat.encode(d).formatted()
        XCTAssertEqual(text.components(separatedBy: "\"symmetric\"").count - 1, 1, "only the symmetric point is marked")
        let back = try PresentationFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(back.layers[0].shapes[0].path.points.map(\.mode), [.smooth, .symmetric, .corner])
    }
}

final class PathEditingTests: XCTestCase {
    func testDeleteHealsTheCurveAndKeepsNeighbourHandles() {
        // One curve split at its middle, then the middle point removed: the original comes back.
        var path = BezierPath(points: [PathPoint(Vec2(0, 0), out: Vec2(0, 100), smooth: false),
                                       PathPoint(Vec2(200, 0), in: Vec2(0, 100), smooth: false)])
        let original = path.segment(0)
        path.insertPoint(segment: 0, t: 0.5)
        XCTAssertEqual(path.points.count, 3)
        path.removePoint(at: 1)
        XCTAssertEqual(path.points.count, 2)
        let healed = path.segment(0)
        assertClose(healed.p1, original.p1, tolerance: 1e-9)
        assertClose(healed.p2, original.p2, tolerance: 1e-9)
        // Directions of the neighbours' handles are kept.
        XCTAssertTrue(path.points[0].outHandle.normalized.isApproximately(Vec2(0, 1), tolerance: 1e-9))
    }

    func testDeletingAnEndPointJustShortensTheOpenPath() {
        var path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0)), PathPoint(Vec2(20, 0))])
        path.removePoint(at: 0)
        XCTAssertEqual(path.points.map(\.position), [Vec2(10, 0), Vec2(20, 0)])
    }

    func testDeletingOnAClosedPathHealsAcrossTheSeam() {
        var path = BezierPath(points: [PathPoint(Vec2(0, 0), in: Vec2(0, -10), out: Vec2(10, 0), smooth: false),
                                       PathPoint(Vec2(100, 0), in: Vec2(-10, 0), out: Vec2(10, 0), smooth: false),
                                       PathPoint(Vec2(100, 100), in: Vec2(-10, 0), out: Vec2(10, 0), smooth: false),
                                       PathPoint(Vec2(0, 100), in: Vec2(10, 0), smooth: false)], closed: true)
        path.removePoint(at: 3)
        XCTAssertEqual(path.points.count, 3)
        XCTAssertTrue(path.closed)
        // The neighbours across the removed point keep a handle each, lengthened.
        XCTAssertGreaterThan(path.points[2].outHandle.length, 0)
        XCTAssertGreaterThan(path.points[0].inHandle.length, 0)
    }

    func testRemovePointsHealsEachInTurn() {
        var path = BezierPath(points: (0..<6).map { PathPoint(Vec2(Double($0) * 10, 0), smooth: false) })
        path.removePoints(at: [1, 3])
        XCTAssertEqual(path.points.map(\.position.x), [0, 20, 40, 50])
    }

    func testSplitOpenPath() throws {
        let path = BezierPath(points: (0..<4).map { PathPoint(Vec2(Double($0) * 10, 0), in: Vec2(-3, 0), out: Vec2(3, 0)) })
        let pieces = try XCTUnwrap(path.split(at: 1))
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].points.count, 2)
        XCTAssertEqual(pieces[1].points.count, 3)
        XCTAssertEqual(pieces[0].points[1].position, pieces[1].points[0].position)
        XCTAssertEqual(pieces[0].points[1].outHandle, .zero)
        XCTAssertEqual(pieces[1].points[0].inHandle, .zero)
        XCTAssertEqual(pieces[0].points[1].mode, .corner)
        XCTAssertNil(path.split(at: 0), "splitting at an end makes no new path")
        XCTAssertNil(path.split(at: 3))
    }

    func testSplitClosedPathOpensAtThePoint() throws {
        let path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(100, 0)), PathPoint(Vec2(50, 80))], closed: true)
        let pieces = try XCTUnwrap(path.split(at: 1))
        XCTAssertEqual(pieces.count, 1)
        XCTAssertFalse(pieces[0].closed)
        XCTAssertEqual(pieces[0].points.map(\.position), [Vec2(100, 0), Vec2(50, 80), Vec2(0, 0), Vec2(100, 0)])
    }

    func testReversedSwapsHandles() {
        let path = BezierPath(points: [PathPoint(Vec2(0, 0), in: Vec2(1, 2), out: Vec2(3, 4)), PathPoint(Vec2(10, 0), in: Vec2(5, 6), out: Vec2(7, 8))])
        let r = path.reversed()
        XCTAssertEqual(r.points[0].position, Vec2(10, 0))
        XCTAssertEqual(r.points[0].inHandle, Vec2(7, 8))
        XCTAssertEqual(r.points[0].outHandle, Vec2(5, 6))
        XCTAssertEqual(r.reversed(), path)
    }

    func testJoinConnectsOrMergesEnds() throws {
        let a = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0), in: Vec2(-2, 0))])
        let b = BezierPath(points: [PathPoint(Vec2(30, 0), out: Vec2(2, 0)), PathPoint(Vec2(40, 0))])
        let apart = try XCTUnwrap(BezierPath.joined(a, .end, b, .start))
        XCTAssertEqual(apart.points.map(\.position.x), [0, 10, 30, 40])

        let c = BezierPath(points: [PathPoint(Vec2(10, 0), out: Vec2(2, 0)), PathPoint(Vec2(20, 0))])
        let merged = try XCTUnwrap(BezierPath.joined(a, .end, c, .start))
        XCTAssertEqual(merged.points.map(\.position.x), [0, 10, 20])
        XCTAssertEqual(merged.points[1].inHandle, Vec2(-2, 0))
        XCTAssertEqual(merged.points[1].outHandle, Vec2(2, 0))

        // End to end flips the second path.
        let flipped = try XCTUnwrap(BezierPath.joined(a, .end, b, .end))
        XCTAssertEqual(flipped.points.map(\.position.x), [0, 10, 40, 30])
        XCTAssertNil(BezierPath.joined(a, .end, BezierPath(points: b.points, closed: true), .start))
    }

    func testCloseByJoiningEnds() throws {
        let open = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0)), PathPoint(Vec2(10, 10)), PathPoint(Vec2(0, 0))])
        let closed = try XCTUnwrap(open.closedByJoiningEnds())
        XCTAssertTrue(closed.closed)
        XCTAssertEqual(closed.points.count, 3, "coincident ends merge")
        XCTAssertNil(BezierPath(points: Array(open.points.prefix(2))).closedByJoiningEnds())
    }

    func testCloseWithStraightEdge() throws {
        let open = BezierPath(points: [
            PathPoint(Vec2(0, 0), in: Vec2(-5, 0), out: Vec2(5, 0)),
            PathPoint(Vec2(10, 0)),
            PathPoint(Vec2(10, 10), in: Vec2(0, -5), out: Vec2(0, 5)),
        ])
        let closed = try XCTUnwrap(open.closedWithStraightEdge())
        XCTAssertTrue(closed.closed)
        XCTAssertEqual(closed.points.map(\.position), open.points.map(\.position))
        XCTAssertEqual(closed.points[0].inHandle, .zero)
        XCTAssertEqual(closed.points[0].outHandle, Vec2(5, 0), "the other handle stays")
        XCTAssertEqual(closed.points[2].outHandle, .zero)
        XCTAssertEqual(closed.points[2].inHandle, Vec2(0, -5))
        XCTAssertEqual(closed.points[0].mode, .corner)
        XCTAssertEqual(closed.points[2].mode, .corner)
        let edge = closed.segment(2)
        XCTAssertEqual(edge.p1, edge.p0, "the closing edge is straight")
        XCTAssertEqual(edge.p2, edge.p3)

        XCTAssertNil(closed.closedWithStraightEdge(), "already closed")
        let line = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0))])
        XCTAssertNil(line.closedWithStraightEdge(), "a straight line encloses nothing")
        let arc = BezierPath(points: [PathPoint(Vec2(0, 0), out: Vec2(0, -5)), PathPoint(Vec2(10, 0), in: Vec2(0, -5))])
        XCTAssertNotNil(arc.closedWithStraightEdge(), "a curved segment closes into a D")
        let loop = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0)), PathPoint(Vec2(0, 0))])
        XCTAssertNil(loop.closedWithStraightEdge(), "ends that meet need no edge")
    }

    func testReshapeSegmentMovesTheCurveUnderTheDrag() {
        var path = BezierPath(points: [PathPoint(Vec2(0, 0), smooth: false), PathPoint(Vec2(100, 0), smooth: false)])
        path.reshapeSegment(0, t: 0.5, by: Vec2(0, 40))
        assertClose(path.segment(0).point(at: 0.5), Vec2(50, 40), tolerance: 1e-9)
        XCTAssertEqual(path.points[0].position, Vec2(0, 0), "anchors stay")
    }

    func testReshapeSegmentHonoursNeighbourModes() {
        var path = BezierPath(points: [
            PathPoint(Vec2(-100, 0), out: Vec2(50, 0), smooth: false),
            PathPoint(Vec2(0, 0), in: Vec2(-40, 0), out: Vec2(40, 0), mode: .symmetric),
            PathPoint(Vec2(100, 0), in: Vec2(-50, 0), smooth: false),
        ])
        path.reshapeSegment(1, t: 0.5, by: Vec2(0, 30))
        // The symmetric point's out handle moved, so its in handle mirrors it.
        assertClose(path.points[1].inHandle, -path.points[1].outHandle, tolerance: 1e-9)
        XCTAssertNotEqual(path.points[1].outHandle.y, 0)
    }
}

final class SnappingTests: XCTestCase {
    private let grid = SnapSettings(isEnabled: true, toAnchors: false, toGrid: true, gridSize: 10)

    func testDisabledLeavesPointsAlone() {
        let r = Snapper.snap(Vec2(12, 19), settings: SnapSettings(), anchors: [], radius: 5)
        XCTAssertEqual(r.point, Vec2(12, 19))
    }

    func testGridSnapsEachAxisWithinTheRadius() {
        let r = Snapper.snap(Vec2(12, 19), settings: grid, anchors: [], radius: 3)
        XCTAssertEqual(r.point, Vec2(10, 20))
        let far = Snapper.snap(Vec2(15, 14), settings: grid, anchors: [], radius: 3)
        XCTAssertEqual(far.point, Vec2(15, 14))
        XCTAssertFalse(far.snappedX || far.snappedY)
        let oneAxis = Snapper.snap(Vec2(11, 15), settings: grid, anchors: [], radius: 3)
        XCTAssertEqual(oneAxis.point, Vec2(10, 15))
        XCTAssertTrue(oneAxis.snappedX)
        XCTAssertFalse(oneAxis.snappedY)
    }

    func testAnchorsBeatTheGrid() {
        var settings = grid
        settings.toAnchors = true
        let r = Snapper.snap(Vec2(8, 8), settings: settings, anchors: [Vec2(7, 7), Vec2(40, 40)], radius: 3)
        XCTAssertEqual(r.point, Vec2(7, 7))
        let none = Snapper.snap(Vec2(8, 8), settings: settings, anchors: [Vec2(40, 40)], radius: 3)
        XCTAssertEqual(none.point, Vec2(10, 10))
    }

    func testTranslationTakesTheClosestPointsAdjustment() {
        let delta = Snapper.snapTranslation(Vec2(9.6, 0.3), of: [Vec2(0, 0), Vec2(50, 0)], settings: grid, anchors: [], radius: 1)
        assertClose(delta, Vec2(10, 0))
    }

    func testAnchorDragSnapsToTheGridAndSkipsItself() throws {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        e.tool = .directSelect
        e.snap = grid
        drag(&e, Vec2(100, 0), Vec2(123, 41))
        let path = e.drawing.layers[0].shapes[0].path
        assertClose(path.points[1].position, Vec2(120, 40))

        // Snapping to another shape's anchor, within 8 screen points at zoom 1.
        e.snap = SnapSettings(isEnabled: true, toAnchors: true, toGrid: false)
        penPath([Vec2(300, 300), Vec2(400, 300)], in: &e)
        e.tool = .directSelect
        drag(&e, Vec2(120, 40), Vec2(296, 304))
        assertClose(e.drawing.layers[0].shapes[0].path.points[1].position, Vec2(300, 300))
    }

    func testSnapRadiusShrinksWithZoom() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        e.tool = .directSelect
        e.snap = SnapSettings(isEnabled: true, toAnchors: false, toGrid: true, gridSize: 10)
        // At 4x zoom the radius is 2 world points, so 3 away from a grid line does not snap.
        e.pencilBegan(at: Vec2(100, 0), zoom: 4)
        e.pencilMoved(to: Vec2(113, 0))
        e.pencilEnded(at: Vec2(113, 0))
        assertClose(e.drawing.layers[0].shapes[0].path.points[1].position, Vec2(113, 0))
    }

    func testMoveSnapsTheSelectionFrame() {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        e.snap = grid
        let before = e.drawing.frame(of: e.selection)!
        drag(&e, Vec2(20, 20), Vec2(20 + 37.2, 20 + 12.1))
        let after = e.drawing.frame(of: e.selection)!
        // The frame center landed on the grid or one of its corners did.
        // Some corner or the center sits on a vertical grid line, and some on a horizontal one.
        let keyPoints = after.corners + [after.center]
        XCTAssertTrue(keyPoints.contains { abs($0.x / 10 - ($0.x / 10).rounded()) < 1e-6 })
        XCTAssertTrue(keyPoints.contains { abs($0.y / 10 - ($0.y / 10).rounded()) < 1e-6 })
        XCTAssertNotEqual(after.corners[0], before.corners[0])
    }
}

final class PenToolTests: XCTestCase {
    func testTapsPlaceCornerAnchors() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        tap(&e, Vec2(100, 0))
        tap(&e, Vec2(100, 100))
        XCTAssertEqual(e.drawing.layers.count, 1)
        let path = e.drawing.layers[0].shapes[0].path
        XCTAssertEqual(path.points.map(\.position), [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)])
        XCTAssertEqual(path.points.map(\.mode), [.corner, .corner, .corner])
        XCTAssertFalse(path.closed)
        XCTAssertTrue(e.isPenActive)
        XCTAssertEqual(e.undoStack.undoStates.count, 3, "one undo step per anchor")
        e.undo()
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.count, 2)
        XCTAssertTrue(e.isPenActive)
        e.undo()
        e.undo()
        XCTAssertTrue(e.drawing.layers.isEmpty)
        XCTAssertFalse(e.isPenActive)
    }

    func testDragAfterPlacingPullsASymmetricHandle() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        drag(&e, Vec2(100, 0), Vec2(130, 20))
        let point = e.drawing.layers[0].shapes[0].path.points[1]
        assertClose(point.position, Vec2(100, 0))
        assertClose(point.outHandle, Vec2(30, 20))
        assertClose(point.inHandle, Vec2(-30, -20))
        XCTAssertEqual(point.mode, .symmetric)
        XCTAssertEqual(e.undoStack.undoStates.count, 2)
    }

    func testTinyMovementIsStillATap() {
        var e = DrawingEditor()
        e.tool = .pen
        drag(&e, Vec2(0, 0), Vec2(2, 0))
        let point = e.drawing.layers[0].shapes[0].path.points[0]
        XCTAssertEqual(point.mode, .corner)
        XCTAssertEqual(point.outHandle, .zero)
    }

    func testTappingTheFirstAnchorClosesThePath() {
        var e = DrawingEditor()
        e.tool = .pen
        for p in [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)] { tap(&e, p) }
        tap(&e, Vec2(3, 4))
        let shape = e.drawing.layers[0].shapes[0]
        XCTAssertTrue(shape.path.closed)
        XCTAssertEqual(shape.path.points.count, 3)
        XCTAssertNotNil(shape.visibleFill)
        XCTAssertFalse(e.isPenActive)
        XCTAssertEqual(e.undoStack.undoStates.count, 4)
        // The next tap starts a new path.
        tap(&e, Vec2(300, 300))
        XCTAssertEqual(e.drawing.layers.count, 2)
    }

    func testTwoAnchorsDoNotCloseOnTheFirst() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        tap(&e, Vec2(100, 0))
        tap(&e, Vec2(2, 2))
        XCTAssertFalse(e.drawing.layers[0].shapes[0].path.closed)
    }

    func testDoneAndDoubleTapEndAnOpenPath() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        tap(&e, Vec2(100, 0))
        tap(&e, Vec2(100, 0))
        XCTAssertFalse(e.isPenActive, "tapping the end again finishes")
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.count, 2)

        tap(&e, Vec2(300, 0))
        tap(&e, Vec2(400, 0))
        e.penFinish()
        XCTAssertFalse(e.isPenActive)
        XCTAssertEqual(e.drawing.shapeCount, 2)

        // A lone anchor is not a path.
        tap(&e, Vec2(0, 500))
        e.penFinish()
        XCTAssertEqual(e.drawing.shapeCount, 2)
    }

    func testSwitchingToolsFinishesThePath() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        tap(&e, Vec2(100, 0))
        e.tool = .select
        XCTAssertFalse(e.isPenActive)
        XCTAssertEqual(e.drawing.shapeCount, 1)
    }

    func testTappingAnOpenEndContinuesThePath() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)], in: &e)
        XCTAssertFalse(e.isPenActive)
        tap(&e, Vec2(100, 100))
        XCTAssertTrue(e.isPenActive)
        XCTAssertEqual(e.drawing.shapeCount, 1, "continuing adds nothing yet")
        tap(&e, Vec2(200, 100))
        XCTAssertEqual(e.drawing.shapeCount, 1)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position.x), [0, 100, 100, 200])
    }

    func testContinuingFromTheStartExtendsThatEnd() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        tap(&e, Vec2(0, 0))
        tap(&e, Vec2(-100, 0))
        XCTAssertEqual(e.drawing.shapeCount, 1)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position.x), [100, 0, -100])
    }

    func testTappingAnotherOpenPathsEndJoinsThem() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        penPath([Vec2(300, 0), Vec2(400, 0)], in: &e)
        XCTAssertEqual(e.drawing.layers.count, 2)
        e.tool = .pen
        tap(&e, Vec2(100, 0))
        tap(&e, Vec2(300, 0))
        XCTAssertEqual(e.drawing.layers.count, 1, "the emptied layer is removed")
        XCTAssertEqual(e.drawing.shapeCount, 1)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position.x), [0, 100, 300, 400])
        XCTAssertFalse(e.isPenActive)
        e.undo()
        XCTAssertEqual(e.drawing.shapeCount, 2)
    }

    func testPathsStartNewLayersUnlessAutoJoinIsOn() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        penPath([Vec2(0, 50), Vec2(100, 50)], in: &e)
        XCTAssertEqual(e.drawing.layers.count, 2)

        e.autoJoinSelectedLayer = true
        e.selection = .layer(e.drawing.layers[0].id)
        penPath([Vec2(0, 200), Vec2(100, 200)], in: &e)
        XCTAssertEqual(e.drawing.layers.count, 2)
        XCTAssertEqual(e.drawing.layers[0].shapes.count, 2)
    }

    func testRubberBandRunsFromTheActiveEndToTheHover() {
        var e = DrawingEditor()
        e.tool = .pen
        XCTAssertNil(e.penPreview)
        tap(&e, Vec2(0, 0))
        e.pencilHovered(at: Vec2(50, 40))
        let preview = e.penPreview
        XCTAssertEqual(preview?.p0, Vec2(0, 0))
        XCTAssertEqual(preview?.p3, Vec2(50, 40))
        XCTAssertFalse(EditorOverlay.vertices(for: e, zoom: 1).isEmpty)
        e.pencilHovered(at: nil)
        XCTAssertNil(e.penPreview)
    }

    func testFillAppliesOnceClosedAndOutlineOffDropsTheStroke() {
        var e = DrawingEditor()
        e.style.outlineEnabled = false
        e.tool = .pen
        for p in [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100)] { tap(&e, p) }
        XCTAssertNotNil(e.drawing.layers[0].shapes[0].stroke, "visible while open")
        tap(&e, Vec2(0, 0))
        XCTAssertNil(e.drawing.layers[0].shapes[0].stroke)
        XCTAssertNotNil(e.drawing.layers[0].shapes[0].fill)
        XCTAssertFalse(e.style.outlineEnabled, "selecting the shape does not change the user's style")
    }

    func testSessionRoutesPencilTouchesByTool() {
        var s = CanvasSession(options: InputOptions())
        s.resetView(viewSize: Vec2(1000, 800))
        s.editor.tool = .pen
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        XCTAssertNil(s.liveStroke, "the pen does not draw freehand")
        s.touchEnded(id: 1, location: Vec2(500, 400))
        s.touchBegan(id: 2, kind: .pencil, location: Vec2(600, 400))
        s.touchEnded(id: 2, location: Vec2(600, 400))
        let placed = s.editor.drawing.layers[0].shapes[0].path.points.map(\.position)
        XCTAssertEqual(placed.count, 2)
        assertClose(placed[0], Vec2(0, 0))
        assertClose(placed[1], Vec2(100, 0))

        s.editor.penFinish()
        s.editor.tool = .pencil
        s.touchBegan(id: 3, kind: .pencil, location: Vec2(500, 600))
        XCTAssertNotNil(s.liveStroke)
        s.touchCancelled(id: 3)

        s.editor.tool = .pen
        s.pencilHovered(at: Vec2(700, 400))
        XCTAssertNil(s.editor.penPreview, "no active path, no preview")
        tap(&s.editor, Vec2(0, 300))
        s.pencilHovered(at: Vec2(700, 400))
        assertClose(s.editor.penPreview?.p3 ?? .zero, Vec2(200, 0))
    }
}

final class SelectionTests: XCTestCase {
    /// Two wide lines in separate layers, y = 0 and y = 300.
    private func twoLines() -> DrawingEditor {
        var e = DrawingEditor()
        e.addStroke([Vec2(0, 0), Vec2(400, 0)], zoom: 1)
        e.addStroke([Vec2(0, 300), Vec2(400, 300)], zoom: 1)
        return e
    }

    func testCoveringNormalizesTheSet() {
        let a = ShapeRef(layer: 1, shape: 2), b = ShapeRef(layer: 1, shape: 3)
        XCTAssertEqual(Selection.covering([]), Selection.none)
        XCTAssertEqual(Selection.covering([a]), .shape(layer: 1, shape: 2))
        XCTAssertEqual(Selection.covering([a, b]), .shapes([a, b]))
    }

    func testMarqueeSelectsTouchedShapesAndPromotesWholeLayers() {
        var e = twoLines()
        e.tool = .select
        drag(&e, Vec2(-20, -20), Vec2(420, 100))
        XCTAssertEqual(e.selection, .layer(e.drawing.layers[0].id), "one whole layer")
        XCTAssertNil(e.marquee)

        drag(&e, Vec2(-20, -20), Vec2(420, 320))
        guard case .shapes(let refs) = e.selection else { return XCTFail("expected a multi-selection") }
        XCTAssertEqual(refs.count, 2)

        // A marquee over nothing clears the selection.
        drag(&e, Vec2(-200, 500), Vec2(-100, 600))
        XCTAssertEqual(e.selection, Selection.none)
        // The marquee does not change the drawing.
        XCTAssertEqual(e.undoStack.undoStates.count, 2)
    }

    func testMarqueeCrossingALongSegmentSelectsIt() {
        var e = twoLines()
        e.tool = .select
        // Neither end of the line is inside the rectangle.
        drag(&e, Vec2(150, -30), Vec2(250, 30))
        XCTAssertEqual(e.selection, .layer(e.drawing.layers[0].id))
    }

    func testAddToggleBuildsAndShrinksTheSelection() {
        var e = twoLines()
        e.tool = .select
        e.addToSelection = true
        tap(&e, Vec2(100, 0))
        let first = e.drawing.layers[0].shapes[0]
        XCTAssertEqual(e.selection, .shape(layer: e.drawing.layers[0].id, shape: first.id))
        tap(&e, Vec2(100, 300))
        guard case .shapes(let refs) = e.selection else { return XCTFail("expected two shapes") }
        XCTAssertEqual(refs.count, 2)
        tap(&e, Vec2(100, 0))
        XCTAssertEqual(e.selection, .shape(layer: e.drawing.layers[1].id, shape: e.drawing.layers[1].shapes[0].id))
        // Tapping empty canvas with Add on keeps the selection.
        tap(&e, Vec2(-300, -300))
        XCTAssertNotEqual(e.selection, Selection.none)
    }

    func testMultiSelectionMovesTogether() {
        var e = twoLines()
        e.tool = .select
        drag(&e, Vec2(-20, -20), Vec2(420, 320))
        let before = e.drawing
        drag(&e, Vec2(100, 150), Vec2(130, 190))
        for (i, layer) in e.drawing.layers.enumerated() {
            let a = before.layers[i].worldShape(0).path.points[0].position
            assertClose(layer.worldShape(0).path.points[0].position, a + Vec2(30, 40))
        }
        XCTAssertEqual(e.undoStack.undoStates.count, 3)
        e.undo()
        XCTAssertEqual(e.drawing, before)
    }

    func testMultiSelectionDeletesAndStyles() {
        var e = twoLines()
        e.tool = .select
        drag(&e, Vec2(-20, -20), Vec2(420, 320))
        e.setOutlineWidth(9)
        XCTAssertEqual(e.drawing.layers.map { $0.shapes[0].stroke?.width }, [9, 9])
        e.deleteSelection()
        XCTAssertTrue(e.drawing.layers.isEmpty)
        e.undo()
        XCTAssertEqual(e.drawing.layers.count, 2)
    }

    func testDirectSelectShowsAnchorsOfTheTappedShapeAtOnce() {
        var e = twoLines()
        e.tool = .directSelect
        e.pencilBegan(at: Vec2(100, 300), zoom: 1)
        XCTAssertEqual(e.selection, .shape(layer: e.drawing.layers[1].id, shape: e.drawing.layers[1].shapes[0].id),
                       "selected on press, before any tap completes")
        e.pencilEnded(at: Vec2(100, 300))
        XCTAssertFalse(EditorOverlay.vertices(for: e, zoom: 1).isEmpty)
        XCTAssertEqual(e.undoStack.undoStates.count, 2, "selecting is not an edit")
    }

    func testDirectSelectMarqueePicksAnchorsAndTheyMoveTogether() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)], in: &e)
        e.tool = .directSelect
        tap(&e, Vec2(0, 0))
        XCTAssertEqual(e.selectedAnchors, [0])
        drag(&e, Vec2(-20, -20), Vec2(120, 20))
        XCTAssertEqual(e.selectedAnchors, [0, 1])
        XCTAssertNil(e.selectedAnchor)

        drag(&e, Vec2(100, 0), Vec2(100, 30))
        let points = e.drawing.layers[0].shapes[0].path.points
        assertClose(points[0].position, Vec2(0, 30))
        assertClose(points[1].position, Vec2(100, 30))
        assertClose(points[2].position, Vec2(100, 100))
        XCTAssertEqual(e.selectedAnchors, [0, 1])

        // Add toggles single anchors.
        e.addToSelection = true
        tap(&e, Vec2(100, 100))
        XCTAssertEqual(e.selectedAnchors, [0, 1, 2])
        tap(&e, Vec2(0, 30))
        XCTAssertEqual(e.selectedAnchors, [1, 2])
    }

    func testTappingAnotherShapesAnchorNarrowsTheSelection() {
        var e = twoLines()
        e.tool = .select
        drag(&e, Vec2(-20, -20), Vec2(420, 320))
        e.tool = .directSelect
        tap(&e, Vec2(400, 300))
        XCTAssertEqual(e.activeShape, ShapeRef(layer: e.drawing.layers[1].id, shape: e.drawing.layers[1].shapes[0].id))
        XCTAssertEqual(e.selectedAnchors.count, 1)
    }
}

final class PointEditingTests: XCTestCase {
    private func fourPointPath() -> DrawingEditor {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)], in: &e)
        e.tool = .directSelect
        return e
    }

    func testDeleteAnchorsKeepsTheShapeAndHeals() {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        e.addToSelection = true
        tap(&e, Vec2(100, 100))
        e.addToSelection = false
        XCTAssertEqual(e.selectedAnchors, [1, 2])
        XCTAssertTrue(e.canDeleteSelectedAnchor)
        e.deleteSelectedAnchors()
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position), [Vec2(0, 0), Vec2(0, 100)])
        XCTAssertTrue(e.selectedAnchors.isEmpty)
        XCTAssertNotEqual(e.selection, Selection.none)

        // Too few points left deletes the shape.
        tap(&e, Vec2(0, 0))
        e.deleteSelectedAnchors()
        XCTAssertTrue(e.drawing.layers.isEmpty)
        e.undo()
        XCTAssertEqual(e.drawing.shapeCount, 1)
    }

    func testDeleteOneAnchorHealsHandlesOnScreen() {
        var e = DrawingEditor()
        e.tool = .pen
        tap(&e, Vec2(0, 0))
        drag(&e, Vec2(100, 100), Vec2(150, 100))
        drag(&e, Vec2(200, 0), Vec2(250, 0))
        e.penFinish()
        e.tool = .directSelect
        let before = e.drawing.layers[0].shapes[0].path
        tap(&e, Vec2(100, 100))
        e.deleteSelectedAnchors()
        let after = e.drawing.layers[0].shapes[0].path
        XCTAssertEqual(after.points.count, 2)
        // The neighbours keep their handle directions.
        XCTAssertEqual(after.points[0].outHandle, before.points[0].outHandle)
        XCTAssertEqual(after.points[1].inHandle.normalized.x, before.points[2].inHandle.normalized.x, accuracy: 1e-9)
    }

    func testModeCommandsApplyToAllSelectedAnchors() {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        e.addToSelection = true
        tap(&e, Vec2(100, 100))
        e.addToSelection = false
        XCTAssertEqual(e.selectedAnchorMode, .corner)
        e.setSelectedAnchorMode(.symmetric)
        XCTAssertEqual(e.selectedAnchorMode, .symmetric)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.mode), [.corner, .symmetric, .symmetric, .corner])
        e.setSelectedAnchorMode(.smooth)
        XCTAssertEqual(e.selectedAnchorIsSmooth, true)
        e.breakSelectedAnchorHandles()
        XCTAssertEqual(e.selectedAnchorMode, .corner)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points[1].outHandle, .zero)
        e.undo()
        XCTAssertEqual(e.selectedAnchorMode, .smooth)
    }

    func testDraggingAHandleHonoursTheMode() throws {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        e.setSelectedAnchorMode(.symmetric)
        let path = e.drawing.layers[0].shapes[0].path
        let handle = path.points[1].outControl
        drag(&e, handle, handle + Vec2(0, 40))
        let after = e.drawing.layers[0].shapes[0].path.points[1]
        assertClose(after.inHandle, -after.outHandle, tolerance: 1e-6)
    }

    func testDraggingASegmentReshapesTheCurve() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        e.tool = .directSelect
        let steps = e.undoStack.undoStates.count
        drag(&e, Vec2(50, 0), Vec2(50, 40))
        let path = e.drawing.layers[0].shapes[0].path
        XCTAssertEqual(path.points.count, 2, "a drag reshapes; only a tap inserts a point")
        XCTAssertEqual(path.segment(0).point(at: 0.5).y, 40, accuracy: 0.5)
        assertClose(path.points[0].position, Vec2(0, 0))
        XCTAssertEqual(e.undoStack.undoStates.count, steps + 1)
        e.undo()
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points[0].outHandle, .zero)
    }

    func testSplitAndJoinCommands() {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        XCTAssertTrue(e.canSplitAtSelectedAnchor)
        XCTAssertTrue(e.canJoinSelection, "a single open path can be closed")
        e.splitAtSelectedAnchor()
        XCTAssertEqual(e.drawing.shapeCount, 2)
        XCTAssertEqual(e.drawing.layers[0].shapes.map(\.path.points.count), [2, 3])
        guard case .shapes = e.selection else { return XCTFail("both pieces selected") }

        XCTAssertTrue(e.canJoinSelection)
        e.joinSelection()
        XCTAssertEqual(e.drawing.shapeCount, 1)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position),
                       [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100)])
        e.undo()
        XCTAssertEqual(e.drawing.shapeCount, 2)
        e.undo()
        XCTAssertEqual(e.drawing.shapeCount, 1)
    }

    func testJoinOnASingleOpenShapeClosesIt() {
        var e = fourPointPath()
        e.selection = .layer(e.drawing.layers[0].id)
        XCTAssertTrue(e.canJoinSelection)
        e.joinSelection()
        XCTAssertTrue(e.drawing.layers[0].shapes[0].path.closed)
        XCTAssertFalse(e.canJoinSelection)
    }

    func testJoinAcrossLayersPicksNearestEnds() {
        var e = DrawingEditor()
        penPath([Vec2(0, 0), Vec2(100, 0)], in: &e)
        penPath([Vec2(500, 0), Vec2(120, 0)], in: &e)
        e.selection = .covering(Set(e.drawing.layers.flatMap { layer in layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) } }))
        e.joinSelection()
        XCTAssertEqual(e.drawing.shapeCount, 1)
        XCTAssertEqual(e.drawing.layers.count, 1)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.map(\.position.x), [0, 100, 120, 500])
    }

    func testNudgeMovesAnchorsOrTheSelection() {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        e.nudge(by: Vec2(1, 0))
        e.nudge(by: Vec2(1, 0))
        assertClose(e.drawing.layers[0].worldShape(0).path.points[1].position, Vec2(102, 0))
        XCTAssertEqual(e.undoStack.undoStates.count, 5, "repeated nudges share an undo step")
        e.selectedAnchors = []
        e.nudge(by: Vec2(0, 5))
        assertClose(e.drawing.layers[0].worldShape(0).path.points[0].position, Vec2(0, 5))
        assertClose(e.drawing.layers[0].worldShape(0).path.points[1].position, Vec2(102, 5))
    }

    func testAnchorPositionFields() {
        var e = fourPointPath()
        tap(&e, Vec2(100, 0))
        assertClose(e.selectedAnchorsCentroid!, Vec2(100, 0))
        e.setSelectedAnchorsPosition(x: 150)
        e.setSelectedAnchorsPosition(y: 20)
        assertClose(e.drawing.layers[0].shapes[0].path.points[1].position, Vec2(150, 20))
        // Two anchors move as a group about their middle.
        e.addToSelection = true
        tap(&e, Vec2(100, 100))
        e.addToSelection = false
        e.setSelectedAnchorsPosition(x: 0)
        let points = e.drawing.layers[0].shapes[0].path.points
        XCTAssertEqual(points[1].position.x - points[2].position.x, 50, accuracy: 1e-9, "relative placement is kept")
        assertClose(e.selectedAnchorsCentroid!, Vec2(0, (20 + 100) / 2))
    }
}

final class TransformTests: XCTestCase {
    func testEdgeHandleScalesOneAxisFromTheOppositeEdge() throws {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        let frame = try XCTUnwrap(e.drawing.frame(of: e.selection))
        let right = frame.edgeMidpoints[1]
        let width = frame.corners[2].x - frame.corners[0].x
        drag(&e, right, right + Vec2(width, 0))
        let after = try XCTUnwrap(e.selectionGeometry)
        XCTAssertEqual(after.width, 200, accuracy: 1)
        XCTAssertEqual(after.height, 100, accuracy: 1)
        XCTAssertEqual(after.minPoint.x, 1.5, accuracy: 1, "the left edge stays")
        XCTAssertEqual(after.minPoint.y, 0, accuracy: 1)

        // The top edge scales vertically only.
        let top = try XCTUnwrap(e.drawing.frame(of: e.selection)).edgeMidpoints[0]
        drag(&e, top, top + Vec2(0, -50))
        let tall = try XCTUnwrap(e.selectionGeometry)
        XCTAssertEqual(tall.width, 200, accuracy: 1)
        XCTAssertGreaterThan(tall.height, 140)
    }

    func testStretchNeverFlipsOrCollapses() throws {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        let frame = try XCTUnwrap(e.drawing.frame(of: e.selection))
        let right = frame.edgeMidpoints[1]
        drag(&e, right, Vec2(-500, 50))
        let after = try XCTUnwrap(e.selectionGeometry)
        XCTAssertGreaterThan(after.width, 0)
        XCTAssertLessThan(after.width, 10)
    }

    func testNumericSizeAndOrigin() throws {
        var e = editorWithSquare()
        e.selection = .layer(e.drawing.layers[0].id)
        let steps = e.undoStack.undoStates.count
        e.setSelectionOrigin(x: 10)
        e.setSelectionOrigin(y: 20)
        let moved = try XCTUnwrap(e.selectionGeometry)
        XCTAssertEqual(moved.minPoint.x, 10, accuracy: 0.5)
        XCTAssertEqual(moved.minPoint.y, 20, accuracy: 0.5)
        XCTAssertEqual(e.undoStack.undoStates.count, steps + 1, "field edits coalesce")

        e.setSelectionSize(width: 50)
        let sized = try XCTUnwrap(e.selectionGeometry)
        XCTAssertEqual(sized.width, 50, accuracy: 0.5)
        XCTAssertEqual(sized.height, moved.height, accuracy: 0.5)
        XCTAssertEqual(sized.minPoint.x, moved.minPoint.x, accuracy: 0.5)
    }

    func testFlipMirrorsAboutTheFrameCenter() throws {
        var e = DrawingEditor()
        e.addStroke([Vec2(0, 0), Vec2(100, 40)], zoom: 1)
        e.selection = .layer(e.drawing.layers[0].id)
        let before = e.drawing.layers[0].worldShape(0)
        let c = try XCTUnwrap(e.drawing.frame(of: e.selection)).center
        e.flipSelection(horizontal: true)
        let flipped = e.drawing.layers[0].worldShape(0)
        for (a, b) in zip(before.path.points, flipped.path.points) {
            assertClose(b.position, Vec2(2 * c.x - a.position.x, a.position.y))
            assertClose(b.outHandle, Vec2(-a.outHandle.x, a.outHandle.y))
        }
        XCTAssertEqual(flipped.stroke?.width, before.stroke?.width)

        e.flipSelection(horizontal: false)
        let both = e.drawing.layers[0].worldShape(0)
        assertClose(both.path.points[0].position, Vec2(2 * c.x - before.path.points[0].position.x, 2 * c.y - before.path.points[0].position.y))
        e.flipSelection(horizontal: true)
        e.flipSelection(horizontal: false)
        assertClose(e.drawing.layers[0].worldShape(0).path.points[0].position, before.path.points[0].position)
        XCTAssertEqual(e.undoStack.undoStates.count, 5)
    }

    func testFlipLeavesReferenceImagesAlone() {
        var e = DrawingEditor()
        let id = e.addReference(name: "r", size: Vec2(10, 10), center: .zero, scale: 1)
        e.selection = .reference(id)
        let before = e.drawing
        e.flipSelection(horizontal: true)
        XCTAssertEqual(e.drawing, before)
    }

    func testPivotDefaultsToTheLayerPivotAndCanBeDragged() throws {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        let layer = e.drawing.layers[0]
        assertClose(try XCTUnwrap(e.pivot), layer.pivot)

        drag(&e, layer.pivot, Vec2(70, 60))
        assertClose(e.drawing.layers[0].worldPivot, Vec2(70, 60), tolerance: 1e-6)
        assertClose(try XCTUnwrap(e.pivot), Vec2(70, 60), tolerance: 1e-6)
        XCTAssertEqual(e.selection, .layer(layer.id), "dragging the pivot does not change the selection")
        e.undo()
        assertClose(e.drawing.layers[0].worldPivot, layer.pivot)

        // Rotation turns about the pivot.
        drag(&e, layer.pivot, Vec2(70, 60))
        let first = e.drawing.layers[0].worldShape(0).path.points[0].position
        e.rotateSelection(byDegrees: 90)
        let expected = (Affine2D.translation(Vec2(70, 60)) * Affine2D.rotation(.pi / 2) * Affine2D.translation(Vec2(-70, -60))).apply(first)
        assertClose(e.drawing.layers[0].worldShape(0).path.points[0].position, expected, tolerance: 1e-6)
    }

    func testPivotOfASingleShapeIsTransientAndSelectionResetsIt() throws {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        tap(&e, Vec2(50, 50))
        guard case .shape = e.selection else { return XCTFail("shape not selected") }
        let layerPivot = e.drawing.layers[0].pivot
        drag(&e, Vec2(50, 50), Vec2(20, 20))
        assertClose(try XCTUnwrap(e.pivot), Vec2(20, 20))
        XCTAssertEqual(e.drawing.layers[0].pivot, layerPivot)
        let before = e.undoStack.undoStates.count
        e.selection = .none
        XCTAssertNil(e.customPivot)
        XCTAssertEqual(e.undoStack.undoStates.count, before)
    }
}
