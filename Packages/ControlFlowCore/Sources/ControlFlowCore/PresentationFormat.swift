import Foundation

/// A presentation read from `presentation.json`, before reference image pixels are attached.
public struct DecodedPresentation: Sendable {
    public var presentation: Presentation
    /// The package-relative image file for each reference image, by reference id.
    public var referenceFiles: [Int: String]

    /// The opening state.
    public var drawing: Drawing { presentation.opening }
}

/// Reads and writes format 1.1, `presentation.json` (see `Schema/` in the repository):
/// the opening state in full, then each keyframe as its changes from the one before.
public enum PresentationFormat {
    public static let version = FormatVersion(1, 1)
    /// The oldest version this build can open.
    public static let oldestReadable = FormatVersion(1, 0)

    // MARK: Encoding

    /// The file for a presentation with only an opening state.
    public static func encode(_ drawing: Drawing, referenceFiles: [Int: String] = [:]) -> JSONValue {
        encode(Presentation(opening: drawing), referenceFiles: referenceFiles)
    }

    /// `referenceFiles` names the package file holding each reference image's pixels.
    /// Numbers are rounded to 4 decimals.
    public static func encode(_ presentation: Presentation, referenceFiles: [Int: String] = [:]) -> JSONValue {
        let opening = presentation.opening
        var references: [JSONValue] = []
        for ref in opening.references {
            if let file = referenceFiles[ref.id] { references.append(reference(ref, file: file)) }
        }
        let file: JSONValue = .object([
            (key: "formatVersion", value: .string(version.description)),
            (key: "name", value: .string(opening.name)),
            (key: "viewport", value: SceneJSON.viewport(opening.viewport)),
            (key: "palette", value: .array(opening.palette.map(SceneJSON.color))),
            (key: "globalColors", value: .array(opening.globalColors.map(SceneJSON.globalColor))),
            (key: "references", value: .array(references)),
            (key: "opening", value: .object([(key: "layers", value: .array(opening.layers.map(SceneJSON.layer)))])),
            (key: "sequences", value: .array(presentation.sequences.map(sequence))),
        ])
        return file.rounded()
    }

    private static func sequence(_ sequence: KeyframeSequence) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "id", value: SceneJSON.id(sequence.id))]
        if let name = sequence.name { members.append((key: "name", value: .string(name))) }
        members.append((key: "keyframes", value: .array(sequence.keyframes.map(keyframe))))
        return .object(members)
    }

    private static func keyframe(_ keyframe: Keyframe) -> JSONValue {
        var members: [(key: String, value: JSONValue)] = [(key: "id", value: SceneJSON.id(keyframe.id))]
        if let name = keyframe.name { members.append((key: "name", value: .string(name))) }
        let curve: JSONValue
        if let name = keyframe.transition.curve.name {
            curve = .string(name)
        } else {
            let c = keyframe.transition.curve.controlPoints
            curve = .array([c.x1, c.y1, c.x2, c.y2].map(SceneJSON.num))
        }
        members.append((key: "transition", value: .object([(key: "duration", value: SceneJSON.num(keyframe.transition.duration)),
                                                           (key: "curve", value: curve)])))
        members.append((key: "changes", value: .array(keyframe.changes.map(change))))
        return .object(members)
    }

    static func change(_ change: SceneChange) -> JSONValue {
        switch change {
        case .set(let id, let props):
            return .object([(key: "set", value: SceneJSON.id(id)),
                            (key: "props", value: .object(props.map { (key: $0.key, value: $0.value) }))])
        case .create(let object, let parent, let after, let before, let t):
            var members: [(key: String, value: JSONValue)] = [(key: "create", value: SceneJSON.object(object))]
            if let parent { members.append((key: "in", value: SceneJSON.id(parent))) }
            if let after { members.append((key: "after", value: SceneJSON.id(after))) }
            if let before { members.append((key: "before", value: SceneJSON.id(before))) }
            if let t { members.append((key: "t", value: SceneJSON.num(t))) }
            return .object(members)
        case .delete(let id, let t):
            var members: [(key: String, value: JSONValue)] = [(key: "delete", value: SceneJSON.id(id))]
            if let t { members.append((key: "t", value: SceneJSON.num(t))) }
            return .object(members)
        case .order(let parent, let ids):
            var members: [(key: String, value: JSONValue)] = [(key: "order", value: .array(ids.map(SceneJSON.id)))]
            if let parent { members.append((key: "in", value: SceneJSON.id(parent))) }
            return .object(members)
        }
    }

    private static func reference(_ ref: ReferenceImage, file: String) -> JSONValue {
        .object([
            (key: "name", value: .string(ref.name)),
            (key: "file", value: .string(file)),
            (key: "width", value: SceneJSON.num(ref.size.x)),
            (key: "height", value: SceneJSON.num(ref.size.y)),
            (key: "x", value: SceneJSON.num(ref.center.x)),
            (key: "y", value: SceneJSON.num(ref.center.y)),
            (key: "rotation", value: SceneJSON.num(ref.rotation * 180 / .pi)),
            (key: "scale", value: SceneJSON.num(ref.scale)),
            (key: "opacity", value: SceneJSON.num(ref.opacity)),
            (key: "hidden", value: .bool(ref.isHidden)),
        ])
    }

    // MARK: Decoding

    /// Reads the file. Every id must be a positive whole number used once (keyframes'
    /// and sequences' included), and every change must refer to objects there at its
    /// keyframe; errors name the JSON path of the problem.
    public static func decode(_ json: JSONValue) throws -> DecodedPresentation {
        let root = Node(root: try migrate(json))
        _ = try root.members()
        var opening = Drawing()
        var ids = IDRegistry()
        opening.name = try root.string("name") ?? "Untitled"
        if let node = try root.field("viewport") {
            opening.viewport = try SceneJSON.readViewport(node)
            if opening.viewport.id != 0 { try ids.claim(opening.viewport.id, at: node.childPath("id")) }
        }
        opening.palette = try root.field("palette")?.array().map { try $0.color() } ?? []
        for node in try root.field("globalColors")?.array() ?? [] {
            let global = try SceneJSON.readGlobalColor(node)
            try ids.claim(global.id, at: node.childPath("id"))
            opening.globalColors.append(GlobalColor(id: global.id, name: opening.uniqueGlobalColorName(global.name), color: global.color))
        }
        let context = SceneJSON.Context(globals: Set(opening.globalColors.map(\.id)))
        for node in try root.field("opening")?.field("layers")?.array() ?? [] {
            let layer = try SceneJSON.readLayer(node, context: context)
            try ids.claimTree(node, created: false)
            opening.layers.append(layer)
        }

        // Keyframes, each checked against the state before it.
        var sequences: [KeyframeSequence] = []
        var state = opening
        state.syncGlobalColors()
        var lookup = SceneLookup(state)
        for sequenceNode in try root.field("sequences")?.array() ?? [] {
            var sequence = KeyframeSequence(id: try SceneJSON.readID(sequenceNode), name: try sequenceNode.string("name"))
            try ids.claimTimeline(sequence.id, at: sequenceNode.childPath("id"))
            for keyframeNode in try sequenceNode.require("keyframes").array() {
                var keyframe = Keyframe(id: try SceneJSON.readID(keyframeNode), name: try keyframeNode.string("name"))
                try ids.claimTimeline(keyframe.id, at: keyframeNode.childPath("id"))
                if let transition = try keyframeNode.field("transition") { keyframe.transition = try self.transition(transition) }
                for changeNode in try keyframeNode.field("changes")?.array() ?? [] {
                    let change = try self.change(changeNode, state: state, lookup: lookup)
                    if case .create = change { try ids.claimTree(changeNode.require("create"), created: true) }
                    guard state.apply(change, lookup: &lookup) else {
                        throw PresentationFileError.invalid(path: changeNode.path, problem: "doesn't apply to the state before it")
                    }
                    keyframe.changes.append(change)
                }
                state.syncGlobalColors()
                if !state.groupsAreValid { state.repairGroups() }
                sequence.keyframes.append(keyframe)
            }
            guard !sequence.keyframes.isEmpty else {
                throw PresentationFileError.invalid(path: sequenceNode.childPath("keyframes"), problem: "is empty")
            }
            sequences.append(sequence)
        }

        // Groups stay whole, and objects read without an id (only the viewport may) get one.
        if !opening.groupsAreValid { opening.repairGroups() }
        opening.nextID = max(ids.next, opening.nextID)
        if opening.viewport.id == 0 { opening.viewport.id = opening.makeID() }

        var files: [Int: String] = [:]
        for node in try root.field("references")?.array() ?? [] {
            let id = opening.makeID()
            var ref = ReferenceImage(id: id, name: try node.string("name") ?? "Reference",
                                     size: Vec2(try node.requireNumber("width"), try node.requireNumber("height")),
                                     center: Vec2(try node.number("x") ?? 0, try node.number("y") ?? 0))
            ref.rotation = (try node.number("rotation") ?? 0) * .pi / 180
            ref.scale = try node.number("scale") ?? 1
            ref.opacity = min(max(try node.number("opacity") ?? 0.5, 0), 1)
            ref.isHidden = try node.bool("hidden") ?? false
            opening.references.append(ref)
            files[id] = try node.require("file").string()
        }
        return DecodedPresentation(presentation: Presentation(opening: opening, sequences: sequences), referenceFiles: files)
    }

    private static func transition(_ node: Node) throws -> Transition {
        let duration = try node.number("duration") ?? Transition.standard.duration
        guard duration >= 0 else { throw PresentationFileError.invalid(path: node.childPath("duration"), problem: "is negative") }
        var curve = TimingCurve.easeInOut
        if let curveNode = try node.field("curve") {
            if case .string(let name) = curveNode.value {
                guard let named = TimingCurve(name: name) else {
                    let names = TimingCurve.presets.compactMap(\.name).map { "\"\($0)\"" }.joined(separator: ", ")
                    throw curveNode.fail("is not one of \(names) or [x1, y1, x2, y2]")
                }
                curve = named
            } else {
                let values = try curveNode.array().map { try $0.number() }
                guard values.count == 4 else { throw curveNode.fail("is not one of the named curves or [x1, y1, x2, y2]") }
                guard (0...1).contains(values[0]), (0...1).contains(values[2]) else {
                    throw curveNode.fail("has an x outside 0...1")
                }
                curve = .custom(x1: values[0], y1: values[1], x2: values[2], y2: values[3])
            }
        }
        return Transition(duration: duration, curve: curve)
    }

    private static func change(_ node: Node, state: Drawing, lookup: SceneLookup) throws -> SceneChange {
        let members = try node.members()
        let kinds = ["set", "create", "delete", "order"].filter { key in members.contains { $0.key == key } }
        guard kinds.count == 1 else { throw node.fail("is not one change: set, create, delete or order") }
        func target(_ key: String) throws -> Int {
            let id = try node.require(key).integer()
            guard state.exists(id, lookup) else { throw PresentationFileError.invalid(path: node.childPath(key), problem: "is not an object there") }
            return id
        }
        switch kinds[0] {
        case "set":
            let id = try target("set")
            let props = try node.require("props")
            let allowed = Drawing.settableKeys(lookup.kinds[id]!)
            var out: [PropertyChange] = []
            for (key, value) in try props.members() {
                guard allowed.contains(PropertyPath.root(of: key)) else {
                    throw PresentationFileError.invalid(path: props.childPath(key), problem: "is not a property that can be set here")
                }
                out.append(PropertyChange(key, value))
            }
            return .set(id: id, props: out)
        case "create":
            let parent = try node.field("in").map { _ in try target("in") }
            let objectNode = try node.require("create")
            let context = SceneJSON.Context(globals: Set(state.globalColors.map(\.id)),
                                            groups: parent.flatMap(state.layerIndex).map { Set(state.layers[$0].groups.map(\.id)) } ?? [])
            let object: SceneObject
            switch parent.flatMap({ lookup.kinds[$0] }) {
            case nil: object = .layer(try SceneJSON.readLayer(objectNode, context: context))
            case .layer?:
                object = try objectNode.field("points") != nil ? .shape(try SceneJSON.readShape(objectNode, context: context))
                    : .group(try SceneJSON.readGroup(objectNode))
            case .shape?: object = .vertex(try SceneJSON.readVertex(objectNode))
            default: throw PresentationFileError.invalid(path: node.childPath("in"), problem: "can't hold objects")
            }
            var t = try node.number("t")
            if let value = t { t = min(max(value, 0), 1) }
            return .create(object, parent: parent, after: try node.integer("after"), before: try node.integer("before"), t: t)
        case "delete":
            let id = try target("delete")
            guard let kind = lookup.kinds[id], kind != .viewport, kind != .globalColor else {
                throw PresentationFileError.invalid(path: node.childPath("delete"), problem: "can't be deleted by a keyframe")
            }
            var t = try node.number("t")
            if let value = t { t = min(max(value, 0), 1) }
            return .delete(id: id, t: t)
        default:
            let parent = try node.field("in").map { _ in try target("in") }
            let ids = try node.require("order").array().map { try $0.integer() }
            let children: [Int]
            switch parent.flatMap({ lookup.kinds[$0] }) {
            case nil: children = state.layers.map(\.id)
            case .layer?: children = state.layers[state.layerIndex(parent!)!].shapes.map(\.id)
            case .shape?:
                let (l, s) = state.shapeLocation(parent!, lookup)!
                children = state.layers[l].shapes[s].path.points.map(\.id)
            default: throw PresentationFileError.invalid(path: node.childPath("in"), problem: "has no order")
            }
            guard Set(ids).count == ids.count, Set(ids).isSubset(of: children) else {
                throw PresentationFileError.invalid(path: node.childPath("order"), problem: "lists objects that aren't its children")
            }
            return .order(parent: parent, ids: ids)
        }
    }

    /// Ids seen so far. Each is used once, except that a keyframe can create an object
    /// with the id of one no longer there (a shape moving to another layer).
    private struct IDRegistry {
        var objects = Set<Int>(), timeline = Set<Int>()
        var next: Int { max(objects.max() ?? 0, timeline.max() ?? 0) + 1 }

        /// Claims a keyframe's or sequence's id.
        mutating func claimTimeline(_ id: Int, at path: String) throws {
            try check(id, at: path)
            guard !objects.contains(id), timeline.insert(id).inserted else {
                throw PresentationFileError.invalid(path: path, problem: "repeats id \(id)")
            }
        }

        mutating func claim(_ id: Int, at path: String, created: Bool = false) throws {
            try check(id, at: path)
            guard !timeline.contains(id), objects.insert(id).inserted || created else {
                throw PresentationFileError.invalid(path: path, problem: "repeats id \(id)")
            }
        }

        /// Claims the ids of an object read from `node` and of everything in it. A created
        /// object's ids may have been used before, but not twice within it.
        mutating func claimTree(_ node: Node, created: Bool) throws {
            var inside = Set<Int>()
            func visit(_ node: Node) throws {
                let path = node.childPath("id")
                let id = try node.require("id").integer()
                try claim(id, at: path, created: created)
                guard inside.insert(id).inserted else { throw PresentationFileError.invalid(path: path, problem: "repeats id \(id)") }
                for key in ["groups", "shapes", "points"] {
                    for child in try node.field(key)?.array() ?? [] { try visit(child) }
                }
            }
            try visit(node)
        }

        private func check(_ id: Int, at path: String) throws {
            guard id > 0 else { throw PresentationFileError.invalid(path: path, problem: "is not a positive id") }
        }
    }

    // MARK: Versions

    /// One upgrade step, applied to files older than `to`.
    struct Migration: Sendable {
        var to: FormatVersion
        var apply: @Sendable (JSONValue) throws -> JSONValue
    }

    /// Upgrade steps, oldest first. Add one here whenever the format changes in a way
    /// older files need rewriting, and bump `version`. Format 1.0 starts afresh.
    static let migrations: [Migration] = []

    /// Checks `formatVersion` and upgrades an older file to the current format.
    public static func migrate(_ json: JSONValue) throws -> JSONValue {
        guard case .object = json else {
            throw PresentationFileError.invalid(path: "(root)", problem: "is not an object")
        }
        guard let field = json["formatVersion"] else {
            throw PresentationFileError.invalid(path: "formatVersion", problem: "is missing")
        }
        guard case .string(let text) = field, let fileVersion = FormatVersion(text) else {
            throw PresentationFileError.invalid(path: "formatVersion", problem: "is not a version like \"1.0\"")
        }
        // From 1.0 only a new major version breaks compatibility.
        if fileVersion.major > version.major { throw PresentationFileError.newerVersion(text) }
        guard fileVersion >= oldestReadable else { throw PresentationFileError.unsupportedVersion(text) }
        var upgraded = json
        for step in migrations where fileVersion < step.to {
            upgraded = try step.apply(upgraded)
        }
        return upgraded
    }

    /// `names` made unique and non-empty, in order: a repeat gets " 2", " 3"...
    static func uniqueNames(_ names: [String], fallback: String) -> [String] {
        var used = Set<String>()
        return names.map { name in
            let base = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : name
            var unique = base
            var n = 2
            while used.contains(unique) {
                unique = "\(base) \(n)"
                n += 1
            }
            used.insert(unique)
            return unique
        }
    }
}
