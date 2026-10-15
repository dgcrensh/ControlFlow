import Foundation

/// What an SVG import brought in.
public struct SVGImportResult: Sendable {
    /// The art as parts, back to front. Ids are only unique within the result; the
    /// editor gives them fresh ones (`DrawingEditor.importParts`).
    public var parts: [Part]
    /// Elements that can't come in (text, images, ...), by element name, with counts.
    public var skipped: [String: Int]

    public var shapeCount: Int { parts.reduce(0) { $0 + $1.shapes.count } }
}

public enum SVGImportError: Error, Hashable, Sendable, CustomStringConvertible, LocalizedError {
    /// Not readable as XML; the reason says where.
    case unreadable(String)
    case notSVG
    /// An SVG with no shapes the editor can use.
    case noArt

    public var description: String {
        switch self {
        case .unreadable(let why): "The file isn't readable SVG: it \(why)."
        case .notSVG: "The file isn't an SVG drawing."
        case .noArt: "The SVG has no shapes to import."
        }
    }

    public var errorDescription: String? { description }
}

/// Reads SVG art into parts of editable shapes.
///
/// Each top-level group becomes a part named after its `data-name` (Illustrator),
/// `inkscape:label` (Inkscape) or `id`; shapes outside any group share a part named
/// after the file. A named group inside a part's group becomes a group of shapes in
/// that part (deeper groups are flattened into it). A document wrapped in a single group is unwrapped first. Paths,
/// rectangles, circles, ellipses, lines, polylines, polygons and `<use>` copies come in,
/// with transforms, presentation attributes, `style` attributes and simple `<style>`
/// rules (by tag, class and id). Fills, gradients (linear and radial), outlines (width,
/// caps, joins, miter limit, dashes) and opacity carry over; opacities fold into the
/// colors' alpha.
///
/// A path with several subpaths (a ring, a letter with a hole) keeps its holes: its fill
/// becomes one shape whose subpaths are joined by hairline bridges that add no area,
/// and its outline goes on separate unfilled shapes, one per subpath. Text, images,
/// clipping paths, masks, patterns and filters are skipped and counted.
public enum SVGImporter {
    public static func parse(_ text: String, name: String = "Imported") throws -> SVGImportResult {
        let root: MarkupElement
        do {
            root = try XMLReader.parse(text)
        } catch let failure as XMLReader.Failure {
            throw SVGImportError.unreadable(failure.message)
        }
        guard root.name == "svg" else { throw SVGImportError.notSVG }
        var context = Context(root: root)
        let parts = context.parts(fileName: name)
        guard !parts.isEmpty else { throw SVGImportError.noArt }
        return SVGImportResult(parts: parts, skipped: context.skipped)
    }

    // MARK: Styles

    /// A paint for fill or stroke.
    enum Paint: Hashable, Sendable {
        case none
        case color(RGBAColor)
        case currentColor
        /// A gradient by id, with the color to use when it can't be found.
        case reference(String, fallback: RGBAColor?)
    }

    /// The inherited presentation properties at one element.
    struct Style: Hashable, Sendable {
        var fill = Paint.color(.black)
        var fillOpacity = 1.0
        var stroke = Paint.none
        var strokeOpacity = 1.0
        var strokeWidth = 1.0
        var cap = LineCap.butt
        var join = LineJoin.miter
        var miterLimit = 4.0
        var dash: [Double] = []
        var dashOffset = 0.0
        var color = RGBAColor.black
        var visible = true
        /// The product of the element's and its ancestors' `opacity`.
        var opacity = 1.0
    }

    /// One rule from a `<style>` sheet with a single simple selector.
    struct Rule: Sendable {
        var tag: String?
        var classes: [String]
        var id: String?
        var declarations: [(String, String)]
        var specificity: Int
        var order: Int

        func matches(_ element: MarkupElement, classes elementClasses: Set<String>) -> Bool {
            if let tag, tag != element.name { return false }
            if let id, element.attributes["id"] != id { return false }
            return classes.allSatisfy(elementClasses.contains)
        }
    }

    /// `name: value; ...` declarations.
    static func declarations(_ text: String) -> [(String, String)] {
        text.split(separator: ";").compactMap { item -> (String, String)? in
            guard let colon = item.firstIndex(of: ":") else { return nil }
            let key = item[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var value = item[item.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix("!important") {
                value = value.dropLast("!important".count).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return key.isEmpty ? nil : (key, value)
        }
    }

    /// Rules from a style sheet. Selectors other than `tag`, `.class`, `#id` and their
    /// combinations (no spaces) are ignored, as are at-rules.
    static func rules(_ sheet: String, startingAt order: Int) -> [Rule] {
        var text = sheet
        // Comments.
        while let open = text.range(of: "/*") {
            let close = text.range(of: "*/", range: open.upperBound..<text.endIndex)
            text.removeSubrange(open.lowerBound..<(close?.upperBound ?? text.endIndex))
        }
        var out: [Rule] = []
        var n = order
        for block in text.split(separator: "}") {
            guard let brace = block.firstIndex(of: "{") else { continue }
            let selectors = block[..<brace]
            let body = declarations(String(block[block.index(after: brace)...]))
            for raw in selectors.split(separator: ",") {
                let selector = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !selector.isEmpty, !selector.hasPrefix("@"),
                      selector.allSatisfy({ $0.isLetter || $0.isNumber || "-_.#*".contains($0) }) else { continue }
                var tag: String?
                var classes: [String] = []
                var id: String?
                var token = ""
                var kind: Character = " "
                func flush() {
                    switch kind {
                    case ".": if !token.isEmpty { classes.append(token) }
                    case "#": if !token.isEmpty { id = token }
                    default: if !token.isEmpty, token != "*" { tag = token }
                    }
                    token = ""
                }
                for c in selector {
                    if c == "." || c == "#" {
                        flush()
                        kind = c
                    } else {
                        token.append(c)
                    }
                }
                flush()
                let specificity = (id == nil ? 0 : 100) + classes.count * 10 + (tag == nil ? 0 : 1)
                out.append(Rule(tag: tag, classes: classes, id: id, declarations: body, specificity: specificity, order: n))
                n += 1
            }
        }
        return out
    }

    /// Parses a color: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()`, `hsl()`,
    /// `hsla()` or a CSS color name.
    static func color(_ text: String) -> RGBAColor? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("#") {
            let hex = s.dropFirst()
            guard hex.allSatisfy(\.isHexDigit) else { return nil }
            switch hex.count {
            case 3, 4:
                return RGBAColor(hex: hex.map { "\($0)\($0)" }.joined())
            case 6, 8:
                return RGBAColor(hex: String(hex))
            default:
                return nil
            }
        }
        if let open = s.firstIndex(of: "("), s.hasSuffix(")") {
            let function = s[..<open].trimmingCharacters(in: .whitespaces)
            let args = s[s.index(after: open)..<s.index(before: s.endIndex)]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map(String.init)
            func component(_ t: String, scale: Double) -> Double? {
                if t.hasSuffix("%") { return Double(t.dropLast()).map { $0 / 100 } }
                return Double(t).map { $0 / scale }
            }
            func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
            let alpha = args.count >= 4 ? (component(args[3], scale: 1) ?? 1) : 1
            switch function {
            case "rgb", "rgba":
                guard args.count >= 3, let r = component(args[0], scale: 255), let g = component(args[1], scale: 255),
                      let b = component(args[2], scale: 255) else { return nil }
                return RGBAColor(r: clamp(r), g: clamp(g), b: clamp(b), a: clamp(alpha))
            case "hsl", "hsla":
                guard args.count >= 3, let h = Double(args[0].replacingOccurrences(of: "deg", with: "")),
                      let sat = component(args[1], scale: 100), let light = component(args[2], scale: 100) else { return nil }
                let (r, g, b) = hslToRGB(h: h, s: clamp(sat), l: clamp(light))
                return RGBAColor(r: r, g: g, b: b, a: clamp(alpha))
            default:
                return nil
            }
        }
        if s == "transparent" { return RGBAColor(r: 0, g: 0, b: 0, a: 0) }
        return namedColors[s].flatMap { RGBAColor(hex: $0) }
    }

    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        let hue = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 360
        guard s > 0 else { return (l, l, l) }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s
        let p = 2 * l - q
        func channel(_ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 0.5 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        return (channel(hue + 1.0 / 3), channel(hue), channel(hue - 1.0 / 3))
    }

    /// A paint value: `none`, a color, `currentColor` or `url(#id) [fallback]`. Nil when unreadable.
    static func paint(_ text: String) -> Paint? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = s.lowercased()
        if lower == "none" { return Paint.none }
        if lower == "currentcolor" { return .currentColor }
        if lower.hasPrefix("url(") {
            guard let close = s.firstIndex(of: ")") else { return nil }
            var target = s[s.index(s.startIndex, offsetBy: 4)..<close].trimmingCharacters(in: .whitespaces)
            target = target.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let fallback = color(String(s[s.index(after: close)...]))
            return .reference(target.hasPrefix("#") ? String(target.dropFirst()) : target, fallback: fallback)
        }
        return color(s).map(Paint.color)
    }

    /// A length in user units (pixels). Percentages and unknown units give nil.
    static func length(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let units: [(String, Double)] = [("px", 1), ("pt", 4.0 / 3), ("pc", 16), ("mm", 96 / 25.4), ("cm", 96 / 2.54),
                                         ("in", 96), ("em", 16), ("ex", 8)]
        for (unit, scale) in units where s.hasSuffix(unit) {
            return Double(s.dropLast(unit.count).trimmingCharacters(in: .whitespaces)).map { $0 * scale }
        }
        if s.hasSuffix("%") { return nil }
        var scanner = NumberScanner(s)
        guard let value = scanner.number() else { return nil }
        scanner.skipSeparators()
        return scanner.isAtEnd ? value : nil
    }

    /// A `transform` attribute: matrix, translate, scale, rotate (about a point), skewX and skewY.
    static func transform(_ text: String) -> Affine2D {
        var result = Affine2D.identity
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n,")).lowercased()
            var scanner = NumberScanner(String(rest[rest.index(after: open)..<close]))
            let a = scanner.numbers()
            rest = rest[rest.index(after: close)...]
            let t: Affine2D
            switch name {
            case "matrix" where a.count == 6:
                t = Affine2D(a: a[0], b: a[1], c: a[2], d: a[3], tx: a[4], ty: a[5])
            case "translate" where !a.isEmpty:
                t = .translation(Vec2(a[0], a.count > 1 ? a[1] : 0))
            case "scale" where !a.isEmpty:
                t = .scale(x: a[0], y: a.count > 1 ? a[1] : a[0])
            case "rotate" where !a.isEmpty:
                let r = Affine2D.rotation(a[0] * .pi / 180)
                if a.count >= 3 {
                    let c = Vec2(a[1], a[2])
                    t = Affine2D.translation(c) * r * Affine2D.translation(-c)
                } else {
                    t = r
                }
            case "skewx" where !a.isEmpty:
                t = Affine2D(a: 1, b: 0, c: tan(a[0] * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy" where !a.isEmpty:
                t = Affine2D(a: 1, b: tan(a[0] * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default:
                continue
            }
            result = result * t
        }
        return result
    }

    // MARK: Walking the document

    /// Elements that never draw by themselves.
    static let definitionElements: Set<String> = [
        "defs", "style", "title", "desc", "metadata", "namedview", "script", "symbol", "clipPath", "mask",
        "linearGradient", "radialGradient", "pattern", "marker", "filter",
    ]
    static let shapeElements: Set<String> = ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"]
    static let groupElements: Set<String> = ["g", "a", "switch", "svg"]

    struct Context {
        let root: MarkupElement
        var ids: [String: MarkupElement] = [:]
        var rules: [Rule] = []
        var skipped: [String: Int] = [:]
        var nextID = 1

        init(root: MarkupElement) {
            self.root = root
            collect(root)
            rules.sort { ($0.specificity, $0.order) < ($1.specificity, $1.order) }
        }

        private mutating func collect(_ element: MarkupElement) {
            if let id = element.attributes["id"], ids[id] == nil { ids[id] = element }
            if element.name == "style" { rules += SVGImporter.rules(element.text, startingAt: rules.count) }
            for child in element.children { collect(child) }
        }

        mutating func makeID() -> Int {
            defer { nextID += 1 }
            return nextID
        }

        /// The element's style: inherited from `parent`, then its presentation attributes,
        /// then matching style rules, then its `style` attribute.
        func style(of element: MarkupElement, parent: Style) -> Style? {
            var style = parent
            var opacity = 1.0
            var display = true
            func apply(_ key: String, _ value: String) {
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard v != "inherit", !v.isEmpty else { return }
                switch key {
                case "fill": if let p = SVGImporter.paint(v) { style.fill = p }
                case "stroke": if let p = SVGImporter.paint(v) { style.stroke = p }
                case "fill-opacity": if let x = SVGImporter.fraction(v) { style.fillOpacity = x }
                case "stroke-opacity": if let x = SVGImporter.fraction(v) { style.strokeOpacity = x }
                case "opacity": if let x = SVGImporter.fraction(v) { opacity = x }
                case "stroke-width": if let x = SVGImporter.length(v), x >= 0 { style.strokeWidth = x }
                case "stroke-linecap": if let c = LineCap(rawValue: v.lowercased()) { style.cap = c }
                case "stroke-linejoin":
                    let lower = v.lowercased()
                    if let j = LineJoin(rawValue: lower) {
                        style.join = j
                    } else if lower.hasPrefix("miter") || lower == "arcs" {
                        style.join = .miter
                    }
                case "stroke-miterlimit": if let x = Double(v), x >= 1 { style.miterLimit = x }
                case "stroke-dasharray":
                    if v.lowercased() == "none" {
                        style.dash = []
                    } else {
                        let lengths = v.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { SVGImporter.length(String($0)) }
                        if lengths.allSatisfy({ $0 >= 0 }) { style.dash = lengths }
                    }
                case "stroke-dashoffset": if let x = SVGImporter.length(v) { style.dashOffset = x }
                case "color": if let c = SVGImporter.color(v) { style.color = c }
                case "display": display = v.lowercased() != "none"
                case "visibility": style.visible = v.lowercased() == "visible"
                default: break
                }
            }
            for (key, value) in element.attributes { apply(key.lowercased(), value) }
            if !rules.isEmpty {
                let classes = Set((element.attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init))
                for rule in rules where rule.matches(element, classes: classes) {
                    for (key, value) in rule.declarations { apply(key, value) }
                }
            }
            if let inline = element.attributes["style"] {
                for (key, value) in SVGImporter.declarations(inline) { apply(key, value) }
            }
            guard display else { return nil }
            style.opacity = parent.opacity * opacity
            return style
        }

        // MARK: Parts

        mutating func parts(fileName: String) -> [Part] {
            let rootStyle = style(of: root, parent: Style()) ?? Style()
            var top = root.children
            var topStyle = rootStyle
            var topTransform = Affine2D.identity
            // Unwrap a document that is all one group.
            while true {
                let drawable = top.filter { !SVGImporter.definitionElements.contains($0.name) }
                guard drawable.count == 1, let only = drawable.first, SVGImporter.groupElements.contains(only.name),
                      only.name != "svg", let inner = style(of: only, parent: topStyle) else { break }
                topStyle = inner
                topTransform = topTransform * SVGImporter.transform(only.attributes["transform"] ?? "")
                top = only.children
            }

            // Groups become parts; runs of shapes between them share a part.
            var groups: [(name: String, shapes: [VectorShape], groups: [ShapeGroup])] = []
            var loose: [VectorShape] = []
            for element in top where !SVGImporter.definitionElements.contains(element.name) {
                guard SVGImporter.groupElements.contains(element.name) else {
                    draw(element, style: topStyle, transform: topTransform, depth: 0, into: &loose)
                    continue
                }
                var shapes: [VectorShape] = []
                var shapeGroups: [ShapeGroup] = []
                drawPart(element, style: topStyle, transform: topTransform, into: &shapes, groups: &shapeGroups)
                guard !shapes.isEmpty else { continue }
                if !loose.isEmpty { groups.append((fileName, loose, [])) }
                loose = []
                groups.append((SVGImporter.partName(element) ?? fileName, shapes, shapeGroups))
            }
            if !loose.isEmpty { groups.append((fileName, loose, [])) }
            var parts: [Part] = []
            for group in groups {
                var part = makePart(name: group.name, shapes: group.shapes)
                part.groups = group.groups
                parts.append(part)
            }
            return parts
        }

        private mutating func makePart(name: String, shapes: [VectorShape]) -> Part {
            let bounds = shapes.reduce(Rect.null) { $0.union($1.path.bounds()) }
            return Part(id: makeID(), name: name, shapes: shapes, pivot: bounds.isNull ? .zero : bounds.center)
        }

        /// Draws a part's group: each named group inside it becomes a group of shapes
        /// (with anything deeper flattened into it); the rest draws as usual.
        private mutating func drawPart(_ element: MarkupElement, style parent: Style, transform: Affine2D,
                                       into shapes: inout [VectorShape], groups: inout [ShapeGroup]) {
            let containers: Set<String> = ["g", "a", "switch"]
            guard containers.contains(element.name), element.attributes["clip-path"] == nil,
                  element.attributes["mask"] == nil, let style = self.style(of: element, parent: parent) else {
                draw(element, style: parent, transform: transform, depth: 0, into: &shapes)
                return
            }
            let t = transform * SVGImporter.transform(element.attributes["transform"] ?? "")
            for child in element.children {
                guard containers.contains(child.name), let name = SVGImporter.partName(child) else {
                    draw(child, style: style, transform: t, depth: 1, into: &shapes)
                    continue
                }
                var inner: [VectorShape] = []
                draw(child, style: style, transform: t, depth: 1, into: &inner)
                guard !inner.isEmpty else { continue }
                let group = ShapeGroup(id: makeID(), name: name)
                groups.append(group)
                for var shape in inner {
                    shape.group = group.id
                    shapes.append(shape)
                }
            }
        }

        /// Adds the shapes `element` draws, in document order.
        mutating func draw(_ element: MarkupElement, style parent: Style, transform: Affine2D, depth: Int,
                           into shapes: inout [VectorShape]) {
            guard depth < 32, !SVGImporter.definitionElements.contains(element.name) else { return }
            guard let style = self.style(of: element, parent: parent) else { return }
            var t = transform * SVGImporter.transform(element.attributes["transform"] ?? "")
            if element.attributes["clip-path"] != nil || element.attributes["mask"] != nil {
                skipped[element.attributes["clip-path"] != nil ? "clip-path" : "mask", default: 0] += 1
            }
            switch element.name {
            case "g", "a", "switch":
                for child in element.children { draw(child, style: style, transform: t, depth: depth + 1, into: &shapes) }
            case "svg":
                // A nested viewport: its children sit at its x and y.
                let x = element.attributes["x"].flatMap(SVGImporter.length) ?? 0
                let y = element.attributes["y"].flatMap(SVGImporter.length) ?? 0
                t = t * Affine2D.translation(Vec2(x, y))
                for child in element.children { draw(child, style: style, transform: t, depth: depth + 1, into: &shapes) }
            case "use":
                guard let href = element.attributes["href"] ?? element.attributes["xlink:href"], href.hasPrefix("#"),
                      let target = ids[String(href.dropFirst())] else { return }
                let x = element.attributes["x"].flatMap(SVGImporter.length) ?? 0
                let y = element.attributes["y"].flatMap(SVGImporter.length) ?? 0
                t = t * Affine2D.translation(Vec2(x, y))
                if target.name == "symbol" {
                    for child in target.children { draw(child, style: style, transform: t, depth: depth + 1, into: &shapes) }
                } else {
                    draw(target, style: style, transform: t, depth: depth + 1, into: &shapes)
                }
            default:
                if SVGImporter.shapeElements.contains(element.name) {
                    guard style.visible else { return }
                    shapes += self.shapes(element, style: style, transform: t)
                } else if !element.name.isEmpty {
                    skipped[element.name, default: 0] += 1
                }
            }
        }

        // MARK: Shapes

        /// The subpaths a shape element describes, in its own coordinates.
        func subpaths(_ element: MarkupElement) -> [SVGSubpath] {
            func number(_ key: String) -> Double { element.attributes[key].flatMap(SVGImporter.length) ?? 0 }
            func closedSubpath(_ path: BezierPath) -> [SVGSubpath] {
                guard let first = path.points.first else { return [] }
                var sub = SVGSubpath(start: first.position)
                sub.segments = (0..<path.segmentCount).map { path.segment($0) }
                sub.closed = true
                return [sub]
            }
            switch element.name {
            case "path":
                return SVGPathParser.parse(element.attributes["d"] ?? "")
            case "rect":
                let w = number("width"), h = number("height")
                guard w > 0, h > 0 else { return [] }
                var rx = element.attributes["rx"].flatMap(SVGImporter.length)
                var ry = element.attributes["ry"].flatMap(SVGImporter.length)
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                let r = Rect(minPoint: Vec2(number("x"), number("y")), maxPoint: Vec2(number("x") + w, number("y") + h))
                return closedSubpath(SVGImporter.roundedRect(r, rx: min(rx ?? 0, w / 2), ry: min(ry ?? 0, h / 2)))
            case "circle":
                let r = number("r")
                guard r > 0 else { return [] }
                let c = Vec2(number("cx"), number("cy"))
                return closedSubpath(ShapePrimitives.ellipse(Rect(minPoint: c - Vec2(r, r), maxPoint: c + Vec2(r, r))))
            case "ellipse":
                let rx = number("rx"), ry = number("ry")
                guard rx > 0, ry > 0 else { return [] }
                let c = Vec2(number("cx"), number("cy"))
                return closedSubpath(ShapePrimitives.ellipse(Rect(minPoint: c - Vec2(rx, ry), maxPoint: c + Vec2(rx, ry))))
            case "line":
                let a = Vec2(number("x1"), number("y1")), b = Vec2(number("x2"), number("y2"))
                return [SVGSubpath(start: a, segments: [CubicBezier(a, a, b, b)])]
            case "polyline", "polygon":
                var scanner = NumberScanner(element.attributes["points"] ?? "")
                let values = scanner.numbers()
                let points = stride(from: 0, to: values.count - 1, by: 2).map { Vec2(values[$0], values[$0 + 1]) }
                guard let first = points.first, points.count >= 2 else { return [] }
                var sub = SVGSubpath(start: first)
                for i in 1..<points.count {
                    sub.segments.append(CubicBezier(points[i - 1], points[i - 1], points[i], points[i]))
                }
                if element.name == "polygon", let last = points.last, !last.isApproximately(first, tolerance: 1e-9) {
                    sub.segments.append(CubicBezier(last, last, first, first))
                }
                sub.closed = element.name == "polygon"
                return [sub]
            default:
                return []
            }
        }

        /// The editor shapes for one SVG shape element, transformed into world space.
        mutating func shapes(_ element: MarkupElement, style: Style, transform: Affine2D) -> [VectorShape] {
            let paths = self.subpaths(element).compactMap(\.bezierPath)
            guard !paths.isEmpty else { return [] }
            let localBounds = paths.reduce(Rect.null) { $0.union($1.bounds()) }

            // The fill. A line has no inside, so it is never filled.
            var fill: RGBAColor?
            var gradient: ShapeGradient?
            let fillAlpha = style.fillOpacity * style.opacity
            switch element.name == "line" ? Paint.none : style.fill {
            case .none:
                break
            case .color(let c):
                fill = c.withAlpha(c.a * fillAlpha)
            case .currentColor:
                fill = style.color.withAlpha(style.color.a * fillAlpha)
            case .reference(let id, let fallback):
                if var g = self.gradient(id, bounds: localBounds) {
                    for i in g.stops.indices { g.stops[i].color.a *= fillAlpha }
                    fill = g.stops[0].color
                    gradient = g.stops.count > 1 ? g : nil
                } else if let fallback {
                    fill = fallback.withAlpha(fallback.a * fillAlpha)
                } else {
                    let solid = self.solidColor(of: id)
                    fill = solid?.withAlpha((solid?.a ?? 1) * fillAlpha)
                }
            }

            // The outline.
            var stroke: StrokeStyle?
            let strokeAlpha = style.strokeOpacity * style.opacity
            var strokeColor: RGBAColor?
            switch style.stroke {
            case .none: break
            case .color(let c): strokeColor = c
            case .currentColor: strokeColor = style.color
            case .reference(let id, let fallback):
                strokeColor = self.gradient(id, bounds: localBounds)?.stops.first?.color ?? fallback ?? solidColor(of: id)
            }
            if let c = strokeColor, style.strokeWidth > 0 {
                var s = StrokeStyle(color: c.withAlpha(c.a * strokeAlpha), width: style.strokeWidth, cap: style.cap,
                                    join: style.join, miterLimit: style.miterLimit, dash: style.dash,
                                    dashOffset: style.dashOffset)
                if s.dashPattern == nil { s.dash = [] }
                if s.dash.isEmpty { s.dashOffset = 0 }
                stroke = s
            }
            guard fill != nil || stroke != nil else { return [] }

            // A closed single path keeps its fill and outline together. Otherwise the fill
            // (bridged when there are several subpaths) and each subpath's outline are
            // separate shapes, so open subpaths and holes draw as they do in SVG.
            var pieces: [(path: BezierPath, fill: Bool, stroke: Bool)] = []
            if fill != nil, paths.count == 1, paths[0].closed {
                pieces.append((paths[0], true, true))
            } else {
                if fill != nil, let filled = SVGImporter.bridged(paths) { pieces.append((filled, true, false)) }
                for path in paths { pieces.append((path, false, true)) }
            }
            var out: [VectorShape] = []
            for piece in pieces {
                let pieceFill = piece.fill ? fill : nil
                let pieceStroke = piece.stroke ? stroke : nil
                guard pieceFill != nil || pieceStroke != nil else { continue }
                var shape = VectorShape(id: makeID(), path: piece.path, fill: pieceFill, stroke: pieceStroke)
                shape.gradient = pieceFill == nil ? nil : gradient
                shape.apply(transform)
                out.append(shape)
            }
            return out
        }

        /// The first stop color of a gradient or pattern-free paint server, for outlines
        /// and when a gradient has a single stop.
        func solidColor(of id: String) -> RGBAColor? {
            stops(of: id).first?.color
        }

        /// Follows `href` links (up to a few) to find an attribute of a gradient.
        func gradientAttribute(_ key: String, of element: MarkupElement) -> String? {
            var current: MarkupElement? = element
            for _ in 0..<8 {
                guard let e = current else { return nil }
                if let value = e.attributes[key] { return value }
                current = (e.attributes["href"] ?? e.attributes["xlink:href"]).flatMap { href in
                    href.hasPrefix("#") ? ids[String(href.dropFirst())] : nil
                }
            }
            return nil
        }

        /// A gradient's stops, from it or the gradient it links to.
        func stops(of id: String) -> [GradientStop] {
            var current = ids[id]
            for _ in 0..<8 {
                guard let e = current else { return [] }
                let stopElements = e.children.filter { $0.name == "stop" }
                if !stopElements.isEmpty {
                    var out: [GradientStop] = []
                    var last = 0.0
                    for stop in stopElements {
                        var props: [String: String] = stop.attributes
                        for (key, value) in SVGImporter.declarations(stop.attributes["style"] ?? "") { props[key] = value }
                        let offsetText = props["offset"] ?? "0"
                        var offset = offsetText.hasSuffix("%")
                            ? (Double(offsetText.dropLast()) ?? 0) / 100 : (Double(offsetText) ?? 0)
                        offset = min(max(offset, last), 1)
                        last = offset
                        var color = props["stop-color"].flatMap(SVGImporter.color) ?? .black
                        if let opacity = props["stop-opacity"].flatMap(SVGImporter.fraction) { color.a *= opacity }
                        out.append(GradientStop(offset: offset, color: color))
                    }
                    return out
                }
                current = (e.attributes["href"] ?? e.attributes["xlink:href"]).flatMap { href in
                    href.hasPrefix("#") ? ids[String(href.dropFirst())] : nil
                }
            }
            return []
        }

        /// A linear or radial gradient in the shape's own coordinates. `bounds` is the
        /// shape's box, for gradients in `objectBoundingBox` units.
        func gradient(_ id: String, bounds: Rect) -> ShapeGradient? {
            guard let element = ids[id], element.name == "linearGradient" || element.name == "radialGradient" else { return nil }
            var stops = self.stops(of: id)
            guard !stops.isEmpty else { return nil }
            if stops.count > ShapeGradient.maxStops { stops = Array(stops.prefix(ShapeGradient.maxStops)) }
            let userSpace = gradientAttribute("gradientUnits", of: element) == "userSpaceOnUse"
            func coordinate(_ key: String, _ fallback: Double) -> Double {
                guard let text = gradientAttribute(key, of: element)?.trimmingCharacters(in: .whitespaces) else { return fallback }
                if text.hasSuffix("%") { return (Double(text.dropLast()) ?? fallback * 100) / 100 }
                return SVGImporter.length(text) ?? fallback
            }
            var space = SVGImporter.transform(gradientAttribute("gradientTransform", of: element) ?? "")
            if !userSpace {
                guard !bounds.isNull else { return nil }
                let box = Affine2D.translation(bounds.minPoint) * Affine2D.scale(x: max(bounds.width, 1e-9),
                                                                                  y: max(bounds.height, 1e-9))
                space = box * space
            }
            if element.name == "linearGradient" {
                let start = Vec2(coordinate("x1", 0), coordinate("y1", 0))
                let end = Vec2(coordinate("x2", 1), coordinate("y2", 0))
                return ShapeGradient(kind: .linear, start: space.apply(start), end: space.apply(end), stops: stops)
            }
            let center = Vec2(coordinate("cx", 0.5), coordinate("cy", 0.5))
            let r = coordinate("r", 0.5)
            return ShapeGradient(kind: .radial, start: space.apply(center), end: space.apply(center + Vec2(r, 0)), stops: stops)
        }
    }

    /// A number in 0...1, also accepted as a percentage.
    static func fraction(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        let value = s.hasSuffix("%") ? Double(s.dropLast()).map { $0 / 100 } : Double(s)
        return value.map { min(max($0, 0), 1) }
    }

    /// The name a group gives its part.
    static func partName(_ element: MarkupElement) -> String? {
        for key in ["data-name", "inkscape:label", "id"] {
            if let name = element.attributes[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                // Illustrator writes spaces in ids as _x5F_ style escapes and _ for spaces.
                return key == "id" ? name.replacingOccurrences(of: "_x5F_", with: "_") : name
            }
        }
        return nil
    }

    /// A rectangle with elliptical corners `rx` by `ry`.
    static func roundedRect(_ r: Rect, rx: Double, ry: Double) -> BezierPath {
        guard rx > 1e-9, ry > 1e-9 else { return ShapePrimitives.rectangle(r) }
        if abs(rx - ry) < 1e-9 { return ShapePrimitives.rectangle(r, cornerRadius: rx) }
        let x0 = r.minPoint.x, y0 = r.minPoint.y, x1 = r.maxPoint.x, y1 = r.maxPoint.y
        let kx = rx * ShapePrimitives.kappa, ky = ry * ShapePrimitives.kappa
        let points = [
            PathPoint(Vec2(x0 + rx, y0), in: Vec2(-kx, 0), out: .zero, mode: .smooth),
            PathPoint(Vec2(x1 - rx, y0), in: .zero, out: Vec2(kx, 0), mode: .smooth),
            PathPoint(Vec2(x1, y0 + ry), in: Vec2(0, -ky), out: .zero, mode: .smooth),
            PathPoint(Vec2(x1, y1 - ry), in: .zero, out: Vec2(0, ky), mode: .smooth),
            PathPoint(Vec2(x1 - rx, y1), in: Vec2(kx, 0), out: .zero, mode: .smooth),
            PathPoint(Vec2(x0 + rx, y1), in: .zero, out: Vec2(-kx, 0), mode: .smooth),
            PathPoint(Vec2(x0, y1 - ry), in: Vec2(0, ky), out: .zero, mode: .smooth),
            PathPoint(Vec2(x0, y0 + ry), in: .zero, out: Vec2(0, -ky), mode: .smooth),
        ]
        return BezierPath(points: ShapePrimitives.mergingCoincident(points), closed: true)
    }

    /// One closed path that fills like the given subpaths together, holes included:
    /// each subpath is wound by how deeply it is nested (outer rings one way, holes
    /// the other), and they are joined by hairline bridges that run out and back along
    /// the same line, so they add no area. Nil with no subpaths.
    static func bridged(_ paths: [BezierPath]) -> BezierPath? {
        let rings = paths.map { path -> BezierPath in
            var closed = path
            closed.closed = true
            return closed
        }
        let polygons = rings.map { $0.flattened(tolerance: 0.5) }
        // Nothing to fill when the rings enclose no area (a lone straight line).
        let enclosed = polygons.reduce(0.0) { total, poly in
            var area = 0.0
            for i in poly.indices { area += poly[i].cross(poly[(i + 1) % poly.count]) }
            return total + abs(area)
        }
        guard !rings.isEmpty, enclosed > 1e-9 else { return nil }
        if rings.count == 1 { return rings[0] }
        var out: [PathPoint] = []
        for (index, ring) in rings.enumerated() {
            let poly = polygons[index]
            guard poly.count >= 3, let probe = poly.first else { continue }
            // How many other rings this one sits inside.
            var depth = 0
            for (other, outer) in polygons.enumerated() where other != index && outer.count >= 3 {
                if windingNumber(of: probe, polygon: outer) != 0 { depth += 1 }
            }
            var area = 0.0
            for i in poly.indices { area += poly[i].cross(poly[(i + 1) % poly.count]) }
            let wantPositive = depth % 2 == 0
            var points = ((area >= 0) == wantPositive ? ring : ring.reversed()).points
            guard !points.isEmpty else { continue }
            // Enter at the first point and come back to it: the entry has no incoming
            // handle and the return copy no outgoing one, so the bridges are straight.
            var back = points[0]
            back.outHandle = .zero
            back.mode = .corner
            points[0].inHandle = .zero
            points[0].mode = .corner
            out += points
            out.append(back)
        }
        guard out.count >= 3 else { return nil }
        return BezierPath(points: out, closed: true)
    }

    /// CSS color names.
    static let namedColors: [String: String] = {
        let table = """
        aliceblue F0F8FF antiquewhite FAEBD7 aqua 00FFFF aquamarine 7FFFD4 azure F0FFFF beige F5F5DC bisque FFE4C4 \
        black 000000 blanchedalmond FFEBCD blue 0000FF blueviolet 8A2BE2 brown A52A2A burlywood DEB887 \
        cadetblue 5F9EA0 chartreuse 7FFF00 chocolate D2691E coral FF7F50 cornflowerblue 6495ED cornsilk FFF8DC \
        crimson DC143C cyan 00FFFF darkblue 00008B darkcyan 008B8B darkgoldenrod B8860B darkgray A9A9A9 \
        darkgreen 006400 darkgrey A9A9A9 darkkhaki BDB76B darkmagenta 8B008B darkolivegreen 556B2F \
        darkorange FF8C00 darkorchid 9932CC darkred 8B0000 darksalmon E9967A darkseagreen 8FBC8F \
        darkslateblue 483D8B darkslategray 2F4F4F darkslategrey 2F4F4F darkturquoise 00CED1 darkviolet 9400D3 \
        deeppink FF1493 deepskyblue 00BFFF dimgray 696969 dimgrey 696969 dodgerblue 1E90FF firebrick B22222 \
        floralwhite FFFAF0 forestgreen 228B22 fuchsia FF00FF gainsboro DCDCDC ghostwhite F8F8FF gold FFD700 \
        goldenrod DAA520 gray 808080 grey 808080 green 008000 greenyellow ADFF2F honeydew F0FFF0 hotpink FF69B4 \
        indianred CD5C5C indigo 4B0082 ivory FFFFF0 khaki F0E68C lavender E6E6FA lavenderblush FFF0F5 \
        lawngreen 7CFC00 lemonchiffon FFFACD lightblue ADD8E6 lightcoral F08080 lightcyan E0FFFF \
        lightgoldenrodyellow FAFAD2 lightgray D3D3D3 lightgreen 90EE90 lightgrey D3D3D3 lightpink FFB6C1 \
        lightsalmon FFA07A lightseagreen 20B2AA lightskyblue 87CEFA lightslategray 778899 lightslategrey 778899 \
        lightsteelblue B0C4DE lightyellow FFFFE0 lime 00FF00 limegreen 32CD32 linen FAF0E6 magenta FF00FF \
        maroon 800000 mediumaquamarine 66CDAA mediumblue 0000CD mediumorchid BA55D3 mediumpurple 9370DB \
        mediumseagreen 3CB371 mediumslateblue 7B68EE mediumspringgreen 00FA9A mediumturquoise 48D1CC \
        mediumvioletred C71585 midnightblue 191970 mintcream F5FFFA mistyrose FFE4E1 moccasin FFE4B5 \
        navajowhite FFDEAD navy 000080 oldlace FDF5E6 olive 808000 olivedrab 6B8E23 orange FFA500 \
        orangered FF4500 orchid DA70D6 palegoldenrod EEE8AA palegreen 98FB98 paleturquoise AFEEEE \
        palevioletred DB7093 papayawhip FFEFD5 peachpuff FFDAB9 peru CD853F pink FFC0CB plum DDA0DD \
        powderblue B0E0E6 purple 800080 rebeccapurple 663399 red FF0000 rosybrown BC8F8F royalblue 4169E1 \
        saddlebrown 8B4513 salmon FA8072 sandybrown F4A460 seagreen 2E8B57 seashell FFF5EE sienna A0522D \
        silver C0C0C0 skyblue 87CEEB slateblue 6A5ACD slategray 708090 slategrey 708090 snow FFFAFA \
        springgreen 00FF7F steelblue 4682B4 tan D2B48C teal 008080 thistle D8BFD8 tomato FF6347 \
        turquoise 40E0D0 violet EE82EE wheat F5DEB3 white FFFFFF whitesmoke F5F5F5 yellow FFFF00 \
        yellowgreen 9ACD32
        """
        let words = table.split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [String: String] = [:]
        for i in stride(from: 0, to: words.count - 1, by: 2) { out[words[i]] = words[i + 1] }
        return out
    }()
}

extension DrawingEditor {
    /// Adds imported parts on top of the art with fresh ids and unique names, and
    /// selects them (one part as a part). Ends isolation, so the new art can be
    /// touched. One undo step. False when there is nothing to add.
    @discardableResult
    public mutating func importParts(_ parts: [Part]) -> Bool {
        let parts = parts.filter { !$0.shapes.isEmpty }
        guard !parts.isEmpty else { return false }
        cancelGesture()
        if let pen = penPath, drawing.indices(part: pen.part, shape: pen.shape) != nil { penFinish() }
        exitIsolation()
        let before = drawing
        var added: [Int] = []
        var refs: Set<ShapeRef> = []
        for part in parts {
            var copy = Part(id: drawing.makeID(), name: drawing.uniquePartName(part.name), pivot: part.pivot)
            for shape in part.shapes {
                var fresh = shape
                fresh.id = drawing.makeID()
                copy.shapes.append(fresh)
                refs.insert(ShapeRef(part: copy.id, shape: fresh.id))
            }
            copy.groups = part.groups
            drawing.renewGroups(of: &copy)
            drawing.parts.append(copy)
            added.append(copy.id)
        }
        selection = added.count == 1 ? .layer(added[0]) : .covering(refs)
        commit(from: before)
        return true
    }

    /// The art as an SVG document (see `SVGWriter`), or nil when there is nothing to export.
    public func svgDocument() -> String? {
        SVGWriter.document(for: drawing)
    }
}
