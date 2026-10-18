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
        let blue = RGBAColor(hex: "#0000FFFF")!, green = RGBAColor(hex: "#00FF00FF")!, gray = RGBAColor(hex: "#808080FF")!
        t.edit(2) { $0.withShape(square) { $0.fill = blue } }
        t.edit(1) { s in
            s.withShape(square) { $0.fill = green }
            s.withShape(triangle) { $0.fill = gray }
        }
        XCTAssertEqual(t.state(at: 1).shape(square)?.fill, green)
        XCTAssertEqual(t.state(at: 2).shape(square)?.fill, blue, "the later keyframe keeps its own value")
        XCTAssertEqual(t.state(at: 2).shape(triangle)?.fill, gray, "and inherits the rest")
    }

    func testAMoveOrOpacityChangeStopsAtTheNextKeyframe() {
        let (d, layer, square, triangle) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        t.insertKeyframe(after: 2)
        let points = t.state(at: 2).shape(square)!.path.points
        t.edit(1) { s in
            s.withShape(square) { $0.apply(.translation(Vec2(50, 0))) }
            s.withShape(triangle) { $0.opacity = 0.4 }
            s.layers[0].transform.rotation = 30
        }
        XCTAssertEqual(t.state(at: 1).shape(square)?.path.points.first?.position, points[0].position + Vec2(50, 0))
        XCTAssertEqual(t.state(at: 1).shape(triangle)?.opacity, 0.4)
        XCTAssertEqual(t.state(at: 1).layers[0].transform.rotation, 30)
        for i in 2...3 {
            XCTAssertEqual(t.state(at: i).shape(square)?.path.points, points, "keyframe \(i) keeps its points")
            XCTAssertEqual(t.state(at: i).shape(triangle)?.opacity, 1, "keyframe \(i) keeps its opacity")
            XCTAssertEqual(t.state(at: i).layers[0].transform.rotation, 0, "keyframe \(i) keeps its transform")
        }
        let next = t.presentation.keyframes[1].changes
        XCTAssertTrue(next.contains(.set(id: triangle, props: [PropertyChange("opacity", 1)])))
        XCTAssertTrue(next.contains(.set(id: layer, props: [PropertyChange("transform.rotation", 0)])))
        XCTAssertEqual(next.count, 2 + points.count, "one set per moved vertex")
        XCTAssertEqual(t.presentation.keyframes[2].changes, [], "keyframes after the next are untouched")

        // Putting it back drops the next keyframe's changes, which have nothing to do.
        t.edit(1) { s in
            s.withShape(square) { $0.apply(.translation(Vec2(-50, 0))) }
            s.withShape(triangle) { $0.opacity = 1 }
            s.layers[0].transform.rotation = 0
        }
        XCTAssertEqual(t.presentation.keyframes[0].changes, [])
        XCTAssertEqual(t.presentation.keyframes[1].changes, [])
        XCTAssertEqual(t.state(at: 2).shape(square)?.path.points, points)
    }

    func testAHeldPropertyMergesIntoTheNextKeyframesOwnChange() {
        let (d, _, square, _) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        let blue = RGBAColor(hex: "#0000FFFF")!
        t.edit(2) { $0.withShape(square) { $0.fill = blue } }
        t.edit(1) { s in s.withShape(square) { $0.opacity = 0.5; $0.transform.rotation = 45 } }
        XCTAssertEqual(t.presentation.keyframes[1].changes, [.set(id: square, props: [
            PropertyChange("fill", .string("#0000FFFF")), PropertyChange("opacity", 1), PropertyChange("transform", .null),
        ])])
        XCTAssertEqual(t.state(at: 2).shape(square)?.opacity, 1)
        XCTAssertEqual(t.state(at: 2).shape(square)?.transform, .identity)
        XCTAssertEqual(t.state(at: 2).shape(square)?.fill, blue)
    }

    func testAnEditAtTheOpeningStateStopsAtTheFirstKeyframe() {
        let (d, _, _, triangle) = scene()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.edit(0) { $0.withShape(triangle) { $0.opacity = 0.2 } }
        XCTAssertEqual(t.state(at: 0).shape(triangle)?.opacity, 0.2)
        XCTAssertEqual(t.state(at: 1).shape(triangle)?.opacity, 1)
        XCTAssertEqual(t.presentation.keyframes[0].changes, [.set(id: triangle, props: [PropertyChange("opacity", 1)])])
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

    /// Vertex, shape and layer changes, created and deleted objects: the marks match the
    /// parents found by indexing both whole scenes, as they were worked out before.
    func testChangedObjectsFindTheParentsOfVerticesAndCreatedObjects() {
        let (d, layer, square, triangle) = scene()
        var t = Timeline(Presentation(opening: d))
        func keyframe(_ change: (inout Drawing) -> Void) {
            let i = t.count
            t.insertKeyframe(after: i - 1)
            t.edit(i, change)
        }
        keyframe { $0.withShape(square) { $0.path.points[0].position += Vec2(10, 0) } }
        keyframe { $0.withShape(triangle) { $0.path.points.insert(PathPoint(Vec2(450, 320)), at: 2) } }
        keyframe { $0.withShape(square) { $0.path.points.remove(at: 1) } }
        keyframe { d in
            var added = Layer(id: d.makeID(), name: "New")
            added.shapes = [VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(9, 9))),
                                        fill: .black)]
            d.layers.append(added)
            d.layers[0].shapes.removeAll { $0.id == triangle }
        }
        keyframe { $0.viewport.background = .black }
        for i in 1..<t.count {
            let id = t.presentation.keyframe(atChainIndex: i)!.id
            let expected = Self.changedObjectsIndexingEverything(&t, at: i)
            XCTAssertFalse(expected.isEmpty, "keyframe \(i)")
            XCTAssertEqual(t.changedObjects(inKeyframe: id), expected, "keyframe \(i)")
        }
        XCTAssertEqual(t.changedObjects(inKeyframe: t.presentation.keyframe(atChainIndex: 1)!.id),
                       [layer, square, d.layers[0].shapes[0].path.points[0].id])
    }

    /// The marks as they were worked out before: every object and vertex of both scenes
    /// indexed, then each change's target and parent walked up.
    private static func changedObjectsIndexingEverything(_ t: inout Timeline, at index: Int) -> Set<Int> {
        let keyframe = t.presentation.keyframe(atChainIndex: index)!
        let lookup = SceneLookup(t.state(at: index - 1)), after = SceneLookup(t.state(at: index))
        var ids = Set<Int>()
        for change in keyframe.changes {
            var parent: Int?
            switch change {
            case .create(_, let p, _, _, _): parent = p
            case .order(let p, _): parent = p
            case .set, .delete: break
            }
            for id in [change.target, parent].compactMap({ $0 }) {
                var current: Int? = id
                while let c = current, ids.insert(c).inserted { current = lookup.parents[c] ?? after.parents[c] }
            }
        }
        return ids
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

    func testUndoAtAKeyframeKeepsTheStatesBeforeIt() {
        let (d, layer, square, _) = scene()
        var e = DrawingEditor(drawing: d)
        for k in 1...4 {
            e.setKeyframe()
            e.selection = .layer(layer)
            e.rotateSelection(byDegrees: 10)
            e.selection = .shape(layer: layer, shape: square)
            e.setOpacity(1 - Double(k) / 10)
        }
        let third = e.presentation.keyframe(atChainIndex: 3)!.id
        e.selectKeyframe(third)
        e.setOpacity(0.05)
        e.undo()
        XCTAssertEqual(e.drawing.shape(square)?.opacity ?? 0, 0.7, accuracy: 1e-9)
        XCTAssertNotNil(e.timeline.states[2], "states before the undone step are kept")
        var fresh = Timeline(e.presentation)
        var live = e.timeline
        for i in 0..<fresh.count {
            // Kept states hold the edits as made; resolved ones, what the file stores.
            XCTAssertEqual(SceneDiff.changes(from: live.state(at: i), to: fresh.state(at: i)), [], "state \(i)")
        }
        e.redo()
        XCTAssertEqual(e.drawing.shape(square)?.opacity ?? 0, 0.05, accuracy: 1e-9)
        fresh = Timeline(e.presentation)
        live = e.timeline
        for i in 0..<fresh.count {
            // Kept states hold the edits as made; resolved ones, what the file stores.
            XCTAssertEqual(SceneDiff.changes(from: live.state(at: i), to: fresh.state(at: i)), [], "state \(i)")
        }
    }

    func testReusedStatesStopAtTheFirstChangedKeyframe() {
        let (d, layer, _, _) = scene()
        var t = Timeline(Presentation(opening: d))
        for k in 1...3 {
            t.insertKeyframe(after: k - 1)
            t.edit(k) { $0.layers[0].transform.rotation = Double(k) * 10 }
        }
        _ = t.state(at: 3)
        var p = t.presentation
        p.updateKeyframe(atChainIndex: 2) { $0.changes = [.set(id: layer, props: [PropertyChange("transform.rotation", 45)])] }
        var reused = Timeline(p)
        reused.reuseStates(of: t)
        XCTAssertNotNil(reused.states[1])
        XCTAssertNil(reused.states[2], "the changed keyframe and those after it resolve again")
        XCTAssertNil(reused.states[3])
        var fresh = Timeline(p)
        for i in 0..<fresh.count { XCTAssertEqual(reused.state(at: i), fresh.state(at: i), "state \(i)") }

        var opening = t.presentation
        opening.opening.layers[0].name = "Other"
        var other = Timeline(opening)
        other.reuseStates(of: t)
        XCTAssertNil(other.states[1], "nothing is reused when the opening state differs")
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

    /// The marks are kept between refreshes, and worked out again when a timeline edit
    /// changes the current keyframe's changes without changing its scene.
    func testChangedObjectsFollowTimelineEdits() {
        let (d, layer, square, triangle) = scene()
        var e = DrawingEditor(drawing: d)
        let first = e.setKeyframe()
        e.selection = .shape(layer: layer, shape: square)
        e.setOpacity(0.5)
        e.setKeyframe()
        e.selection = .shape(layer: layer, shape: triangle)
        e.setOpacity(0.5)
        XCTAssertEqual(e.changedObjects(), [layer, triangle])
        XCTAssertEqual(e.changedObjects(), [layer, triangle])
        e.deleteKeyframe(first)
        XCTAssertEqual(e.changedObjects(), [layer, square, triangle], "the deleted keyframe's changes fold in")
        e.undo()
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

    /// A diff that takes the unchanged layers' changes from the last one gives exactly the
    /// changes of a fresh diff, as one layer after another changes on either side.
    func testAMemoizedDiffEqualsAFreshOne() {
        let a = StressDrawing.make(layers: 6, shapesPerLayer: 8)
        // A keyframe that keys every shape.
        var b = a
        for l in b.layers.indices {
            for s in b.layers[l].shapes.indices { b.layers[l].shapes[s].transform.position += Vec2(Double(l), 3) }
        }
        var memo = SceneDiff.Memo()
        var from = a
        func check(_ label: String, _ edit: (inout Drawing) -> Void) {
            edit(&b)
            b.assignVertexIDs()
            XCTAssertEqual(SceneDiff.changes(from: from, to: b, memo: &memo), SceneDiff.changes(from: from, to: b), label)
        }
        check("first") { _ in }
        check("one shape moved") { $0.layers[2].shapes[1].transform.position += Vec2(5, 0) }
        check("a vertex added") { _ = $0.layers[3].shapes[0].path.insertPoint(segment: 0, t: 0.5) }
        check("a vertex removed") { $0.layers[3].shapes[2].path.points.remove(at: 1) }
        check("a shape moved to another layer") { d in
            let shape = d.layers[0].shapes.removeLast()
            d.layers[1].shapes.insert(shape, at: 2)
        }
        check("shapes reordered") { $0.layers[4].shapes.swapAt(0, 3) }
        check("a shape deleted") { $0.layers[5].shapes.remove(at: 4) }
        check("a group added") { d in
            let group = ShapeGroup(id: d.makeID(), name: "Pair")
            d.layers[2].groups.append(group)
            d.layers[2].shapes[0].group = group.id
            d.layers[2].shapes[1].group = group.id
        }
        check("layers reordered") { $0.layers.swapAt(1, 4) }
        check("a layer deleted") { $0.layers.remove(at: 5) }
        check("a layer added") { d in
            var layer = Layer(id: d.makeID(), name: "New")
            layer.shapes = [VectorShape(id: d.makeID(), path: ShapePrimitives.line(Vec2(0, 0), Vec2(10, 10)), fill: nil)]
            d.layers.insert(layer, at: 2)
        }
        check("an edit undone") { $0.layers[3].shapes[1].transform.position -= Vec2(5, 0) }
        check("the background") { $0.viewport.background = RGBAColor(hex: "#202020FF")! }
        // The state before the keyframe changes too.
        from.layers[2].shapes[3].opacity = 0.5
        check("from changed") { _ in }
        from = b
        check("no changes") { _ in }
    }

    /// Commits at a keyframe store the changes a fresh diff gives, each time.
    func testRepeatedCommitsAtAKeyframeStoreTheFreshDiff() {
        let a = StressDrawing.make(layers: 4, shapesPerLayer: 5)
        var t = Timeline(Presentation(opening: a))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        for step in 0..<6 {
            t.edit(1) { s in
                if step == 0 {
                    for l in s.layers.indices { s.layers[l].transform.position += Vec2(1, 0) }
                } else {
                    s.layers[step % 4].shapes[step % 5].transform.position += Vec2(2, 1)
                }
            }
            XCTAssertEqual(t.presentation.keyframes[0].changes, SceneDiff.changes(from: t.state(at: 0), to: t.state(at: 1)))
        }
    }

    /// Deleting an object before a keyframe that creates a shape and reorders its layer
    /// keeps the order of what is left, the created shape included.
    func testPruningKeepsTheOrderOfShapesAKeyframeCreates() {
        var (d, layer, square, triangle) = scene()
        let circle = VectorShape(id: d.makeID(), path: ShapePrimitives.ellipse(Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(50, 50))),
                                 fill: .black)
        d.layers[0].shapes.append(circle)
        d.assignVertexIDs()
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0)
        t.insertKeyframe(after: 1)
        var created = 0
        t.edit(2) { s in
            var shape = s.layers[0].shapes[0]
            shape.id = s.makeID()
            shape.path.clearVertexIDs()
            created = shape.id
            let rest = s.layers[0].shapes
            s.layers[0].shapes = [rest[1], shape, rest[0], rest[2]]
        }
        XCTAssertEqual(t.state(at: 2).layers[0].shapes.map(\.id), [triangle, created, square, circle.id])
        XCTAssertTrue(t.presentation.keyframes[1].changes.contains { if case .order = $0 { true } else { false } })
        t.edit(1) { $0.layers[0].shapes.removeAll { $0.id == circle.id } }
        XCTAssertEqual(t.state(at: 2).layers[0].shapes.map(\.id), [triangle, created, square])
        XCTAssertEqual(t.presentation.keyframes[1].changes.compactMap { change -> [Int]? in
            if case .order(let parent, let ids) = change, parent == layer { ids } else { nil }
        }, [[triangle, created, square]])
    }

    func testALazyLookupIndexesVerticesOnlyWhenAChangeNeedsThem() {
        let (d, layer, square, _) = scene()
        var state = d
        var lookup = SceneLookup(state, indexingVertices: false)
        state.apply([.set(id: layer, props: [PropertyChange("transform.rotation", 30)])], lookup: &lookup)
        XCTAssertFalse(lookup.hasVertices, "a layer change needs no vertices")
        XCTAssertEqual(state.layers[0].transform.rotation, 30)

        // A vertex created under a shape is found by a later change in the same run.
        var point = PathPoint(Vec2(200, 50))
        point.id = state.makeID()
        let first = state.shape(square)!.path.points[0].id
        state.apply([.create(.vertex(point), parent: square, after: first)], lookup: &lookup)
        XCTAssertFalse(lookup.hasVertices)
        XCTAssertEqual(state.shape(square)?.path.points[1].id, point.id)
        state.apply([.set(id: point.id, props: [PropertyChange("p", .array([.number(210), .number(60)]))])], lookup: &lookup)
        XCTAssertTrue(lookup.hasVertices, "setting a vertex indexes them")
        XCTAssertEqual(state.shape(square)?.path.points[1].position, Vec2(210, 60))
        state.apply([.set(id: first, props: [PropertyChange("p", .array([.number(90), .number(90)]))])], lookup: &lookup)
        XCTAssertEqual(state.shape(square)?.path.points[0].position, Vec2(90, 90))
        XCTAssertEqual(state.apply([.set(id: 999_999, props: [PropertyChange("p", .array([.number(0), .number(0)]))])], lookup: &lookup), [0],
                       "an id that isn't there still fails")
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
