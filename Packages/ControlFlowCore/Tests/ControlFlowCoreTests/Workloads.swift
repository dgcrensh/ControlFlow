import Foundation
@testable import ControlFlowCore

/// One interactive operation on a drawing, timed by `PerformanceTests` (at the stress
/// size, with XCTest's `measure`) and by `ScalingTests` (at several sizes, to see how its
/// cost grows with the drawing). `prepare` does the setup outside the timing and returns
/// a closure that performs the operation once; calling it again repeats it from an
/// equivalent state. (Unchecked `Sendable` so the workloads can be static: the tests
/// run them one at a time.)
struct Workload: @unchecked Sendable {
    var name: String
    var prepare: (Drawing) -> () -> Void

    // MARK: Rendering

    /// What a frame after an edit costs: a warm builder rebuilds the art with one shape's
    /// fill changed (alternately between two drawings, so every call has one change).
    static let artRebuildAfterOneEdit = Workload(name: "Art rebuild after one edit") { drawing in
        var edited = drawing
        edited.layers[0].shapes[0].fill = RGBAColor(r: 1, g: 0, b: 0)
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        var flip = false
        return {
            flip.toggle()
            _ = builder.build(flip ? edited : drawing, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// The same rebuild with no vertices written: the cache walk alone (lookups, shape
    /// comparisons, clip plans and steps). The difference from the row above is the appends.
    static let artRebuildAfterOneEditWalkOnly = Workload(name: "Art rebuild after one edit, no vertices") { drawing in
        var edited = drawing
        edited.layers[0].shapes[0].fill = RGBAColor(r: 1, g: 0, b: 0)
        var builder = ArtBuilder()
        builder.skipsVertices = true
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        var flip = false
        return {
            flip.toggle()
            _ = builder.build(flip ? edited : drawing, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// The rebuild after one edit as the renderer does it (plan step 2.3): no concatenated
    /// vertex array, and only the segments that changed copied out, as `uploadArt` copies
    /// them into new GPU buffers (here into a buffer allocated once).
    static let artRebuildAfterOneEditAndUpload = Workload(name: "Art rebuild after one edit, with upload") { drawing in
        var edited = drawing
        edited.layers[0].shapes[0].fill = RGBAColor(r: 1, g: 0, b: 0)
        var builder = ArtBuilder()
        builder.concatenatesVertices = false
        let first = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        var resident = first.residentIDs
        var gpu = [Float](repeating: 0, count: first.segments.reduce(0) { $0 + $1.floats.count })
        var flip = false
        return {
            flip.toggle()
            let batch = builder.build(flip ? edited : drawing, isolatedLayer: nil, tolerance: 0.5)
            gpu.withUnsafeMutableBytes { target in
                for segment in batch.segmentsToUpload(resident: resident) {
                    segment.floats.withUnsafeBytes { target.baseAddress!.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                }
            }
            resident = batch.residentIDs
        }
    }

    /// A zoom that crosses a power-of-two bucket changes the flattening tolerance, which
    /// re-tessellates every shape. Since plan step 1 the renderer no longer does this in
    /// a frame (it refines in the background, `zoomInRefineVisible`); the row stays as
    /// the total work of a refine and for comparison with earlier tables. With no second
    /// tier, since that would turn this back-and-forth into warm builds.
    static let artRebuildAtNewZoomBucket = Workload(name: "Art rebuild, new zoom bucket") { drawing in
        var builder = ArtBuilder()
        builder.tessellations.secondTierLimit = 0
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2)
        var flip = false
        return {
            flip.toggle()
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: flip ? 0.1 : 0.2)
        }
    }

    /// What a zoom-in across a bucket costs since plan step 1, in the background job's
    /// first result: planning the refine (every shape's bounds, against a warm cache at
    /// the old tolerance) and tessellating the shapes that meet an iPad-sized view
    /// (1,180 × 820 points) at 4x around the busy point, plus the quarter-screen margin.
    /// The renderer keeps drawing meanwhile; this is how long the coarse art shows.
    static let zoomInRefineVisible = Workload(name: "Zoom-in refine, visible shapes") { drawing in
        var builder = ArtBuilder()
        _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2)
        let cache = builder.tessellations
        let center = StressDrawing.busyPoint(layers: drawing.layers.count)
        let half = Vec2(1180, 820) / 8
        let view = Rect(minPoint: center - half, maxPoint: center + half)
        return {
            let plan = cache.refinePlan(for: drawing, tolerance: 0.1, viewRect: view)
            precondition(!plan.visible.isEmpty)
            _ = TessellationCache.tessellate(plan.visible, tolerance: 0.1)
        }
    }

    /// One frame's overlay while the Pencil hovers in the select tool with a layer
    /// selected: the hover hit test plus the overlay build, from a warm cache.
    static let hoverFrame = Workload(name: "Hover frame (select tool)") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.selection = .layer(drawing.layers[0].id)
        var cache = OverlayCache()
        _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        let start = StressDrawing.busyPoint(layers: drawing.layers.count)
        var i = 0
        return {
            i += 1
            editor.pencilHovered(at: start + Vec2(Double(i % 20) * 2, 0), zoom: 1)
            _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        }
    }

    /// The select tool's hover hit test alone (the topmost shape under the Pencil), with
    /// nothing selected, on the busy point: what every hover frame and tap pays.
    static let selectHoverHitTest = Workload(name: "Select hover, hit test only") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        let start = StressDrawing.busyPoint(layers: drawing.layers.count)
        var i = 0
        return {
            i += 1
            editor.pencilHovered(at: start + Vec2(Double(i % 20) * 2, 0), zoom: 1)
            _ = editor.hoverTarget
        }
    }

    /// One overlay frame in the outline view during a pinch: a warm cache, with the zoom
    /// changed by 1% inside one zoom bucket (1 and 0.99 both round up to 1), which keeps
    /// the wireframe since plan step 4.
    static let overlayWireframeAtNewZoom = Workload(name: "Outline view, overlay at a new zoom") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.outlineView = true
        var cache = OverlayCache()
        _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        var flip = false
        return {
            flip.toggle()
            _ = EditorOverlay.layers(for: editor, zoom: flip ? 0.99 : 1, cache: &cache)
        }
    }

    /// The same, with the 1% zoom change crossing a zoom bucket (1.01 rounds up to 2), so
    /// every frame rebuilds the wireframe: what a pinch pays once per power of two.
    static let overlayWireframeAcrossZoomBucket = Workload(name: "Outline view, overlay across a zoom bucket") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.outlineView = true
        var cache = OverlayCache()
        _ = EditorOverlay.layers(for: editor, zoom: 1, cache: &cache)
        var flip = false
        return {
            flip.toggle()
            _ = EditorOverlay.layers(for: editor, zoom: flip ? 1.01 : 1, cache: &cache)
        }
    }

    /// One hover frame with the scissors and nothing selected, on the busy point: the
    /// search for the outline to cut, which the overlay and the hover target both read.
    static let scissorsHover = Workload(name: "Scissors hover") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .scissors
        let start = StressDrawing.busyPoint(layers: drawing.layers.count)
        var i = 0
        return {
            i += 1
            editor.pencilHovered(at: start + Vec2(Double(i % 20) * 2, 0), zoom: 1)
            _ = editor.hoverCut
        }
    }

    // MARK: Drawing

    /// A whole Pencil stroke through `CanvasSession` as the canvas view sends it: 240
    /// samples in batches of 4 with predicted points, then the lift, which fits the curve
    /// and commits the shape as one undo step on top of the drawing.
    static let pencilStroke = Workload(name: "Pencil stroke, 240 samples and lift") { drawing in
        var start = CanvasSession(drawing: drawing)
        start.editor.tool = .pencil
        let origin = StressDrawing.busyPoint(layers: drawing.layers.count)
        let points = (0...240).map { i in origin + Vec2(Double(i), sin(Double(i) / 20) * 40) }
        return {
            var session = start
            session.touchBegan(id: 1, kind: .pencil, location: points[0], time: 0)
            for batch in stride(from: 1, to: points.count, by: 4) {
                let samples = Array(points[batch..<min(batch + 4, points.count)])
                session.touchMoved(id: 1, samples: samples, predicted: [samples.last! + Vec2(1, 0)],
                                   time: Double(batch) / 240)
            }
            session.touchEnded(id: 1, location: points.last!, time: 1)
            precondition(session.editor.drawing.shapeCount == drawing.shapeCount + 1)
        }
    }

    /// One QuickShape poll (`MetalCanvasView` runs one every 100 ms while the Pencil is
    /// down) on a 5-second, 1,200-point stroke that is held still and looks like a circle.
    static let quickShapeCheck = Workload(name: "Quick shape check, 1,200 points") { drawing in
        var start = CanvasSession(drawing: drawing)
        start.editor.tool = .pencil
        let points = (0...1200).map { i -> Vec2 in
            let angle = Double(i) / 1200 * 2 * .pi
            return Vec2(cos(angle), sin(angle)) * 150
        }
        start.touchBegan(id: 1, kind: .pencil, location: points[0], time: 0)
        start.touchMoved(id: 1, samples: Array(points.dropFirst()), time: 0)
        return {
            var session = start
            precondition(session.checkQuickShape(time: 10))
        }
    }

    /// One eraser sample through the middle of the art, from a gesture already under way.
    static let eraserSample = Workload(name: "Eraser sample") { drawing in
        var start = DrawingEditor(drawing: drawing)
        start.tool = .eraser
        let point = StressDrawing.busyPoint(layers: drawing.layers.count)
        start.pencilBegan(at: point - Vec2(20, 0), zoom: 1)
        return {
            var editor = start
            editor.pencilMoved(to: point)
        }
    }

    /// One sample of dragging everything in the select tool (with its live transform).
    static let dragSampleEverything = Workload(name: "Drag sample, everything selected") { drawing in
        var start = DrawingEditor(drawing: drawing)
        start.tool = .select
        start.selection = everything(in: drawing)
        let frame = drawing.geometryBounds(of: start.selection)!
        let grab = frame.minPoint + Vec2(frame.width, frame.height) / 3
        start.pencilBegan(at: grab, zoom: 1)
        start.pencilMoved(to: grab + Vec2(3, 0))
        var i = 1
        return {
            i += 1
            start.pencilMoved(to: grab + Vec2(Double(i % 40) * 3, 0))
        }
    }

    /// The frame after lifting the Pencil from a live drag that moved layer 0 and its
    /// accessories: the renderer carries their triangles and rebuilds the moved drawing.
    static let dragEndOneLayer = Workload(name: "Drag end, one layer moved") { drawing in
        dragEnd(drawing, selection: .layer(drawing.layers[0].id))
    }

    /// The same after dragging everything.
    static let dragEndEverything = Workload(name: "Drag end, everything moved") { drawing in
        dragEnd(drawing, selection: everything(in: drawing))
    }

    /// Each call starts from a copy of a builder that drew the drag (its base, with the
    /// moved shapes marked), so it includes copying that builder's caches on first write.
    private static func dragEnd(_ drawing: Drawing, selection: Selection) -> () -> Void {
        let t = Affine2D.translation(Vec2(30, 12))
        let live = LiveTransform(id: 1, base: drawing, shapes: LiveTransform.shapes(of: selection, in: drawing)!,
                                 transform: t)
        let after = drawing.applying(t, to: selection)
        var during = ArtBuilder()
        _ = during.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        _ = during.build(drawing, isolatedLayer: nil, tolerance: 0.5, moving: live.shapes)
        return {
            var builder = during
            builder.carry(live, to: after, tolerance: 0.5)
            _ = builder.build(after, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// The art's share of the first frame after opening (recommendation 5 of
    /// performance-next.md): a build with nothing cached that leaves out every layer not
    /// yet tessellated. The cold build it replaced is "Art rebuild, new zoom bucket" with
    /// an empty cache, about what `PerformanceTests.testArtBuildCold` times.
    static let openFirstFrame = Workload(name: "Open: first frame's art") { drawing in
        {
            var builder = ArtBuilder()
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2, reusingOtherTolerances: true,
                              leavingOutUncached: true)
        }
    }

    /// From that first frame to the art in view: the background job's first result
    /// (planning whole layers against an empty cache and tessellating the layers that meet
    /// an iPad-sized view at 1x around the busy point), then merging it and the build
    /// that shows those layers on the main thread.
    static let openFirstArtInView = Workload(name: "Open: first art in view") { drawing in
        let center = StressDrawing.busyPoint(layers: drawing.layers.count)
        let half = Vec2(1180, 820) / 2
        let view = Rect(minPoint: center - half, maxPoint: center + half)
        return {
            var builder = ArtBuilder()
            let plan = builder.tessellations.refinePlan(for: drawing, tolerance: 0.2, viewRect: view, wholeLayers: true)
            precondition(!plan.visible.isEmpty)
            builder.tessellations.merge(TessellationCache.tessellate(plan.visible, tolerance: 0.2)!, for: drawing)
            _ = builder.build(drawing, isolatedLayer: nil, tolerance: 0.2, reusingOtherTolerances: true,
                              leavingOutUncached: true)
        }
    }

    /// An undo then a redo of one fill change.
    static let undoRedo = Workload(name: "Undo and redo") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.selection = .shape(layer: drawing.layers[0].id, shape: drawing.layers[0].shapes[0].id)
        editor.setFill(RGBAColor(r: 1, g: 0, b: 0))
        return {
            editor.undo()
            editor.redo()
        }
    }

    // MARK: Keyframes

    /// One playback or scrub frame of a transition in which every layer slides (a layer
    /// transform): the scene interpolated and the art rebuilt from a warm builder.
    static let playbackFrameAllLayersSlide = Workload(name: "Playback frame, every layer slides") { drawing in
        var end = drawing
        for l in end.layers.indices { end.layers[l].transform.position = Vec2(200, 0) }
        return playbackFrame(StressDrawing.transition(from: drawing, to: end))
    }

    /// The same with every shape changing fill and nothing moving.
    static let playbackFrameEveryFillChanges = Workload(name: "Playback frame, every fill changes") { drawing in
        var end = drawing
        for l in end.layers.indices {
            for s in end.layers[l].shapes.indices { end.layers[l].shapes[s].fill = RGBAColor(r: 0.2, g: 0.5, b: 0.9) }
        }
        return playbackFrame(StressDrawing.transition(from: drawing, to: end))
    }

    /// The same with one layer's shapes fading out.
    static let playbackFrameOneLayerFades = Workload(name: "Playback frame, one layer fades") { drawing in
        var end = drawing
        for s in end.layers[0].shapes.indices { end.layers[0].shapes[s].opacity = 0 }
        return playbackFrame(StressDrawing.transition(from: drawing, to: end))
    }

    /// 120 Hz frames through the transition into keyframe 1, wrapping before the end.
    private static func playbackFrame(_ timeline: Timeline) -> () -> Void {
        var timeline = timeline
        var builder = ArtBuilder()
        _ = builder.build(timeline.state(at: 0), isolatedLayer: nil, tolerance: 0.5)
        var frame = 0
        return {
            frame += 1
            let scene = timeline.transition(into: 1, elapsed: Double(frame % 110 + 1) / 120)
            _ = builder.build(scene, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// The first frame after a whole-stage slide ends. The renderer plays a transition
    /// with a copy of its art builder, so the builder that drew the keyframe before the
    /// preview builds it again: the preview's frames left its caches as they were.
    static let frameAfterPlayback = Workload(name: "Frame after playback, every layer slid") { drawing in
        var end = drawing
        for l in end.layers.indices { end.layers[l].transform.position = Vec2(200, 0) }
        var timeline = StressDrawing.transition(from: drawing, to: end)
        let state = timeline.state(at: 1)
        var art = ArtBuilder()
        _ = art.build(state, isolatedLayer: nil, tolerance: 0.5)
        var preview = art
        _ = preview.build(timeline.state(at: 0), isolatedLayer: nil, tolerance: 0.5)
        _ = preview.build(timeline.transition(into: 1, elapsed: 0.5), isolatedLayer: nil, tolerance: 0.5)
        return {
            var builder = art
            _ = builder.build(state, isolatedLayer: nil, tolerance: 0.5)
        }
    }

    /// An undo then a redo of a nudge at keyframe 10 of 20, which resolves keyframe 10's
    /// state again.
    static let undoRedoAtKeyframe = Workload(name: "Undo and redo at keyframe 10 of 20") { drawing in
        let presentation = StressDrawing.presentation(drawing, keyframes: 20)
        var editor = DrawingEditor(presentation: presentation)
        editor.selectKeyframe(presentation.keyframe(atChainIndex: 10)!.id)
        editor.tool = .select
        let layer = editor.drawing.layers[min(3, editor.drawing.layers.count - 1)]
        editor.selection = .shape(layer: layer.id, shape: layer.shapes[min(2, layer.shapes.count - 1)].id)
        editor.nudge(by: Vec2(1, 0))
        return {
            editor.undo()
            editor.redo()
        }
    }

    /// Showing keyframe 20 of 20 with no state resolved yet, as after opening the file:
    /// every keyframe's changes applied in turn from the opening state.
    static let resolveLastKeyframeCold = Workload(name: "Resolve keyframe 20 of 20, cold") { drawing in
        let presentation = StressDrawing.presentation(drawing, keyframes: 20)
        return {
            var timeline = Timeline(presentation)
            precondition(!timeline.state(at: 20).layers.isEmpty)
        }
    }

    /// The Layers panel's "changed" marks at keyframe 10 of 20, with every state resolved:
    /// what `CanvasStore.refresh()` reads after each edit or switch at a keyframe. The
    /// editor keeps the last result, so this times working them out, from the timeline.
    static let changedObjectsAtKeyframe = Workload(name: "Changed objects at keyframe 10 of 20") { drawing in
        let presentation = StressDrawing.presentation(drawing, keyframes: 20)
        var editor = DrawingEditor(presentation: presentation)
        let id = presentation.keyframe(atChainIndex: 10)!.id
        editor.selectKeyframe(id)
        _ = editor.state(atKeyframe: presentation.keyframe(atChainIndex: 20)!.id)
        var timeline = editor.timeline
        return { precondition(!timeline.changedObjects(inKeyframe: id).isEmpty) }
    }

    // MARK: Navigating

    /// A two-finger pan, zoom and rotate of 60 samples through `CanvasSession`, plus the
    /// ink tap test on lift. Navigation never touches the drawing, so this should not grow.
    static let twoFingerNavigation = Workload(name: "Two-finger navigation, 60 samples") { drawing in
        let start = CanvasSession(drawing: drawing)
        return {
            var session = start
            session.touchBegan(id: 1, kind: .finger, location: Vec2(300, 400), time: 0)
            session.touchBegan(id: 2, kind: .finger, location: Vec2(500, 400), time: 0)
            for i in 1...60 {
                let t = Double(i)
                session.touchMoved(id: 1, samples: [Vec2(300 - t, 400 + t)], time: t / 120)
                session.touchMoved(id: 2, samples: [Vec2(500 + t * 2, 400 - t)], time: t / 120)
            }
            session.touchEnded(id: 1, time: 0.5)
            session.touchEnded(id: 2, time: 0.5)
            precondition(session.camera != start.camera)
        }
    }

    // MARK: Panels

    /// What `CanvasStore.refresh()` reads from the editor after an edit, everything selected.
    static let refreshQueries = Workload(name: "Refresh queries, everything selected") { drawing in
        var editor = DrawingEditor(drawing: drawing)
        editor.tool = .select
        editor.selection = everything(in: drawing)
        return { PerformanceTests.readRefreshQueries(editor) }
    }

    static let layerTree = Workload(name: "Layer tree") { drawing in
        { _ = LayerTree(drawing: drawing) }
    }

    // MARK: Files

    /// What an autosave writes, before the thumbnail.
    static let save = Workload(name: "Save: encode and format") { drawing in
        { _ = PresentationFormat.encode(drawing).formatted() }
    }

    /// What opening a document reads: the JSON text parsed and decoded into a drawing.
    static let open = Workload(name: "Open: parse and decode") { drawing in
        let data = Data(PresentationFormat.encode(drawing).formatted().utf8)
        return {
            _ = try! PresentationPackage(files: [PresentationPackage.presentationFile: data])
        }
    }

    /// The first half of opening: the JSON text into a `JSONValue`.
    static let openParse = Workload(name: "Open: parse only") { drawing in
        let data = Data(PresentationFormat.encode(drawing).formatted().utf8)
        return { _ = try! JSONValue(parsing: data) }
    }

    /// The second half of opening: the `JSONValue` into a drawing.
    static let openDecode = Workload(name: "Open: decode only") { drawing in
        let json = try! JSONValue(parsing: Data(PresentationFormat.encode(drawing).formatted().utf8))
        return { _ = try! PresentationFormat.decode(json) }
    }

    static let svgExport = Workload(name: "SVG export") { drawing in
        let editor = DrawingEditor(drawing: drawing)
        return { precondition(editor.svgDocument() != nil) }
    }

    /// Reading back the drawing's own SVG export, as Import SVG does before adding the layers.
    static let svgImport = Workload(name: "SVG import") { drawing in
        let svg = DrawingEditor(drawing: drawing).svgDocument()!
        return { _ = try! SVGImporter.parse(svg) }
    }

    /// Everything above, in the order `ScalingTests` prints them.
    static var all: [Workload] {
        [artRebuildAfterOneEdit, artRebuildAfterOneEditWalkOnly, artRebuildAfterOneEditAndUpload, artRebuildAtNewZoomBucket,
         zoomInRefineVisible, hoverFrame, selectHoverHitTest, overlayWireframeAtNewZoom, overlayWireframeAcrossZoomBucket,
         scissorsHover, pencilStroke, quickShapeCheck, eraserSample, dragSampleEverything, dragEndOneLayer,
         dragEndEverything, undoRedo, twoFingerNavigation, refreshQueries, layerTree, save, open, openParse,
         openDecode, openFirstFrame, openFirstArtInView, svgExport, svgImport, playbackFrameAllLayersSlide,
         playbackFrameEveryFillChanges, playbackFrameOneLayerFades, frameAfterPlayback, undoRedoAtKeyframe,
         resolveLastKeyframeCold, changedObjectsAtKeyframe]
    }

    static func everything(in drawing: Drawing) -> Selection {
        .covering(Set(drawing.layers.flatMap { layer in layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) } }))
    }
}
