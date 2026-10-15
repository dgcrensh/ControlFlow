import Foundation

/// The presentation as a static web page: a folder that any web server, GitHub Pages
/// included, serves as is. It holds `index.html`, `player.js`, `presentation.json`
/// (the same file the app saves) and, when there is text, `text.json` (its glyph
/// outlines, since a browser can't be counted on to have the fonts) and the pictures of
/// image shapes at their `src` (`images/...`), uses relative paths and needs no build step. The player plays it as presentation mode does, with the same inputs plus
/// swipes, and the address's hash (`#3`) opens it with that many sequences played.
///
/// `index.html` and `player.js` are the files in `Player/`; the player ports the
/// playing and drawing code and is checked against `Schema/vectors` by
/// `Schema/test_player.js`. Reference images are editor-only and stay out.
public enum HTMLExport {
    public static let pageFile = "index.html"
    public static let playerFile = "player.js"
    public static let textFile = "text.json"

    public enum ExportError: Error, Equatable {
        /// A file of the player is missing from the build.
        case missingResource(String)
    }

    /// The folder's files, by path within it. `images` holds the encoded pixels of image
    /// shapes by `src`; those the presentation shows are copied in.
    public static func files(for presentation: Presentation, images: [String: Data] = [:]) throws -> [String: Data] {
        var presentation = presentation
        presentation.opening.references = []
        let json = PresentationFormat.encode(presentation)
        var files = [
            pageFile: Data(page(title: presentation.opening.name, template: try resource(pageFile)).utf8),
            playerFile: Data(try resource(playerFile).utf8),
            PresentationPackage.presentationFile: Data(json.formatted().utf8),
        ]
        if let texts = try textLayouts(json) { files[textFile] = Data(texts.formatted().utf8) }
        for src in presentation.imageSources {
            if let image = images[src] { files[src] = image }
        }
        return files
    }

    /// `text.json` for the presentation file `json`: the layout of every text the
    /// presentation shows at a keyframe, or nil when it has none. The texts are read
    /// back from `json`, so they are exactly what the player reads. A text partway
    /// through a transition is laid out as it is at the transition's end (`held`), so
    /// these cover every frame; the player moves the glyphs for the tracking and line
    /// height in between as `TextLayout.adjusted` does.
    ///
    /// `{ "texts": [{ "text", "boxWidth", "lines": [{ "x", "width", "top", "height",
    /// "baseline", "glyphCount" }], "glyphs": [{ "origin", "line", "index", "contours" }] }] }`,
    /// each contour a flat list of `x, y, inX, inY, outX, outY` per point (handles as
    /// offsets, as in the file), relative to the glyph's origin.
    static func textLayouts(_ json: JSONValue) throws -> JSONValue? {
        var timeline = Timeline(try PresentationFormat.decode(json).presentation)
        var seen = Set<TextContent>()
        var texts: [TextContent] = []
        for index in 0..<timeline.count {
            for layer in timeline.state(at: index).layers {
                for shape in layer.shapes {
                    guard var text = shape.text else { continue }
                    text.held = nil
                    if seen.insert(text).inserted { texts.append(text) }
                }
            }
        }
        guard !texts.isEmpty else { return nil }
        return JSONValue.object([(key: "texts", value: .array(texts.map(textLayout)))]).rounded()
    }

    static func textLayout(_ text: TextContent) -> JSONValue {
        let layout = TextShaping.layout(text)
        func number(_ v: Double) -> JSONValue { .number(v) }
        let lines: [JSONValue] = layout.lines.map { line in
            .object([
                (key: "x", value: number(line.x)), (key: "width", value: number(line.width)),
                (key: "top", value: number(line.top)), (key: "height", value: number(line.height)),
                (key: "baseline", value: number(line.baseline)), (key: "glyphCount", value: number(Double(line.glyphCount))),
            ])
        }
        // Spaces draw nothing, so only inked glyphs are written.
        let glyphs: [JSONValue] = layout.glyphs.filter { !$0.contours.isEmpty }.map { glyph in
            let contours: [JSONValue] = glyph.contours.filter { $0.points.count >= 2 }.map { contour in
                .array(contour.points.flatMap { p in
                    [p.position.x, p.position.y, p.inHandle.x, p.inHandle.y, p.outHandle.x, p.outHandle.y].map(number)
                })
            }
            return .object([
                (key: "origin", value: .array([number(glyph.origin.x), number(glyph.origin.y)])),
                (key: "line", value: number(Double(glyph.line))), (key: "index", value: number(Double(glyph.index))),
                (key: "contours", value: .array(contours)),
            ])
        }
        return .object([
            (key: "text", value: SceneJSON.text(text)), (key: "boxWidth", value: number(layout.boxWidth)),
            (key: "lines", value: .array(lines)), (key: "glyphs", value: .array(glyphs)),
        ])
    }

    /// The page with the presentation's name as its title (the player sets it too, once
    /// it has read the file).
    static func page(title: String, template: String) -> String {
        let name = title.isEmpty ? "Untitled" : title
        return template.replacingOccurrences(of: "<title>ControlFlow</title>", with: "<title>\(SVGWriter.escaped(name))</title>")
    }

    static func resource(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: name)
        guard let url = Bundle.module.url(forResource: file.deletingPathExtension().lastPathComponent,
                                          withExtension: file.pathExtension, subdirectory: "Player"),
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else { throw ExportError.missingResource(name) }
        return text
    }
}
