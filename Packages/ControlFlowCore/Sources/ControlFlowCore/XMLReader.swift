import Foundation

/// One element of an XML document, as `XMLReader` reads it.
struct MarkupElement: Sendable {
    /// The local name, without a namespace prefix (`svg:path` is `path`).
    var name: String
    /// Attributes by the name written (`xlink:href` keeps its prefix).
    var attributes: [String: String] = [:]
    var children: [MarkupElement] = []
    /// The character data directly inside the element (CDATA included), for `<style>`.
    var text = ""

    init(name: String) {
        self.name = name
    }
}

/// A small, forgiving XML reader for SVG import: elements, attributes, text, CDATA,
/// comments, processing instructions and a DOCTYPE whose internal entities are
/// expanded (Illustrator writes `xmlns="&ns_svg;"`). Namespaces are only stripped from
/// element names. Unclosed elements are closed at the end instead of failing.
enum XMLReader {
    struct Failure: Error, Sendable {
        var message: String
    }

    static func parse(_ text: String) throws -> MarkupElement {
        var parser = Parser(bytes: Array(text.utf8))
        return try parser.document()
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        var entities: [String: String] = [:]
        var stack: [MarkupElement] = []
        var root: MarkupElement?

        init(bytes: [UInt8]) {
            self.bytes = bytes
            // A UTF-8 byte order mark.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        }

        mutating func document() throws -> MarkupElement {
            while i < bytes.count, root == nil {
                if bytes[i] == UInt8(ascii: "<") {
                    try markup()
                } else {
                    let start = i
                    while i < bytes.count, bytes[i] != UInt8(ascii: "<") { i += 1 }
                    if !stack.isEmpty { stack[stack.count - 1].text += decodedString(start, i) }
                }
            }
            while root == nil, !stack.isEmpty { close() }
            guard let root else { throw Failure(message: "has no elements") }
            return root
        }

        private func string(_ a: Int, _ b: Int) -> String {
            String(decoding: bytes[a..<min(b, bytes.count)], as: UTF8.self)
        }

        /// Whether `text` is at `j`, compared byte by byte (no arrays, since this runs for
        /// every tag).
        private func matches(_ text: String, at j: Int) -> Bool {
            var k = j
            for b in text.utf8 {
                guard k < bytes.count, bytes[k] == b else { return false }
                k += 1
            }
            return true
        }

        private func starts(with text: String) -> Bool { matches(text, at: i) }

        /// Moves past the next `terminator`, returning the index where it starts.
        private mutating func skip(past terminator: String) throws -> Int {
            let first = terminator.utf8.first!
            let count = terminator.utf8.count
            var j = i
            while j + count <= bytes.count {
                if bytes[j] == first, matches(terminator, at: j) {
                    i = j + count
                    return j
                }
                j += 1
            }
            throw Failure(message: "ends inside markup (missing \(terminator))")
        }

        /// An attribute value or text run, with references expanded. Most have none, so
        /// look for `&` in the bytes before building the string twice.
        private func decodedString(_ a: Int, _ b: Int) -> String {
            let text = string(a, b)
            return bytes[a..<min(b, bytes.count)].contains(UInt8(ascii: "&")) ? decode(text) : text
        }

        private mutating func markup() throws {
            if starts(with: "<!--") {
                i += 4
                _ = try skip(past: "-->")
            } else if starts(with: "<![CDATA[") {
                i += 9
                let start = i
                let end = try skip(past: "]]>")
                if !stack.isEmpty { stack[stack.count - 1].text += string(start, end) }
            } else if starts(with: "<?") {
                i += 2
                _ = try skip(past: "?>")
            } else if starts(with: "<!") {
                try doctype()
            } else if starts(with: "</") {
                i += 2
                _ = try skip(past: ">")
                if !stack.isEmpty { close() }
            } else {
                try startTag()
            }
        }

        /// Pops the innermost open element into its parent, or makes it the root.
        private mutating func close() {
            let element = stack.removeLast()
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }

        /// A DOCTYPE (or other `<!` declaration), collecting internal entities.
        private mutating func doctype() throws {
            i += 2
            var depth = 0
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "["), depth == 0 {
                    depth = 1
                    i += 1
                } else if c == UInt8(ascii: "]"), depth == 1 {
                    depth = 0
                    i += 1
                } else if depth == 1, starts(with: "<!ENTITY") {
                    i += 8
                    let start = i
                    let end = try skip(past: ">")
                    entity(string(start, end))
                } else if depth == 1, starts(with: "<!--") {
                    i += 4
                    _ = try skip(past: "-->")
                } else if c == UInt8(ascii: ">"), depth == 0 {
                    i += 1
                    return
                } else {
                    i += 1
                }
            }
        }

        /// ` name "value"` from an entity declaration. Parameter entities are ignored.
        private mutating func entity(_ declaration: String) {
            let trimmed = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("%"),
                  let quote = trimmed.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return }
            let name = trimmed[..<quote].trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = trimmed[trimmed.index(after: quote)...]
            guard !name.isEmpty, !name.contains(" "), let close = rest.firstIndex(of: trimmed[quote]) else { return }
            entities[name] = String(rest[..<close])
        }

        private static func isSpace(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
        }

        private mutating func skipSpace() {
            while i < bytes.count, Self.isSpace(bytes[i]) { i += 1 }
        }

        private mutating func name() -> String {
            let start = i
            while i < bytes.count {
                let c = bytes[i]
                if Self.isSpace(c) || c == UInt8(ascii: "/") || c == UInt8(ascii: ">") || c == UInt8(ascii: "=") { break }
                i += 1
            }
            return string(start, i)
        }

        private mutating func startTag() throws {
            i += 1
            let qualified = name()
            guard !qualified.isEmpty else { throw Failure(message: "has a tag with no name") }
            var element = MarkupElement(name: qualified.split(separator: ":").last.map(String.init) ?? qualified)
            while true {
                skipSpace()
                guard i < bytes.count else { throw Failure(message: "ends inside <\(qualified)>") }
                if bytes[i] == UInt8(ascii: "/") {
                    i += 1
                    _ = try skip(past: ">")
                    stack.append(element)
                    close()
                    return
                }
                if bytes[i] == UInt8(ascii: ">") {
                    i += 1
                    stack.append(element)
                    return
                }
                let key = name()
                guard !key.isEmpty else { throw Failure(message: "has a broken attribute in <\(qualified)>") }
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "=") else {
                    // An attribute with no value, which XML doesn't allow; keep going.
                    element.attributes[key] = ""
                    continue
                }
                i += 1
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") else {
                    throw Failure(message: "has an unquoted attribute \(key) in <\(qualified)>")
                }
                let quote = bytes[i]
                i += 1
                let start = i
                while i < bytes.count, bytes[i] != quote { i += 1 }
                guard i < bytes.count else { throw Failure(message: "ends inside an attribute of <\(qualified)>") }
                element.attributes[key] = decodedString(start, i)
                i += 1
            }
        }

        /// Expands character and entity references.
        private func decode(_ text: String) -> String {
            guard text.contains("&") else { return text }
            var out = ""
            var rest = Substring(text)
            while let amp = rest.firstIndex(of: "&") {
                out += rest[..<amp]
                let after = rest[rest.index(after: amp)...]
                guard let semi = after.firstIndex(of: ";"), after.distance(from: after.startIndex, to: semi) <= 32 else {
                    out += "&"
                    rest = after
                    continue
                }
                let ref = String(after[..<semi])
                if let value = reference(ref) {
                    out += value
                } else {
                    out += "&" + ref + ";"
                }
                rest = after[after.index(after: semi)...]
            }
            return out + rest
        }

        private func reference(_ ref: String) -> String? {
            switch ref {
            case "lt": return "<"
            case "gt": return ">"
            case "amp": return "&"
            case "quot": return "\""
            case "apos": return "'"
            default: break
            }
            if ref.hasPrefix("#x") || ref.hasPrefix("#X") {
                return UInt32(ref.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            }
            if ref.hasPrefix("#") {
                return UInt32(ref.dropFirst()).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            }
            // Entities may hold references themselves, one level deep.
            return entities[ref].map { $0.contains("&") ? $0.replacingOccurrences(of: "&amp;", with: "&") : $0 }
        }
    }
}
