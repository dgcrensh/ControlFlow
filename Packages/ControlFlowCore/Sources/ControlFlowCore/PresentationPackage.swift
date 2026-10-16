import Foundation

/// The contents of a `.controlflow` document package: `presentation.json`, an optional
/// `thumbnail.png`, the pixels of any reference images under `references/`, those of
/// image shapes under `images/`, and the layouts of formulas in `math.json` (see
/// `MathFile`), which go to and from `MathTypesetting` rather than being kept here.
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
    /// The formula layouts in `math.json` are given to `MathTypesetting`; a missing or
    /// unreadable one is ignored, and its formulas are typeset when next drawn.
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
        if let data = files[MathFile.fileName], let json = try? JSONValue(parsing: data) {
            MathTypesetting.insert(MathFile.read(json))
        }
        self.init(presentation: decoded.presentation, referenceImages: images, images: shapeImages)
    }

    /// The package's files. Reference images are named by their stacking order, the
    /// images of image shapes are at their `src`, and `math.json` holds the layouts
    /// `MathTypesetting` knows of the formulas the presentation shows.
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
        if let math = MathFile.data(for: presentation.mathContents) { files[MathFile.fileName] = math }
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

/// `math.json`: the layouts of a presentation's formulas, kept in the package (and the
/// HTML export) so opening, playing and exporting never typeset (see `MathTypesetting`).
/// It is a cache: a formula it leaves out is typeset on the next open.
///
/// `{ "engine", "glyphs": { key: [contour, …] }, "formulas": [{ "math", "engine"?, "box",
/// "baseline", "glyphs": [{ "key", "place", "tags"?, "source"? }], "rules": [[x, y, w, h]] }] }`.
/// Each glyph's contours are stored once for the file, each a flat list of `x, y, inX,
/// inY, outX, outY` per point (handles as offsets) in glyph units (y up, 1000 per em).
/// A formula's box, baseline, places and rules are in thousandths of an em, y down, from
/// the box's top-left: points times `1000 / size`, so 4 decimals keep a small glyph's
/// scale exact. The top-level `engine` names what made every formula; when two engines
/// made them, each formula names its own instead.
public enum MathFile {
    public static let fileName = "math.json"

    /// The file's bytes for the layouts of `maths` that are known (see `json(for:)`): each
    /// outline on a line of its own.
    public static func data(for maths: [MathContent]) -> Data? {
        json(for: maths).map { Data($0.formatted(longNumberLists: true).utf8) }
    }

    /// The file for the layouts of `maths` that are known, in that order, or nil when none is.
    public static func json(for maths: [MathContent]) -> JSONValue? {
        var entries: [(math: MathContent, entry: MathTypesetting.Entry)] = []
        for math in maths {
            if let entry = MathTypesetting.entry(math) { entries.append((math, entry)) }
        }
        guard !entries.isEmpty else { return nil }
        let engines = Set(entries.map(\.entry.engine))
        var glyphs: [(key: String, value: JSONValue)] = []
        var seen = Set<String>()
        var formulas: [JSONValue] = []
        for (math, entry) in entries {
            let layout = entry.layout
            let k = 1000 / math.size
            for glyph in layout.glyphs where seen.insert(glyph.key).inserted {
                let contours = (layout.outlines[glyph.key] ?? []).map { contour -> JSONValue in
                    .array(contour.points.flatMap { p in
                        [p.position.x, p.position.y, p.inHandle.x, p.inHandle.y, p.outHandle.x, p.outHandle.y].map(JSONValue.number)
                    })
                }
                glyphs.append((key: glyph.key, value: .array(contours)))
            }
            var members: [(key: String, value: JSONValue)] = [(key: "math", value: SceneJSON.math(math))]
            if engines.count > 1 { members.append((key: "engine", value: .string(entry.engine))) }
            members.append((key: "box", value: .array([.number(layout.bounds.width * k), .number(layout.bounds.height * k)])))
            members.append((key: "baseline", value: .number(layout.baseline * k)))
            members.append((key: "glyphs", value: .array(layout.glyphs.map { glyph in
                let m = glyph.place
                var g: [(key: String, value: JSONValue)] = [
                    (key: "key", value: .string(glyph.key)),
                    (key: "place", value: .array([m.a * k, m.b * k, m.c * k, m.d * k, m.tx * k, m.ty * k].map(JSONValue.number))),
                ]
                if !glyph.tags.isEmpty { g.append((key: "tags", value: .array(glyph.tags.map(JSONValue.string)))) }
                if let source = glyph.source { g.append((key: "source", value: .string(source))) }
                return .object(g)
            })))
            members.append((key: "rules", value: .array(layout.rules.map { r in
                .array([r.minPoint.x * k, r.minPoint.y * k, r.width * k, r.height * k].map(JSONValue.number))
            })))
            formulas.append(.object(members))
        }
        var file: [(key: String, value: JSONValue)] = []
        if engines.count == 1 { file.append((key: "engine", value: .string(engines.first!))) }
        file.append((key: "glyphs", value: .object(glyphs)))
        file.append((key: "formulas", value: .array(formulas)))
        return JSONValue.object(file).rounded()
    }

    /// The layouts in `json`, each with the engine that made it. Formulas that don't read
    /// are left out, and a file that doesn't read at all gives none: it is only a cache.
    static func read(_ json: JSONValue) -> [MathContent: MathTypesetting.Entry] {
        let root = Node(root: json)
        guard let formulas = try? root.require("formulas").array() else { return [:] }
        let fileEngine = try? root.string("engine")
        let glyphTable = (try? root.require("glyphs").members()) ?? []
        var outlines: [String: [BezierPath]] = [:]
        for (key, value) in glyphTable {
            guard let contours = try? Node(root: value).array().map(readContour) else { continue }
            outlines[key] = contours
        }
        var out: [MathContent: MathTypesetting.Entry] = [:]
        for formula in formulas {
            guard let math = try? SceneJSON.readMath(formula.require("math")),
                  let engine = (try? formula.string("engine")) ?? fileEngine,
                  let layout = try? readLayout(formula, math: math, outlines: outlines) else { continue }
            out[math] = MathTypesetting.Entry(layout: layout, engine: engine)
        }
        return out
    }

    private static func readContour(_ node: Node) throws -> BezierPath {
        let numbers = try node.array().map { try $0.number() }
        guard numbers.count % 6 == 0, numbers.count >= 12 else { throw node.fail("is not a contour") }
        var points: [PathPoint] = []
        for i in stride(from: 0, to: numbers.count, by: 6) {
            points.append(PathPoint(Vec2(numbers[i], numbers[i + 1]), in: Vec2(numbers[i + 2], numbers[i + 3]),
                                    out: Vec2(numbers[i + 4], numbers[i + 5]), mode: .corner))
        }
        return BezierPath(points: points, closed: true)
    }

    private static func readLayout(_ node: Node, math: MathContent, outlines: [String: [BezierPath]]) throws -> MathLayout {
        let k = math.size / 1000
        func numbers(_ node: Node, count: Int) throws -> [Double] {
            let values = try node.array().map { try $0.number() }
            guard values.count == count else { throw node.fail("does not have \(count) numbers") }
            return values.map { $0 * k }
        }
        let box = try numbers(node.require("box"), count: 2)
        var used: [String: [BezierPath]] = [:]
        let glyphs = try node.require("glyphs").array().map { g -> MathLayout.Glyph in
            let key = try g.require("key").string()
            guard let contours = outlines[key] else { throw g.fail("names a glyph that isn't in the file") }
            used[key] = contours
            let p = try numbers(g.require("place"), count: 6)
            let tags = try g.field("tags")?.array().map { try $0.string() } ?? []
            return MathLayout.Glyph(key: key, place: Affine2D(a: p[0], b: p[1], c: p[2], d: p[3], tx: p[4], ty: p[5]),
                                    tags: tags, source: try g.string("source"))
        }
        let rules = try node.require("rules").array().map { r -> Rect in
            let v = try numbers(r, count: 4)
            return Rect(minPoint: Vec2(v[0], v[1]), maxPoint: Vec2(v[0] + v[2], v[1] + v[3]))
        }
        return MathLayout(outlines: used, glyphs: glyphs, rules: rules,
                          bounds: Rect(minPoint: .zero, maxPoint: Vec2(box[0], box[1])), baseline: try node.requireNumber("baseline") * k)
    }
}
