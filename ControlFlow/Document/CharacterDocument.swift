import ControlFlowCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.charstudio` folder package. Declared in Config/Info.plist.
    static let characterStudio = UTType(exportedAs: "com.dgcrensh.characterstudio.character")
}

/// A document saved in the Files app as a `.charstudio` package holding
/// `character.json`, `thumbnail.png` and any reference images. This is the interim
/// save; the presentation format replaces it in milestone 3.
///
/// The editor works on its own `CanvasStore` and copies the drawing back into the
/// document after each finished change, which marks it edited so it autosaves.
struct CharacterDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.characterStudio] }

    var package: CharacterPackage

    init(package: CharacterPackage = CharacterPackage()) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        let interval = Signposts.canvas.beginInterval("Open")
        defer { Signposts.canvas.endInterval("Open", interval) }
        package = try CharacterPackage(files: Self.files(in: configuration.file))
    }

    /// Runs off the main thread, for each autosave.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let interval = Signposts.canvas.beginInterval("Save")
        defer { Signposts.canvas.endInterval("Save", interval) }
        let thumbnail = ThumbnailRenderer.png(for: package.drawing)
        return Self.folder(from: package.files(thumbnail: thumbnail))
    }

    /// Flattens a package folder into package-relative paths such as `references/a.png`.
    private static func files(in wrapper: FileWrapper, prefix: String = "") -> [String: Data] {
        var out: [String: Data] = [:]
        for (name, child) in wrapper.fileWrappers ?? [:] {
            let path = prefix + name
            if child.isDirectory {
                out.merge(files(in: child, prefix: path + "/")) { first, _ in first }
            } else if let data = child.regularFileContents {
                out[path] = data
            }
        }
        return out
    }

    /// Builds a folder wrapper, with subfolders, from package-relative paths.
    private static func folder(from files: [String: Data]) -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        var subfolders: [String: [String: Data]] = [:]
        for (path, data) in files {
            if let slash = path.firstIndex(of: "/") {
                let folder = String(path[..<slash])
                subfolders[folder, default: [:]][String(path[path.index(after: slash)...])] = data
            } else {
                children[path] = FileWrapper(regularFileWithContents: data)
            }
        }
        for (name, contents) in subfolders {
            children[name] = folder(from: contents)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }
}
