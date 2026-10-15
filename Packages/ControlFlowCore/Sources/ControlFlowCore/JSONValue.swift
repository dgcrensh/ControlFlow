import Foundation

/// A JSON value with ordered object keys, so files are written in a readable,
/// stable order. Object equality ignores key order.
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.key == key }?.value
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

extension JSONValue: Equatable {
    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            let lookup = Dictionary(y.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            return x.allSatisfy { lookup[$0.key] == $0.value }
        default: return false
        }
    }
}

extension JSONValue: Hashable {
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null: hasher.combine(0)
        case .bool(let b): hasher.combine(b)
        case .number(let n): hasher.combine(n)
        case .string(let s): hasher.combine(s)
        case .array(let items): hasher.combine(items)
        case .object(let members):
            // Equality ignores key order, so the hash does too.
            hasher.combine(members.count)
            hasher.combine(members.reduce(0) { $0 ^ (31 &* $1.key.hashValue &+ $1.value.hashValue) })
        }
    }
}

extension JSONValue {
    /// The value with every number rounded to `decimals` places (and -0 written as 0), as
    /// files are written.
    public func rounded(decimals: Int = 4) -> JSONValue {
        switch self {
        case .number(let n):
            guard n.isFinite else { return .number(0) }
            let k = pow(10, Double(decimals))
            let r = (n * k).rounded() / k
            return .number(r == 0 ? 0 : r)
        case .array(let items): return .array(items.map { $0.rounded(decimals: decimals) })
        case .object(let members): return .object(members.map { (key: $0.key, value: $0.value.rounded(decimals: decimals)) })
        case .null, .bool, .string: return self
        }
    }
}

// MARK: Writing

extension JSONValue {
    /// Pretty-printed JSON with two-space indents. Arrays of plain values and small
    /// flat objects (such as a path point) stay on one line.
    public func formatted() -> String {
        var out = ""
        write(to: &out, indent: 0)
        out.append("\n")
        return out
    }

    private static let inlineLimit = 120

    private func write(to out: inout String, indent: Int) {
        switch self {
        case .null, .bool, .number, .string:
            out.append(scalarText)
        case .array(let items):
            if items.isEmpty { out.append("[]"); return }
            if let inline = inlineText, inline.count + indent <= Self.inlineLimit {
                out.append(inline)
                return
            }
            out.append("[\n")
            for (i, item) in items.enumerated() {
                out.append(String(repeating: " ", count: indent + 2))
                item.write(to: &out, indent: indent + 2)
                out.append(i == items.count - 1 ? "\n" : ",\n")
            }
            out.append(String(repeating: " ", count: indent) + "]")
        case .object(let members):
            if members.isEmpty { out.append("{}"); return }
            if let inline = inlineText, inline.count + indent <= Self.inlineLimit {
                out.append(inline)
                return
            }
            out.append("{\n")
            for (i, member) in members.enumerated() {
                out.append(String(repeating: " ", count: indent + 2))
                out.append(Self.quoted(member.key) + ": ")
                member.value.write(to: &out, indent: indent + 2)
                out.append(i == members.count - 1 ? "\n" : ",\n")
            }
            out.append(String(repeating: " ", count: indent) + "}")
        }
    }

    /// One-line text for scalars, arrays of scalars or of arrays of scalars, and objects whose values are those. Nil for anything deeper.
    private var inlineText: String? {
        switch self {
        case .null, .bool, .number, .string:
            return scalarText
        case .array(let items):
            if items.allSatisfy(\.isScalar) { return "[" + items.map(\.scalarText).joined(separator: ", ") + "]" }
            guard items.allSatisfy(\.isScalarArray) else { return nil }
            return "[" + items.map { $0.inlineText! }.joined(separator: ", ") + "]"
        case .object(let members):
            var layers: [String] = []
            for member in members {
                switch member.value {
                case .object: return nil
                case .array(let items) where !items.allSatisfy(\.isScalar) && !items.allSatisfy(\.isScalarArray):
                    return nil
                default: layers.append(Self.quoted(member.key) + ": " + member.value.inlineText!)
                }
            }
            return "{ " + layers.joined(separator: ", ") + " }"
        }
    }

    /// True for an array of scalars (empty included).
    private var isScalarArray: Bool {
        if case .array(let items) = self { return items.allSatisfy(\.isScalar) }
        return false
    }

    private var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }

    private var scalarText: String {
        switch self {
        case .null: "null"
        case .bool(let b): b ? "true" : "false"
        case .number(let n): Self.numberText(n)
        case .string(let s): Self.quoted(s)
        case .array, .object: ""
        }
    }

    /// Shortest round-trip text, without a trailing `.0` on whole numbers.
    /// JSON has no NaN or infinity, so those are written as 0.
    static func numberText(_ n: Double) -> String {
        guard n.isFinite else { return "0" }
        if n == 0 { return "0" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        return String(describing: n)
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out.append("\\\"")
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out.append("\\u" + String(repeating: "0", count: 4 - hex.count) + hex)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out.append("\"")
        return out
    }
}

// MARK: Parsing

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    /// Byte offset into the input.
    public var offset: Int

    public var description: String { "\(message) at byte \(offset)" }
}

extension JSONValue {
    public init(parsing data: Data) throws {
        var parser = JSONParser(bytes: [UInt8](data))
        self = try parser.parseDocument()
    }

    public init(parsing text: String) throws {
        try self.init(parsing: Data(text.utf8))
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var i = 0
    var depth = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        // Skip a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard i == bytes.count else { throw error("Unexpected text after the JSON value") }
        return value
    }

    private func error(_ message: String) -> JSONParseError {
        JSONParseError(message: message, offset: i)
    }

    private mutating func skipWhitespace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private mutating func expect(_ literal: String, _ value: JSONValue) throws -> JSONValue {
        let utf8 = Array(literal.utf8)
        guard i + utf8.count <= bytes.count, Array(bytes[i..<i + utf8.count]) == utf8 else {
            throw error("Invalid literal")
        }
        i += utf8.count
        return value
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard i < bytes.count else { throw error("Unexpected end of input") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): return try expect("true", .bool(true))
        case UInt8(ascii: "f"): return try expect("false", .bool(false))
        case UInt8(ascii: "n"): return try expect("null", .null)
        default: return .number(try parseNumber())
        }
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= 512 else { throw error("JSON is nested too deeply") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        i += 1
        var members: [(key: String, value: JSONValue)] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("Expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            i += 1
            let value = try parseValue()
            members.append((key: key, value: value))
            skipWhitespace()
            guard i < bytes.count else { throw error("Unexpected end of input") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw error("Expected ',' or '}'")
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        i += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            items.append(try parseValue())
            skipWhitespace()
            guard i < bytes.count else { throw error("Unexpected end of input") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw error("Expected ',' or ']'")
        }
    }

    private mutating func parseString() throws -> String {
        i += 1
        // Most strings (every key) have no escapes: read them straight from the bytes.
        var end = i
        while end < bytes.count, bytes[end] != UInt8(ascii: "\""), bytes[end] != UInt8(ascii: "\\"), bytes[end] >= 0x20 {
            end += 1
        }
        if end < bytes.count, bytes[end] == UInt8(ascii: "\"") {
            guard let s = String(validating: bytes[i..<end], as: UTF8.self) else {
                i = end + 1
                throw error("Invalid UTF-8 in string")
            }
            i = end + 1
            return s
        }
        var out: [UInt8] = []
        while true {
            guard i < bytes.count else { throw error("Unterminated string") }
            let b = bytes[i]
            i += 1
            switch b {
            case UInt8(ascii: "\""):
                guard let s = String(validating: out, as: UTF8.self) else { throw error("Invalid UTF-8 in string") }
                return s
            case UInt8(ascii: "\\"):
                guard i < bytes.count else { throw error("Unterminated string") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800..<0xDC00).contains(scalar) {
                        // A high surrogate must be followed by an escaped low surrogate.
                        guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw error("Unpaired surrogate")
                        }
                        i += 2
                        let low = try parseHex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw error("Unpaired surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00..<0xE000).contains(scalar) {
                        throw error("Unpaired surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw error("Invalid escape") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default:
                    throw error("Invalid escape")
                }
            default:
                guard b >= 0x20 else { throw error("Control character in string") }
                out.append(b)
            }
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard i + 4 <= bytes.count, let s = String(bytes: bytes[i..<i + 4], encoding: .ascii),
              let v = UInt32(s, radix: 16) else { throw error("Invalid \\u escape") }
        i += 4
        return v
    }

    private static func isDigit(_ b: UInt8) -> Bool { b &- UInt8(ascii: "0") < 10 }

    private static func isNumberByte(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "+"), UInt8(ascii: "."),
             UInt8(ascii: "e"), UInt8(ascii: "E"):
            true
        default:
            false
        }
    }

    /// A number. The token runs over every byte that can appear in a number and must match
    /// JSON's grammar: an optional `-`, digits without a leading zero, an optional point
    /// with digits, an optional exponent with digits (no leading `+`). Plain decimals are
    /// read from the bytes (`FastDecimal`); exponents and long mantissas go through
    /// `Double(text)`.
    private mutating func parseNumber() throws -> Double {
        let start = i
        while i < bytes.count, Self.isNumberByte(bytes[i]) { i += 1 }
        let end = i
        func invalid() -> JSONParseError {
            i = start
            return error("Invalid value")
        }
        var j = start
        let negative = j < end && bytes[j] == UInt8(ascii: "-")
        if negative { j += 1 }
        let digitsStart = j
        while j < end, Self.isDigit(bytes[j]) { j += 1 }
        // At least one digit, and no leading zero.
        guard j > digitsStart, bytes[digitsStart] != UInt8(ascii: "0") || j == digitsStart + 1 else { throw invalid() }
        if j < end, bytes[j] == UInt8(ascii: ".") {
            j += 1
            let fraction = j
            while j < end, Self.isDigit(bytes[j]) { j += 1 }
            guard j > fraction else { throw invalid() }
        }
        let decimalEnd = j
        if j < end, bytes[j] == UInt8(ascii: "e") || bytes[j] == UInt8(ascii: "E") {
            j += 1
            if j < end, bytes[j] == UInt8(ascii: "+") || bytes[j] == UInt8(ascii: "-") { j += 1 }
            let exponent = j
            while j < end, Self.isDigit(bytes[j]) { j += 1 }
            guard j > exponent else { throw invalid() }
        }
        guard j == end else { throw invalid() }
        if decimalEnd == end, let value = FastDecimal.value(bytes, from: digitsStart, to: end, negative: negative) {
            return value
        }
        guard let value = Double(String(decoding: bytes[start..<end], as: UTF8.self)) else { throw invalid() }
        return value
    }
}
