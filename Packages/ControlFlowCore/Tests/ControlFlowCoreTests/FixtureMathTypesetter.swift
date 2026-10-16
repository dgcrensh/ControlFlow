import Foundation
@testable import ControlFlowCore

/// Typesets from `Fixtures/math`: MathJax's real output for the formulas listed in
/// `sources.json`, written by `Schema/typeset_math.mjs` with the MathJax the app
/// bundles. Anything unlisted throws, so a test can't pass on a formula nobody typeset.
struct FixtureMathTypesetter: MathTypesetter {
    let engine = "mathjax-4.1.3/newcm"

    /// The folder of fixtures in the test bundle.
    static var folder: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures").appendingPathComponent("math")
    }

    /// The fixture's file name for `source` in display or inline style: `typeset_math.mjs`'s `fileName`.
    static func fileName(source: String, display: Bool) -> String {
        ImageAssets.hash(Data("\(display ? "D" : "I")\(source)".utf8)) + ".svg"
    }

    /// MathJax's SVG for `math`, or nil when it isn't a fixture.
    static func svg(_ math: MathContent) -> String? {
        let url = folder.appendingPathComponent(fileName(source: math.source, display: math.display))
        return (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) }
    }

    /// `math` laid out from its fixture.
    static func layout(_ math: MathContent) throws -> MathLayout {
        guard let svg = svg(math) else { throw MathError(message: "No fixture for \(math.source)") }
        return try MathLayout.parse(svg: svg, content: math)
    }

    func typeset(_ math: MathContent) async throws(MathError) -> String {
        guard let svg = Self.svg(math) else {
            throw MathError(message: "No fixture for \(math.source); add it to sources.json and run Schema/typeset_math.mjs")
        }
        return svg
    }
}
