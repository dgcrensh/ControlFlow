import XCTest
@testable import ControlFlowCore

/// How the canvas copes with formulas whose layouts come later: it asks for them, draws
/// a placeholder box meanwhile, and draws the glyphs once they arrive (LaTeX PR 2).
final class MathDrawingTests: XCTestCase {
    private let sum = MathContent(source: "a + b = c")
    private let frac = MathContent(source: "\\frac{a}{b}")

    override func setUp() {
        MathTypesetting.reset()
        MathTypesetting.typesetter = nil
    }

    override func tearDown() {
        MathTypesetting.reset()
        MathTypesetting.typesetter = nil
    }

    /// One layer with `maths` side by side, and a second layer with a square.
    private func drawing(_ maths: [MathContent]) -> Drawing {
        var d = Drawing()
        var shapes: [VectorShape] = []
        for (i, math) in maths.enumerated() {
            shapes.append(VectorShape(id: d.makeID(), math: math, fill: .black,
                                      transform: Transform(position: Vec2(Double(i) * 300, 0))))
        }
        let square = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: Vec2(0, 400), maxPoint: Vec2(100, 500))),
                                 fill: .black)
        d.layers = [Layer(id: d.makeID(), name: "Math", shapes: shapes), Layer(id: d.makeID(), name: "Square", shapes: [square])]
        return d
    }

    func testStoringOrForgettingLayoutsBumpsTheGeneration() throws {
        let start = MathTypesetting.generation
        MathTypesetting.insert([sum: try FixtureMathTypesetter.layout(sum)], engine: "test")
        XCTAssertGreaterThan(MathTypesetting.generation, start)
        let inserted = MathTypesetting.generation
        _ = MathTypesetting.layout(sum)
        XCTAssertEqual(MathTypesetting.generation, inserted, "reading changes nothing")
        MathTypesetting.forget([sum])
        XCTAssertGreaterThan(MathTypesetting.generation, inserted)
    }

    func testATypesetBumpsTheGenerationBeforeItsCallback() async {
        MathTypesetting.typesetter = FixtureMathTypesetter()
        let start = MathTypesetting.generation
        let seen = await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            MathTypesetting.request(frac) { continuation.resume(returning: MathTypesetting.generation) }
        }
        XCTAssertGreaterThan(seen, start)
        XCTAssertNotNil(MathTypesetting.layout(frac))
    }

    func testRequestMissingAsksOnlyForWhatIsUnknown() async throws {
        let d = drawing([sum, frac, sum, MathContent(source: "\\frac{a}{")])
        XCTAssertEqual(MathTypesetting.requestMissing(in: d) {}, 0, "nothing without a typesetter")

        MathTypesetting.insert([sum: try FixtureMathTypesetter.layout(sum)], engine: "test")
        let typesetter = CountingTypesetter()
        MathTypesetting.typesetter = typesetter
        let arrived = expectation(description: "arrived")
        arrived.expectedFulfillmentCount = 2
        XCTAssertEqual(MathTypesetting.requestMissing(in: d) { arrived.fulfill() }, 2, "the fraction and the broken one")
        XCTAssertEqual(MathTypesetting.requestMissing(in: d) {}, 0, "both are under way")
        await fulfillment(of: [arrived], timeout: 5)
        XCTAssertNotNil(MathTypesetting.layout(frac))
        XCTAssertNotNil(MathTypesetting.error(MathContent(source: "\\frac{a}{")))
        XCTAssertEqual(MathTypesetting.requestMissing(in: d) {}, 0, "known or failed")
        XCTAssertEqual(typesetter.count, 2)
    }

    func testAFormulaWithoutALayoutDrawsItsPlaceholder() throws {
        let shape = VectorShape(id: 1, math: frac, fill: .black).resolvingLayout()
        let placeholder = try XCTUnwrap(shape.placeholderForMissingLayout)
        XCTAssertEqual(placeholder.path.bounds(), MathLayout.placeholder(frac))
        XCTAssertEqual(placeholder.fill?.a ?? 0, 0.12, accuracy: 1e-9)
        XCTAssertNotNil(placeholder.stroke)

        MathTypesetting.insert([frac: try FixtureMathTypesetter.layout(frac)], engine: "test")
        XCTAssertNil(shape.placeholderForMissingLayout, "its layout is known")
        let square = VectorShape(id: 2, path: ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(1, 1))), fill: .black)
        XCTAssertNil(square.placeholderForMissingLayout)
    }

    func testTheArtRebuildsOnlyLayersWithFormulasWhenLayoutsArrive() throws {
        let d = drawing([sum, frac])
        var builder = ArtBuilder()
        let before = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        let builds = builder.layerBuilds
        XCTAssertEqual(builder.build(d, isolatedLayer: nil, tolerance: 0.5).vertices, before.vertices)
        XCTAssertEqual(builder.layerBuilds, builds, "nothing changed")

        MathTypesetting.insert([sum: try FixtureMathTypesetter.layout(sum), frac: try FixtureMathTypesetter.layout(frac)],
                               engine: "test")
        let after = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(builder.layerBuilds, builds + 1, "the formulas' layer, not the square's")
        XCTAssertNotEqual(after.vertices, before.vertices)
        var cold = ArtBuilder()
        XCTAssertEqual(after.vertices, cold.build(d, isolatedLayer: nil, tolerance: 0.5).vertices, "as a fresh build draws it")

        _ = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertEqual(builder.layerBuilds, builds + 1, "and then it is reused")
    }
}
