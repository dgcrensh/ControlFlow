import Foundation
import XCTest
@testable import ControlFlowCore

/// The demo's folder in `Schema/examples`.
private let demoFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ControlFlowCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // ControlFlowCore
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appendingPathComponent("Schema/examples/demo.controlflow")

private let first = MathContent(source: "a + b = c", size: 96)
private let second = MathContent(source: "\\frac{a}{b}")

/// A presentation showing `first` and then `second` in its place, with its package's files
/// once both are typeset.
private func package() throws -> (PresentationPackage, [String: Data]) {
    var d = Drawing()
    let shape = VectorShape(id: d.makeID(), math: first, fill: .black, transform: Transform(position: Vec2(10, 20)))
    let layer = Layer(id: d.makeID(), name: "Math", shapes: [shape])
    d.layers = [layer]
    var t = Timeline(Presentation(opening: d))
    t.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
    var s = t.state(at: 1)
    s.layers[0].shapes[0].math = second
    t.record(s, at: 1)
    MathTypesetting.insert([first: try FixtureMathTypesetter.layout(first), second: try FixtureMathTypesetter.layout(second)],
                           engine: "mathjax-4.1.3/newcm")
    let package = PresentationPackage(presentation: t.presentation)
    return (package, package.files())
}

/// `math.json` in the package and the HTML export.
final class MathPackageTests: XCTestCase {
    override func setUp() {
        MathTypesetting.reset()
    }

    override func tearDown() {
        MathTypesetting.reset()
        MathTypesetting.typesetter = nil
    }

    func testTheLayoutsRoundTripByteForByte() throws {
        let (_, files) = try package()
        let math = try XCTUnwrap(files[MathFile.fileName])
        let json = try JSONValue(parsing: math)
        XCTAssertEqual(json["engine"], .string("mathjax-4.1.3/newcm"))
        guard case .array(let formulas)? = json["formulas"] else { return XCTFail("no formulas") }
        XCTAssertEqual(formulas.map { $0["math"] }, [SceneJSON.math(first), SceneJSON.math(second)], "in the order they are shown")
        guard case .object(let glyphs)? = json["glyphs"] else { return XCTFail("no glyph table") }
        XCTAssertEqual(glyphs.map(\.key), ["NCM-I-1D44E", "NCM-N-2B", "NCM-I-1D44F", "NCM-N-3D", "NCM-I-1D450"],
                       "each glyph once, a and b shared by both formulas")

        // Opened afresh, every formula is laid out from the file, and saves the same bytes.
        MathTypesetting.reset()
        let reopened = try PresentationPackage(files: files)
        let layout = try XCTUnwrap(MathTypesetting.layout(first))
        let typeset = try FixtureMathTypesetter.layout(first)
        XCTAssertEqual(layout.glyphs.map(\.key), typeset.glyphs.map(\.key))
        XCTAssertEqual(layout.glyphs.map(\.source), typeset.glyphs.map(\.source))
        for (a, b) in zip(layout.glyphs, typeset.glyphs) {
            XCTAssertTrue(a.place.isApproximately(b.place, tolerance: 1e-4), "\(a.place) \(b.place)")
        }
        XCTAssertEqual(layout.bounds.width, typeset.bounds.width, accuracy: 1e-4)
        XCTAssertEqual(layout.baseline, typeset.baseline, accuracy: 1e-4)
        XCTAssertEqual(MathTypesetting.layout(second)?.rules.count, 1)
        XCTAssertEqual(reopened.files()[MathFile.fileName], math)
    }

    func testAFileWithoutMathJSONOpensWithFormulasUnlaidOut() throws {
        var (_, files) = try package()
        files[MathFile.fileName] = nil
        MathTypesetting.reset()
        let reopened = try PresentationPackage(files: files)
        XCTAssertNil(MathTypesetting.layout(first))
        let drawn = reopened.presentation.opening.world.layers[0].shapes[0]
        XCTAssertTrue(drawn.path.points.isEmpty, "a placeholder until it is typeset")
        XCTAssertNil(reopened.files()[MathFile.fileName], "nothing known, nothing written")
    }

    func testADamagedMathJSONIsIgnored() throws {
        var (_, files) = try package()
        for damaged in ["not json", "{ \"formulas\": 3 }", "{ \"engine\": \"x\", \"glyphs\": {}, \"formulas\": [{ \"math\": { \"source\": \"a + b = c\", \"size\": 96 }, \"box\": [1, 2], \"baseline\": 1, \"glyphs\": [{ \"key\": \"missing\", \"place\": [1, 0, 0, 1, 0, 0] }], \"rules\": [] }] }"] {
            files[MathFile.fileName] = Data(damaged.utf8)
            MathTypesetting.reset()
            XCTAssertNoThrow(try PresentationPackage(files: files), damaged)
            XCTAssertNil(MathTypesetting.layout(first), damaged)
        }
    }

    func testLayoutsOfFormulasNoLongerShownAreNotWritten() throws {
        var (package, _) = try package()
        // The second keyframe goes, and with it the fraction.
        var t = Timeline(package.presentation)
        t.deleteKeyframe(t.presentation.keyframes.last!.id)
        package.presentation = t.presentation
        let json = try JSONValue(parsing: try XCTUnwrap(package.files()[MathFile.fileName]))
        guard case .array(let formulas)? = json["formulas"] else { return XCTFail("no formulas") }
        XCTAssertEqual(formulas.map { $0["math"] }, [SceneJSON.math(first)])
    }

    func testAFrozenLayoutSurvivesANewerTypesetter() async throws {
        let (_, files) = try package()
        MathTypesetting.reset()
        _ = try PresentationPackage(files: files)
        let frozen = MathTypesetting.layout(first)
        // A typesetter that would set everything as an x.
        MathTypesetting.typesetter = OtherTypesetter()
        let layout = await MathTypesetting.typeset(first)
        XCTAssertEqual(layout, frozen, "the file's layout is kept")
        XCTAssertEqual(layout?.glyphs.count, 5)
    }

    func testTwoEnginesEachNameTheirOwn() throws {
        var (package, _) = try package()
        MathTypesetting.insert([second: try FixtureMathTypesetter.layout(second)], engine: "mathjax-9/other")
        let files = package.files()
        let json = try JSONValue(parsing: try XCTUnwrap(files[MathFile.fileName]))
        XCTAssertNil(json["engine"])
        guard case .array(let formulas)? = json["formulas"] else { return XCTFail("no formulas") }
        XCTAssertEqual(formulas.map { $0["engine"] }, [.string("mathjax-4.1.3/newcm"), .string("mathjax-9/other")])
        MathTypesetting.reset()
        package = try PresentationPackage(files: files)
        XCTAssertEqual(MathTypesetting.entry(second)?.engine, "mathjax-9/other")
        XCTAssertEqual(MathTypesetting.entry(first)?.engine, "mathjax-4.1.3/newcm")
    }

    func testTheHTMLExportWritesTheSameFile() throws {
        let (package, files) = try package()
        let export = try HTMLExport.files(for: package.presentation)
        XCTAssertEqual(export[MathFile.fileName], files[MathFile.fileName])
    }

    /// The demo's `math.json` is what the fixtures typeset; `UPDATE_VECTORS=1` writes it afresh.
    func testTheExampleHasItsFormulasLaidOut() throws {
        let presentation = try PresentationFormat.decode(JSONValue(parsing: Data(contentsOf: demoFolder.appendingPathComponent("presentation.json")))).presentation
        let maths = presentation.mathContents
        XCTAssertEqual(maths.map(\.source), ["a + b = c", "a = c - b"])
        var layouts: [MathContent: MathLayout] = [:]
        for math in maths { layouts[math] = try FixtureMathTypesetter.layout(math) }
        MathTypesetting.insert(layouts, engine: FixtureMathTypesetter().engine)
        let expected = String(decoding: try XCTUnwrap(MathFile.data(for: maths)), as: UTF8.self)
        let url = demoFolder.appendingPathComponent(MathFile.fileName)
        if ProcessInfo.processInfo.environment["UPDATE_VECTORS"] == "1" {
            try Data(expected.utf8).write(to: url)
            return
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: url), as: UTF8.self), expected,
                       "regenerate with UPDATE_VECTORS=1 swift test --filter MathPackageTests")
    }
}

/// Sets every formula as an x.
private struct OtherTypesetter: MathTypesetter {
    let engine = "other"

    func typeset(_ math: MathContent) async throws(MathError) -> String {
        try await FixtureMathTypesetter().typeset(MathContent(source: "\\sqrt{x}"))
    }
}
