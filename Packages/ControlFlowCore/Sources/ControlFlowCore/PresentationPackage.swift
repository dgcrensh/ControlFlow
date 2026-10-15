import Foundation

/// The contents of a `.controlflow` document package: `presentation.json`, an optional
/// `thumbnail.png`, the pixels of any reference images under `references/`, and those of
/// image shapes under `images/`.
///
/// The package is handled as a map from package-relative path to file bytes, so it
/// is independent of how the app reads and writes folders.
public struct PresentationPackage: Hashable, Sendable {
    public static let presentationFile = "presentation.json"
    public static let thumbnailFile = "thumbnail.png"
    public static let referencesFolder = "references"

    public var presentation: Presentation
    /// Encoded image bytes (PNG or JPEG) for each reference image, by reference id.
    /// May hold images no longer in the document; only referenced ones are saved.
    public var referenceImages: [Int: Data]
    /// Encoded image bytes for image shapes, by `src` (see `ShapeImage`). May hold images
    /// no longer in the presentation; only those it shows are saved.
    public var images: [String: Data]

    public init(presentation: Presentation = Presentation(), referenceImages: [Int: Data] = [:],
                images: [String: Data] = [:]) {
        self.presentation = presentation
        self.referenceImages = referenceImages
        self.images = images
    }

    /// The opening state, which holds the reference images.
    public var drawing: Drawing { presentation.opening }

    /// Reads a package from its files, keyed by path relative to the package root.
    /// A reference image or image shape whose file is missing is kept without pixels.
    public init(files: [String: Data]) throws {
        guard let data = files[Self.presentationFile] else {
            throw PresentationFileError.missingFile(Self.presentationFile)
        }
        let json: JSONValue
        do {
            json = try JSONValue(parsing: data)
        } catch let error as JSONParseError {
            throw PresentationFileError.invalidJSON(error.description)
        }
        let decoded = try PresentationFormat.decode(json)
        var images: [Int: Data] = [:]
        for (id, file) in decoded.referenceFiles {
            if let image = files[Self.normalizedPath(file)] { images[id] = image }
        }
        var shapeImages: [String: Data] = [:]
        for src in decoded.presentation.imageSources {
            if let image = files[src] { shapeImages[src] = image }
        }
        self.init(presentation: decoded.presentation, referenceImages: images, images: shapeImages)
    }

    /// The package's files. Reference images are named by their stacking order, and the
    /// images of image shapes are at their `src`.
    public func files(thumbnail: Data? = nil) -> [String: Data] {
        var files: [String: Data] = [:]
        var names: [Int: String] = [:]
        for (index, ref) in drawing.references.enumerated() {
            guard let image = referenceImages[ref.id] else { continue }
            let name = "\(Self.referencesFolder)/reference-\(index + 1).\(Self.fileExtension(for: image))"
            names[ref.id] = name
            files[name] = image
        }
        for src in presentation.imageSources {
            if let image = images[src] { files[src] = image }
        }
        let json = PresentationFormat.encode(presentation, referenceFiles: names)
        files[Self.presentationFile] = Data(json.formatted().utf8)
        if let thumbnail { files[Self.thumbnailFile] = thumbnail }
        return files
    }

    /// The image format's usual extension, from the file's first bytes.
    public static func fileExtension(for data: Data) -> String {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if bytes.count >= 12, Array(bytes[4...7]) == [0x66, 0x74, 0x79, 0x70] { return "heic" }
        return "img"
    }

    static func normalizedPath(_ path: String) -> String {
        var p = Substring(path)
        while p.hasPrefix("./") { p = p.dropFirst(2) }
        return String(p)
    }
}
