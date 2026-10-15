import XCTest
@testable import ControlFlowCore

final class CanvasSessionTests: XCTestCase {
    private func session(fingerDraws: Bool = false) -> CanvasSession {
        var s = CanvasSession(options: InputOptions(fingerDraws: fingerDraws))
        s.resetView(viewSize: Vec2(1000, 800))
        return s
    }

    func testPencilDrawsAStrokeInWorldSpace() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchMoved(id: 1, samples: [Vec2(510, 400), Vec2(520, 400)], predicted: [Vec2(530, 400)])
        XCTAssertEqual(s.liveStroke?.points.count, 3)
        XCTAssertEqual(s.liveStroke?.predicted, [Vec2(30, 0)])
        s.touchEnded(id: 1, location: Vec2(540, 400))

        XCTAssertNil(s.liveStroke)
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
        let path = try! XCTUnwrap(s.editor.drawing.layers.first?.shapes.first?.path)
        XCTAssertFalse(path.closed)
        XCTAssertTrue(path.points.first!.position.isApproximately(Vec2(0, 0), tolerance: 1e-6))
        XCTAssertTrue(path.points.last!.position.isApproximately(Vec2(40, 0), tolerance: 1e-6))
        XCTAssertTrue(s.editor.canUndo)
    }

    func testCloseSamplesAreDropped() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        s.touchMoved(id: 1, samples: [Vec2(0.1, 0), Vec2(0.2, 0), Vec2(5, 0)])
        XCTAssertEqual(s.liveStroke?.points.count, 2)
    }

    func testCancelledPencilDiscardsStroke() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        s.touchMoved(id: 1, samples: [Vec2(50, 0)])
        s.touchCancelled(id: 1)
        XCTAssertNil(s.liveStroke)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
    }

    func testOneFingerNeverDrawsOrMoves() {
        var s = session()
        let before = s.camera
        s.touchBegan(id: 1, kind: .finger, location: Vec2(100, 100))
        s.touchMoved(id: 1, samples: [Vec2(300, 300)])
        s.touchEnded(id: 1)
        XCTAssertEqual(s.camera, before)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
        XCTAssertNil(s.liveStroke)
    }

    func testTwoFingersPan() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertTrue(s.isNavigating)
        s.touchMoved(id: 1, samples: [Vec2(450, 400)])
        s.touchMoved(id: 2, samples: [Vec2(650, 400)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(550, 400), tolerance: 1e-9))
        s.touchEnded(id: 1)
        XCTAssertFalse(s.isNavigating)
        // The remaining finger alone does nothing.
        s.touchMoved(id: 2, samples: [Vec2(900, 900)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(550, 400), tolerance: 1e-9))
    }

    func testTwoFingersPinchZoomAboutTheirMidpoint() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        s.touchMoved(id: 1, samples: [Vec2(300, 400)])
        s.touchMoved(id: 2, samples: [Vec2(700, 400)])
        XCTAssertEqual(s.camera.zoom, 2, accuracy: 1e-9)
        // The world origin was under the fingers' midpoint and stays there.
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400), tolerance: 1e-9))
        s.touchEnded(id: 1)
        s.touchEnded(id: 2)
        XCTAssertEqual(s.camera.zoom, 2, accuracy: 1e-9)
        XCTAssertFalse(s.editor.canUndo)
    }

    func testThirdFingerIsIgnored() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        s.touchBegan(id: 3, kind: .finger, location: Vec2(500, 600))
        s.touchMoved(id: 3, samples: [Vec2(0, 0)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))
        s.touchEnded(id: 3)
        XCTAssertTrue(s.isNavigating)
    }

    func testPalmWhileDrawingIsIgnored() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(700, 600))
        s.touchBegan(id: 3, kind: .finger, location: Vec2(750, 650))
        XCTAssertFalse(s.isNavigating)
        s.touchMoved(id: 2, samples: [Vec2(0, 0)])
        s.touchMoved(id: 1, samples: [Vec2(520, 400)])
        s.touchEnded(id: 1)
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
        // The ignored touches stay ignored after the Pencil lifts.
        s.touchMoved(id: 3, samples: [Vec2(0, 0)])
        XCTAssertFalse(s.isNavigating)
    }

    func testLargeContactIsTreatedAsPalm() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400), majorRadius: 60)
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertFalse(s.isNavigating)
    }

    func testFirmFingertipsStillPinch() {
        // iPad reports a fingertip pressed into a pinch at about 41.8 pt.
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400), majorRadius: 41.8)
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400), majorRadius: 41.8)
        XCTAssertTrue(s.isNavigating)
        s.touchMoved(id: 1, samples: [Vec2(300, 400)])
        s.touchMoved(id: 2, samples: [Vec2(700, 400)])
        XCTAssertEqual(s.camera.zoom, 2, accuracy: 1e-9)
    }

    func testErasedStrokeStaysGoneAfterPinch() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchMoved(id: 1, samples: [Vec2(540, 400), Vec2(580, 400)])
        s.touchEnded(id: 1, location: Vec2(600, 400))
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)

        s.editor.tool = .eraser
        s.touchBegan(id: 2, kind: .pencil, location: Vec2(550, 370), time: 1)
        s.touchMoved(id: 2, samples: [Vec2(550, 400), Vec2(550, 430)], time: 1.1)
        s.touchEnded(id: 2, location: Vec2(550, 430), time: 1.2)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)

        s.touchBegan(id: 3, kind: .finger, location: Vec2(400, 400), time: 2)
        s.touchBegan(id: 4, kind: .finger, location: Vec2(600, 400), time: 2)
        s.touchMoved(id: 3, samples: [Vec2(300, 400)], time: 2.1)
        s.touchMoved(id: 4, samples: [Vec2(700, 400)], time: 2.1)
        s.touchEnded(id: 3, location: Vec2(300, 400), time: 2.2)
        s.touchEnded(id: 4, location: Vec2(700, 400), time: 2.2)
        XCTAssertEqual(s.camera.zoom, 2, accuracy: 1e-9)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
        // The erase is one undo step.
        s.undo()
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
    }

    func testPencilInterruptsNavigation() {
        var s = session()
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        s.touchBegan(id: 3, kind: .pencil, location: Vec2(500, 400))
        XCTAssertFalse(s.isNavigating)
        XCTAssertTrue(s.isDrawing)
        s.touchMoved(id: 1, samples: [Vec2(0, 0)])
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))
    }

    func testSecondPencilTouchIsIgnored() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(500, 400))
        s.touchBegan(id: 2, kind: .pencil, location: Vec2(600, 400))
        s.touchEnded(id: 2)
        XCTAssertTrue(s.isDrawing)
        s.touchEnded(id: 1)
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
    }

    func testStrokesFollowTheCamera() {
        var s = session()
        s.camera = CanvasCamera(worldToScreen: .scale(2))
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(100, 100))
        s.touchEnded(id: 1)
        XCTAssertEqual(s.editor.drawing.layers[0].shapes[0].path.points.map(\.position), [Vec2(50, 50)])
    }

    func testFingerDrawingInSimulatorTurnsIntoNavigation() {
        var s = session(fingerDraws: true)
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        XCTAssertTrue(s.isDrawing)
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertFalse(s.isDrawing)
        XCTAssertTrue(s.isNavigating)
        s.touchEnded(id: 1)
        s.touchEnded(id: 2)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
    }

    func testFingerDrawingCommitsWhenAlone() {
        var s = session(fingerDraws: true)
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchMoved(id: 1, samples: [Vec2(420, 400)])
        s.touchEnded(id: 1)
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
    }

    func testClearIsUndoable() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        s.touchEnded(id: 1)
        s.clear()
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
        s.undo()
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
    }

    // MARK: Multi-finger taps

    private func drawLine(_ s: inout CanvasSession, id: Int, from a: Vec2, to b: Vec2) {
        s.touchBegan(id: id, kind: .pencil, location: a)
        s.touchMoved(id: id, samples: [Vec2.lerp(a, b, 0.5), b])
        s.touchEnded(id: id, location: b)
    }

    func testTwoFingerTapUndoesAndThreeFingerTapRedoes() {
        var s = session()
        drawLine(&s, id: 1, from: Vec2(100, 100), to: Vec2(200, 100))
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)

        s.touchBegan(id: 2, kind: .finger, location: Vec2(400, 400), time: 1.0)
        s.touchBegan(id: 3, kind: .finger, location: Vec2(500, 400), time: 1.02)
        s.touchMoved(id: 3, samples: [Vec2(502, 401)])
        s.touchEnded(id: 2, location: Vec2(400, 400), time: 1.15)
        s.touchEnded(id: 3, location: Vec2(502, 401), time: 1.16)
        XCTAssertEqual(s.lastTapCommand, .undo)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(Vec2(500, 400)))

        s.touchBegan(id: 4, kind: .finger, location: Vec2(400, 400), time: 2.0)
        s.touchBegan(id: 5, kind: .finger, location: Vec2(500, 400), time: 2.01)
        s.touchBegan(id: 6, kind: .finger, location: Vec2(600, 400), time: 2.02)
        s.touchEnded(id: 4, time: 2.1)
        s.touchEnded(id: 5, time: 2.1)
        s.touchEnded(id: 6, time: 2.12)
        XCTAssertEqual(s.lastTapCommand, .redo)
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
        XCTAssertEqual(s.tapCommandCount, 2)
    }

    func testSlowOrMovingTwoFingerTouchIsNotATap() {
        var s = session()
        drawLine(&s, id: 1, from: Vec2(100, 100), to: Vec2(200, 100))

        s.touchBegan(id: 2, kind: .finger, location: Vec2(400, 400), time: 1.0)
        s.touchBegan(id: 3, kind: .finger, location: Vec2(500, 400), time: 1.0)
        s.touchEnded(id: 2, time: 2.0)
        s.touchEnded(id: 3, time: 2.0)
        XCTAssertNil(s.lastTapCommand)

        s.touchBegan(id: 4, kind: .finger, location: Vec2(400, 400), time: 3.0)
        s.touchBegan(id: 5, kind: .finger, location: Vec2(500, 400), time: 3.0)
        s.touchMoved(id: 4, samples: [Vec2(450, 400)])
        s.touchEnded(id: 4, time: 3.1)
        s.touchEnded(id: 5, time: 3.1)
        XCTAssertNil(s.lastTapCommand)
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
    }

    // MARK: Tools

    func testClosedStrokeBecomesFilledShape() {
        var s = session()
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(400, 300))
        var samples: [Vec2] = []
        for i in 1...64 {
            let a = Double(i) / 64 * 2 * .pi
            samples.append(Vec2(500 - 100 * cos(a), 300 - 100 * sin(a)))
        }
        s.touchMoved(id: 1, samples: samples)
        s.touchEnded(id: 1, location: samples.last!)
        let shape = try! XCTUnwrap(s.editor.drawing.layers.first?.shapes.first)
        XCTAssertTrue(shape.path.closed)
        XCTAssertNotNil(shape.fill)
        XCTAssertNotNil(shape.stroke)
    }

    func testSelectToolDragsALayer() {
        var s = session()
        drawLine(&s, id: 1, from: Vec2(100, 100), to: Vec2(300, 100))
        s.editor.tool = .select
        s.touchBegan(id: 2, kind: .pencil, location: Vec2(200, 100))
        s.touchMoved(id: 2, samples: [Vec2(200, 150), Vec2(200, 200)])
        s.touchEnded(id: 2, location: Vec2(200, 200))
        let layer = s.editor.drawing.layers[0]
        XCTAssertEqual(s.editor.selection, .layer(layer.id))
        let first = layer.shapes[0].path.points[0].position
        XCTAssertTrue(s.camera.toScreen(first).isApproximately(Vec2(100, 200), tolerance: 1e-6))
        s.undo()
        let restored = s.editor.drawing.layers[0].shapes[0].path.points[0].position
        XCTAssertTrue(s.camera.toScreen(restored).isApproximately(Vec2(100, 100), tolerance: 1e-6))
    }

    func testFingersDoNotEditInSelectTool() {
        var s = session()
        drawLine(&s, id: 1, from: Vec2(100, 100), to: Vec2(300, 100))
        s.editor.tool = .select
        s.touchBegan(id: 2, kind: .finger, location: Vec2(200, 100))
        s.touchMoved(id: 2, samples: [Vec2(200, 300)])
        s.touchEnded(id: 2)
        XCTAssertEqual(s.editor.selection, Selection.none)
    }
}
