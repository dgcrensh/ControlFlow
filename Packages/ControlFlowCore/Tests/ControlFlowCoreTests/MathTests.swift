import XCTest
@testable import ControlFlowCore

private let sum = MathContent(source: "a + b = c")

/// A drawing with one layer holding one formula at (100, 200), and a square to its right.
private func mathDrawing(_ math: MathContent = sum) -> (Drawing, ShapeRef) {
    var d = Drawing()
    d.viewport = Viewport(width: 1000, height: 500)
    let shape = VectorShape(id: d.makeID(), math: math, fill: .black, transform: Transform(position: Vec2(100, 200)))
    let square = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(600, 100), maxPoint: Vec2(700, 300))),
                             fill: .black)
    let layer = Layer(id: d.makeID(), name: "Math", shapes: [shape, square])
    d.layers = [layer]
    return (d, ShapeRef(layer: layer.id, shape: shape.id))
}

/// Formulas as shapes: drawn from their layouts, picked by their boxes, kept as
/// formulas by everything that moves or copies shapes.
final class MathTests: XCTestCase {
    private var layout: MathLayout!

    override func setUpWithError() throws {
        MathTypesetting.reset()
        layout = try FixtureMathTypesetter.layout(sum)
        MathTypesetting.insert([sum: layout], engine: "test")
    }

    override func tearDown() {
        MathTypesetting.reset()
        MathTypesetting.typesetter = nil
    }

    private func editor() -> (DrawingEditor, ShapeRef) {
        let (d, ref) = mathDrawing()
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        return (e, ref)
    }

    func testAFormulaResolvesToItsLayout() {
        let shape = VectorShape(id: 1, math: sum)
        XCTAssertTrue(shape.path.points.isEmpty)
        XCTAssertTrue(shape.isLaidOut)
        XCTAssertFalse(shape.hasEditablePath)
        let drawn = shape.resolvingLayout()
        XCTAssertEqual(drawn.path, layout.outline)
        XCTAssertTrue(drawn.path.closed)
        XCTAssertEqual(drawn.layoutFrame, layout.bounds.corners)
        XCTAssertNotNil(drawn.visibleFill)
        XCTAssertEqual(drawn.math, sum, "the drawn shape still knows its source")
        var stroked = shape
        stroked.stroke = StrokeStyle(color: .black, width: 4)
        XCTAssertNil(stroked.resolvingLayout().stroke, "formulas are filled only")
        XCTAssertEqual(shape.geometryBounds, layout.bounds)
    }

    func testWithoutALayoutItIsAPlaceholderBox() {
        let unknown = MathContent(source: "\\frac{a}{b}", size: 40)
        let drawn = VectorShape(id: 1, math: unknown).resolvingLayout()
        XCTAssertTrue(drawn.path.points.isEmpty)
        XCTAssertEqual(drawn.layoutFrame, Rect(minPoint: .zero, maxPoint: Vec2(40, 40)).corners)
        XCTAssertTrue(VectorShape(id: 1, math: unknown).hasGeometry)
    }

    func testTheDrawnDrawingHasTheGlyphsInPlace() {
        let (d, ref) = mathDrawing()
        let drawn = d.world.layers[0].shapes[0]
        XCTAssertEqual(drawn.id, ref.shape)
        XCTAssertEqual(drawn.math, sum)
        let box = drawn.path.bounds()
        XCTAssertGreaterThanOrEqual(box.minPoint.x, 100 - 1e-6)
        XCTAssertGreaterThanOrEqual(box.minPoint.y, 200 - 1e-6)
        XCTAssertLessThanOrEqual(box.maxPoint.x, 100 + layout.bounds.width + 1e-6)
    }

    func testAFormulaIsPickedAnywhereInItsBox() {
        let (d, ref) = mathDrawing()
        // Between "a" and "+" there is no ink, but the box counts.
        let gap = Vec2(100 + (layout.glyphs[0].place.tx + layout.glyphs[1].place.tx) / 2 + 10, 200 + layout.baseline - 2)
        XCTAssertEqual(d.hitTest(gap, tolerance: 0).map { ShapeRef(layer: $0.layer, shape: $0.shape) }, ref)
        XCTAssertNil(d.hitTest(Vec2(95, 200), tolerance: 1))
        let frame = d.frame(of: .shape(layer: ref.layer, shape: ref.shape))!
        XCTAssertTrue(frame.corners[0].isApproximately(Vec2(100, 200)))
        XCTAssertTrue(frame.corners[2].isApproximately(Vec2(100, 200) + layout.bounds.maxPoint))
    }

    func testMovingTurningAndApplyTransformKeepAFormula() {
        let (d, ref) = mathDrawing()
        let target = Selection.shape(layer: ref.layer, shape: ref.shape)
        let moved = d.applying(.translation(Vec2(10, 0)), to: target)
        XCTAssertEqual(moved.shape(ref)!.transform.position, Vec2(110, 200))
        XCTAssertEqual(moved.shape(ref)!.math, sum)
        XCTAssertTrue(moved.shape(ref)!.path.points.isEmpty)
        let turned = d.applying(.rotation(degrees: 90), to: target)
        XCTAssertEqual(turned.shape(ref)!.transform.rotation, 90, accuracy: 1e-9)
        XCTAssertEqual(turned.shape(ref)!.math, sum)
        let scaled = d.applying(.scale(2), to: target)
        XCTAssertEqual(scaled.shape(ref)!.math, sum)
        XCTAssertEqual(scaled.world.layers[0].shapes[0].layoutFrame?[2].x ?? 0, 2 * (100 + layout.bounds.width), accuracy: 1e-6)

        var e = DrawingEditor(drawing: turned)
        e.selection = target
        e.applyTransform()
        XCTAssertEqual(e.drawing.shape(ref)?.math, sum, "Apply Transform keeps the formula")
        XCTAssertTrue(e.drawing.shape(ref)!.path.points.isEmpty)
        // A layer move takes the transform too.
        var layer = d.layers[0]
        layer.move(by: .translation(Vec2(0, 5)))
        XCTAssertEqual(layer.shapes[0].transform.position, Vec2(100, 205))
        XCTAssertEqual(layer.shapes[0].math, sum)
    }

    func testMovingToAnotherLayerKeepsAFormula() {
        var (e, ref) = editor()
        e.drawing.layers[0].transform = Transform(position: Vec2(30, 40))
        let other = Layer(id: e.drawing.makeID(), name: "Other")
        e.drawing.layers.append(other)
        let before = e.drawing.world.layers[0].shapes[0].path.bounds()
        e.moveSelection(toLayer: other.id)
        let moved = e.drawing.layers[1].shapes[0]
        XCTAssertEqual(moved.id, ref.shape)
        XCTAssertEqual(moved.math, sum)
        XCTAssertTrue(moved.path.points.isEmpty)
        let after = e.drawing.world.layers[1].shapes[0].path.bounds()
        XCTAssertTrue(after.minPoint.isApproximately(before.minPoint, tolerance: 1e-6), "it stays where it was")
    }

    func testCopyPasteAndUndo() throws {
        var (e, ref) = editor()
        let text = try XCTUnwrap(e.copySelection())
        XCTAssertTrue(text.contains("\"math\""))
        XCTAssertTrue(e.paste(text))
        XCTAssertEqual(e.drawing.layers[0].shapes.count, 3)
        let pasted = e.drawing.layers[0].shapes[2]
        XCTAssertNotEqual(pasted.id, ref.shape)
        XCTAssertEqual(pasted.math, sum)
        XCTAssertTrue(pasted.path.points.isEmpty)
        e.undo()
        XCTAssertEqual(e.drawing.layers[0].shapes.count, 2)
        e.redo()
        XCTAssertEqual(e.drawing.layers[0].shapes.count, 3)
    }

    func testAlignUsesTheBox() {
        var (e, ref) = editor()
        let square = e.drawing.layers[0].shapes[1].id
        e.selection = .covering([ref, ShapeRef(layer: ref.layer, shape: square)])
        e.align(.bottom, to: .selection)
        let box = e.drawing.layers[0].worldShape(0).geometryBounds
        XCTAssertEqual(box.maxPoint.y, 300, accuracy: 1e-6)
        XCTAssertEqual(e.drawing.shape(ref)?.transform.position.y ?? 0, 300 - layout.bounds.height, accuracy: 1e-6)
    }

    func testTheSVGExportDrawsTheGlyphs() throws {
        var (d, _) = mathDrawing()
        d.layers[0].shapes.removeLast()
        let svg = try XCTUnwrap(SVGWriter.document(for: d))
        XCTAssertEqual(svg.components(separatedBy: "<path").count - 1, 1, "the formula is one path")
        XCTAssertFalse(svg.contains("stroke=\"#"), "filled only")
        // One not typeset yet draws nothing.
        d.layers[0].shapes[0].math = MathContent(source: "\\unknown")
        XCTAssertTrue((SVGWriter.document(for: d) ?? "").contains("<path d=\"\""))
    }

    func testTheWorldKeepsTheFormula() {
        let (d, ref) = mathDrawing()
        XCTAssertTrue(d.hasMath)
        XCTAssertEqual(d.world.shape(ref)?.math, sum)
        XCTAssertFalse(Drawing().hasMath)
    }

    func testTheSceneJSONWritesOnlyWhatIsntTheDefault() throws {
        let (d, ref) = mathDrawing(MathContent(source: "e^{i\\pi} + 1 = 0", size: 96, display: false))
        let json = PresentationFormat.encode(d)
        guard case .array(let layers)? = json["opening"]?["layers"], case .array(let shapes)? = layers.first?["shapes"],
              let shape = shapes.first else { return XCTFail("no shape") }
        XCTAssertEqual(shape["math"], JSONValue.object([
            (key: "source", value: .string("e^{i\\pi} + 1 = 0")), (key: "size", value: 96), (key: "display", value: .bool(false)),
        ]))
        XCTAssertEqual(shape["points"], JSONValue.array([]))
        XCTAssertEqual(json["formatVersion"], JSONValue.string("1.3"))
        let back = try PresentationFormat.decode(JSONValue(parsing: json.formatted())).drawing
        XCTAssertEqual(back.shape(ref), d.shape(ref))
        let plain = PresentationFormat.encode(mathDrawing().0)
        guard case .array(let l2)? = plain["opening"]?["layers"], case .array(let s2)? = l2.first?["shapes"] else { return XCTFail() }
        XCTAssertEqual(s2.first?["math"], JSONValue.object([(key: "source", value: .string("a + b = c"))]))
    }

    func testAFileSizeIsClampedAndMustBePositive() throws {
        func read(_ math: String) throws -> MathContent? {
            let json = try JSONValue(parsing: """
                { "formatVersion": "1.3", "opening": { "viewport": { "width": 100, "height": 100 }, "layers": [
                  { "id": 1, "name": "A", "shapes": [{ "id": 2, "points": [], "closed": true, "math": \(math) }] }] } }
                """)
            return try PresentationFormat.decode(json).drawing.layers[0].shapes[0].math
        }
        XCTAssertEqual(try read("{ \"source\": \"x\", \"size\": 5000 }")?.size, 2000)
        XCTAssertThrowsError(try read("{ \"source\": \"x\", \"size\": 0 }"))
        XCTAssertThrowsError(try read("{ \"size\": 10 }"), "a source is required")
    }

    func testAKeyframeChangesTheSourceAsAPropertyAndItMorphs() {
        let (d, ref) = mathDrawing()
        var t = Timeline(Presentation(opening: d))
        let k = t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = t.state(at: 1)
        s.layers[0].shapes[0].math!.source = "a = c - b"
        s.layers[0].shapes[0].math!.size = 36
        t.record(s, at: 1)
        XCTAssertEqual(t.presentation.keyframe(k)?.changes,
                       [.set(id: ref.shape, props: [PropertyChange("math.source", .string("a = c - b")),
                                                    PropertyChange("math.size", 36)])])
        let half = t.transition(into: 1, elapsed: 0.5).layers[0].shapes[0].math
        XCTAssertEqual(half?.unmorphed, MathContent(source: "a = c - b", size: 36), "the new formula, morphing from the old")
        XCTAssertEqual(half?.morph, MathMorphState(from: sum, progress: 0.5))
        // Back to the default writes the default.
        s.layers[0].shapes[0].math!.size = 72
        s.layers[0].shapes[0].math!.display = false
        t.record(s, at: 1)
        XCTAssertEqual(t.presentation.keyframe(k)?.changes,
                       [.set(id: ref.shape, props: [PropertyChange("math.source", .string("a = c - b")),
                                                    PropertyChange("math.display", .bool(false))])])
        XCTAssertEqual(t.presentation.mathContents, [sum, MathContent(source: "a = c - b", display: false)])
    }

    func testRequestsTypesetOnceAndRemember() async throws {
        MathTypesetting.reset()
        let typesetter = CountingTypesetter()
        MathTypesetting.typesetter = typesetter
        let frac = MathContent(source: "\\frac{a}{b}")
        XCTAssertNil(MathTypesetting.layout(frac))
        async let first = MathTypesetting.typeset(frac)
        async let second = MathTypesetting.typeset(frac)
        let (a, b) = await (first, second)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b)
        XCTAssertEqual(typesetter.count, 1, "two requests share one typeset")
        XCTAssertEqual(MathTypesetting.layout(frac), a)
        _ = await MathTypesetting.typeset(frac)
        XCTAssertEqual(typesetter.count, 1, "a known layout isn't typeset again")

        let broken = MathContent(source: "\\frac{a}{")
        let none = await MathTypesetting.typeset(broken)
        XCTAssertNil(none)
        XCTAssertNotNil(MathTypesetting.error(broken))
        XCTAssertNil(MathTypesetting.layout(broken))

        MathTypesetting.forget([frac])
        XCTAssertNil(MathTypesetting.layout(frac))
        _ = await MathTypesetting.typeset(frac)
        XCTAssertEqual(typesetter.count, 3, "a forgotten formula is typeset anew")
    }

    func testWithoutATypesetterARequestFinishesAtOnce() {
        MathTypesetting.typesetter = nil
        let done = expectation(description: "done")
        MathTypesetting.request(MathContent(source: "q")) { done.fulfill() }
        wait(for: [done], timeout: 1)
        XCTAssertNil(MathTypesetting.layout(MathContent(source: "q")))
    }
}

/// The fixture typesetter, counting what it is asked for.
final class CountingTypesetter: MathTypesetter, @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var count: Int { lock.withLock { made } }
    let engine = "mathjax-4.1.3/newcm"

    func typeset(_ math: MathContent) async throws(MathError) -> String {
        lock.withLock { made += 1 }
        return try await FixtureMathTypesetter().typeset(math)
    }
}
