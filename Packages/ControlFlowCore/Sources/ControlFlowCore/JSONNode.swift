import Foundation

/// A file format version such as `1.0` (`MAJOR.MINOR`, with an optional `.PATCH`).
public struct FormatVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major; self.minor = minor; self.patch = patch
    }

    public init(_ major: Int, _ minor: Int) {
        self.init(major, minor, 0)
    }

    /// Parses `MAJOR.MINOR` or `MAJOR.MINOR.PATCH`; pre-release and build suffixes are ignored.
    public init?(_ text: String) {
        let core = text.split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        self.init(numbers[0]!, numbers[1]!, parts.count == 3 ? numbers[2]! : 0)
    }

    /// `MAJOR.MINOR`, with `.PATCH` only when it isn't 0.
    public var description: String { patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)" }

    public static func < (a: FormatVersion, b: FormatVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

/// Why a document's file could not be read.
public enum PresentationFileError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    case invalidJSON(String)
    case missingFile(String)
    /// `path` is a JSON path such as `opening.layers[0].shapes[2].points[0].p`.
    case invalid(path: String, problem: String)
    case unsupportedVersion(String)
    /// The file was written by a newer version of the app.
    case newerVersion(String)

    public var description: String {
        switch self {
        case .invalidJSON(let detail): "The file is not valid JSON (\(detail))."
        case .missingFile(let name): "The document is missing \(name)."
        case .invalid(let path, let problem): "The file is damaged: \(path) \(problem)."
        case .unsupportedVersion(let v): "Format version \(v) is not supported."
        case .newerVersion(let v): "This file was saved by a newer version of the app (format \(v))."
        }
    }

    public var errorDescription: String? { description }
}

/// One step from a node to a child: a member key or an array index.
enum PathStep {
    case root
    case key(String)
    case index(Int)
}

/// A node's place in the document, shared by its children so that reading a value builds
/// no strings: the path is only spelled out when an error needs it.
final class PathLink {
    let parent: PathLink?
    let step: PathStep

    init(parent: PathLink?, step: PathStep) {
        self.parent = parent
        self.step = step
    }

    static func path(parent: PathLink?, step: PathStep) -> String {
        let prefix = parent.map { path(parent: $0.parent, step: $0.step) } ?? ""
        switch step {
        case .root: return prefix
        case .key(let key): return prefix.isEmpty ? key : prefix + "." + key
        case .index(let index): return "\(prefix)[\(index)]"
        }
    }
}

/// A JSON value with its path, for error messages.
struct Node {
    let value: JSONValue
    /// The parent's place, and the step from it to this node.
    private let parent: PathLink?
    private let step: PathStep

    init(root value: JSONValue) {
        self.value = value
        parent = nil
        step = .root
    }

    private init(value: JSONValue, parent: PathLink, step: PathStep) {
        self.value = value
        self.parent = parent
        self.step = step
    }

    /// The JSON path, such as `opening.layers[0].shapes[2].points[0].p`; empty at the root.
    var path: String { PathLink.path(parent: parent, step: step) }

    private var link: PathLink { PathLink(parent: parent, step: step) }

    func fail(_ problem: String) -> PresentationFileError {
        .invalid(path: path.isEmpty ? "(root)" : path, problem: problem)
    }

    /// The path of the member `key`, for errors found after reading it.
    func childPath(_ key: String) -> String { PathLink.path(parent: link, step: .key(key)) }

    func members() throws -> [(key: String, value: JSONValue)] {
        guard case .object(let m) = value else { throw fail("is not an object") }
        return m
    }

    /// The member `key`; a missing key or `null` is nil.
    func field(_ key: String) throws -> Node? {
        let m = try members()
        guard let v = m.first(where: { $0.key == key })?.value, !v.isNull else { return nil }
        return Node(value: v, parent: link, step: .key(key))
    }

    func require(_ key: String) throws -> Node {
        guard let node = try field(key) else {
            throw PresentationFileError.invalid(path: childPath(key), problem: "is missing")
        }
        return node
    }

    func array() throws -> [Node] {
        guard case .array(let items) = value else { throw fail("is not an array") }
        let link = link
        return items.enumerated().map { Node(value: $0.element, parent: link, step: .index($0.offset)) }
    }

    func string() throws -> String {
        guard case .string(let s) = value else { throw fail("is not a string") }
        return s
    }

    func number() throws -> Double {
        guard case .number(let n) = value, n.isFinite else { throw fail("is not a number") }
        return n
    }

    func integer() throws -> Int {
        guard let n = Int(exactly: try number()) else { throw fail("is not a whole number") }
        return n
    }

    func bool() throws -> Bool {
        guard case .bool(let b) = value else { throw fail("is not true or false") }
        return b
    }

    func vec2() throws -> Vec2 {
        if let pair = Node.pair(value) { return pair }
        let items = try array()
        guard items.count == 2 else { throw fail("is not an [x, y] pair") }
        return Vec2(try items[0].number(), try items[1].number())
    }

    /// A string naming one case of `T`.
    func keyword<T: RawRepresentable & CaseIterable>(_: T.Type) throws -> T where T.RawValue == String {
        let text = try string()
        guard let value = T(rawValue: text) else {
            let names = T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
            throw fail("is not one of \(names)")
        }
        return value
    }

    func color() throws -> RGBAColor {
        guard let color = RGBAColor(hex: try string()) else { throw fail("is not a #RRGGBBAA color") }
        return color
    }

    // MARK: Member values

    // Reading a member through `field(key)` allocates a path link and a node, and `vec2()` an array of
    // nodes, all for an error path that is almost never read. These read the member's value directly and
    // only build the node when the value is the wrong type, so a bad file throws exactly what
    // `field(key)?.number()` and the rest would.

    /// The member `key` read by `fast`, or by `slow` on its node when `fast` returns nil; a missing key or
    /// `null` is nil.
    private func member<T>(_ key: String, fast: (JSONValue) -> T?, slow: (Node) throws -> T) throws -> T? {
        guard case .object(let m) = value else { return try field(key).map(slow) }
        guard let v = m.first(where: { $0.key == key })?.value, !v.isNull else { return nil }
        if let result = fast(v) { return result }
        return try slow(Node(value: v, parent: link, step: .key(key)))
    }

    /// The member `key`, which must be present.
    private func required<T>(_ key: String, _ read: (String) throws -> T?) throws -> T {
        guard let result = try read(key) else {
            throw PresentationFileError.invalid(path: childPath(key), problem: "is missing")
        }
        return result
    }

    func number(_ key: String) throws -> Double? {
        try member(key, fast: { if case .number(let n) = $0, n.isFinite { n } else { nil } }, slow: { try $0.number() })
    }

    func requireNumber(_ key: String) throws -> Double { try required(key, number) }

    func integer(_ key: String) throws -> Int? {
        try member(key, fast: { if case .number(let n) = $0 { Int(exactly: n) } else { nil } }, slow: { try $0.integer() })
    }

    func bool(_ key: String) throws -> Bool? {
        try member(key, fast: { if case .bool(let b) = $0 { b } else { nil } }, slow: { try $0.bool() })
    }

    func string(_ key: String) throws -> String? {
        try member(key, fast: { if case .string(let s) = $0 { s } else { nil } }, slow: { try $0.string() })
    }

    func color(_ key: String) throws -> RGBAColor? {
        try member(key, fast: { if case .string(let s) = $0 { RGBAColor(hex: s) } else { nil } }, slow: { try $0.color() })
    }

    func requireColor(_ key: String) throws -> RGBAColor { try required(key, color) }

    func vec2(_ key: String) throws -> Vec2? { try member(key, fast: Node.pair, slow: { try $0.vec2() }) }

    func requireVec2(_ key: String) throws -> Vec2 { try required(key, vec2) }

    /// `value` as an `[x, y]` pair of finite numbers, or nil.
    private static func pair(_ value: JSONValue) -> Vec2? {
        guard case .array(let items) = value, items.count == 2,
              case .number(let x) = items[0], x.isFinite, case .number(let y) = items[1], y.isFinite else { return nil }
        return Vec2(x, y)
    }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}
