import Foundation

/// The contents of a `.charstudio` document package: `character.json`, an optional
/// `thumbnail.png`, and the pixels of any reference images under `references/`.
///
/// The package is handled as a map from package-relative path to file bytes, so it
/// is independent of how the app reads and writes folders.
public struct CharacterPackage: Hashable, Sendable {
    public static let characterFile = "character.json"
    public static let thumbnailFile = "thumbnail.png"
    public static let referencesFolder = "references"

    public var drawing: Drawing
    /// Encoded image bytes (PNG or JPEG) for each reference image, by reference id.
    /// May hold images no longer in the drawing; only referenced ones are saved.
    public var referenceImages: [Int: Data]

    public init(drawing: Drawing = Drawing(), referenceImages: [Int: Data] = [:]) {
        self.drawing = drawing
        self.referenceImages = referenceImages
    }

    /// Reads a package from its files, keyed by path relative to the package root.
    /// A reference image whose file is missing is kept without pixels.
    public init(files: [String: Data]) throws {
        guard let data = files[Self.characterFile] else {
            throw CharacterFileError.missingFile(Self.characterFile)
        }
        let json: JSONValue
        do {
            json = try JSONValue(parsing: data)
        } catch let error as JSONParseError {
            throw CharacterFileError.invalidJSON(error.description)
        }
        let decoded = try CharacterFormat.decode(json)
        var images: [Int: Data] = [:]
        for (id, file) in decoded.referenceFiles {
            if let image = files[Self.normalizedPath(file)] { images[id] = image }
        }
        self.init(drawing: decoded.drawing, referenceImages: images)
    }

    /// The package's files. Reference images are named by their stacking order.
    public func files(thumbnail: Data? = nil) -> [String: Data] {
        var files: [String: Data] = [:]
        var names: [Int: String] = [:]
        for (index, ref) in drawing.references.enumerated() {
            guard let image = referenceImages[ref.id] else { continue }
            let name = "\(Self.referencesFolder)/reference-\(index + 1).\(Self.fileExtension(for: image))"
            names[ref.id] = name
            files[name] = image
        }
        let json = CharacterFormat.encode(drawing, referenceFiles: names)
        files[Self.characterFile] = Data(json.formatted().utf8)
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
