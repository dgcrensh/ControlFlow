import XCTest
@testable import ControlFlowCore

private let landscapeView = Vec2(1180, 820)
private let portraitView = Vec2(820, 1180)
private let landscape = Viewport(width: 1920, height: 1080)
private let portrait = Viewport(width: 1080, height: 1920)

private func target(_ viewport: Viewport, _ view: Vec2, current: Double = 0, turn: Double? = nil) -> Double {
    RotationLock.targetRotation(viewport: viewport, viewSize: view, current: current, interfaceTurn: turn)
}

private func lockedSession(view: Vec2, viewport: Viewport = landscape) -> CanvasSession {
    var s = CanvasSession()
    s.editor.updateViewport { $0.width = viewport.width; $0.height = viewport.height }
    s.setRotationLocked(true, viewSize: view, animated: false)
    s.resetView(viewSize: view)
    return s
}

final class RotationLockTests: XCTestCase {
    // MARK: The rule

    func testSidesThatAgreeAreNeverTurned() {
        XCTAssertEqual(target(landscape, landscapeView), 0)
        XCTAssertEqual(target(portrait, portraitView), 0)
        // Never upside down, from wherever the camera was.
        XCTAssertEqual(target(landscape, landscapeView, current: 180), 0)
        XCTAssertEqual(target(landscape, landscapeView, current: 90, turn: 90), 0)
        XCTAssertEqual(target(Viewport(width: 1600, height: 1200), landscapeView, current: 200), 0)
    }

    func testSidesThatDisagreeTakeAQuarterTurn() {
        XCTAssertEqual(target(landscape, portraitView), 90, "no turn to go by: the deck's top on the right")
        XCTAssertEqual(target(portrait, landscapeView), 90)
        XCTAssertEqual(target(landscape, portraitView, current: 180), 90)
        // The closer of the two.
        XCTAssertEqual(target(landscape, portraitView, current: 250), 270)
        XCTAssertEqual(target(landscape, portraitView, current: 300), 270)
        XCTAssertEqual(target(landscape, portraitView, current: 100), 90)
        XCTAssertEqual(target(landscape, portraitView, current: 170), 90)
        XCTAssertEqual(target(landscape, portraitView, current: 190), 270)
        XCTAssertEqual(target(landscape, portraitView, current: 359), 270)
        XCTAssertEqual(target(landscape, portraitView, current: 1), 90)
    }

    func testTheArtStaysStillOnTheGlass() {
        // Landscape Right to portrait: the interface turns 90 counterclockwise on the
        // glass, so the camera turns 90 clockwise.
        let toPortrait = DisplayOrientation.turn(from: .landscapeRight, to: .portrait)
        XCTAssertEqual(toPortrait, -90)
        XCTAssertEqual(target(landscape, portraitView, current: 0, turn: toPortrait), 90)
        // Landscape Left to portrait goes the other way.
        let fromLeft = DisplayOrientation.turn(from: .landscapeLeft, to: .portrait)
        XCTAssertEqual(fromLeft, 90)
        XCTAssertEqual(target(landscape, portraitView, current: 0, turn: fromLeft), 270)
        // Portrait to upside-down portrait is a half turn, which UIKit keeps upright: so
        // does the lock.
        let flip = DisplayOrientation.turn(from: .portrait, to: .portraitUpsideDown)
        XCTAssertEqual(flip, 180)
        XCTAssertEqual(target(landscape, portraitView, current: 270, turn: flip), 270)
    }

    func testSquareViewportsAndViewsAreNeverTurned() {
        XCTAssertEqual(target(Viewport(width: 1080, height: 1080), portraitView), 0)
        // Within 2% of square counts as square.
        XCTAssertEqual(target(Viewport(width: 1010, height: 1000), portraitView), 0)
        XCTAssertEqual(target(Viewport(width: 1030, height: 1000), portraitView), 90)
        XCTAssertEqual(target(landscape, Vec2(1000, 1010)), 0)
        XCTAssertEqual(target(landscape, .zero), 0)
    }

    func testSplitViewGoesByTheViewNotTheDevice() {
        // A tall Split View window on a landscape iPad is portrait.
        XCTAssertEqual(target(landscape, Vec2(507, 820)), 90)
        XCTAssertEqual(target(portrait, Vec2(507, 820)), 0)
        // A wide window is landscape.
        XCTAssertEqual(target(landscape, Vec2(1180, 400)), 0)
    }

    // MARK: Camera

    func testQuarterTurnsAreExact() {
        let camera = CanvasCamera(worldToScreen: Affine2D.translation(Vec2(10, 20)) * Affine2D.scale(2))
        let turned = camera.turned(to: 90, about: Vec2(100, 100))
        XCTAssertEqual(turned.worldToScreen.a, 0)
        XCTAssertEqual(turned.worldToScreen.b, 2)
        XCTAssertEqual(turned.zoom, 2, accuracy: 1e-12)
        XCTAssertEqual(turned.rotationDegrees, 90, accuracy: 1e-12)
        XCTAssertTrue(turned.toWorld(Vec2(100, 100)).isApproximately(camera.toWorld(Vec2(100, 100)), tolerance: 1e-9))
        XCTAssertEqual(camera.turned(to: 270, about: .zero).rotationDegrees, 270, accuracy: 1e-12)
        XCTAssertEqual(camera.turned(to: -90, about: .zero).rotationDegrees, 270, accuracy: 1e-12)
    }

    func testZoomToFitAtAQuarterTurnFitsTheTurnedDeck() {
        let camera = try! XCTUnwrap(CanvasCamera.fitting(landscape.bounds, in: portraitView, rotation: 90))
        // The deck's 1920 points run down the screen's 1180.
        let zoom = 1180.0 / 1920
        XCTAssertEqual(camera.zoom, zoom, accuracy: 1e-9)
        XCTAssertTrue(camera.toScreen(landscape.center).isApproximately(portraitView / 2, tolerance: 1e-9))
        // The deck's top-left corner is at the top right of the screen.
        let corner = camera.toScreen(.zero)
        XCTAssertEqual(corner.x, 410 + 540 * zoom, accuracy: 1e-9)
        XCTAssertEqual(corner.y, 590 - 960 * zoom, accuracy: 1e-9)
    }

    // MARK: Session

    func testLockedFingersPanAndZoomButDoNotRotate() {
        var s = lockedSession(view: landscapeView)
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        // Twist and spread: a quarter turn and twice the distance.
        s.touchMoved(id: 1, samples: [Vec2(500, 200)])
        s.touchMoved(id: 2, samples: [Vec2(500, 600)])
        XCTAssertEqual(s.camera.rotationDegrees, 0, accuracy: 1e-9)
        XCTAssertEqual(s.camera.zoom, 2, accuracy: 1e-9)
        // The world point under the start midpoint stays under the current midpoint.
        let start = CanvasCamera.centered(in: landscapeView).toWorld(Vec2(500, 400))
        XCTAssertTrue(s.camera.toScreen(start).isApproximately(Vec2(500, 400), tolerance: 1e-9))

        // Unlocked, the same twist rotates.
        var free = CanvasSession()
        free.resetView(viewSize: landscapeView)
        free.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        free.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        free.touchMoved(id: 1, samples: [Vec2(500, 200)])
        free.touchMoved(id: 2, samples: [Vec2(500, 600)])
        XCTAssertEqual(free.camera.rotationDegrees, 90, accuracy: 1e-9)
    }

    func testResetAndFitUseTheLockedRotation() {
        var s = lockedSession(view: portraitView)
        XCTAssertEqual(s.camera.rotationDegrees, 90)
        XCTAssertEqual(s.camera.zoom, 1)
        XCTAssertTrue(s.camera.toScreen(.zero).isApproximately(portraitView / 2, tolerance: 1e-9))
        s.zoom(toFit: landscape.bounds, viewSize: portraitView)
        XCTAssertEqual(s.camera.rotationDegrees, 90)
        XCTAssertEqual(s.camera.zoom, min((820.0 - 96) / 1080, (1180.0 - 96) / 1920), accuracy: 1e-9)

        var free = CanvasSession()
        free.zoom(toFit: landscape.bounds, viewSize: portraitView)
        XCTAssertEqual(free.camera.rotationDegrees, 0)
    }

    func testTurningTheLockOnSnapsAnimatedAboutTheCenter() {
        var s = CanvasSession()
        s.resetView(viewSize: landscapeView)
        s.camera = s.camera.applying(screenTransform: .scale(1.5), anchor: landscapeView / 2)
            .rotated(by: 200, about: Vec2(300, 300))
        let centerWorld = s.camera.toWorld(landscapeView / 2)
        s.setRotationLocked(true, viewSize: landscapeView)
        XCTAssertTrue(s.isTurning)
        XCTAssertTrue(s.stepTurn(at: 10))
        XCTAssertEqual(s.camera.rotationDegrees, 200, accuracy: 1e-9, "the first frame starts the clock")
        XCTAssertTrue(s.stepTurn(at: 10.125))
        // Halfway through, eased, the short way round from 200 to 360.
        XCTAssertEqual(s.camera.rotationDegrees, 280, accuracy: 1e-9)
        XCTAssertFalse(s.stepTurn(at: 10.3))
        XCTAssertFalse(s.isTurning)
        XCTAssertEqual(s.camera.rotationDegrees, 0, accuracy: 1e-12)
        XCTAssertEqual(s.camera.zoom, 1.5, accuracy: 1e-9)
        XCTAssertTrue(s.camera.toWorld(landscapeView / 2).isApproximately(centerWorld, tolerance: 1e-6))
    }

    func testTurningTheLockOnPicksTheCloserQuarterTurn() {
        var s = CanvasSession()
        s.resetView(viewSize: portraitView)
        s.camera = s.camera.rotated(by: 240, about: portraitView / 2)
        s.setRotationLocked(true, viewSize: portraitView, animated: false)
        XCTAssertEqual(s.camera.rotationDegrees, 270, accuracy: 1e-12)
    }

    func testTurningTheLockOffChangesNothing() {
        var s = lockedSession(view: portraitView)
        let camera = s.camera
        s.setRotationLocked(false, viewSize: portraitView)
        XCTAssertEqual(s.camera, camera)
        XCTAssertFalse(s.isRotationLocked)
    }

    func testFingersTakeOverFromATurn() {
        var s = CanvasSession()
        s.resetView(viewSize: landscapeView)
        s.camera = s.camera.rotated(by: 30, about: landscapeView / 2)
        s.setRotationLocked(true, viewSize: landscapeView)
        _ = s.stepTurn(at: 0)
        _ = s.stepTurn(at: 0.1)
        s.touchBegan(id: 1, kind: .finger, location: Vec2(400, 400))
        s.touchBegan(id: 2, kind: .finger, location: Vec2(600, 400))
        XCTAssertFalse(s.isTurning)
        XCTAssertEqual(s.camera.rotationDegrees, 0, accuracy: 1e-12)
        // And a tap puts back the turned camera, not a frame of the turn.
        s.touchEnded(id: 1, location: Vec2(400, 400), time: 0.1)
        s.touchEnded(id: 2, location: Vec2(600, 400), time: 0.1)
        XCTAssertEqual(s.camera.rotationDegrees, 0, accuracy: 1e-12)
    }

    func testTurningTheIPadKeepsTheCenterAndTheZoom() {
        var s = lockedSession(view: landscapeView)
        s.camera = s.camera.applying(screenTransform: .scale(3), anchor: Vec2(200, 300))
        let centerWorld = s.camera.toWorld(landscapeView / 2)
        s.viewDidResize(from: landscapeView, to: portraitView,
                        interfaceTurn: DisplayOrientation.turn(from: .landscapeRight, to: .portrait))
        XCTAssertEqual(s.camera.rotationDegrees, 90, accuracy: 1e-12)
        XCTAssertEqual(s.camera.zoom, 3, accuracy: 1e-9)
        XCTAssertTrue(s.camera.toWorld(portraitView / 2).isApproximately(centerWorld, tolerance: 1e-6))
        // And back again.
        s.viewDidResize(from: portraitView, to: landscapeView,
                        interfaceTurn: DisplayOrientation.turn(from: .portrait, to: .landscapeRight))
        XCTAssertEqual(s.camera.rotationDegrees, 0, accuracy: 1e-12)
        XCTAssertTrue(s.camera.toWorld(landscapeView / 2).isApproximately(centerWorld, tolerance: 1e-6))
    }

    func testResizingUnlockedKeepsTheCenter() {
        var s = CanvasSession()
        s.resetView(viewSize: landscapeView)
        s.camera = s.camera.rotated(by: 17, about: Vec2(100, 100))
        let camera = s.camera
        let centerWorld = s.camera.toWorld(landscapeView / 2)
        s.viewDidResize(from: landscapeView, to: portraitView, interfaceTurn: -90)
        XCTAssertEqual(s.camera.rotation, camera.rotation, accuracy: 1e-12)
        XCTAssertEqual(s.camera.zoom, camera.zoom, accuracy: 1e-12)
        XCTAssertTrue(s.camera.toWorld(portraitView / 2).isApproximately(centerWorld, tolerance: 1e-6))
    }

    func testAViewportChangeIsKeptLocked() {
        var s = lockedSession(view: landscapeView)
        XCTAssertEqual(s.camera.rotationDegrees, 0)
        s.editor.setViewportAspect(9.0 / 16)
        s.keepRotationLocked(viewSize: landscapeView, animated: false)
        XCTAssertEqual(s.camera.rotationDegrees, 90)
        // Nothing to do once it agrees.
        s.keepRotationLocked(viewSize: landscapeView)
        XCTAssertFalse(s.isTurning)
    }

    // MARK: Presenting

    func testPresentingTurnedFillsThePortraitScreen() {
        let flat = Presenter.camera(fitting: landscape, in: portraitView)
        XCTAssertEqual(flat.zoom, 820.0 / 1920, accuracy: 1e-9)
        let turned = Presenter.camera(fitting: landscape, in: portraitView, rotation: 90)
        XCTAssertEqual(turned.zoom, min(820.0 / 1080, 1180.0 / 1920), accuracy: 1e-9)
        XCTAssertEqual(turned.rotationDegrees, 90)
        XCTAssertTrue(turned.toScreen(landscape.center).isApproximately(portraitView / 2, tolerance: 1e-9))
    }

    func testPresentationTapsFollowTheTurn() {
        func tap(_ location: Vec2, rotation: Double) -> PresentationAction? {
            var touches = PresentationTouches()
            touches.began(id: 1, at: location, time: 0)
            return touches.ended(id: 1, at: location, time: 0.1, viewSize: portraitView, rotation: rotation)
        }
        // Turned 90 clockwise, the deck's right half is the bottom of the screen.
        XCTAssertEqual(tap(Vec2(100, 1000), rotation: 90), .advance)
        XCTAssertEqual(tap(Vec2(700, 200), rotation: 90), .back)
        XCTAssertEqual(tap(Vec2(100, 1000), rotation: 270), .back)
        XCTAssertEqual(tap(Vec2(700, 200), rotation: 0), .advance)
        XCTAssertEqual(tap(Vec2(100, 200), rotation: 0), .back)
    }
}
