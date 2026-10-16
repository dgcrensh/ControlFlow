import Foundation
import XCTest
@testable import ControlFlowCore

/// `MathLayout.parse(svg:content:)` on MathJax's real output (`Fixtures/math`).
final class MathLayoutTests: XCTestCase {
    private func layout(_ source: String, size: Double = 72, display: Bool = true) throws -> MathLayout {
        try FixtureMathTypesetter.layout(MathContent(source: source, size: size, display: display))
    }

    func testEveryListedFormulaHasItsFixture() throws {
        let data = try Data(contentsOf: FixtureMathTypesetter.folder.appendingPathComponent("sources.json"))
        guard case .array(let sources) = try JSONValue(parsing: data) else { return XCTFail("sources.json is not a list") }
        XCTAssertFalse(sources.isEmpty)
        for entry in sources {
            guard case .string(let source)? = entry["source"] else { return XCTFail("an entry has no source") }
            var display = true
            if case .bool(let d)? = entry["display"] { display = d }
            let math = MathContent(source: source, display: display)
            XCTAssertNotNil(FixtureMathTypesetter.svg(math), "no fixture for \(source): run node Schema/typeset_math.mjs")
            XCTAssertNoThrow(try MathLayout.parse(svg: FixtureMathTypesetter.svg(math) ?? "", content: math), source)
        }
    }

    func testGlyphsAreInReadingOrderWithTheirKeys() throws {
        let l = try layout("a^2+b^2=c^2")
        XCTAssertEqual(l.glyphs.map(\.key), ["NCM-I-1D44E", "NCM-N-32", "NCM-N-2B", "NCM-I-1D44F", "NCM-N-32", "NCM-N-3D",
                                            "NCM-I-1D450", "NCM-N-32"])
        XCTAssertEqual(l.glyphs.map(\.source), ["a", "2", "+", "b", "2", "=", "c", "2"])
        XCTAssertEqual(l.outlines.count, 6, "each distinct glyph's outline once")
        XCTAssertTrue(l.rules.isEmpty)
        // Left to right.
        let xs = l.glyphs.map { $0.place.tx }
        XCTAssertEqual(xs, xs.sorted())
        // An exponent is smaller and higher (y down) than its base.
        XCTAssertLessThan(abs(l.glyphs[1].place.a), abs(l.glyphs[0].place.a))
        XCTAssertLessThan(l.glyphs[1].place.ty, l.glyphs[0].place.ty)
    }

    func testTheBoxAndBaselineAreInPointsWithYDown() throws {
        // viewBox="0 -883.9 5256.7 966.9": 1000 units per em, at 72 points per em.
        let l = try layout("a^2+b^2=c^2")
        XCTAssertEqual(l.bounds.minPoint, .zero)
        XCTAssertEqual(l.bounds.width, 5256.7 * 0.072, accuracy: 1e-9)
        XCTAssertEqual(l.bounds.height, 966.9 * 0.072, accuracy: 1e-9)
        XCTAssertEqual(l.baseline, 883.9 * 0.072, accuracy: 1e-9)
        // The glyphs sit on the baseline, flipped: a glyph's y up becomes y down.
        XCTAssertEqual(l.glyphs[0].place, Affine2D(a: 0.072, b: 0, c: 0, d: -0.072, tx: 0, ty: l.baseline))
        let outline = l.outline.bounds()
        XCTAssertGreaterThanOrEqual(outline.minPoint.y, -1e-6)
        XCTAssertLessThanOrEqual(outline.maxPoint.y, l.bounds.height + 1e-6)
        XCTAssertGreaterThan(outline.width, l.bounds.width * 0.9)
        // Twice the size, twice as big.
        let big = try layout("a^2+b^2=c^2", size: 144)
        XCTAssertEqual(big.bounds.width, l.bounds.width * 2, accuracy: 1e-9)
        XCTAssertEqual(big.glyphs[3].place.tx, l.glyphs[3].place.tx * 2, accuracy: 1e-9)
    }

    func testAFractionHasOneRuleBetweenItsGlyphs() throws {
        let l = try layout("\\frac{a}{b}")
        XCTAssertEqual(l.glyphs.map(\.key), ["NCM-I-1D44E", "NCM-I-1D44F"])
        XCTAssertEqual(l.rules.count, 1)
        let rule = l.rules[0]
        // <rect width="729" height="60" x="120" y="220"/> under scale(1,-1), viewBox top at -1118.
        XCTAssertEqual(rule.minPoint.x, 120 * 0.072, accuracy: 1e-9)
        XCTAssertEqual(rule.width, 729 * 0.072, accuracy: 1e-9)
        XCTAssertEqual(rule.height, 60 * 0.072, accuracy: 1e-9)
        XCTAssertEqual(rule.minPoint.y, (1118 - 280) * 0.072, accuracy: 1e-9)
        XCTAssertLessThan(l.glyphs[0].place.ty, rule.minPoint.y, "the numerator's baseline is above the bar")
        XCTAssertGreaterThan(l.glyphs[1].place.ty, rule.maxPoint.y, "the denominator's is below it")
    }

    func testMatricesUseSizedDelimiters() throws {
        let l = try layout("\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}")
        let keys = l.glyphs.map(\.key)
        XCTAssertEqual(keys.filter { $0.hasSuffix("-31") || $0.hasSuffix("-32") || $0.hasSuffix("-33") || $0.hasSuffix("-34") }.count, 4)
        XCTAssertTrue(keys.first!.hasSuffix("-28") && keys.first! != "NCM-N-28", "a size variant of (: \(keys.first!)")
        XCTAssertTrue(keys.last!.hasSuffix("-29") && keys.last! != "NCM-N-29", "a size variant of ): \(keys.last!)")
    }

    func testStretchedExtendersStayInTheirWindow() throws {
        // A tall ( is built of a top, an extender cut to length by a nested <svg>, and a
        // bottom; the extender must end within the formula's box.
        let l = try layout("\\left(\\begin{matrix}1\\\\3\\\\5\\\\7\\\\9\\end{matrix}\\right)")
        let outline = l.outline.bounds()
        XCTAssertGreaterThanOrEqual(outline.minPoint.y, l.bounds.minPoint.y - 1e-6)
        XCTAssertLessThanOrEqual(outline.maxPoint.y, l.bounds.maxPoint.y + 1e-6)
        XCTAssertTrue(l.glyphs.contains { $0.key == "NCM-N-239C" }, "the extender is there")
    }

    func testClassTagsTheGlyphsInside() throws {
        let l = try layout("\\class{lhs}{a+b}=c")
        XCTAssertEqual(l.glyphs.map(\.tags), [["lhs"], ["lhs"], ["lhs"], [], []])
    }

    func testEntitiesInTheSourceAreDecoded() throws {
        let l = try layout("x < y \\text{ if } a \\& b")
        XCTAssertTrue(l.glyphs.contains { $0.source == "<" }, "\(l.glyphs.map(\.source))")
        XCTAssertTrue(l.glyphs.contains { $0.source == "\\&" })
    }

    func testInlineStyleIsSmaller() throws {
        let display = try layout("\\sum_{k=1}^n k")
        let inline = try layout("\\sum_{k=1}^n k", display: false)
        XCTAssertLessThan(inline.bounds.height, display.bounds.height)
    }

    func testKeysDropMathJaxsPrefix() {
        XCTAssertEqual(MathLayout.glyphKey("MJX-12-NCM-I-1D44E"), "NCM-I-1D44E")
        XCTAssertEqual(MathLayout.glyphKey("NCM-I-1D44E"), "NCM-I-1D44E")
        XCTAssertEqual(MathLayout.glyphKey("MJX-x-A"), "MJX-x-A")
    }

    func testMalformedSVGThrows() {
        let math = MathContent(source: "x")
        XCTAssertThrowsError(try MathLayout.parse(svg: "", content: math))
        XCTAssertThrowsError(try MathLayout.parse(svg: "<svg><g></g></svg>", content: math), "no viewBox")
        XCTAssertThrowsError(try MathLayout.parse(svg: "<div>not math</div>", content: math))
    }
}
