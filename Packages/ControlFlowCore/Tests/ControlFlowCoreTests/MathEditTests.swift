import XCTest
@testable import ControlFlowCore

private func tap(_ e: inout DrawingEditor, _ p: Vec2, time: Double? = nil) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p, time: time)
}

/// Typesets the edit's draft with the fixture typesetter and reports it, as the app
/// does after a pause in typing.
private func typesetDraft(_ e: inout DrawingEditor) async {
    guard let content = e.mathDraftContent else { return }
    _ = await MathTypesetting.typeset(content)
    e.mathDraftTypeset(content)
}

/// A drawing with one formula at (100, 200).
private func formulaEditor(_ source: String = "a + b = c") async throws -> (DrawingEditor, ShapeRef) {
    var d = Drawing()
    let math = MathContent(source: source)
    _ = await MathTypesetting.typeset(math)
    let shape = VectorShape(id: d.makeID(), math: math, fill: .black, transform: Transform(position: Vec2(100, 200)))
    let layer = Layer(id: d.makeID(), name: "Math", shapes: [shape])
    d.layers = [layer]
    return (DrawingEditor(drawing: d), ShapeRef(layer: layer.id, shape: shape.id))
}

/// The Math tool: making and editing formulas, their style, Convert to Outlines, copy
/// and paste, and Retypeset All Formulas.
final class MathEditTests: XCTestCase {
    override func setUp() {
        MathTypesetting.reset()
        MathTypesetting.typesetter = FixtureMathTypesetter()
    }

    override func tearDown() {
        MathTypesetting.reset()
        MathTypesetting.typesetter = nil
    }

    func testTheMathToolTypesANewFormula() async {
        var e = DrawingEditor()
        e.tool = .math
        tap(&e, Vec2(100, 300))
        let edit = try! XCTUnwrap(e.mathEdit)
        XCTAssertEqual(edit.draft, "")
        XCTAssertEqual(e.drawing.shape(edit.ref)?.math?.source, "")
        XCTAssertEqual(e.selection, .shape(layer: edit.ref.layer, shape: edit.ref.shape))
        XCTAssertNil(e.mathDraftContent, "an empty draft has nothing to typeset")
        let blank = e.drawing.shape(edit.ref)!.math!
        let blankLayout = await MathTypesetting.typeset(blank)
        XCTAssertNil(blankLayout, "a blank formula is never typeset")
        XCTAssertEqual(e.drawing.frame(of: e.selection)?.corners[2].y ?? 0, 300 + blank.size / 2, accuracy: 1e-6,
                       "so it shows as its placeholder box")

        e.setMathDraft("a + b = c")
        XCTAssertEqual(e.drawing.shape(edit.ref)?.math?.source, "", "the source waits for the draft to typeset")
        XCTAssertEqual(e.mathDraftContent?.source, "a + b = c")
        await typesetDraft(&e)
        XCTAssertEqual(e.drawing.shape(edit.ref)?.math?.source, "a + b = c")
        XCTAssertNil(e.mathEdit?.error)
        // The tap is the left middle of the formula's box.
        let frame = e.drawing.frame(of: e.selection)!
        XCTAssertEqual(frame.corners[0].x, 100, accuracy: 1e-6)

        e.endMathEdit()
        XCTAssertNil(e.mathEdit)
        let box = e.drawing.shape(edit.ref)!.geometryBounds
        XCTAssertTrue(e.drawing.shape(edit.ref)!.transform.pivot.isApproximately(box.center), "a new formula pivots on its middle")
        // Making and typing is one undo step.
        e.undo()
        XCTAssertNil(e.drawing.shape(edit.ref))
        XCTAssertFalse(e.canUndo)
    }

    func testABrokenDraftKeepsTheLastGoodFormula() async throws {
        var (e, ref) = try await formulaEditor()
        e.beginMathEdit(ref)
        XCTAssertEqual(e.tool, .math)
        XCTAssertEqual(e.mathEdit?.draft, "a + b = c")
        e.setMathDraft("a^2+b^2=c^2")
        await typesetDraft(&e)
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a^2+b^2=c^2")

        e.setMathDraft("\\frac{a}{")
        await typesetDraft(&e)
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a^2+b^2=c^2", "the shape keeps the last source that typeset")
        XCTAssertEqual(e.mathEdit?.draft, "\\frac{a}{")
        XCTAssertNotNil(e.mathEdit?.error)
        XCTAssertEqual(e.mathEditGeometry?.failed, true, "the overlay outlines it in red")

        // Fixing the draft clears the error at once when its layout is already known.
        e.setMathDraft("a + b = c")
        XCTAssertNil(e.mathEdit?.error)
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a + b = c")
        e.setMathDraft("\\frac{a}{b}")
        await typesetDraft(&e)
        e.endMathEdit()
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "\\frac{a}{b}")

        // The whole session is one undo step.
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a + b = c")
        XCTAssertFalse(e.canUndo)
    }

    func testAResultForAnOlderDraftIsDropped() async throws {
        var (e, ref) = try await formulaEditor()
        e.beginMathEdit(ref)
        e.setMathDraft("\\frac{a}{b}")
        let stale = try XCTUnwrap(e.mathDraftContent)
        e.setMathDraft("\\frac{a}{bc")
        _ = await MathTypesetting.typeset(stale)
        e.mathDraftTypeset(stale)
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a + b = c")
        XCTAssertNil(e.mathEdit?.error)
    }

    func testANewFormulaLeftEmptyLeavesNothingToUndo() {
        var e = DrawingEditor()
        e.tool = .math
        tap(&e, Vec2(100, 300))
        let ref = e.mathEdit!.ref
        e.setMathDraft("\\frac{a}{")
        tap(&e, Vec2(600, 600))
        XCTAssertNil(e.mathEdit, "a tap on empty canvas ends the edit")
        XCTAssertNil(e.drawing.shape(ref), "a formula that never typeset goes")
        XCTAssertTrue(e.drawing.layers.isEmpty)
        XCTAssertFalse(e.canUndo)
    }

    func testEmptyingAFormulaDeletesIt() async throws {
        var (e, ref) = try await formulaEditor()
        e.beginMathEdit(ref)
        e.setMathDraft("  ")
        e.endMathEdit()
        XCTAssertNil(e.drawing.shape(ref))
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a + b = c")
    }

    func testTapsWithTheMathTool() async throws {
        var (e, ref) = try await formulaEditor()
        e.tool = .math
        let inside = e.drawing.frame(of: .shape(layer: ref.layer, shape: ref.shape))!.center
        e.pencilHovered(at: inside)
        XCTAssertEqual(e.hoverTarget, ref)
        tap(&e, inside)
        XCTAssertEqual(e.mathEdit?.ref, ref, "a tap on a formula edits it")
        e.pencilHovered(at: inside)
        XCTAssertNil(e.hoverTarget, "the formula being edited isn't highlighted")
        tap(&e, Vec2(900, 900))
        XCTAssertNil(e.mathEdit)
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "a + b = c")
        tap(&e, Vec2(900, 900))
        XCTAssertNotNil(e.mathEdit, "a tap on empty canvas with nothing being edited starts a formula")
        XCTAssertNotEqual(e.mathEdit?.ref, ref)
        e.tool = .select
        XCTAssertNil(e.mathEdit, "changing tools ends the edit")
        XCTAssertEqual(e.drawing.layers.count, 1)
    }

    func testDoubleTappingAFormulaWithSelectEditsIt() async throws {
        var (e, ref) = try await formulaEditor()
        e.tool = .select
        let inside = e.drawing.frame(of: .shape(layer: ref.layer, shape: ref.shape))!.center
        tap(&e, inside, time: 1)
        tap(&e, inside, time: 1.1)
        XCTAssertEqual(e.tool, .math)
        XCTAssertEqual(e.mathEdit?.ref, ref)
        XCTAssertEqual(e.selection, .shape(layer: ref.layer, shape: ref.shape))
        e.selection = .none
        XCTAssertNil(e.mathEdit, "the edit ends with the selection")
    }

    func testEditEditsTheSelectedFormula() async throws {
        var (e, ref) = try await formulaEditor()
        e.tool = .select
        e.selection = .layer(ref.layer)
        e.editSelectedMath()
        XCTAssertEqual(e.mathEdit?.ref, ref)
        XCTAssertEqual(e.tool, .math)
    }

    func testSizeAndDisplayChangeTheSelectedFormulas() async throws {
        var (e, ref) = try await formulaEditor()
        e.tool = .select
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        e.setMathSize(40)
        e.setMathSize(48)
        e.setMathDisplay(false)
        XCTAssertEqual(e.drawing.shape(ref)?.math, MathContent(source: "a + b = c", size: 48, display: false))
        XCTAssertEqual(e.mathStyle, MathContent(source: "", size: 48, display: false), "new formulas follow")
        e.setMathSize(10_000)
        XCTAssertEqual(e.drawing.shape(ref)?.math?.size, TextContent.sizeRange.upperBound)
        e.undo()
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)?.math, MathContent(source: "a + b = c", size: 48, display: true),
                       "a run of size changes is one undo step")
        // Selecting a formula shows its style.
        e.selection = .none
        e.mathStyle = MathContent(source: "")
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        XCTAssertEqual(e.mathStyle.size, 48)
    }

    func testConvertToOutlinesMakesGlyphAndRuleShapes() async throws {
        var (e, ref) = try await formulaEditor("\\frac{a}{b}")
        e.tool = .select
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        XCTAssertTrue(e.canConvertToOutlines)
        let layout = try XCTUnwrap(MathTypesetting.layout(MathContent(source: "\\frac{a}{b}")))
        let before = e.drawing.world.layers[0].shapes[0].path.bounds()
        e.convertTextToOutlines()
        let layer = e.drawing.layers[0]
        XCTAssertEqual(layer.shapes.count, layout.glyphs.count + layout.rules.count)
        XCTAssertEqual(layer.shapes.count, 3, "a, b and the fraction bar")
        XCTAssertTrue(layer.shapes.allSatisfy { $0.math == nil && $0.layoutFrame == nil && !$0.path.points.isEmpty })
        let group = try XCTUnwrap(layer.shapes[0].group)
        XCTAssertTrue(layer.shapes.allSatisfy { $0.group == group })
        XCTAssertEqual(layer.group(group)?.name, "\\frac{a}{b}")
        // It looks the same: together the pieces cover the formula's ink.
        let world = e.drawing.world.layers[0].shapes.map { $0.path.bounds() }
        let union = world.dropFirst().reduce(world[0]) { $0.union($1) }
        XCTAssertTrue(union.minPoint.isApproximately(before.minPoint, tolerance: 1e-6))
        XCTAssertTrue(union.maxPoint.isApproximately(before.maxPoint, tolerance: 1e-6))
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)?.math?.source, "\\frac{a}{b}", "one undo step")
    }

    func testAFormulaWithNoLayoutCannotBeConverted() {
        var d = Drawing()
        let shape = VectorShape(id: d.makeID(), math: MathContent(source: "x"))
        let layer = Layer(id: d.makeID(), name: "Math", shapes: [shape])
        d.layers = [layer]
        var e = DrawingEditor(drawing: d)
        e.selection = .shape(layer: layer.id, shape: shape.id)
        XCTAssertFalse(e.canConvertToOutlines)
    }

    func testCopyGivesTheSourceAsText() async throws {
        var (e, ref) = try await formulaEditor()
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        XCTAssertEqual(e.clipboard()?.mathSource, "a + b = c")
        var square = Drawing()
        square.layers = [Layer(id: 1, name: "L", shapes: [VectorShape(id: 2, path: ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(9, 9))))])]
        var other = DrawingEditor(drawing: square)
        other.selection = .layer(1)
        XCTAssertNil(other.clipboard()?.mathSource, "no formula, no text")
    }

    func testPastingTextWithTheMathToolMakesAFormula() async {
        var e = DrawingEditor()
        e.tool = .math
        XCTAssertFalse(e.pasteMath("  \n", at: Vec2(500, 300)))
        XCTAssertTrue(e.pasteMath("a + b = c\n", at: Vec2(500, 300)))
        let edit = try! XCTUnwrap(e.mathEdit)
        XCTAssertEqual(edit.draft, "a + b = c")
        XCTAssertGreaterThan(edit.revision, 1, "the app copies the pasted source into its field")
        await typesetDraft(&e)
        e.endMathEdit()
        XCTAssertEqual(e.drawing.shape(edit.ref)?.math?.source, "a + b = c")
        e.undo()
        XCTAssertTrue(e.drawing.layers.isEmpty, "one undo step")
    }

    func testRetypesetAllForgetsEveryLayout() async throws {
        var (e, _) = try await formulaEditor()
        let math = MathContent(source: "a + b = c")
        XCTAssertNotNil(MathTypesetting.layout(math))
        let revision = e.documentRevision
        XCTAssertEqual(e.forgetFormulaLayouts(), [math])
        XCTAssertNil(MathTypesetting.layout(math))
        XCTAssertEqual(e.documentRevision, revision, "forgetting doesn't change the document")
        _ = await MathTypesetting.typeset(math)
        e.formulaLayoutsChanged()
        XCTAssertNotEqual(e.documentRevision, revision, "the new layouts are saved")
        XCTAssertFalse(e.canUndo)
    }
}
