import XCTest
@testable import ControlFlowCore

private func tap(_ e: inout DrawingEditor, _ p: Vec2, time: Double? = nil) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p, time: time)
}

private func drag(_ e: inout DrawingEditor, _ a: Vec2, _ b: Vec2) {
    e.pencilBegan(at: a, zoom: 1)
    e.pencilMoved(to: Vec2.lerp(a, b, 0.5))
    e.pencilEnded(at: b)
}

private func assertClose(_ a: Double, _ b: Double, tolerance: Double = 1e-6, _ message: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a, b, accuracy: tolerance, message, file: file, line: line)
}

/// A drawing with one layer holding one text shape at (100, 200).
private func textDrawing(_ text: TextContent = TextContent(string: "Hi there", size: 10)) -> (Drawing, ShapeRef) {
    var d = Drawing()
    let shape = VectorShape(id: d.makeID(), text: text, fill: .black, transform: Transform(position: Vec2(100, 200)))
    let layer = Layer(id: d.makeID(), name: "Words", shapes: [shape])
    d.layers = [layer]
    return (d, ShapeRef(layer: layer.id, shape: shape.id))
}

final class TextLayoutTests: XCTestCase {
    /// The stub advances 0.6 of the size per character.
    func testStubLaysOutOneLinePerParagraph() {
        let layout = TextShaping.layout(TextContent(string: "ab\ncde", size: 10))
        XCTAssertEqual(layout.lines.count, 2)
        assertClose(layout.lines[0].width, 12)
        assertClose(layout.lines[1].width, 18)
        assertClose(layout.boxWidth, 18, "an auto-width text is as wide as its widest line")
        assertClose(layout.lines[1].top, 12, "lines are 1.2 times the size apart")
        XCTAssertEqual(layout.lines[0].range, 0..<2)
        XCTAssertEqual(layout.lines[1].range, 3..<6)
        XCTAssertEqual(layout.carets.count, 7)
        XCTAssertEqual(layout.carets[2], TextLayout.Caret(x: 12, line: 0), "the caret before the line break ends line 0")
        XCTAssertEqual(layout.carets[3], TextLayout.Caret(x: 0, line: 1))
        XCTAssertEqual(layout.carets[6], TextLayout.Caret(x: 18, line: 1))
        XCTAssertEqual(layout.glyphs.count, 5)
        XCTAssertEqual(layout.glyphs[4].index, 2)
        XCTAssertEqual(layout.glyphs[0].contours.count, 2, "a stub glyph is a box with a hole")
    }

    func testABoxWrapsBeforeTheWordThatWouldOverflow() {
        let layout = TextShaping.layout(TextContent(string: "aa bb cc", size: 10, width: 40))
        // "aa bb" is 30 wide; "aa bb cc" would be 48.
        XCTAssertEqual(layout.lines.map(\.range), [0..<6, 6..<8])
        assertClose(layout.boxWidth, 40)
        assertClose(layout.lines[0].width, 30, "trailing spaces don't count")
    }

    func testAlignmentPlacesLinesInTheBox() {
        let layout = TextShaping.layout(TextContent(string: "a\nabc", size: 10, align: .right))
        assertClose(layout.lines[0].x, 12)
        assertClose(layout.lines[1].x, 0)
        let centered = TextShaping.layout(TextContent(string: "a\nabc", size: 10, align: .center))
        assertClose(centered.lines[0].x, 6)
    }

    func testAdjustedMatchesALayoutAtTheNewMetrics() {
        let base = TextContent(string: "ab cd\nefg", size: 10, align: .center)
        var changed = base
        changed.tracking = 3
        changed.lineHeight = 2
        let adjusted = TextShaping.layout(base).adjusted(from: base, tracking: 3, lineHeight: 2)
        let direct = TextShaping.layout(changed)
        XCTAssertEqual(adjusted.glyphs.count, direct.glyphs.count)
        for (a, b) in zip(adjusted.glyphs, direct.glyphs) {
            XCTAssertTrue(a.origin.isApproximately(b.origin, tolerance: 1e-9), "\(a.origin) is not \(b.origin)")
        }
        assertClose(adjusted.boxWidth, direct.boxWidth)
        assertClose(adjusted.bounds.height, direct.bounds.height)
    }

    func testHeldMetricsKeepTheLineBreaks() {
        var text = TextContent(string: "aa bb cc", size: 10, width: 40)
        text.tracking = 10
        XCTAssertEqual(TextShaping.layout(text).lines.count, 3, "with more tracking the words wrap sooner")
        text.held = TextMetrics(tracking: 0, lineHeight: 1.2)
        XCTAssertEqual(TextShaping.layout(text).lines.count, 2, "held, the lines break as they did")
    }

    func testTextCacheDropsTheLeastRecentlyUsed() {
        var cache = TextCache<Int>(limit: 8)
        let texts = (0..<9).map { TextContent(string: "t\($0)") }
        for (i, text) in texts.prefix(8).enumerated() { cache.set(i, for: text) }
        // Touch the first two, so the next oldest go when the ninth arrives.
        XCTAssertEqual(cache.value(for: texts[0]), 0)
        XCTAssertEqual(cache.value(for: texts[1]), 1)
        cache.set(8, for: texts[8])
        XCTAssertEqual(cache.count, 7, "a quarter of the cache goes, then the new text comes in")
        XCTAssertEqual(cache.value(for: texts[0]), 0)
        XCTAssertEqual(cache.value(for: texts[1]), 1)
        XCTAssertNil(cache.value(for: texts[2]))
        XCTAssertNil(cache.value(for: texts[3]))
        XCTAssertEqual(cache.value(for: texts[4]), 4)
        XCTAssertEqual(cache.value(for: texts[8]), 8)
    }

    func testTweenedTextsDoNotPushStaticTextsOut() {
        let counter = CountingShaper()
        let previous = TextShaping.shaper
        TextShaping.shaper = counter
        defer { TextShaping.shaper = previous }

        let title = TextContent(string: "Title", size: 40)
        _ = TextShaping.outline(title)
        XCTAssertEqual(counter.count, 1)
        // A tracking tween: a new held text every frame, many more than the cache holds.
        var tweened = TextContent(string: "Moving", size: 20)
        tweened.held = TextMetrics(tracking: 0, lineHeight: 1.2)
        for frame in 0..<(TextShaping.cacheLimit * 2) {
            tweened.tracking = Double(frame) / 100
            _ = TextShaping.outline(tweened)
        }
        XCTAssertEqual(counter.count, 2, "each tweened frame adjusts one layout at the held metrics")
        XCTAssertLessThanOrEqual(TextShaping.cachedCounts.held, TextShaping.heldCacheLimit)
        _ = TextShaping.outline(title)
        XCTAssertEqual(counter.count, 2, "the static title is still laid out")
    }

    func testCaretsAndSelectionBoxes() {
        let layout = TextShaping.layout(TextContent(string: "abc\nde", size: 10))
        XCTAssertEqual(layout.offset(nearest: Vec2(7, 3)), 1)
        XCTAssertEqual(layout.offset(nearest: Vec2(100, 15)), 6, "past the end of the last line")
        XCTAssertEqual(layout.offset(from: 2, lines: 1), 6, "down from x 12 lands at the end of the shorter line")
        XCTAssertEqual(layout.offset(from: 5, lines: -1), 1)
        let boxes = layout.selectionRects(1..<5)
        XCTAssertEqual(boxes.count, 2)
        assertClose(boxes[0].minPoint.x, 6)
        assertClose(boxes[1].maxPoint.x, 6)
        let caret = layout.caret(at: 4)
        XCTAssertEqual(caret.top, Vec2(0, 12))
        XCTAssertEqual(caret.bottom, Vec2(0, 24))
    }

    func testBridgingAddsNoArea() {
        let rings = [Rect(minPoint: Vec2(0, 0), maxPoint: Vec2(10, 10)), Rect(minPoint: Vec2(20, 30), maxPoint: Vec2(30, 40)),
                     Rect(minPoint: Vec2(50, 0), maxPoint: Vec2(60, 10))].map {
            BezierPath(points: $0.corners.map { PathPoint($0, smooth: false) }, closed: true)
        }
        let poly = BezierPath.bridging(rings).flattened(tolerance: 0.1)
        for inside in [Vec2(5, 5), Vec2(25, 35), Vec2(55, 5)] {
            XCTAssertNotEqual(windingNumber(of: inside, polygon: poly), 0)
        }
        // Between the rings, where a chain of bridges round the three would have enclosed area.
        for outside in [Vec2(30, 10), Vec2(40, 8), Vec2(15, 15)] {
            XCTAssertEqual(windingNumber(of: outside, polygon: poly), 0, "\(outside)")
        }
    }
}

final class TextShapeTests: XCTestCase {
    func testTheDrawnDrawingHasTheGlyphs() {
        let (d, ref) = textDrawing()
        XCTAssertTrue(d.shape(ref)!.path.points.isEmpty, "the text keeps no points")
        let world = d.world
        let drawn = world.layers[0].shapes[0]
        XCTAssertFalse(drawn.path.points.isEmpty)
        XCTAssertTrue(drawn.path.closed)
        XCTAssertEqual(drawn.text, d.shape(ref)!.text, "the drawn shape still knows its words")
        // 7 letters, each a box with a hole, at 100 across.
        let box = drawn.path.bounds()
        assertClose(box.minPoint.x, 100 + 0.6)
        XCTAssertNotNil(drawn.layoutFrame)
    }

    func testATextIsTappedAnywhereInItsBox() {
        let (d, ref) = textDrawing()
        // Between the letters "i" and " " there is no ink, but the box counts.
        let hit = d.hitTest(Vec2(100 + 13, 205), tolerance: 0)
        XCTAssertEqual(hit.map { ShapeRef(layer: $0.layer, shape: $0.shape) }, ref)
        XCTAssertNil(d.hitTest(Vec2(100 - 5, 205), tolerance: 1))
        let frame = d.frame(of: .shape(layer: ref.layer, shape: ref.shape))!
        XCTAssertTrue(frame.corners[0].isApproximately(Vec2(100, 200)))
        XCTAssertTrue(frame.corners[2].isApproximately(Vec2(100 + 48, 212)))
    }

    func testMovingATextChangesItsTransform() {
        let (d, ref) = textDrawing()
        let moved = d.applying(.translation(Vec2(10, 0)), to: .shape(layer: ref.layer, shape: ref.shape))
        XCTAssertEqual(moved.shape(ref)!.transform.position, Vec2(110, 200))
        XCTAssertTrue(moved.shape(ref)!.path.points.isEmpty)
        // Taking a transform into its points (Apply Transform, a layer move) moves its transform instead.
        var layer = d.layers[0]
        layer.move(by: .translation(Vec2(0, 5)))
        XCTAssertEqual(layer.shapes[0].transform.position, Vec2(100, 205))
        XCTAssertTrue(layer.shapes[0].path.points.isEmpty)
    }

    func testTheFileWritesOnlyWhatIsntTheDefault() throws {
        let (d, ref) = textDrawing(TextContent(string: "Hello", font: "AvenirNext-DemiBold", size: 96, align: .center,
                                               width: 800))
        let json = PresentationFormat.encode(d)
        guard case .array(let layers)? = json["opening"]?["layers"], case .array(let shapes)? = layers.first?["shapes"],
              let shape = shapes.first else { return XCTFail("no shape") }
        XCTAssertEqual(shape["text"], JSONValue.object([
            (key: "string", value: .string("Hello")), (key: "font", value: .string("AvenirNext-DemiBold")),
            (key: "size", value: 96), (key: "align", value: .string("center")), (key: "width", value: 800),
        ]))
        XCTAssertEqual(shape["points"], JSONValue.array([]))
        XCTAssertEqual(json["formatVersion"], JSONValue.string(PresentationFormat.version.description))
        let back = try PresentationFormat.decode(JSONValue(parsing: json.formatted())).drawing
        XCTAssertEqual(back.shape(ref), d.shape(ref))
    }

    func testAKeyframeChangesTheWordsAsAProperty() {
        let (d, ref) = textDrawing()
        var t = Timeline(Presentation(opening: d))
        let k = t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = t.state(at: 1)
        s.layers[0].shapes[0].text!.string = "Thank you"
        s.layers[0].shapes[0].text!.tracking = 4
        t.record(s, at: 1)
        XCTAssertEqual(t.presentation.keyframe(k)?.changes,
                       [.set(id: ref.shape, props: [PropertyChange("text.string", .string("Thank you")),
                                                    PropertyChange("text.tracking", 4)])])
        // Back to the default writes the default.
        s.layers[0].shapes[0].text!.tracking = 0
        s.layers[0].shapes[0].text!.size = 72
        t.record(s, at: 1)
        XCTAssertEqual(t.presentation.keyframe(k)?.changes,
                       [.set(id: ref.shape, props: [PropertyChange("text.string", .string("Thank you")),
                                                    PropertyChange("text.size", 72)])])
    }

    func testWordsSnapAndTrackingMovesInATransition() {
        let (d, _) = textDrawing(TextContent(string: "aa bb cc", size: 10, width: 40))
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = t.state(at: 1)
        s.layers[0].shapes[0].text!.string = "aa bb cc dd"
        s.layers[0].shapes[0].text!.tracking = 10
        s.layers[0].shapes[0].text!.size = 12
        t.record(s, at: 1)
        let half = t.transition(into: 1, elapsed: 0.5).layers[0].shapes[0].text!
        XCTAssertEqual(half.string, "aa bb cc dd", "the words take their new value at the start")
        XCTAssertEqual(half.size, 12, "so does the size")
        assertClose(half.tracking, 5)
        XCTAssertEqual(half.held, TextMetrics(tracking: 10, lineHeight: 1.2), "the lines break as they will at the end")
        let end = TextShaping.layout(t.state(at: 1).layers[0].shapes[0].text!)
        XCTAssertEqual(TextShaping.layout(half).lines.map(\.range), end.lines.map(\.range))
        XCTAssertNil(t.transition(into: 1, elapsed: 1).layers[0].shapes[0].text!.held)
    }
}

final class TextEditingTests: XCTestCase {
    func testEditsKeepToCharacterBoundaries() {
        var e = TextEditing(string: "a😀b")
        XCTAssertEqual(e.selection, 4..<4)
        e.moveLeft()
        e.moveLeft()
        XCTAssertEqual(e.selection, 1..<1, "the emoji is one step")
        e.deleteForward()
        XCTAssertEqual(e.string, "ab")
        e.insert("cd")
        XCTAssertEqual(e.string, "acdb")
        XCTAssertEqual(e.selection, 3..<3)
        e.moveRight(extending: true)
        XCTAssertEqual(e.selection, 3..<4)
        e.deleteBackward()
        XCTAssertEqual(e.string, "acd")
        e.selectWord(at: 1)
        XCTAssertEqual(e.selection, 0..<3)
        XCTAssertEqual(TextEditing(string: "a😀b", selection: 2..<2).selection, 1..<1, "a caret inside a character moves to its start")
    }

    func testTheTextToolTypesANewText() {
        var e = DrawingEditor()
        e.tool = .text
        e.style.fill = RGBAColor(hex: "#336699FF")!
        e.textStyle.size = 10
        tap(&e, Vec2(50, 60))
        guard let edit = e.textEdit else { return XCTFail("the tap starts typing") }
        e.typeText("Hello")
        XCTAssertEqual(e.editedString, "Hello")
        let shape = e.drawing.shape(edit.ref)!
        XCTAssertEqual(shape.fill, RGBAColor(hex: "#336699FF")!)
        XCTAssertNil(shape.stroke)
        // The tap is the middle of the first line, at its start.
        let frame = e.drawing.frame(of: .shape(layer: edit.ref.layer, shape: edit.ref.shape))!
        XCTAssertTrue(frame.corners[0].isApproximately(Vec2(50, 54)))
        e.setEditedText("Hello world", selection: 11..<11)
        e.endTextEdit()
        XCTAssertNil(e.textEdit)
        XCTAssertEqual(e.drawing.shape(edit.ref)?.text?.string, "Hello world")
        let pivot = e.drawing.shape(edit.ref)!.transform.pivot
        XCTAssertTrue(pivot.isApproximately(TextShaping.layout(e.drawing.shape(edit.ref)!.text!).bounds.center),
                      "a new text turns about the middle of its box")
        XCTAssertTrue(frame.corners[0].isApproximately(e.drawing.frame(of: .shape(layer: edit.ref.layer, shape: edit.ref.shape))!.corners[0]),
                      "moving the pivot doesn't move the text")
        e.undo()
        XCTAssertNil(e.drawing.shape(edit.ref), "the whole session is one undo step")
        XCTAssertFalse(e.canUndo)
    }

    func testAnEmptyTextGoesAwayWithNothingToUndo() {
        var e = DrawingEditor()
        e.tool = .text
        tap(&e, Vec2(50, 60))
        XCTAssertNotNil(e.textEdit)
        // Tapping away ends the edit; it doesn't start another text.
        tap(&e, Vec2(500, 600))
        XCTAssertNil(e.textEdit)
        XCTAssertTrue(e.drawing.layers.isEmpty)
        XCTAssertFalse(e.canUndo)
    }

    func testDraggingMakesATextBox() {
        var e = DrawingEditor()
        e.tool = .text
        e.textStyle.size = 10
        drag(&e, Vec2(20, 30), Vec2(120, 50))
        guard let edit = e.textEdit else { return XCTFail("the drag starts typing") }
        XCTAssertEqual(e.drawing.shape(edit.ref)?.text?.width, 100)
        XCTAssertNil(e.marquee)
    }

    func testTappingInTheTextPlacesTheCaret() {
        var e = DrawingEditor()
        e.tool = .text
        e.textStyle.size = 10
        tap(&e, Vec2(0, 6))
        e.typeText("abcdef")
        let revision = e.textEdit!.revision
        tap(&e, Vec2(13, 6))
        XCTAssertEqual(e.textEdit?.selection, 2..<2)
        XCTAssertGreaterThan(e.textEdit!.revision, revision, "the app learns of the caret the editor moved")
        drag(&e, Vec2(1, 6), Vec2(24, 6))
        XCTAssertEqual(e.textEdit?.selection, 0..<4)
        XCTAssertEqual(e.textEditGeometry?.selection.count, 1)
    }

    func testDoubleTappingATextWithSelectEditsIt() {
        // Big enough that a tap inside isn't on a handle.
        let (d, ref) = textDrawing(TextContent(string: "Hi there", size: 100))
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        tap(&e, Vec2(170, 250), time: 1)
        tap(&e, Vec2(170, 250), time: 1.1)
        XCTAssertEqual(e.tool, .text)
        XCTAssertEqual(e.textEdit?.ref, ref)
        XCTAssertEqual(e.textEdit?.selection, 1..<1, "the caret goes where the tap was (between H and i, at 160)")
        e.tool = .select
        XCTAssertNil(e.textEdit, "changing tools ends the edit")
    }

    func testTheSideHandleOfATextBoxChangesItsWidth() {
        let (d, ref) = textDrawing(TextContent(string: "aa bb cc", size: 100, width: 400))
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        // Two lines in a 400 by 240 box: the right side's middle is at (500, 320). Drag it 20 further.
        drag(&e, Vec2(500, 320), Vec2(520, 320))
        XCTAssertEqual(e.drawing.shape(ref)?.text?.width, 420)
        XCTAssertEqual(e.drawing.shape(ref)?.transform.scale, Vec2(1, 1), "the box wraps; it doesn't stretch")
        // The left side moves left by 10: wider, and the right side stays.
        drag(&e, Vec2(100, 320), Vec2(90, 320))
        XCTAssertEqual(e.drawing.shape(ref)?.text?.width ?? 0, 430, accuracy: 1e-9)
        let frame = e.drawing.frame(of: e.selection)!
        XCTAssertTrue(frame.corners[1].isApproximately(Vec2(520, 200), tolerance: 1e-9))
        XCTAssertTrue(frame.corners[0].isApproximately(Vec2(90, 200), tolerance: 1e-9))
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)?.text?.width, 420)
    }

    func testStyleCommandsChangeTheSelectedText() {
        let (d, ref) = textDrawing()
        var e = DrawingEditor(drawing: d)
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        XCTAssertEqual(e.textStyle.size, 10, "selecting a text takes up its style")
        e.setTextSize(24)
        e.setTextSize(30)
        e.setTextAlignment(.center)
        e.setTextFont("Futura-Bold")
        let text = e.drawing.shape(ref)!.text!
        XCTAssertEqual(text.size, 30)
        XCTAssertEqual(text.align, .center)
        XCTAssertEqual(text.font, "Futura-Bold")
        XCTAssertEqual(text.string, "Hi there")
        e.undo()
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)!.text!.size, 30, "a run of size changes is one step")
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)!.text!.size, 10)
    }

    func testConvertToOutlinesMakesAGroupOfGlyphs() {
        let (d, ref) = textDrawing(TextContent(string: "ab c", size: 10))
        var e = DrawingEditor(drawing: d)
        e.selection = .shape(layer: ref.layer, shape: ref.shape)
        let before = e.drawing.world.layers[0].shapes[0].path.bounds()
        e.convertTextToOutlines()
        let layer = e.drawing.layers[0]
        XCTAssertEqual(layer.shapes.count, 3, "one shape per glyph; the space draws nothing")
        XCTAssertEqual(layer.groups.count, 1)
        XCTAssertEqual(layer.groups[0].name, "ab c")
        XCTAssertTrue(layer.shapes.allSatisfy { $0.text == nil && $0.group == layer.groups[0].id && !$0.path.points.isEmpty })
        let after = e.drawing.world.layers[0].shapes.reduce(Rect.null) { $0.union($1.path.bounds()) }
        XCTAssertTrue(after.minPoint.isApproximately(before.minPoint) && after.maxPoint.isApproximately(before.maxPoint),
                      "the letters stay where they were")
        XCTAssertEqual(e.drawing.shapeRefs(in: e.selection).count, 3)
        e.undo()
        XCTAssertEqual(e.drawing.shape(ref)?.text?.string, "ab c")
    }

    func testDirectSelectAndScissorsLeaveTextAlone() {
        let (d, ref) = textDrawing()
        var e = DrawingEditor(drawing: d)
        e.tool = .directSelect
        tap(&e, Vec2(100.6, 199))
        XCTAssertEqual(e.selection, .shape(layer: ref.layer, shape: ref.shape))
        XCTAssertTrue(e.selectedAnchors.isEmpty)
        e.tool = .scissors
        tap(&e, Vec2(100.6, 199))
        XCTAssertEqual(e.drawing.layers[0].shapes.count, 1)
        XCTAssertNotNil(e.drawing.shape(ref)?.text)
    }
}

/// Counts the layouts the shaper is asked for.
private final class CountingShaper: TextShaper, @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0
    var count: Int { lock.withLock { made } }

    func layout(_ text: TextContent) -> TextLayout {
        lock.withLock { made += 1 }
        return StubTextShaper().layout(text)
    }
}
