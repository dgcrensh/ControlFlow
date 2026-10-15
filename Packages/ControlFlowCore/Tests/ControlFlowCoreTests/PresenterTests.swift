import Foundation
import XCTest
@testable import ControlFlowCore

/// Two sequences on one square: the first moves it 100 points right over 1 second
/// (linear), then fades it to 0.5 over 0.5 seconds (linear); the second moves it another
/// 100 points with a cut.
private func presentation() -> Presentation {
    var d = Drawing()
    var layer = Layer(id: d.makeID(), name: "Art")
    layer.shapes = [VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(100, 100))),
                                fill: .black)]
    d.layers = [layer]
    d.assignVertexIDs()
    var e = DrawingEditor(drawing: d)
    let shape = Selection.shape(layer: layer.id, shape: layer.shapes[0].id)
    let move = e.setKeyframe()
    e.selection = shape
    e.nudge(by: Vec2(100, 0))
    e.setTransition(Transition(duration: 1, curve: .linear), ofKeyframe: move)
    let fade = e.setKeyframe()
    e.selection = shape
    e.setOpacity(0.5)
    e.setTransition(Transition(duration: 0.5, curve: .linear), ofKeyframe: fade)
    let jump = e.newSequence()
    e.selection = shape
    e.nudge(by: Vec2(100, 0))
    e.setTransition(Transition(duration: 0), ofKeyframe: jump)
    return e.presentation
}

private extension Drawing {
    var square: VectorShape { layers[0].shapes[0] }
    /// Where the square's left edge is, with the transforms applied.
    var left: Double { world.layers[0].shapes[0].path.bounds().minPoint.x }
}

final class PresenterTests: XCTestCase {
    func testPlaysEachSequenceOnAdvance() {
        var p = Presenter(presentation: presentation())
        XCTAssertEqual(p.sequenceCount, 2)
        XCTAssertTrue(p.isAtStart)
        XCTAssertEqual(p.counter, "Opening, 2 sequences")
        XCTAssertEqual(p.scene(at: 5).left, 0, accuracy: 1e-9)
        XCTAssertEqual(p.nextSequence, 0)

        p.advance()
        XCTAssertTrue(p.isPlaying)
        XCTAssertEqual(p.counter, "Sequence 1 of 2")
        // The first frame starts the clock, however late it comes.
        XCTAssertEqual(p.scene(at: 10).left, 0, accuracy: 1e-9)
        XCTAssertEqual(p.scene(at: 10.5).left, 50, accuracy: 1e-6)
        let fading = p.scene(at: 11.25)
        XCTAssertEqual(fading.left, 100, accuracy: 1e-6)
        XCTAssertEqual(fading.square.opacity, 0.75, accuracy: 1e-6)
        XCTAssertTrue(p.isPlaying)

        // It stops on the sequence's last keyframe.
        let end = p.scene(at: 11.6)
        XCTAssertFalse(p.isPlaying)
        XCTAssertEqual(p.position, 1)
        XCTAssertEqual(end.square.opacity, 0.5)
        XCTAssertEqual(p.scene(at: 20), p.state(afterSequences: 1))
        XCTAssertEqual(p.counter, "Sequence 1 of 2")

        // A cut plays in one frame.
        p.advance()
        XCTAssertEqual(p.scene(at: 30).left, 200, accuracy: 1e-6)
        XCTAssertTrue(p.isAtEnd)
        XCTAssertNil(p.nextSequence)
        XCTAssertNil(p.nextEndState())
        let revision = p.revision
        p.advance()
        XCTAssertEqual(p.revision, revision, "nothing after the last sequence")
    }

    func testAdvanceWhilePlayingJumpsToTheEnd() {
        var p = Presenter(presentation: presentation())
        p.advance()
        _ = p.scene(at: 0)
        _ = p.scene(at: 0.3)
        p.advance()
        XCTAssertFalse(p.isPlaying, "doesn't queue the next sequence")
        XCTAssertEqual(p.position, 1)
        let end = p.scene(at: 0.4)
        XCTAssertEqual(end.left, 100, accuracy: 1e-6)
        XCTAssertEqual(end.square.opacity, 0.5)
    }

    func testBackJumpsToThePreviousEnd() {
        var p = Presenter(presentation: presentation())
        p.perform(.advance)
        p.perform(.advance)
        p.perform(.advance)
        p.perform(.advance)
        XCTAssertTrue(p.isAtEnd)
        p.perform(.back)
        XCTAssertFalse(p.isPlaying, "no animation")
        XCTAssertEqual(p.position, 1)
        XCTAssertEqual(p.scene(at: 0).left, 100, accuracy: 1e-6)
        p.perform(.back)
        XCTAssertTrue(p.isAtStart)
        XCTAssertEqual(p.scene(at: 0).left, 0, accuracy: 1e-9)
        let revision = p.revision
        p.perform(.back)
        p.perform(.exit)
        XCTAssertEqual(p.revision, revision, "nothing before the opening state, and exit is the caller's")

        // Back while a sequence plays returns to where Advance was pressed.
        p.advance()
        _ = p.scene(at: 0)
        _ = p.scene(at: 0.5)
        XCTAssertEqual(p.playingSequence, 0)
        p.back()
        XCTAssertFalse(p.isPlaying)
        XCTAssertTrue(p.isAtStart)
        XCTAssertEqual(p.scene(at: 1).left, 0, accuracy: 1e-9)
    }

    func testNextEndState() {
        var p = Presenter(presentation: presentation())
        XCTAssertEqual(p.nextSequenceTitle, "Sequence 1")
        XCTAssertEqual(p.nextEndState(), p.state(afterSequences: 1))
        p.advance()
        // While the first plays, the next is the second.
        XCTAssertEqual(p.nextSequence, 1)
        XCTAssertEqual(p.nextEndState()?.left ?? 0, 200, accuracy: 1e-6)
    }

    func testSequenceWithNoKeyframes() {
        var presentation = presentation()
        presentation.sequences.insert(KeyframeSequence(id: 900, name: "Empty"), at: 1)
        var p = Presenter(presentation: presentation)
        p.advance()
        _ = p.scene(at: 0)
        _ = p.scene(at: 2)
        XCTAssertEqual(p.position, 1)
        XCTAssertEqual(p.nextSequenceTitle, "Empty")
        p.advance()
        XCTAssertFalse(p.isPlaying, "nothing to play")
        XCTAssertEqual(p.position, 2)
        XCTAssertEqual(p.scene(at: 3), p.state(afterSequences: 1))
        p.advance()
        XCTAssertEqual(p.scene(at: 4).left, 200, accuracy: 1e-6)
        XCTAssertTrue(p.isAtEnd)
    }

    func testNoSequences() {
        var p = Presenter(presentation: Presentation())
        XCTAssertEqual(p.counter, "No sequences")
        p.advance()
        p.back()
        XCTAssertTrue(p.isAtStart)
        XCTAssertTrue(p.isAtEnd)
        XCTAssertEqual(p.revision, 0)
    }

    func testKeys() {
        let advance: [PresentationKey] = [.space, .returnKey, .rightArrow, .downArrow, .pageDown]
        let back: [PresentationKey] = [.leftArrow, .upArrow, .pageUp]
        XCTAssertEqual(advance.map(\.action), Array(repeating: .advance, count: advance.count))
        XCTAssertEqual(back.map(\.action), Array(repeating: .back, count: back.count))
        XCTAssertEqual(PresentationKey.escape.action, .exit)
        XCTAssertEqual(PresentationKey.allCases.count, 9)
    }

    func testCameraLetterboxesTheViewport() {
        let viewport = Viewport(width: 1920, height: 1080)
        let camera = Presenter.camera(fitting: viewport, in: Vec2(1024, 768))
        XCTAssertEqual(camera.zoom, 1024.0 / 1920, accuracy: 1e-9)
        let topLeft = camera.toScreen(.zero), bottomRight = camera.toScreen(Vec2(1920, 1080))
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 96, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.x, 1024, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.y, 672, accuracy: 1e-9)
        // Pillarboxed on a tall view.
        let tall = Presenter.camera(fitting: viewport, in: Vec2(500, 1000))
        XCTAssertEqual(tall.toScreen(viewport.center).x, 250, accuracy: 1e-9)
        XCTAssertEqual(tall.toScreen(viewport.center).y, 500, accuracy: 1e-9)
        XCTAssertEqual(Presenter.camera(fitting: viewport, in: .zero), CanvasCamera())
    }

    func testShowSceneIsViewOnly() {
        let presentation = presentation()
        var editor = DrawingEditor(presentation: presentation)
        var p = Presenter(presentation: presentation)
        let end = p.state(afterSequences: 2)
        let revision = editor.displayRevision
        editor.showScene(end)
        XCTAssertEqual(editor.shownDrawing, end)
        XCTAssertNotEqual(editor.displayRevision, revision)
        let shown = editor.displayRevision
        editor.showScene(end)
        XCTAssertEqual(editor.displayRevision, shown, "the same scene again changes nothing")
        XCTAssertEqual(editor.presentation, presentation)
    }
}

final class PresentationTouchesTests: XCTestCase {
    private let width = 1000.0

    func testTapHalves() {
        var t = PresentationTouches()
        t.began(id: 1, at: Vec2(800, 300), time: 0)
        XCTAssertNil(t.moved(id: 1, to: Vec2(805, 302)))
        XCTAssertEqual(t.ended(id: 1, at: Vec2(806, 303), time: 0.1, width: width), .advance)
        t.began(id: 2, at: Vec2(200, 300), time: 1)
        XCTAssertEqual(t.ended(id: 2, at: Vec2(200, 300), time: 1.1, width: width), .back)
    }

    func testNotTaps() {
        var t = PresentationTouches()
        // Held too long.
        t.began(id: 1, at: Vec2(800, 300), time: 0)
        XCTAssertNil(t.ended(id: 1, at: Vec2(800, 300), time: 1, width: width))
        // Dragged.
        t.began(id: 2, at: Vec2(800, 300), time: 2)
        _ = t.moved(id: 2, to: Vec2(700, 300))
        XCTAssertNil(t.ended(id: 2, at: Vec2(700, 300), time: 2.1, width: width))
        // Two fingers.
        t.began(id: 3, at: Vec2(800, 300), time: 3)
        t.began(id: 4, at: Vec2(900, 300), time: 3)
        XCTAssertNil(t.ended(id: 3, at: Vec2(800, 300), time: 3.1, width: width))
        XCTAssertNil(t.ended(id: 4, at: Vec2(900, 300), time: 3.1, width: width))
        // Cancelled.
        t.began(id: 5, at: Vec2(800, 300), time: 4)
        t.cancelled(id: 5)
        XCTAssertNil(t.ended(id: 5, at: Vec2(800, 300), time: 4.1, width: width))
        // And a tap after all that still works.
        t.began(id: 6, at: Vec2(800, 300), time: 5)
        XCTAssertEqual(t.ended(id: 6, at: Vec2(800, 300), time: 5.1, width: width), .advance)
    }

    func testPinchInExits() {
        var t = PresentationTouches()
        t.began(id: 1, at: Vec2(300, 300), time: 0)
        t.began(id: 2, at: Vec2(700, 300), time: 0)
        XCTAssertNil(t.moved(id: 1, to: Vec2(350, 300)), "not far enough")
        XCTAssertEqual(t.moved(id: 2, to: Vec2(550, 300)), .exit)
        XCTAssertNil(t.moved(id: 2, to: Vec2(500, 300)), "once")
        XCTAssertNil(t.ended(id: 1, at: Vec2(350, 300), time: 0.2, width: width))
        XCTAssertNil(t.ended(id: 2, at: Vec2(500, 300), time: 0.2, width: width))

        // Spreading the fingers does nothing.
        t.began(id: 3, at: Vec2(400, 300), time: 1)
        t.began(id: 4, at: Vec2(600, 300), time: 1)
        XCTAssertNil(t.moved(id: 4, to: Vec2(900, 300)))
    }
}
