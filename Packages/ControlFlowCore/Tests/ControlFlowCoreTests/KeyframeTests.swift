import Foundation
import XCTest
@testable import ControlFlowCore

/// A drawing with one layer holding a square and a triangle.
private func scene() -> (drawing: Drawing, layer: Int, square: Int, triangle: Int) {
    var d = Drawing()
    var layer = Layer(id: d.makeID(), name: "Art", pivot: Vec2(300, 300))
    let square = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(100, 100), maxPoint: Vec2(300, 300))),
                             fill: RGBAColor(hex: "#FF0000FF")!)
    var triangle = VectorShape(id: d.makeID(), path: BezierPath(points: [PathPoint(Vec2(400, 100)), PathPoint(Vec2(500, 300)), PathPoint(Vec2(300, 300))],
                                                                closed: true), fill: .black)
    triangle.opacity = 1
    layer.shapes = [square, triangle]
    d.layers = [layer]
    d.assignVertexIDs()
    return (d, layer.id, square.id, triangle.id)
}

private extension Timeline {
    /// Edits the state at `index` and records it.
    mutating func edit(_ index: Int, _ change: (inout Drawing) -> Void) {
        var s = state(at: index)
        change(&s)
        s.assignVertexIDs()
        record(s, at: index)
    }
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

final class KeyframeEditingTests: XCTestCase {
    func testAnEditBecomesTheKeyframesChanges() {
        let (d, layer, _, _) = scene()
        var t = Timeline(Presentation(opening: d))
        let k = t.insertKeyframe(after: 0)
        XCTAssertEqual(t.presentation.sequences.count, 1, "the first keyframe makes a sequence")
        XCTAssertEqual(t.state(at: 1), t.state(at: 0), "a new keyframe looks like the one before it")
        t.edit(1) { $0.layers[0].transform.rotation = 30 }
        XCTAssertEqual(t.presentation.keyframe(k)?.changes, [.set(id: layer, props: [PropertyChange("transform.rotation", 30)])])
        XCTAssertEqual(t.state(at: 0).layers[0].transform.rotation, 0, "the opening state is unchanged")

        // Setting it back drops the change.
        t.edit(1) { $0.layers[0].transform.rotation = 0 }
        XCTAssertEqual(t.presentation.keyframe(k)?.changes, [])
    }

    func testEditsCarryForwardUntilAKeyframeSetsTheSameProperty() {
        let (d, _, square, triangle) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        t.edit(2) { $0.withShape(square) { $0.opacity = 0.3 } }
        t.edit(1) { s in
            s.withShape(square) { $0.opacity = 0.7 }
            s.withShape(triangle) { $0.opacity = 0.5 }
        }
        XCTAssertEqual(t.state(at: 1).shape(square)?.opacity, 0.7)
        XCTAssertEqual(t.state(at: 2).shape(square)?.opacity, 0.3, "the later keyframe keeps its own value")
        XCTAssertEqual(t.state(at: 2).shape(triangle)?.opacity, 0.5, "and inherits the rest")
    }

    func testDeletingAnObjectDropsLaterChangesToIt() {
        let (d, _, square, triangle) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        t.edit(2) { s in
            s.withShape(square) { $0.opacity = 0.3 }
            s.withShape(triangle) { $0.opacity = 0.5 }
        }
        XCTAssertEqual(t.presentation.keyframes[1].changes.count, 2)
        t.edit(1) { $0.layers[0].shapes.removeAll { $0.id == square } }
        XCTAssertEqual(t.presentation.keyframes[0].changes, [.delete(id: square)])
        XCTAssertEqual(t.presentation.keyframes[1].changes, [.set(id: triangle, props: [PropertyChange("opacity", 0.5)])])
        XCTAssertNil(t.state(at: 2).shape(square))
    }

    func testNamesAndHintsAreTheSameAtEveryKeyframe() {
        let (d, layer, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        t.edit(2) { s in
            s.layers[0].name = "Renamed"
            s.withShape(square) { $0.isLocked = true }
        }
        XCTAssertEqual(t.presentation.keyframes[1].changes, [], "names and hints aren't keyed")
        for i in 0..<3 {
            XCTAssertEqual(t.state(at: i).layer(layer)?.name, "Renamed")
            XCTAssertEqual(t.state(at: i).shape(square)?.isLocked, true)
        }
    }

    func testNewObjectsCanBeCreatedAtAKeyframe() {
        let (d, layer, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        var circle = 0
        t.edit(1) { s in
            circle = s.makeID()
            s.layers[0].shapes.insert(VectorShape(id: circle, path: ShapePrimitives.ellipse(Rect(minPoint: .zero, maxPoint: Vec2(50, 50))), fill: .black), at: 1)
        }
        guard case .create(.shape(let shape), let parent, let after, _, _)? = t.presentation.keyframes[0].changes.first else {
            return XCTFail("\(t.presentation.keyframes[0].changes)")
        }
        XCTAssertEqual(shape.id, circle)
        XCTAssertEqual(parent, layer)
        XCTAssertEqual(after, square)
        XCTAssertNil(t.state(at: 0).shape(circle))
        XCTAssertEqual(t.state(at: 1).layers[0].shapes.map(\.id)[1], circle)
        // Ids aren't handed out twice, keyframes' included.
        let next = t.insertKeyframe(after: 1)
        XCTAssertGreaterThan(next, circle)
    }
}

final class TimelineCommandTests: XCTestCase {
    /// Three keyframes turning the layer by 10, 20 and 30 degrees, the last also fading the square.
    private func timeline() -> (Timeline, square: Int) {
        let (d, _, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        for i in 1...3 {
            t.insertKeyframe(after: i - 1)
            t.edit(i) { $0.layers[0].transform.rotation = Double(10 * i) }
        }
        t.edit(3) { $0.withShape(square) { $0.opacity = 0.5 } }
        return (t, square)
    }

    func testDeletingAKeyframeFoldsItIntoTheNext() {
        var (t, _) = timeline()
        let after = t.state(at: 3)
        let ids = t.presentation.keyframes.map(\.id)
        XCTAssertEqual(t.deleteKeyframe(ids[1]), 1)
        XCTAssertEqual(t.presentation.keyframes.map(\.id), [ids[0], ids[2]])
        XCTAssertEqual(t.state(at: 2), after, "later states look the same")
        // The first keyframe's changes fold into the second when it goes.
        t.deleteKeyframe(ids[0])
        XCTAssertEqual(t.state(at: 1), after)
        t.deleteKeyframe(ids[2])
        XCTAssertTrue(t.presentation.sequences.isEmpty, "an empty sequence goes")
        XCTAssertEqual(t.count, 1)
    }

    func testSequencesSplitMergeAndDelete() {
        var (t, _) = timeline()
        let ids = t.presentation.keyframes.map(\.id)
        XCTAssertFalse(t.splitSequence(at: ids[0]))
        XCTAssertTrue(t.splitSequence(at: ids[1]))
        XCTAssertEqual(t.presentation.sequences.map { $0.keyframes.map(\.id) }, [[ids[0]], [ids[1], ids[2]]])
        XCTAssertEqual(t.presentation.chainRange(ofSequence: 1), 2...3)
        let end = t.state(at: 3)
        t.deleteSequence(at: 0)
        XCTAssertEqual(t.presentation.sequences.map { $0.keyframes.map(\.id) }, [[ids[1], ids[2]]])
        XCTAssertEqual(t.state(at: 2).layers, end.layers)
        t.splitSequence(at: ids[2])
        XCTAssertTrue(t.mergeSequence(at: 0))
        XCTAssertFalse(t.mergeSequence(at: 0))
        XCTAssertEqual(t.presentation.sequences.count, 1)

        // A new sequence goes after the current one's last keyframe.
        let k = t.insertSequence(after: 1)
        XCTAssertEqual(t.presentation.sequences.map { $0.keyframes.map(\.id) }, [[ids[1], ids[2]], [k]])
        XCTAssertEqual(t.state(at: 3).layers, end.layers)
    }

    func testRevertDuplicateAndMove() {
        var (t, square) = timeline()
        let ids = t.presentation.keyframes.map(\.id)
        t.revertKeyframe(ids[2])
        XCTAssertEqual(t.presentation.keyframes[2].changes, [])
        XCTAssertEqual(t.state(at: 3), t.state(at: 2))
        t.edit(3) { $0.withShape(square) { $0.opacity = 0.5 } }

        t.setTransition(Transition(duration: 2, curve: .linear), ofKeyframe: ids[1])
        let copy = t.duplicateKeyframe(ids[1])!
        XCTAssertEqual(t.presentation.keyframes.map(\.id), [ids[0], ids[1], copy, ids[2]])
        XCTAssertEqual(t.presentation.keyframe(copy)?.transition, Transition(duration: 2, curve: .linear))
        XCTAssertEqual(t.state(at: 3), t.state(at: 2), "a duplicate is a hold")
        XCTAssertEqual(t.lastTransition, Transition(duration: 2, curve: .linear), "new keyframes take the last transition set")

        // Moving keeps how each keyframe looks.
        let looks = Dictionary(uniqueKeysWithValues: (1..<t.count).map { (t.presentation.keyframe(atChainIndex: $0)!.id, t.state(at: $0)) })
        let sequence = t.presentation.sequences[0].id
        XCTAssertTrue(t.moveKeyframe(ids[2], toSequence: sequence, at: 0))
        XCTAssertEqual(t.presentation.keyframes.map(\.id), [ids[2], ids[0], ids[1], copy])
        for i in 1..<t.count {
            XCTAssertEqual(t.state(at: i), looks[t.presentation.keyframe(atChainIndex: i)!.id])
        }
        XCTAssertEqual(t.presentation.keyframes[0].changes.count, 2, "the rotation and the fade")
        XCTAssertFalse(t.moveKeyframe(ids[2], toSequence: sequence, at: 0))
    }

    func testChangedObjectsIncludeTheirParents() {
        var (t, square) = timeline()
        let (_, layer, _, _) = scene()
        XCTAssertEqual(t.changedObjects(inKeyframe: t.presentation.keyframes[0].id), [layer])
        XCTAssertEqual(t.changedObjects(inKeyframe: t.presentation.keyframes[2].id), [layer, square])
    }
}

final class KeyframeEditorTests: XCTestCase {
    func testEditsAtAKeyframeUndo() {
        let (d, layer, square, _) = scene()
        var e = DrawingEditor(drawing: d)
        let k = e.setKeyframe()
        XCTAssertEqual(e.currentKeyframe, k)
        e.selection = .shape(layer: layer, shape: square)
        e.setOpacity(0.25)
        XCTAssertEqual(e.presentation.keyframe(k)?.changes, [.set(id: square, props: [PropertyChange("opacity", 0.25)])])
        e.deleteSelection()
        XCTAssertEqual(e.presentation.keyframe(k)?.changes, [.delete(id: square)])

        e.undo()
        XCTAssertEqual(e.drawing.shape(square)?.opacity, 0.25)
        XCTAssertEqual(e.currentKeyframe, k)
        e.selectKeyframe(nil)
        XCTAssertEqual(e.drawing.shape(square)?.opacity, 1, "the opening state is unchanged")
        e.undo()
        e.undo()
        XCTAssertTrue(e.presentation.sequences.isEmpty)
        XCTAssertNil(e.currentKeyframe)
        e.redo()
        XCTAssertEqual(e.currentKeyframe, k)
        e.redo()
        XCTAssertNil(e.currentKeyframe, "redo returns to where the step was undone")
        e.selectKeyframe(k)
        XCTAssertEqual(e.drawing.shape(square)?.opacity, 0.25)
    }

    func testTimelineCommandsAreOneUndoStepEach() {
        let (d, layer, _, _) = scene()
        var e = DrawingEditor(drawing: d)
        let first = e.setKeyframe()
        e.selection = .layer(layer)
        e.rotateSelection(byDegrees: 30)
        let second = e.newSequence()
        XCTAssertEqual(e.presentation.sequences.count, 2)
        e.setTransition(Transition(duration: 1), ofKeyframe: second, continuous: true)
        e.setTransition(Transition(duration: 2), ofKeyframe: second, continuous: true)
        e.renameSequence(e.presentation.sequences[1].id, to: "  Next ")
        XCTAssertEqual(e.presentation.sequences[1].name, "Next")
        e.deleteKeyframe(second)
        XCTAssertEqual(e.currentKeyframe, first, "the keyframe before becomes current")
        e.undo() // delete
        e.undo() // rename
        XCTAssertEqual(e.presentation.keyframe(second)?.transition.duration, 2)
        e.undo() // both transition changes
        XCTAssertEqual(e.presentation.keyframe(second)?.transition, .standard)
        e.undo() // new sequence
        XCTAssertEqual(e.presentation.sequences.count, 1)
        XCTAssertEqual(e.drawing.layers[0].transform.rotation, 30, accuracy: 1e-9)
    }

    func testRevertSelectionToPrevious() {
        let (d, layer, square, triangle) = scene()
        var e = DrawingEditor(drawing: d)
        e.setKeyframe()
        e.selection = .shapes([ShapeRef(layer: layer, shape: square), ShapeRef(layer: layer, shape: triangle)])
        e.setOpacity(0.5)
        e.selection = .shape(layer: layer, shape: square)
        e.revertSelectionToPrevious()
        XCTAssertEqual(e.drawing.shape(square)?.opacity, 1)
        XCTAssertEqual(e.drawing.shape(triangle)?.opacity, 0.5)
        XCTAssertEqual(e.changedObjects(), [layer, triangle])
    }

    func testAPresentationRoundTripsThroughTheEditor() {
        let (d, _, square, _) = scene()
        var e = DrawingEditor(drawing: d)
        e.setKeyframe()
        e.drawing.withShape(square) { $0.opacity = 0.5 }
        e.selectKeyframe(nil)
        let saved = e.presentation
        let reopened = DrawingEditor(presentation: saved)
        XCTAssertEqual(reopened.presentation, saved)
        XCTAssertEqual(saved.keyframes[0].changes, [.set(id: square, props: [PropertyChange("opacity", 0.5)])],
                       "an edit made without a commit is kept")
    }
}

final class SceneDiffTests: XCTestCase {
    private func assertRoundTrip(_ a: Drawing, _ b: Drawing, file: StaticString = #filePath, line: UInt = #line) {
        let changes = SceneDiff.changes(from: a, to: b)
        var c = a
        XCTAssertEqual(c.apply(changes), [], "every change applies", file: file, line: line)
        c.nextID = b.nextID
        XCTAssertEqual(c, b, "\(changes)", file: file, line: line)
        XCTAssertEqual(SceneDiff.changes(from: b, to: b), [], file: file, line: line)
    }

    func testApplyingTheDiffGivesTheNewState() {
        let (a, _, square, triangle) = scene()
        var b = a
        // Points moved, inserted, removed; a shape created, one reordered; a new layer.
        b.withShape(square) { s in
            s.path.points[0].position += Vec2(5, 5)
            _ = s.path.insertPoint(segment: 1, t: 0.25)
            s.fill = nil
            s.stroke = StrokeStyle(color: .black, width: 4)
        }
        b.withShape(triangle) { s in s.path.points.remove(at: 1) }
        b.layers[0].shapes.reverse()
        var layer = Layer(id: b.makeID(), name: "New")
        layer.shapes = [VectorShape(id: b.makeID(), path: ShapePrimitives.line(Vec2(0, 0), Vec2(10, 10)), fill: nil)]
        b.layers.insert(layer, at: 0)
        b.viewport.background = RGBAColor(hex: "#101010FF")!
        b.assignVertexIDs()
        assertRoundTrip(a, b)
        assertRoundTrip(b, a)
    }

    func testGroupsAndGlobalColorsRoundTrip() {
        var (a, _, square, triangle) = scene()
        let ink = GlobalColor(id: a.makeID(), name: "Ink", color: .black)
        a.globalColors = [ink]
        a.withShape(triangle) { $0.fillGlobal = ink.id }
        var b = a
        let group = ShapeGroup(id: b.makeID(), name: "Pair")
        b.layers[0].groups = [group]
        b.withShape(square) { $0.group = group.id }
        b.withShape(triangle) { $0.group = group.id }
        b.globalColors[0].color = RGBAColor(hex: "#3366FFFF")!
        b.syncGlobalColors()
        XCTAssertEqual(b.shape(triangle)?.fill, RGBAColor(hex: "#3366FFFF")!)
        assertRoundTrip(a, b)
        assertRoundTrip(b, a)
    }

    func testMovingAShapeToAnotherLayerKeepsItsID() {
        var (a, _, square, _) = scene()
        let other = Layer(id: a.makeID(), name: "Other")
        a.layers.append(other)
        var b = a
        let shape = b.layers[0].shapes.removeFirst()
        b.layers[1].shapes.append(shape)
        let changes = SceneDiff.changes(from: a, to: b)
        XCTAssertEqual(changes.first, .delete(id: square))
        assertRoundTrip(a, b)
    }
}

final class InterpolationTests: XCTestCase {
    func testTimingCurves() {
        for curve in TimingCurve.presets + [.custom(x1: 0.3, y1: 1.6, x2: 0.6, y2: 1)] {
            XCTAssertEqual(curve.progress(at: 0), 0)
            XCTAssertEqual(curve.progress(at: 1), 1)
            XCTAssertEqual(curve.progress(at: -1), 0)
            XCTAssertEqual(curve.progress(at: 2), 1)
        }
        XCTAssertEqual(TimingCurve.linear.progress(at: 0.3), 0.3)
        XCTAssertEqual(TimingCurve.easeInOut.progress(at: 0.5), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TimingCurve.easeIn.progress(at: 0.3) + TimingCurve.easeOut.progress(at: 0.7), 1, accuracy: 1e-9)
        // CSS's ease at a quarter of the way.
        XCTAssertEqual(TimingCurve.ease.progress(at: 0.25), 0.4094, accuracy: 1e-3)
        XCTAssertGreaterThan(TimingCurve.custom(x1: 0.3, y1: 1.6, x2: 0.6, y2: 1).progress(at: 0.6), 1, "overshoots")
        var last = 0.0
        for i in 1...100 {
            let p = TimingCurve.ease.progress(at: Double(i) / 100)
            XCTAssertGreaterThanOrEqual(p, last)
            last = p
        }
        XCTAssertEqual(TimingCurve.custom(x1: -1, y1: 0, x2: 3, y2: 1).controlPoints.x2, 1)
        XCTAssertEqual(Transition(duration: -2).duration, 0)
    }

    func testTransitionsBlendNumbersAndColors() {
        let (d, _, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 2, curve: .linear))
        t.edit(1) { s in
            s.layers[0].transform.rotation = 400
            s.withShape(square) { $0.fill = RGBAColor(hex: "#0000FFFF")!; $0.path.points[0].position += Vec2(100, 0) }
        }
        let half = t.transition(into: 1, elapsed: 1)
        XCTAssertEqual(half.layers[0].transform.rotation, 200, accuracy: 1e-9, "turns take the long way")
        XCTAssertEqual(half.shape(square)?.fill?.hexString, "#800080FF")
        XCTAssertEqual(half.shape(square)?.path.points[0].position.x ?? 0, 150, accuracy: 1e-9)
        XCTAssertEqual(t.transition(into: 1, elapsed: 0), t.state(at: 0).withNextID(t.state(at: 1).nextID))
        XCTAssertEqual(t.transition(into: 1, elapsed: 5), t.state(at: 1))
        XCTAssertEqual(t.duration(ofSequence: 0), 2)
        XCTAssertEqual(t.playing(sequence: 0, at: 1).finished, false)
        XCTAssertEqual(t.playing(sequence: 0, at: 2).finished, true)
    }

    func testCreatedObjectsPopInAndDeletedOnesStayToTheEnd() {
        let (d, _, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var circle = 0
        t.edit(1) { s in
            s.layers[0].shapes.removeAll { $0.id == square }
            circle = s.makeID()
            s.layers[0].shapes.append(VectorShape(id: circle, path: ShapePrimitives.ellipse(Rect(minPoint: .zero, maxPoint: Vec2(50, 50))), fill: .black))
        }
        for elapsed in [0, 0.5, 0.99] {
            let s = t.transition(into: 1, elapsed: elapsed)
            XCTAssertNotNil(s.shape(square), "deleted at \(elapsed)")
            XCTAssertNotNil(s.shape(circle), "created at \(elapsed)")
        }
        XCTAssertNil(t.transition(into: 1, elapsed: 1).shape(square))
    }

    func testCutsAndSnaps() {
        let (d, _, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 0, curve: .linear))
        t.edit(1) { $0.withShape(square) { $0.fill = nil } }
        XCTAssertEqual(t.transition(into: 1, elapsed: 0), t.state(at: 1))
        t.setTransition(Transition(duration: 1, curve: .linear), ofKeyframe: t.presentation.keyframes[0].id)
        XCTAssertNil(t.transition(into: 1, elapsed: 0.1).shape(square)?.fill, "a fill turned off snaps at the start")
    }

    func testABornVertexStartsOnTheOldCurve() {
        let (d, _, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var born = 0
        t.edit(1) { s in
            s.withShape(square) { shape in
                let i = shape.path.insertPoint(segment: 0, t: 0.5)
                shape.path.points[i].position += Vec2(0, -50)
            }
            s.assignVertexIDs()
            born = s.shape(square)!.path.points[1].id
        }
        guard case .create(.vertex, _, _, _, let param)? = t.presentation.keyframes[0].changes.first else {
            return XCTFail("\(t.presentation.keyframes[0].changes)")
        }
        XCTAssertEqual(param ?? 0, 0.5, accuracy: 1e-9)
        let start = t.transition(into: 1, elapsed: 0).shape(square)!
        let end = t.state(at: 1).shape(square)!
        let original = t.state(at: 0).shape(square)!
        XCTAssertEqual(start.path.points.count, 5)
        XCTAssertEqual(start.path.points[1].id, born)
        let mid = original.path.segment(0).point(at: 0.5)
        XCTAssertTrue(start.path.points[1].position.isApproximately(mid, tolerance: 1e-9))
        let half = t.transition(into: 1, elapsed: 0.5).shape(square)!
        XCTAssertTrue(half.path.points[1].position.isApproximately((mid + end.path.points[1].position) / 2, tolerance: 1e-9))
    }

    func testADyingVertexRidesToTheHealedSegment() {
        let (d, _, _, triangle) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        let dying = d.shape(triangle)!.path.points[1].id
        t.edit(1) { $0.withShape(triangle) { $0.path.points.remove(at: 1) } }
        let near = t.transition(into: 1, elapsed: 0.999).shape(triangle)!
        XCTAssertEqual(near.path.points.count, 3)
        let point = near.path.points.first { $0.id == dying }!.position
        // The healed edge runs straight from (400, 100) to (300, 300); the point ends on it.
        let along = Vec2(-100, 200), offset = point - Vec2(400, 100)
        XCTAssertEqual(abs(offset.x * along.y - offset.y * along.x) / 223.607, 0, accuracy: 0.5)
        XCTAssertEqual(t.transition(into: 1, elapsed: 1).shape(triangle)!.path.points.count, 2)
    }
}
