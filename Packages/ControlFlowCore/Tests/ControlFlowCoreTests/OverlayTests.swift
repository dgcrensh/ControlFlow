import XCTest
@testable import ControlFlowCore

/// The overlay's kept layers (`OverlayCache`) must always draw what a fresh build draws.
final class OverlayTests: XCTestCase {
    private func editor() -> DrawingEditor {
        var editor = DrawingEditor(drawing: StressDrawing.make(layers: 3, shapesPerLayer: 4))
        editor.tool = .directSelect
        let layer = editor.drawing.layers[0]
        editor.selection = .covering(Set(layer.shapes.map { ShapeRef(layer: layer.id, shape: $0.id) }))
        return editor
    }

    private func flat(_ layers: OverlayLayers) -> [Float] {
        layers.wireframe + layers.guides + layers.selection + layers.top
    }

    /// Steps through hover, selection, anchor, tool, view, zoom and drawing changes with
    /// one cache, comparing each frame with a fresh build at the same zoom (so the same
    /// zoom bucket). Hovering and a zoom inside the bucket keep the kept layers; a zoom
    /// across a bucket rebuilds them.
    func testCachedLayersMatchAFreshBuild() {
        var editor = editor()
        var cache = OverlayCache()
        var zoom = 1.0
        let layer = editor.drawing.layers[0]
        let first = ShapeRef(layer: layer.id, shape: layer.shapes[0].id)
        let steps: [(String, (inout DrawingEditor, inout Double) -> Void)] = [
            ("start", { _, _ in }),
            ("hover", { e, _ in e.pencilHovered(at: StressDrawing.busyPoint(layers: 3), zoom: 1) }),
            ("hover elsewhere", { e, _ in e.pencilHovered(at: .zero, zoom: 1) }),
            ("one shape", { e, _ in e.selection = .shape(layer: first.layer, shape: first.shape) }),
            ("an anchor", { e, _ in e.selectedAnchors = [2] }),
            ("two anchors", { e, _ in e.selectedAnchors = [2, 5] }),
            ("zoom inside the bucket", { _, z in z = 0.75 }),
            ("zoom across a bucket", { _, z in z = 2.5 }),
            ("zoom inside the new bucket", { _, z in z = 3.9 }),
            ("edit", { e, _ in e.setFill(.white) }),
            ("scissors", { e, _ in e.tool = .scissors }),
            ("scissors hover", { e, _ in e.pencilHovered(at: StressDrawing.busyPoint(layers: 3), zoom: 2.5) }),
            ("outline view", { e, _ in e.outlineView = true }),
            ("pinch inside the bucket", { _, z in z = 2.1 }),
            ("pinch across a bucket", { _, z in z = 4.5 }),
            ("pinch out across a bucket", { _, z in z = 0.3 }),
            ("ghosting", { e, _ in e.ghostsUnselected = true }),
            ("select tool", { e, _ in e.tool = .select }),
            ("dark", { _, _ in }),
            ("undo", { e, _ in e.undo() }),
            ("outline view off", { e, _ in e.outlineView = false }),
        ]
        var generation = cache.generation
        for (name, change) in steps {
            change(&editor, &zoom)
            let dark = name == "dark"
            let layers = EditorOverlay.layers(for: editor, zoom: zoom, darkMode: dark, cache: &cache)
            XCTAssertEqual(flat(layers), EditorOverlay.vertices(for: editor, zoom: zoom, darkMode: dark), name)
            if name.hasPrefix("hover") || name.contains("inside") {
                XCTAssertEqual(cache.generation, generation, "\(name) rebuilt a kept layer")
            }
            if name.contains("across") {
                XCTAssertNotEqual(cache.generation, generation, "\(name) kept a layer built for another bucket")
            }
            generation = cache.generation
        }
    }

    /// The overlay's capsules carry their widths in screen points (the shader scales them
    /// with the zoom), so the kept layers are the same at any zoom within a bucket.
    func testOverlayCapsulesAreScreenSpace() {
        var editor = editor()
        editor.outlineView = true
        let n = CapsuleTessellator.floatsPerVertex
        var cache = OverlayCache()
        let near = EditorOverlay.layers(for: editor, zoom: 1.6, cache: &cache)
        var fresh = OverlayCache()
        let far = EditorOverlay.layers(for: editor, zoom: 1.1, cache: &fresh)
        XCTAssertFalse(near.wireframe.isEmpty)
        XCTAssertFalse(near.selection.isEmpty)
        XCTAssertEqual(near.wireframe, far.wireframe)
        XCTAssertEqual(near.selection, far.selection)
        for layer in [near.wireframe, near.selection] {
            for v in stride(from: 0, to: layer.count, by: n) {
                XCTAssertEqual(layer[v + 7], 1, "screen-space flag")
            }
        }
        // The wireframe is one point wide, whatever the zoom.
        XCTAssertEqual(near.wireframe[6], 0.5)
    }
}
