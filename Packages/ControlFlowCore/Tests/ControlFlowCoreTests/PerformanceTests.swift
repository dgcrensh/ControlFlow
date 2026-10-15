import Foundation
import XCTest
@testable import ControlFlowCore

/// Timings of the hot paths named in `docs/plans/performance-audit.md`, on the
/// `StressDrawing`. They have no baselines, so they never fail on speed: read the
/// numbers in the test log (`swift test --filter PerformanceTests`, or Xcode's test
/// report) and compare them before and after a change. `swift test` builds in debug,
/// so use `-c release` for numbers that are closer to the app's.
final class PerformanceTests: XCTestCase {
    /// Made once: the stress drawing takes a moment to build in a debug build.
    private static let drawing = StressDrawing.make()

    private var drawing: Drawing { Self.drawing }

    func testStressDrawingIsValid() {
        XCTAssertEqual(drawing.layers.count, StressDrawing.layers)
        XCTAssertEqual(drawing.shapeCount, StressDrawing.layers * StressDrawing.shapesPerLayer)
        XCTAssertTrue(drawing.groupsAreValid)
        XCTAssertTrue(drawing.layers.contains { $0.shapes.contains(where: \.isClipped) })
        XCTAssertTrue(drawing.layers.contains { $0.shapes.contains { $0.stroke?.dash.isEmpty == false } })
        XCTAssertNotNil(drawing.hitTest(StressDrawing.busyPoint(), tolerance: 4))
        XCTAssertNil(drawing.hitTest(StressDrawing.emptyPoint, tolerance: 4))
    }

    // MARK: Art

    /// A first build tessellates every shape.
    func testArtBuildCold() {
        let drawing = drawing
        measure {
            var builder = ArtBuilder()
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// A rebuild with nothing changed takes every shape from the cache.
    func testArtBuildWarm() {
        let drawing = drawing
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        measure {
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// Every shape of the stress drawing in one layer, as an SVG import might make, with
    /// every third shape clipped, so the per-layer clip-base work is at its largest. A
    /// rebuild with nothing changed.
    func testArtBuildWarmOneLayer() {
        var layer = Layer(id: drawing.nextID, name: "All", shapes: drawing.layers.flatMap(\.shapes))
        layer.groups = drawing.layers.flatMap(\.groups)
        for i in layer.shapes.indices where i % 3 == 2 { layer.shapes[i].isClipped = true }
        var drawing = Drawing()
        drawing.layers = [layer]
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        measure {
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    // MARK: Dragging

    /// Every shape, as select all leaves it.
    private var everything: Selection {
        .covering(Set(drawing.layers.flatMap { layer in layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) } }))
    }

    /// Drags the whole character 20 samples to the right, building the art after each
    /// sample as `build` says, from a warm builder.
    private func measureDrag(_ build: @escaping (inout ArtBuilder, DrawingEditor) -> Void) {
        var start = DrawingEditor(drawing: drawing)
        start.tool = .select
        start.selection = everything
        // A third of the way in, clear of the pivot and the handles.
        let frame = try! XCTUnwrap(drawing.geometryBounds(of: everything))
        let grab = frame.minPoint + Vec2(frame.width, frame.height) / 3
        var warm = ArtBuilder()
        _ = warm.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        measure {
            var editor = start
            var builder = warm
            editor.pencilBegan(at: grab, zoom: 1)
            for i in 1...20 {
                editor.pencilMoved(to: grab + Vec2(Double(i) * 3, 0))
                build(&builder, editor)
            }
            editor.pencilEnded(at: grab + Vec2(60, 0))
            build(&builder, editor)
        }
    }

    /// The renderer before live transforms: every sample re-tessellates every moved shape.
    func testDragRebuildingEverySample() {
        measureDrag { builder, editor in _ = builder.build(editor.drawing, isolatedLayer: nil, tolerance: 0.5) }
    }

    /// As the renderer draws a drag now: the drag's starting drawing once, then only the
    /// transform changes, and at the end the moved triangles are carried into one warm
    /// rebuild of the moved drawing.
    func testDragWithLiveTransform() {
        var built: Int?
        var last: LiveTransform?
        measureDrag { builder, editor in
            if let live = editor.liveTransform, live.movesTessellation {
                last = live
                guard built != live.id else { return }
                built = live.id
                _ = builder.build(live.base, isolatedLayer: nil, tolerance: 0.5, moving: live.shapes)
            } else {
                built = nil
                if let ended = last { builder.carry(ended, to: editor.drawing) }
                last = nil
                _ = builder.build(editor.drawing, isolatedLayer: nil, tolerance: 0.5)
            }
        }
    }

    /// What a smart-guide drag of one shape collects on its first step: the box of every
    /// other shape and group.
    func testSmartGuideTargets() {
        let editor = DrawingEditor(drawing: drawing)
        let first = drawing.layers[0]
        let one = Selection.shape(layer: first.id, shape: first.shapes[0].id)
        measure {
            for _ in 0..<10 { withExtendedLifetime(editor.makeGuideTargets(in: drawing, excluding: one)) {} }
        }
    }

    // MARK: Refresh

    /// The editor queries `CanvasStore.refresh()` reads after every edit, with
    /// everything selected (10 refreshes).
    func testRefreshQueries() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.selection = everything
        measure {
            for _ in 0..<10 { Self.readRefreshQueries(editor) }
        }
    }

    /// What one refresh reads from the editor beyond plain flags.
    static func readRefreshQueries(_ editor: DrawingEditor) {
        var n = 0
        func read<T>(_ value: T) { withExtendedLifetime(value) { n += 1 } }
        read(editor.canJoinSelection)
        read(editor.canTransformSelection)
        read(editor.selectionGeometry)
        read(editor.selectionAppearance)
        read(editor.selectionStyle)
        read(editor.canClipSelection)
        read(editor.canGroupSelection)
        read(editor.canUngroupSelection)
        read(editor.selectedGroup)
        read(editor.groupsToAddSelectionTo)
        read(editor.canArrange)
        read(editor.canHideOrLockSelection)
        read(editor.canMoveSelectedShapes)
        read(editor.hasHiddenArt)
        read(editor.hasLockedArt)
        read(editor.canDuplicateMirrored)
        read(editor.drawing.exportArea())
        read(LayerTree(drawing: editor.drawing))
        XCTAssertEqual(n, 18)
    }

    // MARK: Live stroke

    /// A 5-second stroke at 240 Hz, tessellated once per 120 Hz frame as it grows,
    /// with two predicted points: `frame` returns the floats it drew.
    private func measureLiveStroke(_ frame: @escaping (InkStroke) -> Int) {
        measure {
            var stroke = InkStroke(id: 1, start: .zero, brush: Brush(width: 4, color: .black))
            var floats = 0
            for i in 1...1200 {
                stroke.append(Vec2(Double(i), sin(Double(i) / 40) * 100), minSpacing: 0)
                guard i % 2 == 0 else { continue }
                stroke.predicted = [stroke.points[i] + Vec2(1, 0), stroke.points[i] + Vec2(2, 0)]
                floats += frame(stroke)
            }
            XCTAssertGreaterThan(floats, 0)
        }
    }

    /// Re-tessellating the whole stroke every frame, as the renderer did before.
    func testLiveStrokeFullEveryFrame() {
        measureLiveStroke { CapsuleTessellator.vertices(for: $0).count }
    }

    /// Only the new segments and the predicted tail each frame.
    func testLiveStrokeIncremental() {
        var live = LiveStrokeTessellator()
        measureLiveStroke { live.update(for: $0).count + live.committed.count }
    }

    // MARK: Hit-testing and erasing

    /// What every hover frame and select tap off the art costs.
    func testHitTestMiss() {
        let drawing = drawing
        measure {
            for _ in 0..<20 { _ = drawing.hitTest(StressDrawing.emptyPoint, tolerance: 4) }
        }
    }

    /// A hover or tap in the middle of the art, where many bounds overlap.
    func testHitTestHit() {
        let drawing = drawing
        let point = StressDrawing.busyPoint()
        measure {
            for _ in 0..<20 { _ = drawing.hitTest(point, tolerance: 4) }
        }
    }

    /// An eraser stroke diagonally across the whole character, sample by sample.
    func testEraseAlongDiagonal() {
        var start = DrawingEditor(drawing: drawing)
        start.tool = .eraser
        let end = Vec2(StressDrawing.cell * Double(StressDrawing.columns - 1),
                       StressDrawing.cell * Double(StressDrawing.layers / StressDrawing.columns - 1))
        let samples = 20
        measure {
            var editor = start
            editor.pencilBegan(at: .zero, zoom: 1)
            for i in 1...samples { editor.pencilMoved(to: end * (Double(i) / Double(samples))) }
            editor.pencilEnded(at: end)
        }
    }

    // MARK: Panels and file

    func testLayerTree() {
        let drawing = drawing
        measure {
            for _ in 0..<10 { _ = LayerTree(drawing: drawing) }
        }
    }

    /// What a save writes: the JSON model and its text.
    func testEncodeAndFormat() {
        let drawing = drawing
        measure {
            _ = PresentationFormat.encode(drawing).formatted()
        }
    }

    // MARK: Overlay

    /// The outline view draws every shape as a wireframe in the overlay: one frame that
    /// rebuilds it, as after an edit or a zoom.
    func testOverlayInOutlineView() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.outlineView = true
        editor.selection = .layer(drawing.layers[0].id)
        measure {
            var cache = OverlayCache()
            _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        }
    }

    /// 20 frames of the Pencil hovering across the middle of the art, the overlay built
    /// for each as the renderer builds it: the kept layers come from a cache warmed by
    /// the frame before the hover starts.
    private func measureHoverFrames(_ editor: DrawingEditor) {
        let start = StressDrawing.busyPoint()
        var warm = OverlayCache()
        _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &warm)
        measure {
            var editor = editor
            var cache = warm
            var floats = 0
            for i in 0..<20 {
                editor.pencilHovered(at: start + Vec2(Double(i) * 2, 0), zoom: 1)
                let layers = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
                floats += layers.wireframe.count + layers.guides.count + layers.selection.count + layers.top.count
            }
            XCTAssertGreaterThan(floats, 0)
        }
    }

    /// Hovering in the outline view, with a layer selected.
    func testOverlayHoverInOutlineView() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.outlineView = true
        editor.selection = .layer(drawing.layers[0].id)
        measureHoverFrames(editor)
    }

    /// Hovering in direct select with everything selected: every shape's anchors show.
    func testOverlayHoverDirectSelectAll() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .directSelect
        editor.selection = everything
        measureHoverFrames(editor)
    }

    /// Hovering with the scissors over one selected layer: the cut point follows the Pencil.
    func testOverlayHoverScissors() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .scissors
        editor.selection = .layer(drawing.layers[0].id)
        measureHoverFrames(editor)
    }

    /// Hovering in the select tool, which outlines what a tap would pick.
    func testOverlayHoverSelect() {
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.selection = .layer(drawing.layers[0].id)
        measureHoverFrames(editor)
    }

    // MARK: Undo

    /// 500 separate fill changes, each one undo step holding a whole-drawing snapshot;
    /// the stack keeps only the newest `UndoStack.defaultLimit`.
    func testUndoGrowthOver500Commits() {
        let start = DrawingEditor(drawing: drawing)
        let refs = drawing.layers.flatMap { layer in layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) } }
        measure {
            var editor = start
            for i in 0..<500 {
                // A different shape each time, so the changes don't coalesce into one step.
                let ref = refs[i * 7 % refs.count]
                editor.selection = .shape(layer: ref.layer, shape: ref.shape)
                editor.setFill(RGBAColor(r: Double(i) / 500, g: 0.5, b: 0.5))
            }
            XCTAssertEqual(editor.undoStack.undoStates.count, min(500, UndoStack<EditorSnapshot>.defaultLimit))
        }
    }

    /// 500 nudges, each its own undo step.
    func testUndoGrowthOver500Nudges() {
        let start = DrawingEditor(drawing: drawing)
        let refs = drawing.layers.flatMap { layer in layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) } }
        measure {
            var editor = start
            for i in 0..<500 {
                let ref = refs[i * 7 % refs.count]
                editor.selection = .shape(layer: ref.layer, shape: ref.shape)
                editor.nudge(by: Vec2(1, 0))
            }
            XCTAssertEqual(editor.undoStack.undoStates.count, min(500, UndoStack<EditorSnapshot>.defaultLimit))
        }
    }

    // MARK: Presenting

    /// Playing a one-keyframe sequence that animates 50 shapes of the stress drawing:
    /// every layer moves (a transform), even shapes change color and odd shapes change
    /// shape (their points move). Each frame interpolates the scene and rebuilds the art,
    /// which tessellates the reshaped shapes again (10 frames).
    func testPlaybackFrames() {
        var opening = drawing
        opening.layers = Array(opening.layers.prefix(max(1, 50 / StressDrawing.shapesPerLayer)))
        var end = opening
        for l in end.layers.indices {
            end.layers[l].transform.position = end.layers[l].transform.position + Vec2(120, -40)
            for s in end.layers[l].shapes.indices {
                if s % 2 == 0 {
                    end.layers[l].shapes[s].fill = RGBAColor(hex: "#2B7BE0FF")
                } else {
                    for p in end.layers[l].shapes[s].path.points.indices {
                        end.layers[l].shapes[s].path.points[p].position = end.layers[l].shapes[s].path.points[p].position * 1.1
                    }
                }
            }
        }
        var timeline = Timeline(Presentation(opening: opening))
        let keyframe = timeline.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .easeInOut))
        timeline.record(end, at: 1)
        XCTAssertEqual(timeline.presentation.keyframe(keyframe)?.changes.isEmpty, false)
        var presenter = Presenter(presentation: timeline.presentation)
        var builder = ArtBuilder()
        _ = builder.build(presenter.scene(at: 0), isolatedLayer: nil, tolerance: 0.5)
        presenter.advance()
        _ = presenter.scene(at: 0)
        var frame = 0
        measure {
            for _ in 0..<10 {
                frame += 1
                // 120 Hz frames, wrapping before the end so the sequence keeps playing.
                let scene = presenter.scene(at: Double(frame % 110 + 1) / 120)
                _ = builder.build(scene, isolatedLayer: nil, tolerance: 0.5)
            }
        }
        XCTAssertTrue(presenter.isPlaying)
    }

    // MARK: Workloads

    /// Times `workload` on the stress drawing, `calls` calls per `measure` run. The same
    /// workloads run at several sizes in `ScalingTests`.
    private func measure(_ workload: Workload, calls: Int = 1) {
        let operation = workload.prepare(drawing)
        operation()
        measure {
            for _ in 0..<calls { operation() }
        }
    }

    /// One shape's fill changed, then a frame (10 calls).
    func testArtRebuildAfterOneEdit() { measure(.artRebuildAfterOneEdit, calls: 10) }

    /// A zoom across a power-of-two bucket, then a frame.
    func testArtRebuildAtNewZoomBucket() { measure(.artRebuildAtNewZoomBucket) }

    func testPencilStroke() { measure(.pencilStroke) }

    /// 10 polls of a long stroke held still.
    func testQuickShapeCheck() { measure(.quickShapeCheck, calls: 10) }

    func testTwoFingerNavigation() { measure(.twoFingerNavigation) }

    /// 10 undo-redo pairs.
    func testUndoRedo() { measure(.undoRedo, calls: 10) }

    func testOpenDocument() { measure(.open) }

    func testSVGExport() { measure(.svgExport) }

    func testSVGImport() { measure(.svgImport) }
}
