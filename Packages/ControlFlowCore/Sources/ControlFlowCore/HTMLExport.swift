import Foundation

/// The presentation as a static web page: a folder that any web server, GitHub Pages
/// included, serves as is. It holds `index.html`, `player.js` and `presentation.json`
/// (the same format 1.0 file the app saves), uses relative paths and needs no build
/// step. The player plays it as presentation mode does, with the same inputs plus
/// swipes, and the address's hash (`#3`) opens it with that many sequences played.
///
/// `index.html` and `player.js` are the files in `Player/`; the player ports the
/// playing and drawing code and is checked against `Schema/vectors` by
/// `Schema/test_player.js`. Reference images are editor-only and stay out.
public enum HTMLExport {
    public static let pageFile = "index.html"
    public static let playerFile = "player.js"

    public enum ExportError: Error, Equatable {
        /// A file of the player is missing from the build.
        case missingResource(String)
    }

    /// The folder's files, by path within it.
    public static func files(for presentation: Presentation) throws -> [String: Data] {
        var presentation = presentation
        presentation.opening.references = []
        let json = PresentationFormat.encode(presentation)
        return [
            pageFile: Data(page(title: presentation.opening.name, template: try resource(pageFile)).utf8),
            playerFile: Data(try resource(playerFile).utf8),
            PresentationPackage.presentationFile: Data(json.formatted().utf8),
        ]
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
