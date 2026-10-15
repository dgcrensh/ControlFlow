import XCTest
@testable import ControlFlowCore

private func circle(center: Vec2, radius: Double, samples: Int, closeGap: Double = 0) -> [Vec2] {
    (0...samples).map { i in
        let a = Double(i) / Double(samples) * (2 * .pi - closeGap)
        return center + Vec2(cos(a), sin(a)) * radius
    }
}

/// Largest distance from any sample to the path's flattened outline.
private func maxDeviation(_ samples: [Vec2], from path: BezierPath) -> Double {
    let poly = path.flattened(tolerance: 0.05)
    let ring = path.closed ? poly + [poly[0]] : poly
    return samples.map { p in
        (1..<ring.count).map { p.distance(toSegment: ring[$0 - 1], ring[$0]) }.min() ?? .infinity
    }.max() ?? 0
}

final class BezierTests: XCTestCase {
    func testSplitPreservesTheCurve() {
        let c = CubicBezier(Vec2(0, 0), Vec2(10, 30), Vec2(40, 30), Vec2(50, 0))
        let (l, r) = c.split(at: 0.3)
        XCTAssertTrue(l.p3.isApproximately(c.point(at: 0.3)))
        XCTAssertTrue(l.point(at: 0.5).isApproximately(c.point(at: 0.15), tolerance: 1e-9))
        XCTAssertTrue(r.point(at: 0.5).isApproximately(c.point(at: 0.65), tolerance: 1e-9))
    }

    func testFlattenStaysWithinTolerance() {
        let c = CubicBezier(Vec2(0, 0), Vec2(0, 100), Vec2(100, 100), Vec2(100, 0))
        var pts = [c.p0]
        c.flatten(tolerance: 0.25, into: &pts)
        XCTAssertGreaterThan(pts.count, 8)
        for i in 0...50 {
            let p = c.point(at: Double(i) / 50)
            let d = (1..<pts.count).map { p.distance(toSegment: pts[$0 - 1], pts[$0]) }.min()!
            XCTAssertLessThan(d, 0.5)
        }
    }

    func testNearestPoint() {
        let c = CubicBezier(Vec2(0, 0), Vec2(33, 0), Vec2(66, 0), Vec2(100, 0))
        let n = c.nearest(to: Vec2(25, 10))
        XCTAssertEqual(c.point(at: n.t).x, 25, accuracy: 0.01)
        XCTAssertEqual(n.distance, 10, accuracy: 0.01)
    }

    func testInsertPointKeepsShape() {
        var path = BezierPath(points: [
            PathPoint(Vec2(0, 0), out: Vec2(20, -40), smooth: false),
            PathPoint(Vec2(100, 0), in: Vec2(-20, -40), smooth: false),
        ])
        let before = path.segment(0)
        let index = path.insertPoint(segment: 0, t: 0.4)
        XCTAssertEqual(index, 1)
        XCTAssertEqual(path.points.count, 3)
        XCTAssertTrue(path.points[1].position.isApproximately(before.point(at: 0.4), tolerance: 1e-9))
        XCTAssertTrue(path.segment(0).point(at: 0.5).isApproximately(before.point(at: 0.2), tolerance: 1e-9))
        XCTAssertTrue(path.segment(1).point(at: 0.5).isApproximately(before.point(at: 0.7), tolerance: 1e-9))
    }

    func testInsertOnClosingSegment() {
        var path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(100, 0)), PathPoint(Vec2(50, 80))], closed: true)
        let closing = path.segment(2)
        let index = path.insertPoint(segment: 2, t: 0.5)
        XCTAssertEqual(index, 3)
        XCTAssertTrue(path.points[3].position.isApproximately(closing.point(at: 0.5)))
        XCTAssertEqual(path.segmentCount, 4)
    }

    func testSmoothHandleMirrorsDirectionAndKeepsLength() {
        var path = BezierPath(points: [
            PathPoint(Vec2(0, 0)),
            PathPoint(Vec2(50, 0), in: Vec2(-10, 0), out: Vec2(20, 0), smooth: true),
            PathPoint(Vec2(100, 0)),
        ])
        path.setHandle(1, .outgoing, to: Vec2(50, 30))
        XCTAssertTrue(path.points[1].outHandle.isApproximately(Vec2(0, 30)))
        XCTAssertTrue(path.points[1].inHandle.isApproximately(Vec2(0, -10), tolerance: 1e-9))

        path.toggleSmooth(1)
        XCTAssertFalse(path.points[1].isSmooth)
        path.setHandle(1, .outgoing, to: Vec2(80, 0))
        XCTAssertTrue(path.points[1].inHandle.isApproximately(Vec2(0, -10), tolerance: 1e-9))
    }

    func testCornerTurnedSmoothGetsHandlesFromNeighbours() {
        var path = BezierPath(points: [
            PathPoint(Vec2(0, 0), smooth: false),
            PathPoint(Vec2(60, 60), smooth: false),
            PathPoint(Vec2(120, 0), smooth: false),
        ])
        path.toggleSmooth(1)
        XCTAssertTrue(path.points[1].isSmooth)
        XCTAssertTrue(path.points[1].outHandle.normalized.isApproximately(Vec2(1, 0), tolerance: 1e-9))
        XCTAssertTrue(path.points[1].inHandle.normalized.isApproximately(Vec2(-1, 0), tolerance: 1e-9))
        XCTAssertEqual(path.points[1].outHandle.length, Vec2(60, 60).length / 3, accuracy: 1e-9)
    }

    func testClosedPathFlattenDoesNotRepeatStart() {
        let path = BezierPath(points: [PathPoint(Vec2(0, 0)), PathPoint(Vec2(10, 0)), PathPoint(Vec2(0, 10))], closed: true)
        let poly = path.flattened(tolerance: 1)
        XCTAssertEqual(poly.count, 3)
        XCTAssertNotEqual(poly.last, poly.first)
    }
}

final class CurveFitterTests: XCTestCase {
    func testStraightLineFitsOneSegment() {
        let pts = (0...50).map { Vec2(Double($0) * 2, 0) }
        let path = CurveFitter.fit(pts, options: .init(tolerance: 1, smoothingPasses: 0))
        XCTAssertFalse(path.closed)
        XCTAssertEqual(path.points.count, 2)
        XCTAssertTrue(path.points[0].position.isApproximately(Vec2(0, 0)))
        XCTAssertTrue(path.points[1].position.isApproximately(Vec2(100, 0)))
    }

    func testArcFitsWithinTolerance() {
        let pts = (0...80).map { i -> Vec2 in
            let a = Double(i) / 80 * .pi
            return Vec2(cos(a), sin(a)) * 100
        }
        let path = CurveFitter.fit(pts, options: .init(tolerance: 1, smoothingPasses: 0))
        XCTAssertFalse(path.closed)
        XCTAssertLessThan(path.points.count, 8, "a semicircle should need only a few segments")
        XCTAssertLessThan(maxDeviation(pts, from: path), 1.2)
    }

    func testLoopBecomesClosedSmoothPath() {
        let pts = circle(center: Vec2(0, 0), radius: 100, samples: 120, closeGap: 0.05)
        let path = CurveFitter.fit(pts, options: .init(tolerance: 1, smoothingPasses: 0))
        XCTAssertTrue(path.closed)
        XCTAssertGreaterThanOrEqual(path.points.count, 2)
        XCTAssertLessThan(path.points.count, 10)
        XCTAssertTrue(path.points.allSatisfy(\.isSmooth))
        XCTAssertLessThan(maxDeviation(Array(pts.dropLast(2)), from: path), 1.5)
    }

    func testOpenArcIsNotClosed() {
        let pts = circle(center: Vec2(0, 0), radius: 100, samples: 120, closeGap: 1.5)
        let path = CurveFitter.fit(pts, options: .init(tolerance: 1, smoothingPasses: 0, closeDistance: 16))
        XCTAssertFalse(path.closed)
    }

    func testSharpCornerBecomesCornerPoint() {
        var pts = (0...40).map { Vec2(Double($0) * 2.5, 0) }
        pts += (1...40).map { Vec2(100, Double($0) * 2.5) }
        let path = CurveFitter.fit(pts, options: .init(tolerance: 1, smoothingPasses: 0))
        XCTAssertEqual(path.points.count, 3)
        XCTAssertFalse(path.points[1].isSmooth)
        XCTAssertTrue(path.points[1].position.isApproximately(Vec2(100, 0), tolerance: 1e-9))
    }

    func testSquareLoopHasFourCorners() {
        var pts: [Vec2] = []
        let corners = [Vec2(0, 0), Vec2(100, 0), Vec2(100, 100), Vec2(0, 100), Vec2(0, 0)]
        for k in 0..<4 {
            for i in 0..<25 { pts.append(Vec2.lerp(corners[k], corners[k + 1], Double(i) / 25)) }
        }
        pts.append(Vec2(0, 2))
        let path = CurveFitter.fit(pts, options: .init(tolerance: 1, smoothingPasses: 0))
        XCTAssertTrue(path.closed)
        XCTAssertEqual(path.points.filter { !$0.isSmooth }.count, 4)
        XCTAssertLessThan(maxDeviation(pts, from: path), 2.5)
    }

    func testSinglePointMakesADot() {
        let path = CurveFitter.fit([Vec2(5, 5)])
        XCTAssertEqual(path.points.map(\.position), [Vec2(5, 5)])
        XCTAssertEqual(path.segmentCount, 0)
    }

    func testSmoothingRemovesJitter() {
        let jitter = (0...100).map { i in Vec2(Double(i) * 2, i % 2 == 0 ? 1.5 : -1.5) }
        let tight = CurveFitter.fit(jitter, options: .forSmoothing(0, zoom: 1))
        let smooth = CurveFitter.fit(jitter, options: .forSmoothing(1, zoom: 1))
        XCTAssertLessThan(smooth.points.count, tight.points.count)
        XCTAssertLessThanOrEqual(smooth.points.count, 3)
    }
}

final class DrawingTests: XCTestCase {
    private func square(id: Int, at origin: Vec2, size: Double, fill: RGBAColor? = .white) -> VectorShape {
        let pts = [origin, origin + Vec2(size, 0), origin + Vec2(size, size), origin + Vec2(0, size)]
        return VectorShape(id: id, path: BezierPath(points: pts.map { PathPoint($0, smooth: false) }, closed: true),
                           fill: fill, stroke: StrokeStyle(color: .black, width: 2))
    }

    func testWindingNumber() {
        let sq = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        XCTAssertNotEqual(windingNumber(of: Vec2(5, 5), polygon: sq), 0)
        XCTAssertEqual(windingNumber(of: Vec2(15, 5), polygon: sq), 0)
    }

    func testHitTestFindsTopmostShape() {
        var d = Drawing()
        d.layers = [
            Layer(id: 1, name: "Body", shapes: [square(id: 10, at: .zero, size: 100)]),
            Layer(id: 2, name: "Head", shapes: [square(id: 20, at: Vec2(50, 50), size: 100)]),
        ]
        XCTAssertEqual(d.hitTest(Vec2(75, 75), tolerance: 1)?.layer, 2)
        XCTAssertEqual(d.hitTest(Vec2(25, 25), tolerance: 1)?.layer, 1)
        XCTAssertNil(d.hitTest(Vec2(300, 300), tolerance: 1))
    }

    func testUnfilledShapeIsHitOnlyOnItsOutline() {
        let shape = square(id: 1, at: .zero, size: 100, fill: nil)
        XCTAssertFalse(shape.contains(Vec2(50, 50), tolerance: 2))
        XCTAssertTrue(shape.contains(Vec2(50, 1), tolerance: 2))
    }

    func testTransformScalesOutlineWidth() {
        var shape = square(id: 1, at: .zero, size: 10)
        shape.apply(.scale(3))
        XCTAssertEqual(shape.stroke?.width ?? 0, 6, accuracy: 1e-9)
        XCTAssertTrue(shape.path.points[2].position.isApproximately(Vec2(30, 30)))
    }

    func testReferenceTransformAndCorners() {
        var r = ReferenceImage(id: 1, name: "Sketch", size: Vec2(200, 100), center: Vec2(0, 0), scale: 1)
        XCTAssertTrue(r.corners[0].isApproximately(Vec2(-100, -50)))
        r.apply(Affine2D.rotation(.pi / 2) * Affine2D.scale(2))
        XCTAssertEqual(r.scale, 2, accuracy: 1e-9)
        XCTAssertEqual(r.rotation, .pi / 2, accuracy: 1e-9)
        XCTAssertTrue(r.corners[0].isApproximately(Vec2(100, -200), tolerance: 1e-9))
    }

    func testSelectionFrameContains() {
        let frame = SelectionFrame(corners: [Vec2(0, -10), Vec2(10, 0), Vec2(0, 10), Vec2(-10, 0)])
        XCTAssertTrue(frame.contains(.zero))
        XCTAssertFalse(frame.contains(Vec2(8, 8)))
    }
}

final class UndoStackTests: XCTestCase {
    func testUndoRedo() {
        var stack = UndoStack<Int>()
        stack.record(0)
        stack.record(1)
        XCTAssertEqual(stack.undo(current: 2), 1)
        XCTAssertEqual(stack.undo(current: 1), 0)
        XCTAssertNil(stack.undo(current: 0))
        XCTAssertEqual(stack.redo(current: 0), 1)
        stack.record(1)
        XCTAssertFalse(stack.canRedo)
    }

    func testCoalescing() {
        var stack = UndoStack<Int>()
        stack.record(0, coalescingKey: "fill")
        stack.record(1, coalescingKey: "fill")
        stack.record(2, coalescingKey: "fill")
        XCTAssertEqual(stack.undoStates, [0])
        stack.record(3, coalescingKey: "outline")
        XCTAssertEqual(stack.undoStates, [0, 3])
    }

    func testLimitDropsOldestSteps() {
        var stack = UndoStack<Int>(limit: 3)
        for i in 0..<5 { stack.record(i) }
        XCTAssertEqual(stack.undoStates, [2, 3, 4])
        XCTAssertEqual(stack.undo(current: 5), 4)
        XCTAssertEqual(stack.redo(current: 4), 5)
        XCTAssertEqual(stack.undoStates, [2, 3, 4])
        stack.record(5)
        XCTAssertEqual(stack.undoStates, [3, 4, 5])
        XCTAssertEqual(UndoStack<Int>().limit, UndoStack<Int>.defaultLimit)
    }
}

final class DrawingEditorTests: XCTestCase {
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

    private func tap(_ e: inout DrawingEditor, _ p: Vec2) {
        e.pencilBegan(at: p, zoom: 1)
        e.pencilEnded(at: p)
    }

    private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2) {
        e.pencilBegan(at: a, zoom: 1)
        e.pencilMoved(to: Vec2.lerp(a, b, 0.5))
        e.pencilEnded(at: b)
    }

    func testClosedStrokeMakesLayerWithFill() {
        let e = editorWithSquare()
        XCTAssertEqual(e.drawing.layers.count, 1)
        let shape = e.drawing.layers[0].shapes[0]
        XCTAssertTrue(shape.path.closed)
        XCTAssertEqual(shape.fill, e.style.fill)
        XCTAssertEqual(shape.stroke?.width, e.style.outlineWidth)
    }

    func testStrokesJoinTheSelectedLayerWhenTheyOverlap() {
        var e = editorWithSquare()
        let layerID = e.drawing.layers[0].id
        e.selection = .layer(layerID)
        // Off by default: the stroke starts its own layer.
        e.addStroke([Vec2(20, 50), Vec2(80, 50)], zoom: 1)
        XCTAssertEqual(e.drawing.layers.count, 2)
        e.undo()
        e.autoJoinSelectedLayer = true
        e.addStroke([Vec2(20, 50), Vec2(80, 50)], zoom: 1)
        XCTAssertEqual(e.drawing.layers.count, 1)
        XCTAssertEqual(e.drawing.layers[0].shapes.count, 2)

        e.addStroke([Vec2(500, 500), Vec2(600, 500)], zoom: 1)
        XCTAssertEqual(e.drawing.layers.count, 2)

        e.selection = .none
        e.addStroke([Vec2(20, 60), Vec2(80, 60)], zoom: 1)
        XCTAssertEqual(e.drawing.layers.count, 3)
    }

    func testTapSelectsLayerThenShape() {
        var e = editorWithSquare()
        e.tool = .select
        let layer = e.drawing.layers[0]
        tap(&e, Vec2(50, 50))
        XCTAssertEqual(e.selection, .layer(layer.id))
        tap(&e, Vec2(50, 50))
        XCTAssertEqual(e.selection, .shape(layer: layer.id, shape: layer.shapes[0].id))
        tap(&e, Vec2(400, 400))
        XCTAssertEqual(e.selection, Selection.none)
    }

    func testScaleHandleScalesAboutOppositeCorner() throws {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        let frame = try XCTUnwrap(e.drawing.frame(of: e.selection))
        let corner = frame.corners[2]
        let anchor = frame.corners[0]
        drag(&e, corner, anchor + (corner - anchor) * 2)
        let after = try XCTUnwrap(e.drawing.frame(of: e.selection))
        XCTAssertTrue(after.corners[0].isApproximately(anchor, tolerance: 0.5))
        XCTAssertEqual(after.corners[2].x - after.corners[0].x, (corner.x - anchor.x) * 2, accuracy: 1)
        XCTAssertEqual(e.undoStack.undoStates.count, 2)
    }

    func testRotateHandleRotatesAboutCenter() throws {
        var e = editorWithSquare()
        e.tool = .select
        tap(&e, Vec2(50, 50))
        let frame = try XCTUnwrap(e.drawing.frame(of: e.selection))
        let handle = frame.rotateHandle(offset: EditorMetrics.rotateHandleOffset)
        let c = frame.center
        // A quarter turn clockwise: the handle above the center moves to its right.
        let target = c + Vec2(handle.distance(to: c), 0)
        let before = e.drawing.layers[0].shapes[0].path.points[0].position
        drag(&e, handle, target)
        let after = e.drawing.layers[0].shapes[0].path.points[0].position
        let expected = (Affine2D.translation(c) * Affine2D.rotation(.pi / 2) * Affine2D.translation(-c)).apply(before)
        XCTAssertTrue(after.isApproximately(expected, tolerance: 1e-6))
    }

    func testDirectSelectMovesAnchorAndSetsMode() throws {
        var e = editorWithSquare()
        e.tool = .directSelect
        tap(&e, Vec2(50, 50))
        guard case .shape = e.selection else { return XCTFail("shape not selected") }
        let path = e.drawing.layers[0].shapes[0].path
        let corner = try XCTUnwrap(path.points.firstIndex { $0.position.isApproximately(Vec2(100, 100), tolerance: 1) })

        drag(&e, path.points[corner].position, Vec2(130, 120))
        XCTAssertEqual(e.selectedAnchor, corner)
        XCTAssertTrue(e.drawing.layers[0].shapes[0].path.points[corner].position.isApproximately(Vec2(130, 120), tolerance: 1.5))

        XCTAssertEqual(e.selectedAnchorIsSmooth, false)
        // Tapping the selected anchor no longer changes its mode; the mode control does.
        tap(&e, Vec2(130, 120))
        XCTAssertEqual(e.selectedAnchorIsSmooth, false)
        e.setSelectedAnchorMode(.smooth)
        XCTAssertEqual(e.selectedAnchorIsSmooth, true)

        e.undo()
        XCTAssertEqual(e.selectedAnchorIsSmooth, false)
        e.undo()
        XCTAssertTrue(e.drawing.layers[0].shapes[0].path.points[corner].position.isApproximately(Vec2(100, 100), tolerance: 1))
    }

    func testDirectSelectInsertsAndDeletesPoints() throws {
        var e = editorWithSquare()
        e.tool = .directSelect
        tap(&e, Vec2(50, 50))
        let count = e.drawing.layers[0].shapes[0].path.points.count
        // Tap on the top edge, between corners.
        tap(&e, Vec2(50, 0.5))
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.count, count + 1)
        let inserted = try XCTUnwrap(e.selectedAnchor)
        XCTAssertTrue(e.drawing.layers[0].shapes[0].path.points[inserted].position.isApproximately(Vec2(50, 0), tolerance: 1.5))
        XCTAssertTrue(e.canDeleteSelectedAnchor)
        e.deleteSelectedAnchor()
        XCTAssertEqual(e.drawing.layers[0].shapes[0].path.points.count, count)
        XCTAssertNil(e.selectedAnchor)
    }

    func testStyleChangesApplyToSelectionAndCoalesce() {
        var e = editorWithSquare()
        e.selection = .layer(e.drawing.layers[0].id)
        let undoCount = e.undoStack.undoStates.count
        e.setFill(.black)
        e.setFill(.white)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].fill, .white)
        XCTAssertEqual(e.undoStack.undoStates.count, undoCount + 1)
        e.setOutlineWidth(9)
        XCTAssertEqual(e.drawing.layers[0].shapes[0].stroke?.width, 9)
        XCTAssertEqual(e.selectionStyle?.outlineWidth, 9)
        e.setOutlineEnabled(false)
        XCTAssertNil(e.drawing.layers[0].shapes[0].stroke)
        // A shape with no outline keeps its fill, so it never becomes invisible.
        e.setFillEnabled(false)
        XCTAssertNotNil(e.drawing.layers[0].shapes[0].fill)
    }

    func testDeleteAndUndoRestoresSelectionTarget() {
        var e = editorWithSquare()
        e.selection = .layer(e.drawing.layers[0].id)
        e.deleteSelection()
        XCTAssertTrue(e.drawing.layers.isEmpty)
        XCTAssertEqual(e.selection, Selection.none)
        e.undo()
        XCTAssertEqual(e.drawing.layers.count, 1)
        e.redo()
        XCTAssertTrue(e.drawing.layers.isEmpty)
    }

    func testReferenceImagesAreLockedButAdjustable() {
        var e = DrawingEditor()
        let id = e.addReference(name: "Sketch", size: Vec2(200, 200), center: .zero, scale: 1)
        e.tool = .select
        tap(&e, .zero)
        XCTAssertEqual(e.selection, Selection.none, "reference images are never hit by a tap")

        e.adjustReference(id)
        XCTAssertEqual(e.selection, .reference(id))
        drag(&e, Vec2(10, 10), Vec2(60, 10))
        XCTAssertTrue(e.drawing.references[0].center.isApproximately(Vec2(50, 0)))

        e.updateReference(id, coalescingKey: "opacity") { $0.opacity = 0.2 }
        e.updateReference(id, coalescingKey: "opacity") { $0.opacity = 0.3 }
        XCTAssertEqual(e.drawing.references[0].opacity, 0.3)
        e.undo()
        XCTAssertEqual(e.drawing.references[0].opacity, 0.5)
    }

    func testOverlayHasHandlesInSelectTool() {
        var e = editorWithSquare()
        // Only the viewport's border.
        let border = EditorOverlay.vertices(for: DrawingEditor(), zoom: 1)
        XCTAssertEqual(EditorOverlay.vertices(for: e, zoom: 1), border)
        e.tool = .select
        tap(&e, Vec2(50, 50))
        XCTAssertGreaterThan(EditorOverlay.vertices(for: e, zoom: 1).count, border.count)
    }
}
