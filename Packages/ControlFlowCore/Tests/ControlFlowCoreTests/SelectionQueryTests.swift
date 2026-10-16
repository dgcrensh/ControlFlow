import XCTest
@testable import ControlFlowCore

/// A 50-point square with its top-left corner at (`x`, 0).
private func square(_ x: Double) -> BezierPath {
    ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, 0), maxPoint: Vec2(x + 50, 50)))
}

/// An editor with the Select tool and one layer of filled squares at x = 0, 100, 200, ...
private func editor(squares count: Int) -> DrawingEditor {
    var d = Drawing()
    let shapes = (0..<count).map { i in VectorShape(id: d.makeID(), path: square(Double(i) * 100), fill: .ink) }
    d.layers.append(Layer(id: d.makeID(), name: "Art", shapes: shapes))
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

private func refs(_ e: DrawingEditor, _ indices: [Int], layer: Int = 0) -> Set<ShapeRef> {
    let p = e.drawing.layers[layer]
    return Set(indices.map { ShapeRef(layer: p.id, shape: p.shapes[$0].id) })
}

/// The queries the app reads after every change, and the caches that keep them cheap with
/// a big selection (round 2 of the smoothness profile).
final class SelectionQueryTests: XCTestCase {
    // MARK: Align

    /// The count works without bounds, so it must drop the units that have no geometry
    /// as `alignmentBoxes()` does.
    func testAlignmentUnitCountLeavesOutUnitsWithNoGeometry() {
        var e = editor(squares: 4)
        let empty = e.drawing.makeID()
        e.drawing.layers[0].shapes.append(VectorShape(id: empty, path: BezierPath(), fill: .ink))
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        e.selection = .covering(refs(e, [0, 1, 2, 4]))
        XCTAssertEqual(e.alignmentUnits().count, 3, "the group, the square and the empty shape")
        XCTAssertEqual(e.alignmentUnitCount, 2, "the empty shape has nothing to line up")
        XCTAssertEqual(e.alignAvailability, AlignAvailability(canAlign: true, canDistribute: false, alignsToViewportOnly: false))

        e.selection = .covering(refs(e, [0, 1, 2, 3]))
        XCTAssertEqual(e.alignmentUnitCount, 3)
        XCTAssertTrue(e.canDistribute)

        e.selection = .shape(layer: e.drawing.layers[0].id, shape: empty)
        XCTAssertEqual(e.alignmentUnitCount, 0)
        XCTAssertFalse(e.canAlign)

        e.selection = .layer(e.drawing.layers[0].id)
        XCTAssertEqual(e.alignmentUnitCount, 1)
        XCTAssertTrue(e.alignsToViewportOnly)
    }

    /// Part of a group is each shape; the units keep draw order and each whole group once.
    func testUnitsOfAPartlySelectedGroupAreItsShapes() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection()
        let layer = e.drawing.layers[0]
        e.selection = .covering(refs(e, [0, 1, 3]))
        XCTAssertEqual(e.alignmentUnits(), [0, 1, 3].map { .shape(layer: layer.id, shape: layer.shapes[$0].id) })
        e.selection = .covering(refs(e, [0, 1, 2, 3]))
        XCTAssertEqual(e.alignmentUnits(), [.shape(layer: layer.id, shape: layer.shapes[0].id), .covering(refs(e, [1, 2])),
                                            .shape(layer: layer.id, shape: layer.shapes[3].id)])
    }

    // MARK: Coalescing

    /// Nudges of one selection are one undo step; selecting something else, even the
    /// same shapes again later, starts another.
    func testNudgesCoalesceWhileTheSelectionStaysTheSame() {
        var e = editor(squares: 2)
        let a = Selection.covering(refs(e, [0])), b = Selection.covering(refs(e, [1]))
        let start = e.drawing
        e.selection = a
        e.nudge(by: Vec2(1, 0))
        e.nudge(by: Vec2(1, 0))
        let afterA = e.drawing
        e.selection = b
        e.nudge(by: Vec2(0, 1))
        e.selection = a
        e.nudge(by: Vec2(1, 0))
        e.undo()
        e.undo()
        XCTAssertEqual(e.drawing, afterA, "each later run was its own step")
        e.undo()
        XCTAssertEqual(e.drawing, start, "the first two nudges were one step")
    }

    // MARK: Refresh

    /// The key the app skips the selection's queries on: unchanged by hovering and the
    /// camera, changed by anything the queries read.
    func testSelectionQueriesKeyFollowsWhatTheQueriesRead() {
        var s = CanvasSession(options: InputOptions())
        s.editor = editor(squares: 3)
        s.resetView(viewSize: Vec2(1000, 800))
        let start = s.editor.selectionQueriesKey
        s.pencilHovered(at: Vec2(10, 10))
        s.camera.worldToScreen = .scale(2) * s.camera.worldToScreen
        XCTAssertEqual(s.editor.selectionQueriesKey, start)
        s.editor.selection = .covering(refs(s.editor, [0]))
        let selected = s.editor.selectionQueriesKey
        XCTAssertNotEqual(selected, start)
        s.editor.tool = .directSelect
        XCTAssertNotEqual(s.editor.selectionQueriesKey, selected)
        s.editor.tool = .select
        XCTAssertEqual(s.editor.selectionQueriesKey, selected)
        s.editor.nudge(by: Vec2(1, 0))
        XCTAssertNotEqual(s.editor.selectionQueriesKey, selected)
    }

    // MARK: Hover

    /// With the select tool only the shape a touch would hit shows, so a hover reports a
    /// change only when that shape does. Tools that draw at the hover point always change.
    func testHoverReportsWhetherTheOverlayChanged() {
        var e = editor(squares: 2)
        XCTAssertTrue(e.pencilHovered(at: Vec2(25, 25)), "now over the first square")
        XCTAssertFalse(e.pencilHovered(at: Vec2(30, 20)), "still over it")
        XCTAssertTrue(e.pencilHovered(at: Vec2(125, 25)), "over the second")
        XCTAssertTrue(e.pencilHovered(at: Vec2(75, 300)), "over nothing")
        XCTAssertFalse(e.pencilHovered(at: Vec2(80, 300)))
        XCTAssertFalse(e.pencilHovered(at: nil), "the Pencil left from over nothing")
        XCTAssertTrue(e.pencilHovered(at: Vec2(25, 25)))
        XCTAssertTrue(e.pencilHovered(at: nil), "the Pencil left from over a square")

        XCTAssertTrue(e.pencilHovered(at: Vec2(25, 25)))
        e.selection = .covering(refs(e, [1]))
        e.nudge(by: Vec2(1, 0))
        XCTAssertTrue(e.pencilHovered(at: Vec2(25, 25)), "the first hover after an edit draws")

        e.tool = .eraser
        XCTAssertTrue(e.pencilHovered(at: Vec2(25, 25)))
        XCTAssertTrue(e.pencilHovered(at: Vec2(25, 25)), "the eraser's ring follows the Pencil")
    }

    // MARK: Marquee

    /// A marquee touching one shape of each of several groups takes each whole group, but
    /// not their locked shapes, and nothing of the groups it missed.
    func testMarqueeTakesTheWholeGroupsItTouches() {
        var e = editor(squares: 6)
        for pair in [[0, 1], [2, 3], [4, 5]] {
            e.selection = .covering(refs(e, pair))
            e.groupSelection()
        }
        e.drawing.layers[0].shapes[3].isLocked = true
        e.selection = .none
        // Over the squares at x = 100 and 200: one shape of each of the first two groups.
        e.pencilBegan(at: Vec2(110, -10), zoom: 1)
        e.pencilMoved(to: Vec2(160, 30))
        e.pencilMoved(to: Vec2(220, 60))
        e.pencilEnded(at: Vec2(220, 60))
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [0, 1, 2]))
    }

    // MARK: Ghosting

    func testGhostFocusCacheMatchesTheEditor() {
        var e = editor(squares: 3)
        var cache = GhostFocusCache()
        XCTAssertNil(cache.focus(of: e))
        e.ghostsUnselected = true
        XCTAssertEqual(cache.focus(of: e), e.ghostFocus)
        e.selection = .covering(refs(e, [0, 2]))
        XCTAssertEqual(cache.focus(of: e), e.ghostFocus)
        XCTAssertEqual(cache.focus(of: e)?.count, 2)
        e.deleteSelection()
        XCTAssertEqual(cache.focus(of: e), e.ghostFocus)
        e.ghostsUnselected = false
        XCTAssertNil(cache.focus(of: e))
    }
}
