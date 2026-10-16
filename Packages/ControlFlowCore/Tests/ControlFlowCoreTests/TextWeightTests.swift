import XCTest
@testable import ControlFlowCore

/// A drawing with one layer holding one text shape.
private func weightedDrawing(_ text: TextContent) -> (Drawing, ShapeRef) {
    var d = Drawing()
    let shape = VectorShape(id: d.makeID(), text: text, fill: .black, transform: Transform(position: Vec2(100, 200)))
    let layer = Layer(id: d.makeID(), name: "Words", shapes: [shape])
    d.layers = [layer]
    return (d, ShapeRef(layer: layer.id, shape: shape.id))
}

/// "Bold" in 700 and " words" in the text's own 400.
private let boldThenRegular = TextContent(string: "Bold words", size: 10, weights: [TextWeightRun(0..<4, weight: 700)])

final class TextWeightTests: XCTestCase {
    func testWeightsAreKeptInOrderApartAndInsideTheString() {
        let text = TextContent(string: "Hello world", weights: [
            TextWeightRun(6..<11, weight: 700), TextWeightRun(8..<20, weight: 400), TextWeightRun(0..<1, weight: 1000),
            TextWeightRun(3..<3, weight: 200), TextWeightRun(1..<2, weight: 900),
        ])
        XCTAssertEqual(text.weights, [TextWeightRun(0..<2, weight: 900), TextWeightRun(6..<8, weight: 700)],
                       "the later run wins, the text's own weight is dropped, and weights stay in 100...900")
        XCTAssertEqual(text.weightRuns, [TextWeightRun(0..<2, weight: 900), TextWeightRun(2..<6, weight: 400),
                                         TextWeightRun(6..<8, weight: 700), TextWeightRun(8..<11, weight: 400)])
        XCTAssertEqual(text.weight(at: 7), 700)
        XCTAssertEqual(text.weight(at: 99), 400, "past the end is the last character's")
        XCTAssertNil(text.uniformWeight(in: 5..<7))
        XCTAssertEqual(text.uniformWeight(in: 6..<8), 700)
        XCTAssertTrue(TextContent(string: "", weights: [TextWeightRun(0..<4, weight: 700)]).weights.isEmpty)
        XCTAssertTrue(boldThenRegular.style.weights.isEmpty, "new text starts in one weight")
    }

    func testTypingTakesTheWeightBeforeTheCaret() {
        var text = TextContent(string: "Hello", weights: [TextWeightRun(0..<3, weight: 700)])
        // "l" typed after "Hel": the bold one, though the diff alone can't tell which "l" is new.
        text.replaceString(with: "Helllo", selection: 3..<3, newSelection: 4..<4)
        XCTAssertEqual(text.weights, [TextWeightRun(0..<4, weight: 700)])
        // Deleting the regular "l" after the bold ones.
        text.replaceString(with: "Hello", selection: 5..<5, newSelection: 4..<4)
        XCTAssertEqual(text.string, "Hello")
        XCTAssertEqual(text.weights, [TextWeightRun(0..<4, weight: 700)])
        // Typing at the very start takes the first character's weight.
        text.replaceString(with: "Oh Hello", selection: 0..<0, newSelection: 3..<3)
        XCTAssertEqual(text.weights, [TextWeightRun(0..<7, weight: 700)])
        // Typing over a selection that spans both weights takes the first one's.
        text.replaceString(with: "Oh Hi", selection: 4..<8, newSelection: 5..<5)
        XCTAssertEqual(text.weights, [TextWeightRun(0..<5, weight: 700)])
        // A typing weight wins.
        text.replaceString(with: "Oh Hi!", selection: 5..<5, newSelection: 6..<6, typing: 300)
        XCTAssertEqual(text.weights, [TextWeightRun(0..<5, weight: 700), TextWeightRun(5..<6, weight: 300)])
    }

    func testAChangeAwayFromTheCaretKeepsTheWeightsItDidNotTouch() {
        // Autocorrect rewrites a word before the caret: the unchanged letters keep theirs.
        var text = TextContent(string: "a teh b", weights: [TextWeightRun(2..<5, weight: 700)])
        text.replaceString(with: "a the b", selection: 7..<7, newSelection: 7..<7)
        XCTAssertEqual(text.weights, [TextWeightRun(2..<5, weight: 700)])
    }

    func testTheFileWritesWeightsAsRuns() throws {
        let (d, ref) = weightedDrawing(boldThenRegular)
        let json = PresentationFormat.encode(d)
        guard case .array(let layers)? = json["opening"]?["layers"], case .array(let shapes)? = layers.first?["shapes"],
              let shape = shapes.first else { return XCTFail("no shape") }
        XCTAssertEqual(shape["text"]?["weights"], JSONValue.array([
            .object([(key: "start", value: 0), (key: "length", value: 4), (key: "weight", value: 700)]),
        ]))
        let back = try PresentationFormat.decode(JSONValue(parsing: json.formatted())).drawing
        XCTAssertEqual(back.shape(ref), d.shape(ref))
        // A text in one weight writes none.
        let plain = PresentationFormat.encode(weightedDrawing(TextContent(string: "Hi")).0)
        guard case .array(let l2)? = plain["opening"]?["layers"], case .array(let s2)? = l2.first?["shapes"] else { return XCTFail() }
        XCTAssertNil(s2.first?["text"]?["weights"])
    }

    func testTheFileRejectsBadRunsAndTidiesTheRest() throws {
        func read(_ weights: String) throws -> TextContent? {
            let file = """
                { "formatVersion": "1.4", "opening": { "viewport": { "width": 100, "height": 100 }, "layers": [
                  { "id": 1, "name": "A", "shapes": [{ "id": 2, "closed": true, "points": [],
                    "text": { "string": "abcdef", "weight": 300, "weights": \(weights) } }] }] } }
                """
            return try PresentationFormat.decode(JSONValue(parsing: file)).drawing.layers[0].shapes[0].text
        }
        XCTAssertEqual(try read(#"[{ "start": 4, "length": 99, "weight": 700 }, { "start": 0, "length": 1, "weight": 300 }]"#)?.weights,
                       [TextWeightRun(4..<6, weight: 700)])
        XCTAssertThrowsError(try read(#"[{ "start": -1, "length": 2, "weight": 700 }]"#))
        XCTAssertThrowsError(try read(#"[{ "start": 1, "weight": 700 }]"#))
        XCTAssertThrowsError(try read(#"{ "start": 1 }"#))
    }

    func testAKeyframeSetsTheWeightsAsOneValue() throws {
        let (d, ref) = weightedDrawing(TextContent(string: "Hi there", size: 10))
        var t = Timeline(Presentation(opening: d))
        let k = t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = t.state(at: 1)
        s.layers[0].shapes[0].text!.setWeight(700, in: 3..<8)
        t.record(s, at: 1)
        let run = JSONValue.object([(key: "start", value: 3), (key: "length", value: 5), (key: "weight", value: 700)])
        XCTAssertEqual(t.presentation.keyframe(k)?.changes, [.set(id: ref.shape, props: [PropertyChange("text.weights", .array([run]))])])
        XCTAssertEqual(t.transition(into: 1, elapsed: 0.5).layers[0].shapes[0].text!.weights, [TextWeightRun(3..<8, weight: 700)],
                       "weights take their new value at the start")
        // Back to one weight writes the default.
        s.layers[0].shapes[0].text!.weights = []
        s.layers[0].shapes[0].text!.string = "Hi"
        t.record(s, at: 1)
        let json = PresentationFormat.encode(t.presentation)
        let back = try PresentationFormat.decode(JSONValue(parsing: json.formatted())).presentation
        var reread = Timeline(back)
        XCTAssertEqual(reread.state(at: 1).layers[0].shapes[0].text, TextContent(string: "Hi", size: 10))
    }

    // MARK: Editing

    private func editing(_ text: TextContent = boldThenRegular) -> (DrawingEditor, ShapeRef) {
        let (d, ref) = weightedDrawing(text)
        var e = DrawingEditor(drawing: d)
        e.tool = .text
        e.beginTextEdit(ref)
        return (e, ref)
    }

    func testChoosingAWeightWhileTypingSetsTheSelectedWords() {
        var (e, ref) = editing(TextContent(string: "Bold words", size: 10))
        e.setTextSelection(5..<10)
        e.setTextWeight(800)
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weights, [TextWeightRun(5..<10, weight: 800)])
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weight, 400, "the text's own weight stays")
        XCTAssertEqual(e.textStyle.weight, 800, "the style controls show the selection's weight")
        e.setTextSelection(1..<1)
        XCTAssertEqual(e.textStyle.weight, 400)
        e.typeText("x")
        e.endTextEdit()
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weights, [TextWeightRun(6..<11, weight: 800)], "typing moves the runs")
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)!.text, TextContent(string: "Bold words", size: 10),
                       "the session, weights and all, is one undo step")
    }

    func testAWeightChosenAtTheCaretIsWhatIsTypedNext() {
        var (e, ref) = editing()
        e.setTextSelection(4..<4)
        XCTAssertEqual(e.textStyle.weight, 700, "the caret after a bold word shows bold")
        e.setTextWeight(400)
        XCTAssertEqual(e.drawing.shape(ref)!.text, boldThenRegular, "nothing changes until something is typed")
        XCTAssertEqual(e.textStyle.weight, 400)
        e.typeText("!")
        e.typeText("?")
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weights, [TextWeightRun(0..<4, weight: 700)])
        // Moving the caret forgets the typing weight.
        e.setTextWeight(900)
        e.setTextSelection(0..<0)
        e.typeText("A")
        XCTAssertEqual(e.drawing.shape(ref)!.text!.string, "ABold!? words")
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weights, [TextWeightRun(0..<5, weight: 700)])
    }

    func testCommandBTogglesBold() {
        var (e, ref) = editing(TextContent(string: "Bold words", size: 10))
        e.setTextSelection(0..<4)
        e.toggleTextBold()
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weights, [TextWeightRun(0..<4, weight: 700)])
        e.setTextSelection(0..<6)
        e.toggleTextBold()
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weights, [TextWeightRun(0..<6, weight: 700)], "a mixed selection goes bold")
        e.toggleTextBold()
        XCTAssertTrue(e.drawing.shape(ref)!.text!.weights.isEmpty, "an all-bold one goes back to regular")
        // A named font has no weights.
        e.endTextEdit()
        e.setTextFont("Futura-Medium")
        e.beginTextEdit(ref, selection: 0..<4)
        e.toggleTextBold()
        XCTAssertTrue(e.drawing.shape(ref)!.text!.weights.isEmpty)
    }

    func testChoosingAWeightForTheWholeTextClearsTheRuns() {
        let (d, ref) = weightedDrawing(boldThenRegular)
        var e = DrawingEditor(drawing: d)
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        XCTAssertEqual(e.textStyle.weight, 400, "a selected text shows its own weight")
        e.toggleTextBold()
        let text = e.drawing.shape(ref)!.text!
        XCTAssertEqual(text.weight, 700, "a text partly regular goes bold")
        XCTAssertTrue(text.weights.isEmpty)
        e.undo()
        e.setTextWeight(300)
        XCTAssertEqual(e.drawing.shape(ref)!.text!.weight, 300)
        XCTAssertTrue(e.drawing.shape(ref)!.text!.weights.isEmpty)
    }

    func testEndingAnEditShowsTheTextsOwnWeightAgain() {
        var (e, _) = editing()
        e.setTextSelection(1..<1)
        XCTAssertEqual(e.textStyle.weight, 700)
        e.endTextEdit()
        XCTAssertEqual(e.textStyle.weight, 400)
    }

    func testTheHTMLExportKeysLayoutsByTheirWeights() throws {
        let (d, _) = weightedDrawing(boldThenRegular)
        let texts = try HTMLExport.textLayouts(PresentationFormat.encode(d))
        guard case .array(let list)? = texts?["texts"] else { return XCTFail("no texts") }
        XCTAssertEqual(list.first?["text"]?["weights"], SceneJSON.text(boldThenRegular)["weights"])
    }
}
