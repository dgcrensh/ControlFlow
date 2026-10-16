import Foundation
import XCTest
@testable import ControlFlowCore

private let before = MathContent(source: "a + b = c")
private let after = MathContent(source: "a = c - b")

/// A layout made by hand: one glyph per key, each a square `size` glyph units across at
/// `x` points along the baseline, with `tags`.
private func layout(_ glyphs: [(key: String, x: Double, tags: [String])], size: [String: Double] = [:],
                    rules: [Rect] = []) -> MathLayout {
    var outlines: [String: [BezierPath]] = [:]
    for g in glyphs where outlines[g.key] == nil {
        let s = size[g.key] ?? 500
        outlines[g.key] = [ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(s, s)))]
    }
    return MathLayout(outlines: outlines,
                      glyphs: glyphs.map { MathLayout.Glyph(key: $0.key, place: Affine2D(a: 0.072, b: 0, c: 0, d: -0.072, tx: $0.x, ty: 50),
                                                            tags: $0.tags) },
                      rules: rules, bounds: Rect(minPoint: .zero, maxPoint: Vec2(Double(glyphs.count) * 40, 70)), baseline: 50)
}

private func pairs(_ p: MathMorph.Pairing) -> [[Int?]] { p.glyphs.map { [$0.from, $0.to] } }

/// Formulas morphing between keyframes: which glyphs match, and the frames between.
final class MathMorphTests: XCTestCase {
    override func setUpWithError() throws {
        MathTypesetting.reset()
        try insert(before, after)
    }

    override func tearDown() {
        MathTypesetting.reset()
    }

    private func insert(_ maths: MathContent...) throws {
        for math in maths { MathTypesetting.insert([math: try FixtureMathTypesetter.layout(math)], engine: "test") }
    }

    func testMatchingSymbolsPairAndTheRestShrinkOrGrow() throws {
        let a = try XCTUnwrap(MathTypesetting.layout(before)), b = try XCTUnwrap(MathTypesetting.layout(after))
        XCTAssertEqual(a.glyphs.map(\.source), ["a", "+", "b", "=", "c"])
        XCTAssertEqual(b.glyphs.map(\.source), ["a", "=", "c", "-", "b"])
        let p = MathMorph.pair(a, b)
        // a, =, c and b move; − is new and + leaves.
        XCTAssertEqual(pairs(p), [[0, 0], [3, 1], [4, 2], [nil, 3], [2, 4], [1, nil]])
        XCTAssertTrue(p.rules.isEmpty)
    }

    func testRepeatedSymbolsPairInReadingOrder() {
        let a = layout([("x", 0, []), ("y", 40, []), ("x", 80, []), ("x", 120, [])])
        let b = layout([("x", 0, []), ("x", 40, []), ("y", 80, [])])
        XCTAssertEqual(pairs(MathMorph.pair(a, b)), [[0, 0], [2, 1], [1, 2], [3, nil]])
    }

    func testClassTagsOverrideReadingOrder() {
        // \class{one}{x} + \class{two}{x} → \class{two}{x} + \class{one}{x}: each x follows its tag.
        let a = layout([("x", 0, ["one"]), ("+", 40, []), ("x", 80, ["two"])])
        let b = layout([("x", 0, ["two"]), ("+", 40, []), ("x", 80, ["one"])])
        XCTAssertEqual(pairs(MathMorph.pair(a, b)), [[2, 0], [1, 1], [0, 2]])
        // The innermost tag decides, and a tag only one side has is ignored.
        let c = layout([("x", 0, ["outer", "one"]), ("y", 40, ["lonely"])])
        let d = layout([("y", 0, []), ("x", 40, ["one"])])
        XCTAssertEqual(pairs(MathMorph.pair(c, d)), [[1, 0], [0, 1]])
        // A tagged glyph left over doesn't pair outside its tag.
        let e = layout([("x", 0, ["one"]), ("z", 40, ["one"])])
        let f = layout([("x", 0, ["one"]), ("z", 40, [])])
        XCTAssertEqual(pairs(MathMorph.pair(e, f)), [[0, 0], [nil, 1], [1, nil]])
    }

    func testAFractionBarLerps() throws {
        let small = MathContent(source: "\\frac{a}{b}"), large = MathContent(source: "\\frac{a}{b}", size: 144)
        try insert(small, large)
        let a = try XCTUnwrap(MathTypesetting.layout(small)), b = try XCTUnwrap(MathTypesetting.layout(large))
        let p = MathMorph.pair(a, b)
        XCTAssertEqual(p.rules.map { [$0.from, $0.to] }, [[0, 0]])
        XCTAssertEqual(pairs(p), [[0, 0], [1, 1]])
        let half = MathMorph.outline(a, b, p, progress: 0.5).bounds()
        let ends = (a.outline.bounds(), b.outline.bounds())
        XCTAssertEqual(half.width, (ends.0.width + ends.1.width) / 2, accuracy: 1e-6, "everything scales with the size")
        XCTAssertEqual(MathMorph.bounds(a, b, progress: 0.5).width, (a.bounds.width + b.bounds.width) / 2, accuracy: 1e-9)
        // A rule that is new grows from its center.
        let none = layout([("a", 0, [])]), bar = layout([("a", 0, [])], rules: [Rect(minPoint: Vec2(0, 30), maxPoint: Vec2(40, 34))])
        let growing = MathMorph.outline(none, bar, MathMorph.pair(none, bar), progress: 0.5)
        let ruleRing = MathMorph.scaled(Rect(minPoint: Vec2(0, 30), maxPoint: Vec2(40, 34)), by: 0.5)
        XCTAssertEqual(ruleRing, Rect(minPoint: Vec2(10, 31), maxPoint: Vec2(30, 33)))
        XCTAssertTrue(growing.points.contains { $0.position == Vec2(10, 31) })
    }

    func testAGrowingParenthesisSwapsOutlineHalfway() {
        let a = layout([("NCM-N-28", 0, [])], size: ["NCM-N-28": 500])
        let b = layout([("NCM-S3-28", 0, [])], size: ["NCM-S3-28": 1000])
        let p = MathMorph.pair(a, b)
        XCTAssertEqual(pairs(p), [[0, 0]], "the same symbol at another size moves")
        XCTAssertEqual(MathMorph.symbol("NCM-S6-28"), "NCM-28")
        let early = MathMorph.outline(a, b, p, progress: 0.4).bounds(), late = MathMorph.outline(a, b, p, progress: 0.6).bounds()
        XCTAssertEqual(early.width, 500 * 0.072, accuracy: 1e-9, "the old outline until halfway")
        XCTAssertEqual(late.width, 1000 * 0.072, accuracy: 1e-9, "then the new one")
        // Different symbols don't pair.
        XCTAssertEqual(pairs(MathMorph.pair(a, layout([("NCM-S3-29", 0, [])]))), [[nil, 0], [0, nil]])
    }

    func testUnmatchedGlyphsScaleAboutTheirCenters() {
        let a = layout([("x", 0, [])]), b = layout([("y", 100, [])])
        let p = MathMorph.pair(a, b)
        let quarter = MathMorph.outline(a, b, p, progress: 0.25)
        // The x at 3/4 size and the y at 1/4, each about its own center.
        let rings = quarter.points.map(\.position)
        let xCenter = Vec2(250 * 0.072, 50 - 250 * 0.072), yCenter = Vec2(100 + 250 * 0.072, 50 - 250 * 0.072)
        XCTAssertTrue(rings.contains { ($0 - Vec2(xCenter.x - 0.75 * 18, xCenter.y + 0.75 * 18)).length < 1e-9 })
        XCTAssertTrue(rings.contains { ($0 - Vec2(yCenter.x + 0.25 * 18, yCenter.y - 0.25 * 18)).length < 1e-9 })
        // Nothing is drawn of a glyph at no size.
        let overshoot = MathMorph.outline(a, b, p, progress: 1.2)
        XCTAssertTrue(overshoot.points.allSatisfy { $0.position.x > 90 }, "the x is gone past the end")
    }

    func testTheEndsAreExactlyTheTwoFormulas() throws {
        let a = try XCTUnwrap(MathTypesetting.layout(before)), b = try XCTUnwrap(MathTypesetting.layout(after))
        let p = MathMorph.pair(a, b)
        XCTAssertEqual(MathMorph.outline(a, b, p, progress: 0), a.outline)
        XCTAssertEqual(MathMorph.outline(a, b, p, progress: 1), b.outline)
        XCTAssertNotEqual(MathMorph.outline(a, b, p, progress: 0.5), b.outline)
    }

    func testAMorphingShapeResolvesToTheFrame() throws {
        var math = after
        math.morph = MathMorphState(from: before, progress: 0.5)
        let a = try XCTUnwrap(MathTypesetting.layout(before)), b = try XCTUnwrap(MathTypesetting.layout(after))
        XCTAssertEqual(MathTypesetting.layout(math), b, "layouts are of the formula without its morph")
        let drawn = VectorShape(id: 1, math: math).resolvingLayout()
        XCTAssertEqual(drawn.path, MathMorph.outline(a, b, MathMorph.pair(a, b), progress: 0.5))
        XCTAssertEqual(drawn.layoutFrame, MathMorph.bounds(a, b, progress: 0.5).corners)
        XCTAssertEqual(drawn.math?.morph, math.morph)
    }

    func testAnUnknownLayoutSnaps() throws {
        var math = after
        math.morph = MathMorphState(from: MathContent(source: "\\sqrt{x}", size: 13), progress: 0.5)
        let drawn = VectorShape(id: 1, math: math).resolvingLayout()
        XCTAssertEqual(drawn.path, MathTypesetting.layout(after)?.outline, "drawn as the new formula from the start")
        // And once it is known, it morphs.
        try insert(MathContent(source: "\\sqrt{x}", size: 13))
        XCTAssertNotEqual(VectorShape(id: 1, math: math).resolvingLayout().path, MathTypesetting.layout(after)?.outline)
    }

    func testATransitionMorphsAndAKeyframeDoesNot() {
        var d = Drawing()
        let shape = VectorShape(id: d.makeID(), math: before)
        d.layers = [Layer(id: d.makeID(), name: "Math", shapes: [shape])]
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = t.state(at: 1)
        s.layers[0].shapes[0].math = after
        t.record(s, at: 1)
        XCTAssertEqual(t.transition(into: 1, elapsed: 0.25).layers[0].shapes[0].math?.morph, MathMorphState(from: before, progress: 0.25))
        XCTAssertNil(t.state(at: 1).layers[0].shapes[0].math?.morph)
        XCTAssertEqual(t.presentation.mathContents, [before, after])
        // An unchanged formula doesn't morph.
        s.layers[0].shapes[0].math = before
        s.layers[0].shapes[0].transform.position = Vec2(10, 0)
        t.record(s, at: 1)
        XCTAssertNil(t.transition(into: 1, elapsed: 0.25).layers[0].shapes[0].math?.morph)
    }

    func testTheArtDrawsEachFrame() throws {
        var d = Drawing()
        d.viewport = Viewport(width: 400, height: 200)
        d.layers = [Layer(id: d.makeID(), name: "Math", shapes: [VectorShape(id: d.makeID(), math: before)])]
        var t = Timeline(Presentation(opening: d))
        t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = t.state(at: 1)
        s.layers[0].shapes[0].math = after
        t.record(s, at: 1)
        // A builder that drew the frames before draws each as one that starts afresh does.
        var warm = ArtBuilder()
        var last: [Float] = []
        for elapsed in [0.0, 0.3, 0.6, 0.9, 1.0] {
            let frame = t.transition(into: 1, elapsed: elapsed)
            let drawn = warm.build(frame, isolatedLayer: nil, tolerance: 0.25)
            var cold = ArtBuilder()
            XCTAssertEqual(drawn.vertices, cold.build(frame, isolatedLayer: nil, tolerance: 0.25).vertices, "at \(elapsed)")
            XCTAssertFalse(drawn.vertices.isEmpty)
            XCTAssertNotEqual(drawn.vertices, last, "each frame is drawn anew")
            last = drawn.vertices
        }
    }
}
