import Foundation
import XCTest
@testable import ControlFlowCore

/// The HTML export: the folder's files and the presentation it carries. How the player
/// plays is checked against the test vectors by `Schema/test_player.js`.
final class HTMLExportTests: XCTestCase {
    private func demo() throws -> PresentationPackage {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Schema/examples/demo.controlflow")
        var files: [String: Data] = [:]
        for name in ["presentation.json", "references/reference-1.png"] {
            files[name] = try Data(contentsOf: url.appendingPathComponent(name))
        }
        return try PresentationPackage(files: files)
    }

    func testTheFolderHoldsThePagePlayerAndPresentation() throws {
        let files = try HTMLExport.files(for: try demo().presentation)
        XCTAssertEqual(Set(files.keys), ["index.html", "player.js", "presentation.json", "text.json"])
        let page = try XCTUnwrap(files["index.html"].flatMap { String(data: $0, encoding: .utf8) })
        // Relative paths only, so the folder can be served from anywhere.
        XCTAssertTrue(page.contains("<script src=\"player.js\"></script>"))
        for absolute in ["src=\"/", "src=\"http", "href=\"/", "href=\"http"] { XCTAssertFalse(page.contains(absolute), absolute) }
        let player = try XCTUnwrap(files["player.js"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(player.contains("fetch('presentation.json'"))
        XCTAssertTrue(player.contains("function renderScene("))
    }

    func testThePresentationIsTheSameFileWithoutReferences() throws {
        let package = try demo()
        XCTAssertFalse(package.presentation.opening.references.isEmpty)
        let files = try HTMLExport.files(for: package.presentation)
        let exported = try PresentationPackage(files: ["presentation.json": try XCTUnwrap(files["presentation.json"])])
        XCTAssertTrue(exported.presentation.opening.references.isEmpty)
        var expected = package.presentation
        expected.opening.references = []
        XCTAssertEqual(exported.presentation.sequences, expected.sequences)
        XCTAssertEqual(exported.presentation.opening.layers, expected.opening.layers)
        XCTAssertEqual(exported.presentation.opening.viewport, expected.opening.viewport)
        XCTAssertEqual(exported.presentation.opening.globalColors, expected.opening.globalColors)
        // Byte for byte what saving it without references writes.
        XCTAssertEqual(files["presentation.json"], Data(PresentationFormat.encode(expected).formatted().utf8))
    }

    func testTextJSONLaysOutEveryTextTheKeyframesShow() throws {
        let files = try HTMLExport.files(for: try demo().presentation)
        let json = try JSONValue(parsing: try XCTUnwrap(files["text.json"]))
        guard case .array(let texts)? = json["texts"] else { return XCTFail("no texts") }
        // The title as it opens, spread out, and with new words (its spacing coming back
        // as they arrive is the last layout, adjusted by the player).
        let shown = texts.compactMap { entry -> String? in
            guard case .string(let string)? = entry["text"]?["string"] else { return nil }
            guard case .number(let tracking)? = entry["text"]?["tracking"] else { return string }
            return "\(string), tracking \(Int(tracking))"
        }
        XCTAssertEqual(shown, ["Hello", "Hello, tracking 24", "Nice to meet you"])
        // Glyphs carry their outlines; spaces draw nothing and are left out.
        guard case .array(let glyphs)? = texts[2]["glyphs"] else { return XCTFail("no glyphs") }
        XCTAssertEqual(glyphs.count, "Nicetomeetyou".count)
        guard case .array(let contours)? = glyphs[0]["contours"], case .array(let numbers)? = contours.first else {
            return XCTFail("no contours")
        }
        XCTAssertEqual(numbers.count % 6, 0)

        // No text, no text.json.
        XCTAssertNil(try HTMLExport.files(for: Presentation())["text.json"])
    }

    func testThePageIsTitledWithTheName() throws {
        var presentation = Presentation()
        presentation.opening.name = "Q3 <Plan> & \"Goals\""
        let files = try HTMLExport.files(for: presentation)
        let page = try XCTUnwrap(files["index.html"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(page.contains("<title>Q3 &lt;Plan&gt; &amp; &quot;Goals&quot;</title>"))
        presentation.opening.name = ""
        let untitled = try XCTUnwrap(try HTMLExport.files(for: presentation)["index.html"].flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(untitled.contains("<title>Untitled</title>"))
    }
}
