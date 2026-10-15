import Foundation
import XCTest
@testable import ControlFlowCore

/// A drawing with one layer holding a square and a triangle.
private func scene() -> (drawing: Drawing, layer: Int, square: Int, triangle: Int) {
    var d = Drawing()
    var layer = Layer(id: d.makeID(), name: "Art", pivot: Vec2(300, 300))
    let square = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(100, 100), maxPoint: Vec2(300, 300))),
                             fill: RGBAColor(hex: "#FF0000FF")!)
    let triangle = VectorShape(id: d.makeID(), path: BezierPath(points: [PathPoint(Vec2(400, 100)), PathPoint(Vec2(500, 300)), PathPoint(Vec2(300, 300))],
                                                                closed: true), fill: .black)
    layer.shapes = [square, triangle]
    d.layers = [layer]
    d.assignVertexIDs()
    return (d, layer.id, square.id, triangle.id)
}

private extension Drawing {
    func shape(_ id: Int) -> VectorShape? {
        for layer in layers { if let s = layer.shapes.first(where: { $0.id == id }) { return s } }
        return nil
    }
    mutating func withShape(_ id: Int, _ change: (inout VectorShape) -> Void) {
        for l in layers.indices {
            if let s = layers[l].shapes.firstIndex(where: { $0.id == id }) { change(&layers[l].shapes[s]) }
        }
    }
}

/// An editor with two keyframes: the first turns the layer to 30 degrees over 1 second
/// (linear), the second fades the square to 0.5 with a cut. The second is current.
private func editor() -> (e: DrawingEditor, layer: Int, square: Int, first: Int, second: Int) {
    let (d, layer, square, _) = scene()
    var e = DrawingEditor(drawing: d)
    let first = e.setKeyframe()
    e.selection = .layer(layer)
    e.rotateSelection(byDegrees: 30)
    e.setTransition(Transition(duration: 1, curve: .linear), ofKeyframe: first)
    let second = e.setKeyframe()
    e.selection = .shape(layer: layer, shape: square)
    e.setOpacity(0.5)
    e.setTransition(Transition(duration: 0), ofKeyframe: second)
    e.selection = .none
    return (e, layer, square, first, second)
}

final class TimelineStripTests: XCTestCase {
    func testChipsAndBlocks() {
        var (e, _, _, first, second) = editor()
        let third = e.newSequence()
        e.renameKeyframe(second, to: "Fade")
        e.renameSequence(e.presentation.sequences[1].id, to: "Outro")
        let strip = e.timelineStrip
        XCTAssertFalse(strip.openingIsCurrent)
        XCTAssertEqual(strip.sequences.map(\.title), ["Sequence 1", "Outro"])
        XCTAssertEqual(strip.chips.map(\.id), [first, second, third])
        XCTAssertEqual(strip.chips.map(\.number), [1, 2, 3], "numbers run on across sequences")
        XCTAssertEqual(strip.chips.map(\.title), ["1", "Fade", "3"])
        XCTAssertEqual(strip.chips.map(\.changeCount), [1, 1, 0])
        XCTAssertEqual(strip.currentChip?.id, third)
        XCTAssertEqual(strip.sequences.map(\.isCurrent), [false, true])
        XCTAssertEqual(strip.sequences.map(\.canMergeWithNext), [true, false])
        XCTAssertEqual(strip.sequences[0].duration, 1, "1s plus a cut")
        XCTAssertEqual(strip.sequences[1].duration, 0, "a new keyframe takes the last transition set, the cut")
        XCTAssertEqual(strip.chips[0].transition, Transition(duration: 1, curve: .linear))

        e.selectKeyframe(nil)
        XCTAssertTrue(e.timelineStrip.openingIsCurrent)
        XCTAssertNil(e.timelineStrip.currentChip)
        XCTAssertEqual(e.timelineStrip.sequences.map(\.isCurrent), [false, false])
        XCTAssertTrue(TimelineStrip().openingIsCurrent)
        XCTAssertTrue(TimelineStrip(presentation: Presentation(opening: scene().drawing), currentKeyframe: nil).sequences.isEmpty)
    }

    func testDurationLabels() {
        XCTAssertEqual(Transition(duration: 0).durationLabel, "Cut")
        XCTAssertEqual(Transition(duration: 0.5).durationLabel, "0.5s")
        XCTAssertEqual(Transition(duration: 1).durationLabel, "1s")
        XCTAssertEqual(Transition(duration: 0.25).durationLabel, "0.25s")
        XCTAssertEqual(Transition(duration: 1.05).durationLabel, "1.05s")
        XCTAssertEqual(Transition(duration: 2.999).durationLabel, "3s")
        XCTAssertEqual(Transition.seconds(-1), "0")
        XCTAssertEqual(Transition.seconds(10.1), "10.1")
    }

    func testKeyedPropertyNames() {
        XCTAssertEqual(TimelineStrip.propertyNames(["stroke.width", "transform.position", "transform.rotation", "points", "fill"]),
                       ["Transform", "Points", "Fill", "Outline"])
        XCTAssertEqual(TimelineStrip.propertyNames(["created", "fillGlobal", "zzz"]), ["Created here", "Fill", "zzz"])
        XCTAssertEqual(TimelineStrip.propertyNames([]), [])
    }

    func testCurveEditing() {
        XCTAssertEqual(TimingCurve.custom(x1: 0.42, y1: 0, x2: 0.58, y2: 1).normalized, .easeInOut)
        XCTAssertEqual(TimingCurve.custom(x1: 0.3, y1: 0, x2: 0.58, y2: 1).normalized, .custom(x1: 0.3, y1: 0, x2: 0.58, y2: 1))
        XCTAssertEqual(TimingCurve.ease.normalized, .ease)

        // Moving a control point makes a custom curve, unless it lands on a preset.
        XCTAssertEqual(TimingCurve.easeInOut.moving(controlPoint: true, to: Vec2(0.3, 0.2)), .custom(x1: 0.3, y1: 0.2, x2: 0.58, y2: 1))
        XCTAssertEqual(TimingCurve.easeInOut.moving(controlPoint: false, to: Vec2(1, 1)), .easeIn)
        XCTAssertEqual(TimingCurve.easeIn.moving(controlPoint: true, to: Vec2(0, 0)), .linear)
        // x is clamped to 0...1 and y to -1...2; non-finite values go to 0.
        XCTAssertEqual(TimingCurve.linear.moving(controlPoint: true, to: Vec2(-3, 5)), .custom(x1: 0, y1: 2, x2: 1, y2: 1))
        XCTAssertEqual(TimingCurve.linear.moving(controlPoint: false, to: Vec2(4, -7)), .custom(x1: 0, y1: 0, x2: 1, y2: -1))
        XCTAssertEqual(TimingCurve.ease.moving(controlPoint: true, to: Vec2(.nan, .infinity)), .custom(x1: 0, y1: 0, x2: 0.25, y2: 1))

        XCTAssertEqual(TimingCurve.easeInOut.displayName, "Ease In Out")
        XCTAssertEqual(TimingCurve.custom(x1: 0.1, y1: 0, x2: 0.2, y2: 1).displayName, "Custom")

        for curve in TimingCurve.presets + [.custom(x1: 0.3, y1: 1.6, x2: 0.6, y2: 1)] {
            let samples = curve.samples(count: 9)
            XCTAssertEqual(samples.count, 9)
            XCTAssertEqual(samples.first, Vec2(0, 0))
            XCTAssertEqual(samples.last, Vec2(1, 1))
        }
        XCTAssertEqual(TimingCurve.linear.samples(count: 0), [Vec2(0, 0), Vec2(1, 1)], "at least two")
        XCTAssertEqual(TimingCurve.linear.samples(count: 5)[2], Vec2(0.5, 0.5))
    }
}

final class TimelinePreviewTests: XCTestCase {
    func testScrubbingShowsTheTransitionWithoutEditing() {
        var (e, _, square, first, second) = editor()
        e.selectKeyframe(first)
        let revision = e.revision, display = e.displayRevision
        let document = e.presentation, canUndo = e.canUndo, undoCount = e.undoStack.undoStates.count
        let current = e.drawing

        e.scrubPreview(into: first, fraction: 0)
        XCTAssertEqual(e.preview?.layers[0].transform.rotation ?? -1, 0, accuracy: 1e-9)
        e.scrubPreview(into: first, fraction: 0.5)
        XCTAssertEqual(e.preview?.layers[0].transform.rotation ?? -1, 15, accuracy: 1e-9)
        XCTAssertEqual(e.shownDrawing, e.preview)
        e.scrubPreview(into: first, fraction: 2)
        XCTAssertEqual(e.preview?.layers[0].transform.rotation ?? -1, 30, accuracy: 1e-9, "clamped to the end")

        // A cut shows the keyframe before it until the end.
        e.scrubPreview(into: second, fraction: 0.5)
        XCTAssertEqual(e.preview?.shape(square)?.opacity, 1)
        XCTAssertEqual(e.preview?.layers[0].transform.rotation ?? -1, 30, accuracy: 1e-9)
        e.scrubPreview(into: second, fraction: 1)
        XCTAssertEqual(e.preview?.shape(square)?.opacity, 0.5)

        XCTAssertGreaterThan(e.displayRevision, display)
        XCTAssertEqual(e.revision, revision, "a preview isn't an edit")
        XCTAssertEqual(e.drawing, current)
        XCTAssertEqual(e.presentation, document)
        XCTAssertEqual(e.canUndo, canUndo)
        XCTAssertEqual(e.undoStack.undoStates.count, undoCount)
        XCTAssertEqual(e.currentKeyframe, first)

        let shown = e.displayRevision
        e.endPreview()
        XCTAssertNil(e.preview)
        XCTAssertEqual(e.shownDrawing, current)
        XCTAssertGreaterThan(e.displayRevision, shown)
        let ended = e.displayRevision
        e.endPreview()
        XCTAssertEqual(e.displayRevision, ended, "ending no preview changes nothing")

        // Unknown keyframes, and the opening state, have no transition to scrub.
        e.scrubPreview(into: 9999, fraction: 0.5)
        XCTAssertNil(e.preview)
    }

    func testPreviewsEndOnSelectKeyframeUndoAndCommands() {
        var (e, _, _, first, second) = editor()
        e.scrubPreview(into: first, fraction: 0.5)
        e.selectKeyframe(first)
        XCTAssertNil(e.preview, "selectKeyframe")

        e.scrubPreview(into: first, fraction: 0.5)
        e.undo()
        XCTAssertNil(e.preview, "undo")
        e.scrubPreview(into: first, fraction: 0.5)
        e.redo()
        XCTAssertNil(e.preview, "redo")

        e.selectKeyframe(second)
        e.scrubPreview(into: first, fraction: 0.5)
        let k = e.setKeyframe()
        XCTAssertNil(e.preview, "setKeyframe")
        XCTAssertEqual(e.currentKeyframe, k)
        XCTAssertEqual(e.shownDrawing, e.drawing)
    }

    func testPlayingASequence() {
        var (e, _, square, first, _) = editor()
        e.selectKeyframe(first)
        let document = e.presentation, revision = e.revision
        let range = try! XCTUnwrap(e.currentSequenceRange)
        XCTAssertEqual(range, 1...2)
        XCTAssertEqual(e.chainRange(ofSequence: e.presentation.sequences[0].id), 1...2)
        XCTAssertNil(e.chainRange(ofSequence: 9999))
        XCTAssertEqual(e.chainIndex(ofKeyframe: first), 1)
        XCTAssertNil(e.chainIndex(ofKeyframe: 9999))
        XCTAssertEqual(e.timeline.duration(of: range), 1)

        XCTAssertFalse(e.playPreview(range, at: 0))
        XCTAssertEqual(e.preview?.layers[0].transform.rotation ?? -1, 0, accuracy: 1e-9, "starts from the state before")
        XCTAssertFalse(e.playPreview(range, at: 0.25))
        XCTAssertEqual(e.preview?.layers[0].transform.rotation ?? -1, 7.5, accuracy: 1e-9)
        XCTAssertEqual(e.preview?.shape(square)?.opacity, 1)
        XCTAssertTrue(e.playPreview(range, at: 1), "the cut at the end finishes at once")
        XCTAssertNil(e.preview)
        XCTAssertEqual(e.shownDrawing, e.drawing)
        XCTAssertEqual(e.presentation, document)
        XCTAssertEqual(e.revision, revision)
        XCTAssertEqual(e.currentKeyframe, first, "playing doesn't change the current keyframe")

        // From the opening state, the first sequence plays; a range outside the chain finishes.
        e.selectKeyframe(nil)
        XCTAssertEqual(e.currentSequenceRange, 1...2)
        XCTAssertTrue(e.playPreview(0...1, at: 0))
        XCTAssertTrue(e.playPreview(1...5, at: 0))
        XCTAssertNil(e.preview)
        XCTAssertNil(DrawingEditor(drawing: scene().drawing).currentSequenceRange)
    }

    func testTimelinePlayingARange() {
        let (e, _, _, _, _) = editor()
        var t = e.timeline
        XCTAssertNil(t.playing(0...1, at: 0))
        XCTAssertNil(t.playing(1...3, at: 0))
        XCTAssertEqual(t.playing(1...2, at: .nan)?.finished, false, "a non-finite time plays from the start")
        XCTAssertEqual(t.playing(1...1, at: 1)?.finished, true)
        XCTAssertEqual(t.playing(sequence: 0, at: 0.5).finished, false)
        XCTAssertEqual(t.playing(sequence: 7, at: 0).finished, true)
        XCTAssertEqual(t.duration(of: 2...2), 0)
    }
}

final class OnionSkinTests: XCTestCase {
    func testOnionSkinShowsTheKeyframeBefore() {
        var (e, _, _, first, second) = editor()
        e.selectKeyframe(nil)
        let rev = e.onionRevision
        e.showsOnionSkin = true
        XCTAssertNil(e.onionSkin, "the opening state has nothing before it")
        e.selectKeyframe(first)
        XCTAssertEqual(e.onionSkin, e.state(atKeyframe: nil))
        e.selectKeyframe(second)
        XCTAssertEqual(e.onionSkin, e.state(atKeyframe: first))
        XCTAssertGreaterThan(e.onionRevision, rev)
        XCTAssertEqual(e.state(atKeyframe: second), e.drawing)

        // A command that changes the current keyframe moves it along.
        e.setKeyframe()
        XCTAssertEqual(e.onionSkin, e.state(atKeyframe: second))
        e.undo()
        XCTAssertEqual(e.currentKeyframe, second)
        XCTAssertEqual(e.onionSkin, e.state(atKeyframe: first))

        e.showsOnionSkin = false
        XCTAssertNil(e.onionSkin)
        e.selectKeyframe(first)
        XCTAssertNil(e.onionSkin)
    }
}

final class KeyedPropertiesTests: XCTestCase {
    func testWhatTheKeyframeKeysOnTheSelection() {
        let (d, layer, square, triangle) = scene()
        var e = DrawingEditor(drawing: d)
        e.selection = .layer(layer)
        XCTAssertEqual(e.keyedProperties(), [], "nothing at the opening state")
        e.setKeyframe()
        XCTAssertEqual(e.keyedProperties(), [], "a hold keys nothing")

        e.nudge(by: Vec2(10, 0))
        XCTAssertEqual(e.keyedProperties(), ["transform.position"])

        e.selection = .shape(layer: layer, shape: square)
        XCTAssertEqual(e.keyedProperties(), [], "the layer moved, not the square")
        e.setFill(RGBAColor(hex: "#0000FFFF")!)
        XCTAssertEqual(e.keyedProperties(), ["fill"])
        e.selection = .shape(layer: layer, shape: triangle)
        XCTAssertEqual(e.keyedProperties(), [])
        e.nudge(by: Vec2(0, 5))
        XCTAssertTrue(e.keyedProperties().contains("transform.position"), "\(e.keyedProperties())")

        // A shape created at the keyframe, and points edited on another.
        var circle = 0
        e.drawing.layers[0].shapes.append({
            circle = e.drawing.makeID()
            return VectorShape(id: circle, path: ShapePrimitives.ellipse(Rect(minPoint: .zero, maxPoint: Vec2(50, 50))), fill: .black)
        }())
        e.drawing.assignVertexIDs()
        let current = e.currentKeyframe
        e.selectKeyframe(nil)
        e.selectKeyframe(current)
        e.selection = .shape(layer: layer, shape: circle)
        XCTAssertEqual(e.keyedProperties(), ["created"])
        e.selection = .shapes([ShapeRef(layer: layer, shape: square), ShapeRef(layer: layer, shape: circle)])
        XCTAssertEqual(e.keyedProperties(), ["fill", "created"])
        e.selection = .none
        XCTAssertEqual(e.keyedProperties(), [])
    }

    func testEditedPointsAreKeyedAsPoints() {
        let (d, layer, square, triangle) = scene()
        var e = DrawingEditor(drawing: d)
        let k = e.setKeyframe()
        // At the keyframe: the square's first point moves, the triangle loses one and
        // gains one.
        e.drawing.withShape(square) { $0.path.points[0].position += Vec2(5, 5) }
        e.drawing.withShape(triangle) { shape in
            shape.path.points.remove(at: 1)
            _ = shape.path.insertPoint(segment: 0, t: 0.5)
        }
        e.drawing.assignVertexIDs()
        e.selectKeyframe(nil) // commits the edit to the keyframe
        e.selectKeyframe(k)
        e.selection = .shape(layer: layer, shape: square)
        XCTAssertEqual(e.keyedProperties(), ["points"], "a moved point")
        e.selection = .shape(layer: layer, shape: triangle)
        XCTAssertEqual(e.keyedProperties(), ["points"], "a removed and an inserted point")
        e.selection = .layer(layer)
        XCTAssertEqual(e.keyedProperties(), [])
    }
}

final class PreviewInputTests: XCTestCase {
    private func session() -> (CanvasSession, Int) {
        var s = CanvasSession(options: InputOptions())
        s.resetView(viewSize: Vec2(1000, 800))
        let k = s.editor.setKeyframe()
        s.editor.selectKeyframe(nil)
        return (s, k)
    }

    private func stroke(_ s: inout CanvasSession, id: Int) {
        s.touchBegan(id: id, kind: .pencil, location: Vec2(500, 400))
        s.touchMoved(id: id, samples: [Vec2(520, 400), Vec2(540, 400)])
        s.touchEnded(id: id, location: Vec2(560, 400))
    }

    func testThePencilIsIgnoredDuringAPreview() {
        var (s, k) = session()
        s.editor.selectKeyframe(k)
        s.editor.scrubPreview(into: k, fraction: 0.5)
        stroke(&s, id: 1)
        XCTAssertNil(s.liveStroke)
        XCTAssertEqual(s.editor.drawing.shapeCount, 0)
        XCTAssertNotNil(s.editor.preview, "the touch didn't end the preview")

        // Hover too.
        s.pencilHovered(at: Vec2(500, 400))
        XCTAssertNotNil(s.editor.preview)

        // A two-finger tap still navigates but doesn't undo.
        s.touchBegan(id: 2, kind: .finger, location: Vec2(400, 400), time: 1.0)
        s.touchBegan(id: 3, kind: .finger, location: Vec2(500, 400), time: 1.02)
        s.touchEnded(id: 2, location: Vec2(400, 400), time: 1.1)
        s.touchEnded(id: 3, location: Vec2(500, 400), time: 1.1)
        XCTAssertEqual(s.editor.currentKeyframe, k, "the keyframe wasn't undone")
        XCTAssertNotNil(s.editor.preview)

        s.editor.endPreview()
        stroke(&s, id: 4)
        XCTAssertEqual(s.editor.drawing.shapeCount, 1)
    }

    func testTheOverlayShowsNoSelectionDuringAPreview() {
        var (e, layer, square, first, _) = editor()
        e.selectKeyframe(first)
        e.selection = .shape(layer: layer, shape: square)
        e.tool = .directSelect
        e.outlineView = true
        var cache = OverlayCache()
        let editing = EditorOverlay.layers(for: e, zoom: 1, cache: &cache)
        XCTAssertFalse(editing.selection.isEmpty)

        e.scrubPreview(into: first, fraction: 0.5)
        let previewing = EditorOverlay.layers(for: e, zoom: 1, cache: &cache)
        XCTAssertTrue(previewing.selection.isEmpty)
        XCTAssertTrue(previewing.top.isEmpty)
        XCTAssertFalse(previewing.guides.isEmpty, "the viewport border")
        XCTAssertFalse(previewing.wireframe.isEmpty)
        XCTAssertNotEqual(previewing.wireframe, editing.wireframe, "the wireframe follows the preview")

        e.endPreview()
        let after = EditorOverlay.layers(for: e, zoom: 1, cache: &cache)
        XCTAssertEqual(after.selection, editing.selection)
        XCTAssertEqual(after.wireframe, editing.wireframe)
    }
}
