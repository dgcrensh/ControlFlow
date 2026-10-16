import Foundation

/// The JSON of the scene's objects as format 1.0 writes them (see `Schema/README.md`),
/// shared by the file and by keyframe changes, whose `set` keys are dotted paths into it.
///
/// Numbers are written at full precision here; `PresentationFormat` rounds the whole file
/// as it writes it. Optional keys are written only when they aren't their defaults.
///
/// Each object's JSON splits into its id, its *properties* (what a keyframe can `set`),
/// its *editor hints* and names (the same at every keyframe, so never keyed) and its
/// children (layers hold groups and shapes, shapes hold points), which are objects of
/// their own.
enum SceneJSON {
    // MARK: Values

    static func num(_ x: Double) -> JSONValue { x.isFinite ? .number(x == 0 ? 0 : x) : .number(0) }

    static func vec(_ v: Vec2) -> JSONValue { .array([num(v.x), num(v.y)]) }

    static func color(_ c: RGBAColor) -> JSONValue { .string(c.hexString) }

    static func id(_ id: Int) -> JSONValue { .number(Double(id)) }

    // MARK: Properties

    /// A transform's non-default keys, or nil when it has none.
    static func transform(_ t: Transform) -> JSONValue? {
        // Compared as written (to 4 decimals), so a value that rounds to its default
        // isn't written and the file reads back to what it says.
        func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000_05 }
        func same(_ a: Vec2, _ b: Vec2) -> Bool { same(a.x, b.x) && same(a.y, b.y) }
        var members: [(key: String, value: JSONValue)] = []
        if !same(t.position, .zero) { members.append((key: "position", value: vec(t.position))) }
        if !same(t.rotation, 0) { members.append((key: "rotation", value: num(t.rotation))) }
        if !same(t.scale, Vec2(1, 1)) { members.append((key: "scale", value: vec(t.scale))) }
        if !same(t.pivot, .zero) { members.append((key: "pivot", value: vec(t.pivot))) }
        return members.isEmpty ? nil : .object(members)
    }

    static func layerProps(_ layer: Layer) -> [(key: String, value: JSONValue)] {
        transform(layer.transform).map { [(key: "transform", value: $0)] } ?? []
    }

    static func groupProps(_ group: ShapeGroup) -> [(key: String, value: JSONValue)] {
        var members: [(key: String, value: JSONValue)] = []
        if group.isClipped { members.append((key: "clipped", value: .bool(true))) }
        if let t = transform(group.transform) { members.append((key: "transform", value: t)) }
        return members
    }

    static func shapeProps(_ shape: VectorShape) -> [(key: String, value: JSONValue)] {
        var members: [(key: String, value: JSONValue)] = []
        if let group = shape.group { members.append((key: "group", value: id(group))) }
        members.append((key: "closed", value: .bool(shape.path.closed)))
        if let text = shape.text { members.append((key: "text", value: self.text(text))) }
        if let math = shape.math { members.append((key: "math", value: self.math(math))) }
        if let image = shape.image { members.append((key: "image", value: .object([(key: "src", value: .string(image.src))]))) }
        if let fill = shape.fill {
            members.append((key: "fill", value: color(fill)))
            if let global = shape.fillGlobal { members.append((key: "fillGlobal", value: id(global))) }
            if let gradient = shape.gradient { members.append((key: "gradient", value: self.gradient(gradient))) }
        }
        if let stroke = shape.stroke { members.append((key: "stroke", value: self.stroke(stroke))) }
        if shape.opacity != 1 { members.append((key: "opacity", value: num(shape.opacity))) }
        if shape.isClipped { members.append((key: "clipped", value: .bool(true))) }
        if let t = transform(shape.transform) { members.append((key: "transform", value: t)) }
        return members
    }

    static func vertexProps(_ point: PathPoint) -> [(key: String, value: JSONValue)] {
        var members: [(key: String, value: JSONValue)] = [
            (key: "p", value: vec(point.position)),
            (key: "in", value: vec(point.inHandle)),
            (key: "out", value: vec(point.outHandle)),
        ]
        if point.width != 1 { members.append((key: "w", value: num(point.width))) }
        if !point.isSmooth { members.append((key: "smooth", value: .bool(false))) }
        if point.mode == .symmetric { members.append((key: "symmetric", value: .bool(true))) }
        if !point.stroked { members.append((key: "stroked", value: .bool(false))) }
        return members
    }

    static func stroke(_ stroke: StrokeStyle) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "color", value: color(stroke.color))]
        if let global = stroke.global { members.append((key: "global", value: id(global))) }
        members.append((key: "width", value: num(stroke.width)))
        if stroke.cap != .round { members.append((key: "cap", value: .string(stroke.cap.rawValue))) }
        if stroke.join != .round { members.append((key: "join", value: .string(stroke.join.rawValue))) }
        if stroke.miterLimit != 4 { members.append((key: "miterLimit", value: num(stroke.miterLimit))) }
        if !stroke.dash.isEmpty {
            members.append((key: "dash", value: .array(stroke.dash.map(num))))
            if stroke.dashOffset != 0 { members.append((key: "dashOffset", value: num(stroke.dashOffset))) }
        }
        if stroke.alignment != .center { members.append((key: "align", value: .string(stroke.alignment.rawValue))) }
        return .object(members)
    }

    /// A text's words, and its style where it isn't the default.
    static func text(_ text: TextContent) -> JSONValue {
        let plain = TextContent()
        var members: [(key: String, value: JSONValue)] = [(key: "string", value: .string(text.string))]
        if text.font != plain.font { members.append((key: "font", value: .string(text.font))) }
        if text.weight != plain.weight { members.append((key: "weight", value: .number(Double(text.weight)))) }
        if !text.weights.isEmpty {
            members.append((key: "weights", value: .array(text.weights.map { run in
                .object([
                    (key: "start", value: .number(Double(run.range.lowerBound))),
                    (key: "length", value: .number(Double(run.range.count))),
                    (key: "weight", value: .number(Double(run.weight))),
                ])
            })))
        }
        if text.italic { members.append((key: "italic", value: .bool(true))) }
        if text.size != plain.size { members.append((key: "size", value: num(text.size))) }
        if text.align != plain.align { members.append((key: "align", value: .string(text.align.rawValue))) }
        if let width = text.width { members.append((key: "width", value: num(width))) }
        if text.lineHeight != plain.lineHeight { members.append((key: "lineHeight", value: num(text.lineHeight))) }
        if text.tracking != plain.tracking { members.append((key: "tracking", value: num(text.tracking))) }
        return .object(members)
    }

    static func math(_ math: MathContent) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "source", value: .string(math.source))]
        if math.size != 72 { members.append((key: "size", value: num(math.size))) }
        if !math.display { members.append((key: "display", value: .bool(false))) }
        return .object(members)
    }

    static func gradient(_ gradient: ShapeGradient) -> JSONValue {
        .object([
            (key: "type", value: .string(gradient.kind.rawValue)),
            (key: "start", value: vec(gradient.start)),
            (key: "end", value: vec(gradient.end)),
            (key: "stops", value: .array(gradient.stops.map {
                .object([(key: "offset", value: num($0.offset)), (key: "color", value: color($0.color))])
            })),
        ])
    }

    static func viewportProps(_ viewport: Viewport) -> [(key: String, value: JSONValue)] {
        [(key: "background", value: color(viewport.background))]
    }

    static func globalColorProps(_ global: GlobalColor) -> [(key: String, value: JSONValue)] {
        [(key: "color", value: color(global.color))]
    }

    /// `hidden` and `locked`, written only when true.
    static func hints(hidden: Bool, locked: Bool) -> [(key: String, value: JSONValue)] {
        var members: [(key: String, value: JSONValue)] = []
        if hidden { members.append((key: "hidden", value: .bool(true))) }
        if locked { members.append((key: "locked", value: .bool(true))) }
        return members
    }

    // MARK: Whole objects

    static func layer(_ layer: Layer) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "id", value: id(layer.id)), (key: "name", value: .string(layer.name))]
        members += layerProps(layer)
        members += hints(hidden: layer.isHidden, locked: layer.isLocked)
        if !layer.groups.isEmpty { members.append((key: "groups", value: .array(layer.groups.map(group)))) }
        members.append((key: "shapes", value: .array(layer.shapes.map(shape))))
        return .object(members)
    }

    static func group(_ group: ShapeGroup) -> JSONValue {
        .object([(key: "id", value: id(group.id)), (key: "name", value: .string(group.name))] + groupProps(group))
    }

    static func shape(_ shape: VectorShape) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "id", value: id(shape.id))]
        members += shapeProps(shape)
        members += hints(hidden: shape.isHidden, locked: shape.isLocked)
        members.append((key: "points", value: .array(shape.path.points.map(vertex))))
        return .object(members)
    }

    static func vertex(_ point: PathPoint) -> JSONValue {
        .object([(key: "id", value: id(point.id))] + vertexProps(point))
    }

    static func viewport(_ viewport: Viewport) -> JSONValue {
        .object([(key: "id", value: id(viewport.id)), (key: "width", value: num(viewport.width)),
                 (key: "height", value: num(viewport.height))] + viewportProps(viewport))
    }

    static func globalColor(_ global: GlobalColor) -> JSONValue {
        .object([(key: "id", value: id(global.id)), (key: "name", value: .string(global.name))] + globalColorProps(global))
    }

    static func object(_ object: SceneObject) -> JSONValue {
        switch object {
        case .layer(let layer): self.layer(layer)
        case .group(let group): self.group(group)
        case .shape(let shape): self.shape(shape)
        case .vertex(let point): vertex(point)
        }
    }

    // MARK: Reading

    /// What objects being read can refer to.
    struct Context {
        /// Global color ids; a shape following an unknown one keeps its plain color.
        var globals: Set<Int>
        /// The ids of the groups of the layer being read; a shape in an unknown group is
        /// read ungrouped.
        var groups: Set<Int> = []
    }

    static func readID(_ node: Node) throws -> Int {
        let id = try node.require("id").integer()
        guard id > 0 else { throw PresentationFileError.invalid(path: node.childPath("id"), problem: "is not a positive id") }
        return id
    }

    static func readTransform(_ node: Node) throws -> Transform {
        Transform(position: try node.vec2("position") ?? .zero, rotation: try node.number("rotation") ?? 0,
                  scale: try node.vec2("scale") ?? Vec2(1, 1), pivot: try node.vec2("pivot") ?? .zero)
    }

    /// Sets a layer's properties from `node` (its JSON, or a props object made from it).
    static func readLayerProps(_ node: Node, into layer: inout Layer) throws {
        layer.transform = try node.field("transform").map(readTransform) ?? .identity
    }

    static func readGroupProps(_ node: Node, into group: inout ShapeGroup) throws {
        group.isClipped = try node.bool("clipped") ?? false
        group.transform = try node.field("transform").map(readTransform) ?? .identity
    }

    /// Sets everything of a shape but its id, hints and points.
    static func readShapeProps(_ node: Node, into shape: inout VectorShape, context: Context) throws {
        shape.group = try node.integer("group").flatMap { context.groups.contains($0) ? $0 : nil }
        shape.path.closed = try node.bool("closed") ?? false
        shape.fill = try node.color("fill")
        shape.fillGlobal = nil
        shape.gradient = nil
        if shape.fill != nil {
            shape.fillGlobal = try node.integer("fillGlobal").flatMap { context.globals.contains($0) ? $0 : nil }
            shape.gradient = try node.field("gradient").map(readGradient)
        }
        shape.text = try node.field("text").map(readText)
        shape.math = try node.field("math").map(readMath)
        shape.image = try node.field("image").map(readImage)
        shape.stroke = try node.field("stroke").map { try readStroke($0, context: context) }
        shape.opacity = min(max(try node.number("opacity") ?? 1, 0), 1)
        shape.isClipped = try node.bool("clipped") ?? false
        shape.transform = try node.field("transform").map(readTransform) ?? .identity
    }

    /// Sets everything of a point but its id.
    static func readVertexProps(_ node: Node, into point: inout PathPoint) throws {
        point.position = try node.requireVec2("p")
        point.inHandle = try node.vec2("in") ?? .zero
        point.outHandle = try node.vec2("out") ?? .zero
        point.width = 1
        if let width = try node.number("w") {
            guard width >= 0 else { throw PresentationFileError.invalid(path: node.childPath("w"), problem: "is negative") }
            point.width = width
        }
        point.mode = .smooth
        point.isSmooth = try node.bool("smooth") ?? true
        if point.isSmooth, try node.bool("symmetric") ?? false { point.mode = .symmetric }
        point.stroked = try node.bool("stroked") ?? true
    }

    static func readStroke(_ node: Node, context: Context) throws -> StrokeStyle {
        let width = try node.requireNumber("width")
        guard width >= 0 else { throw PresentationFileError.invalid(path: node.childPath("width"), problem: "is negative") }
        var stroke = StrokeStyle(color: try node.requireColor("color"), width: width)
        stroke.global = try node.integer("global").flatMap { context.globals.contains($0) ? $0 : nil }
        stroke.cap = try node.field("cap")?.keyword(LineCap.self) ?? .round
        stroke.join = try node.field("join")?.keyword(LineJoin.self) ?? .round
        if let limit = try node.number("miterLimit") {
            guard limit >= 1 else { throw PresentationFileError.invalid(path: node.childPath("miterLimit"), problem: "is less than 1") }
            stroke.miterLimit = limit
        }
        if let dash = try node.field("dash") {
            stroke.dash = try dash.array().map { item in
                let length = try item.number()
                guard length >= 0 else { throw PresentationFileError.invalid(path: item.path, problem: "is negative") }
                return length
            }
        }
        stroke.dashOffset = try node.number("dashOffset") ?? 0
        stroke.alignment = try node.field("align")?.keyword(StrokeAlignment.self) ?? .center
        return stroke
    }

    static func readText(_ node: Node) throws -> TextContent {
        var text = TextContent(string: try node.require("string").string())
        text.font = try node.string("font") ?? TextContent.systemFont
        if text.font.isEmpty { text.font = TextContent.systemFont }
        if let weight = try node.integer("weight") {
            text.weight = min(max(weight, TextContent.weightRange.lowerBound), TextContent.weightRange.upperBound)
        }
        if let weights = try node.field("weights") {
            text.weights = try weights.array().map { run in
                let start = try run.requireInteger("start"), length = try run.requireInteger("length")
                guard start >= 0 else { throw PresentationFileError.invalid(path: run.childPath("start"), problem: "is negative") }
                guard length >= 0 else { throw PresentationFileError.invalid(path: run.childPath("length"), problem: "is negative") }
                // Runs past the string are cut to it, so a huge number can't overflow.
                let lower = min(start, 1 << 40)
                return TextWeightRun(lower..<(lower + min(length, 1 << 40)), weight: try run.requireInteger("weight"))
            }
        }
        text.italic = try node.bool("italic") ?? false
        if let size = try node.number("size") {
            guard size > 0 else { throw PresentationFileError.invalid(path: node.childPath("size"), problem: "is not positive") }
            text.size = min(max(size, TextContent.sizeRange.lowerBound), TextContent.sizeRange.upperBound)
        }
        text.align = try node.field("align")?.keyword(TextAlignment.self) ?? .left
        if let width = try node.number("width") {
            guard width > 0 else { throw PresentationFileError.invalid(path: node.childPath("width"), problem: "is not positive") }
            text.width = width
        }
        if let lineHeight = try node.number("lineHeight") {
            text.lineHeight = min(max(lineHeight, TextContent.lineHeightRange.lowerBound), TextContent.lineHeightRange.upperBound)
        }
        text.tracking = try node.number("tracking") ?? 0
        text.normalizeWeights()
        return text
    }

    static func readMath(_ node: Node) throws -> MathContent {
        var math = MathContent(source: try node.require("source").string())
        if let size = try node.number("size") {
            guard size > 0 else { throw PresentationFileError.invalid(path: node.childPath("size"), problem: "is not positive") }
            math.size = min(max(size, TextContent.sizeRange.lowerBound), TextContent.sizeRange.upperBound)
        }
        math.display = try node.bool("display") ?? true
        return math
    }

    static func readImage(_ node: Node) throws -> ShapeImage {
        let src = try node.require("src").string()
        guard ImageAssets.isValidSource(src) else {
            throw PresentationFileError.invalid(path: node.childPath("src"), problem: "is not a file in \(ImageAssets.folder)/")
        }
        return ShapeImage(src: src)
    }

    static func readGradient(_ node: Node) throws -> ShapeGradient {
        var stops: [GradientStop] = []
        for stop in try node.require("stops").array() {
            let offset = min(max(try stop.require("offset").number(), 0), 1)
            stops.append(GradientStop(offset: offset, color: try stop.require("color").color()))
        }
        guard !stops.isEmpty else { throw PresentationFileError.invalid(path: node.childPath("stops"), problem: "is empty") }
        return ShapeGradient(kind: try node.require("type").keyword(ShapeGradient.Kind.self),
                             start: try node.require("start").vec2(), end: try node.require("end").vec2(), stops: stops)
    }

    static func readViewportProps(_ node: Node, into viewport: inout Viewport) throws {
        viewport.background = try node.color("background") ?? .white
    }

    static func readGlobalColorProps(_ node: Node, into global: inout GlobalColor) throws {
        global.color = try node.requireColor("color")
    }

    static func readLayer(_ node: Node, context: Context) throws -> Layer {
        var layer = Layer(id: try readID(node), name: try node.string("name") ?? "Layer")
        try readLayerProps(node, into: &layer)
        layer.isHidden = try node.bool("hidden") ?? false
        layer.isLocked = try node.bool("locked") ?? false
        layer.groups = try node.field("groups")?.array().map(readGroup) ?? []
        var inner = context
        inner.groups = Set(layer.groups.map(\.id))
        layer.shapes = try node.field("shapes")?.array().map { try readShape($0, context: inner) } ?? []
        return layer
    }

    static func readGroup(_ node: Node) throws -> ShapeGroup {
        var group = ShapeGroup(id: try readID(node), name: try node.string("name") ?? "Group")
        try readGroupProps(node, into: &group)
        return group
    }

    static func readShape(_ node: Node, context: Context) throws -> VectorShape {
        var shape = VectorShape(id: try readID(node), path: BezierPath())
        try readShapeProps(node, into: &shape, context: context)
        shape.isHidden = try node.bool("hidden") ?? false
        shape.isLocked = try node.bool("locked") ?? false
        shape.path.points = try node.require("points").array().map(readVertex)
        return shape
    }

    static func readVertex(_ node: Node) throws -> PathPoint {
        var point = PathPoint(.zero)
        point.id = try readID(node)
        try readVertexProps(node, into: &point)
        return point
    }

    static func readGlobalColor(_ node: Node) throws -> GlobalColor {
        var global = GlobalColor(id: try readID(node), name: try node.require("name").string(), color: .black)
        try readGlobalColorProps(node, into: &global)
        return global
    }

    static func readViewport(_ node: Node) throws -> Viewport {
        let width = try node.requireNumber("width"), height = try node.requireNumber("height")
        guard width > 0, height > 0 else { throw PresentationFileError.invalid(path: node.path, problem: "has no area") }
        var viewport = Viewport(width: width, height: height)
        viewport.id = try node.integer("id") ?? 0
        try readViewportProps(node, into: &viewport)
        return viewport
    }
}

/// Dotted property keys (`transform.rotation`, `gradient.stops.1.color`) into an object's
/// JSON: how a keyframe's `set` names what it changes.
enum PropertyPath {
    /// The value an optional key has when it isn't written, for keys with one. A change back
    /// to it is written as the value rather than as `null`.
    static let defaults: [String: JSONValue] = [
        "opacity": 1, "clipped": .bool(false),
        "transform.position": .array([0, 0]), "transform.rotation": 0, "transform.scale": .array([1, 1]),
        "transform.pivot": .array([0, 0]),
        "stroke.cap": .string("round"), "stroke.join": .string("round"), "stroke.miterLimit": 4,
        "stroke.dash": .array([]), "stroke.dashOffset": 0, "stroke.align": .string("center"),
        "w": 1, "smooth": .bool(true), "symmetric": .bool(false), "stroked": .bool(true),
        "text.font": .string(TextContent.systemFont), "text.weight": 400, "text.weights": .array([]), "text.italic": .bool(false), "text.size": 72,
        "text.align": .string("left"), "text.lineHeight": 1.2, "text.tracking": 0,
        "math.size": 72, "math.display": .bool(true),
    ]

    /// The property changes that turn `a` into `b` (both objects of the same kind): every
    /// leaf that differs. A key `b` doesn't have is set to its default (see `defaults`),
    /// or to `null` when it has none (no fill, no outline, no group). A nested object is
    /// compared key by key, as is an array of objects of the same length (gradient
    /// stops); any other array is one value.
    static func changes(from a: JSONValue, to b: JSONValue) -> [(key: String, value: JSONValue)] {
        var out: [(key: String, value: JSONValue)] = []
        diff(a, b, prefix: "", into: &out)
        return out
    }

    private static func diff(_ a: JSONValue, _ b: JSONValue, prefix: String, into out: inout [(key: String, value: JSONValue)]) {
        func key(_ k: String) -> String { prefix.isEmpty ? k : prefix + "." + k }
        switch (a, b) {
        case (.object(let am), .object(let bm)):
            let bLookup = Dictionary(bm.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            let aKeys = Set(am.map(\.key))
            for (k, av) in am {
                if let bv = bLookup[k] {
                    diff(av, bv, prefix: key(k), into: &out)
                } else {
                    out.append((key: key(k), value: defaults[key(k)] ?? .null))
                }
            }
            for (k, bv) in bm where !aKeys.contains(k) {
                // A new nested object is written key by key, so it reads like an edit of its defaults.
                if case .object = bv { diff(.object([]), bv, prefix: key(k), into: &out) } else { out.append((key: key(k), value: bv)) }
            }
        case (.array(let ai), .array(let bi)) where ai.count == bi.count && !ai.isEmpty &&
            ai.allSatisfy(\.isObject) && bi.allSatisfy(\.isObject):
            for i in ai.indices { diff(ai[i], bi[i], prefix: key(String(i)), into: &out) }
        default:
            if a != b { out.append((key: prefix, value: b)) }
        }
    }

    /// `object` with each change applied: a `null` removes the key, and missing objects on
    /// the way are made. Throws (naming the key) when a path runs into a value that isn't
    /// an object, or an index past the end of an array.
    static func apply(_ changes: [(key: String, value: JSONValue)], to object: JSONValue) throws -> JSONValue {
        var result = object
        for change in changes {
            let parts = change.key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !parts.contains(where: \.isEmpty) else { throw PathError(key: change.key) }
            guard let updated = set(result, parts[...], to: change.value) else { throw PathError(key: change.key) }
            result = updated
        }
        return result
    }

    struct PathError: Error { var key: String }

    private static func set(_ value: JSONValue, _ path: ArraySlice<String>, to new: JSONValue) -> JSONValue? {
        guard let first = path.first else { return new }
        let rest = path.dropFirst()
        switch value {
        case .object(var members):
            if let i = members.firstIndex(where: { $0.key == first }) {
                if rest.isEmpty, new.isNull {
                    members.remove(at: i)
                } else {
                    guard let child = set(members[i].value, rest, to: new) else { return nil }
                    members[i].value = child
                }
            } else if !(rest.isEmpty && new.isNull) {
                guard let child = set(.object([]), rest, to: new) else { return nil }
                members.append((key: first, value: child))
            }
            return .object(members)
        case .array(var items):
            guard let i = Int(first), items.indices.contains(i), !(rest.isEmpty && new.isNull) else { return nil }
            guard let child = set(items[i], rest, to: new) else { return nil }
            items[i] = child
            return .array(items)
        default:
            return nil
        }
    }

    /// The top-level key of a dotted path.
    static func root(of key: String) -> Substring {
        key.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first ?? Substring(key)
    }
}

extension JSONValue {
    var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}
