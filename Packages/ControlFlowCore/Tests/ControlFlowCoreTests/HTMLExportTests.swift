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
        XCTAssertEqual(Set(files.keys), ["index.html", "player.js", "presentation.json"])
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
