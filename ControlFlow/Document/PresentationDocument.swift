import ControlFlowCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.controlflow` folder package. Declared in Config/Info.plist.
    static let controlFlowPresentation = UTType(exportedAs: "com.dgcrensh.controlflow.presentation")
}

/// A document saved in the Files app as a `.controlflow` package holding
/// `presentation.json`, `thumbnail.png` and any reference images (see Schema/README.md).
///
/// The editor works on its own `CanvasStore` and copies the presentation back into the
/// document after each finished change, which marks it edited so it autosaves.
struct PresentationDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.controlFlowPresentation] }

    var package: PresentationPackage

    init(package: PresentationPackage = PresentationPackage()) {
        self.package = package
    }

    init(configuration: ReadConfiguration) throws {
        let interval = Signposts.canvas.beginInterval("Open")
        defer { Signposts.canvas.endInterval("Open", interval) }
        package = try PresentationPackage(files: Self.files(in: configuration.file))
    }

    /// Runs off the main thread, for each autosave.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let interval = Signposts.canvas.beginInterval("Save")
        defer { Signposts.canvas.endInterval("Save", interval) }
        // The opening state stands for the presentation.
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
    static func folder(from files: [String: Data]) -> FileWrapper {
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
