import Foundation

/// Where each object of a scene is, by id, so a keyframe's changes can find what they
/// refer to. Entries can go stale as objects are removed; `Drawing`'s lookups check them.
///
/// Vertices outnumber everything else, so a lookup made with `indexingVertices: false`
/// leaves them out until a change looks up an id it doesn't know (see `prepare`): most
/// keyframes only set layer and shape properties. Ids are unique across a scene (the
/// file format and the editor both make sure), so until then a create checks only that
/// its layers, groups and shapes aren't there yet.
struct SceneLookup {
    enum Kind { case viewport, globalColor, layer, group, shape, vertex }

    private(set) var kinds: [Int: Kind] = [:]
    /// A group's or shape's layer, a vertex's shape.
    private(set) var parents: [Int: Int] = [:]
    /// Whether `kinds` and `parents` hold vertices.
    private(set) var hasVertices: Bool

    init(_ drawing: Drawing, indexingVertices: Bool = true) {
        hasVertices = indexingVertices
        kinds[drawing.viewport.id] = .viewport
        for global in drawing.globalColors { kinds[global.id] = .globalColor }
        for layer in drawing.layers { add(.layer(layer), parent: nil) }
    }

    mutating func add(_ object: SceneObject, parent: Int?) {
        if let parent { parents[object.id] = parent }
        switch object {
        case .layer(let layer):
            kinds[layer.id] = .layer
            for group in layer.groups { add(.group(group), parent: layer.id) }
            for shape in layer.shapes { add(.shape(shape), parent: layer.id) }
        case .group(let group):
            kinds[group.id] = .group
        case .shape(let shape):
            kinds[shape.id] = .shape
            guard hasVertices else { return }
            for point in shape.path.points {
                kinds[point.id] = .vertex
                parents[point.id] = shape.id
            }
        case .vertex(let point):
            guard hasVertices else { return }
            kinds[point.id] = .vertex
        }
    }

    /// Indexes the vertices of `drawing`, the scene as it is now, when `id` is one the
    /// lookup doesn't know and they aren't indexed yet.
    mutating func prepare(for id: Int?, in drawing: Drawing) {
        guard !hasVertices, let id, kinds[id] == nil else { return }
        hasVertices = true
        for layer in drawing.layers {
            for shape in layer.shapes {
                for point in shape.path.points {
                    kinds[point.id] = .vertex
                    parents[point.id] = shape.id
                }
            }
        }
    }
}

extension SceneObject {
    /// Every id the object holds, its own first.
    var allIDs: [Int] {
        switch self {
        case .layer(let layer):
            [layer.id] + layer.groups.map(\.id) + layer.shapes.flatMap { SceneObject.shape($0).allIDs }
        case .group(let group): [group.id]
        case .shape(let shape): [shape.id] + shape.path.points.map(\.id)
        case .vertex(let point): [point.id]
        }
    }
}

extension Drawing {
    // MARK: Finding objects

    func shapeLocation(_ id: Int, _ lookup: SceneLookup) -> (layer: Int, shape: Int)? {
        guard lookup.kinds[id] == .shape, let layer = lookup.parents[id].flatMap(layerIndex),
              let s = layers[layer].shapes.firstIndex(where: { $0.id == id }) else { return nil }
        return (layer, s)
    }

    func groupLocation(_ id: Int, _ lookup: SceneLookup) -> (layer: Int, group: Int)? {
        guard lookup.kinds[id] == .group, let layer = lookup.parents[id].flatMap(layerIndex),
              let g = layers[layer].groups.firstIndex(where: { $0.id == id }) else { return nil }
        return (layer, g)
    }

    func vertexLocation(_ id: Int, _ lookup: SceneLookup) -> (layer: Int, shape: Int, point: Int)? {
        guard lookup.kinds[id] == .vertex, let (l, s) = lookup.parents[id].flatMap({ shapeLocation($0, lookup) }),
              let p = layers[l].shapes[s].path.points.firstIndex(where: { $0.id == id }) else { return nil }
        return (l, s, p)
    }

    func exists(_ id: Int, _ lookup: SceneLookup) -> Bool {
        switch lookup.kinds[id] {
        case .viewport: viewport.id == id
        case .globalColor: globalColor(id) != nil
        case .layer: layerIndex(id) != nil
        case .group: groupLocation(id, lookup) != nil
        case .shape: shapeLocation(id, lookup) != nil
        case .vertex: vertexLocation(id, lookup) != nil
        case nil: false
        }
    }

    /// The ids of the children an `order` change with parent `parent` lists: the layers
    /// for nil, a layer's shapes, a shape's vertices. Empty when `parent` isn't there.
    func childIDs(of parent: Int?, _ lookup: SceneLookup) -> Set<Int> {
        guard let parent else { return Set(layers.map(\.id)) }
        switch lookup.kinds[parent] {
        case .layer: return layerIndex(parent).map { Set(layers[$0].shapes.map(\.id)) } ?? []
        case .shape: return shapeLocation(parent, lookup).map { Set(layers[$0.layer].shapes[$0.shape].path.points.map(\.id)) } ?? []
        default: return []
        }
    }

    /// Every id of a viewport, global color, layer, group, shape and vertex.
    var objectIDs: Set<Int> {
        var ids: Set<Int> = [viewport.id]
        ids.formUnion(globalColors.map(\.id))
        for layer in layers { ids.formUnion(SceneObject.layer(layer).allIDs) }
        return ids
    }

    /// The ids of layers that differ between this drawing and `other` (or are in only one).
    func changedLayerIDs(comparedTo other: Drawing) -> Set<Int> {
        let mine = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = Set(layers.map(\.id)).symmetricDifference(other.layers.map(\.id))
        for layer in other.layers where mine[layer.id].map({ $0 != layer }) ?? false { changed.insert(layer.id) }
        return changed
    }

    /// The ids in this drawing that `other` doesn't have.
    func idsMissing(from other: Drawing) -> Set<Int> {
        let changed = changedLayerIDs(comparedTo: other)
        var mine: Set<Int> = [viewport.id], theirs: Set<Int> = [other.viewport.id]
        mine.formUnion(globalColors.map(\.id))
        theirs.formUnion(other.globalColors.map(\.id))
        for layer in layers where changed.contains(layer.id) { mine.formUnion(SceneObject.layer(layer).allIDs) }
        for layer in other.layers where changed.contains(layer.id) { theirs.formUnion(SceneObject.layer(layer).allIDs) }
        return mine.subtracting(theirs)
    }

    // MARK: Applying changes

    /// The property keys a `set` may change, by kind of object.
    static func settableKeys(_ kind: SceneLookup.Kind) -> Set<Substring> {
        switch kind {
        case .viewport: ["background"]
        case .globalColor: ["color"]
        case .layer: ["transform"]
        case .group: ["clipped", "transform"]
        case .shape: ["group", "closed", "fill", "fillGlobal", "gradient", "stroke", "opacity", "clipped", "transform", "text", "math", "image"]
        case .vertex: ["p", "in", "out", "w", "smooth", "symmetric", "stroked"]
        }
    }

    /// Applies one change. Returns false, changing nothing, when it refers to an object
    /// that isn't there (or creates one that is), or its properties don't read.
    mutating func apply(_ change: SceneChange, lookup: inout SceneLookup) -> Bool {
        switch change {
        case .set(let id, _), .delete(let id, _): lookup.prepare(for: id, in: self)
        case .order(let parent, _): lookup.prepare(for: parent, in: self)
        case .create(_, let parent, _, _, _): lookup.prepare(for: parent, in: self)
        }
        switch change {
        case .set(let id, let props):
            guard let kind = lookup.kinds[id], exists(id, lookup) else { return false }
            let allowed = Drawing.settableKeys(kind)
            guard props.allSatisfy({ allowed.contains(PropertyPath.root(of: $0.key)) }) else { return false }
            let changes = props.map { (key: $0.key, value: $0.value) }
            func patched(_ members: [(key: String, value: JSONValue)]) -> Node? {
                (try? PropertyPath.apply(changes, to: .object(members))).map { Node(root: $0) }
            }
            do {
                switch kind {
                case .viewport:
                    guard let node = patched(SceneJSON.viewportProps(viewport)) else { return false }
                    try SceneJSON.readViewportProps(node, into: &viewport)
                case .globalColor:
                    guard let g = globalColors.firstIndex(where: { $0.id == id }),
                          let node = patched(SceneJSON.globalColorProps(globalColors[g])) else { return false }
                    try SceneJSON.readGlobalColorProps(node, into: &globalColors[g])
                case .layer:
                    guard let l = layerIndex(id), let node = patched(SceneJSON.layerProps(layers[l])) else { return false }
                    try SceneJSON.readLayerProps(node, into: &layers[l])
                case .group:
                    guard let (l, g) = groupLocation(id, lookup), let node = patched(SceneJSON.groupProps(layers[l].groups[g]))
                    else { return false }
                    try SceneJSON.readGroupProps(node, into: &layers[l].groups[g])
                case .shape:
                    guard let (l, s) = shapeLocation(id, lookup), let node = patched(SceneJSON.shapeProps(layers[l].shapes[s]))
                    else { return false }
                    let context = SceneJSON.Context(globals: Set(globalColors.map(\.id)), groups: Set(layers[l].groups.map(\.id)))
                    var shape = layers[l].shapes[s]
                    try SceneJSON.readShapeProps(node, into: &shape, context: context)
                    layers[l].shapes[s] = shape
                case .vertex:
                    guard let (l, s, p) = vertexLocation(id, lookup),
                          let node = patched(SceneJSON.vertexProps(layers[l].shapes[s].path.points[p])) else { return false }
                    var point = layers[l].shapes[s].path.points[p]
                    try SceneJSON.readVertexProps(node, into: &point)
                    layers[l].shapes[s].path.points[p] = point
                }
            } catch {
                return false
            }
            return true

        case .create(let object, let parent, let after, let before, _):
            guard !object.allIDs.contains(where: { exists($0, lookup) || $0 <= 0 }) else { return false }
            switch object {
            case .layer(let layer):
                guard parent == nil else { return false }
                layers.insert(layer, at: Drawing.insertionIndex(after: after, in: layers.map(\.id)))
            case .group(let group):
                guard let l = parent.flatMap(layerIndex), lookup.kinds[parent!] == .layer else { return false }
                layers[l].groups.append(group)
            case .shape(let shape):
                guard let l = parent.flatMap(layerIndex), lookup.kinds[parent!] == .layer else { return false }
                layers[l].shapes.insert(shape, at: Drawing.insertionIndex(after: after, in: layers[l].shapes.map(\.id)))
            case .vertex(let point):
                guard let (l, s) = parent.flatMap({ shapeLocation($0, lookup) }) else { return false }
                let ids = layers[l].shapes[s].path.points.map(\.id)
                var index = Drawing.insertionIndex(after: after, in: ids)
                if after != nil, !ids.contains(after!), let b = before.flatMap({ ids.firstIndex(of: $0) }) { index = b }
                layers[l].shapes[s].path.points.insert(point, at: index)
            }
            lookup.add(object, parent: parent)
            return true

        case .delete(let id, _):
            switch lookup.kinds[id] {
            case .layer:
                guard let l = layerIndex(id) else { return false }
                layers.remove(at: l)
            case .group:
                guard let (l, g) = groupLocation(id, lookup) else { return false }
                layers[l].groups.remove(at: g)
                for s in layers[l].shapes.indices where layers[l].shapes[s].group == id { layers[l].shapes[s].group = nil }
            case .shape:
                guard let (l, s) = shapeLocation(id, lookup) else { return false }
                layers[l].shapes.remove(at: s)
            case .vertex:
                guard let (l, s, p) = vertexLocation(id, lookup) else { return false }
                layers[l].shapes[s].path.points.remove(at: p)
            case .viewport, .globalColor, nil:
                return false
            }
            return true

        case .order(let parent, let ids):
            guard Set(ids).count == ids.count else { return false }
            if let parent {
                switch lookup.kinds[parent] {
                case .layer:
                    guard let l = layerIndex(parent) else { return false }
                    layers[l].shapes = Drawing.reordered(layers[l].shapes, ids)
                case .shape:
                    guard let (l, s) = shapeLocation(parent, lookup) else { return false }
                    layers[l].shapes[s].path.points = Drawing.reordered(layers[l].shapes[s].path.points, ids)
                default:
                    return false
                }
            } else {
                layers = Drawing.reordered(layers, ids)
            }
            return true
        }
    }

    /// Where a child placed after sibling `after` goes: first when `after` is nil, last
    /// when it isn't there.
    static func insertionIndex(after: Int?, in ids: [Int]) -> Int {
        guard let after else { return 0 }
        return ids.firstIndex(of: after).map { $0 + 1 } ?? ids.count
    }

    /// `items` with those listed in `ids` put in that order, in the places the listed ones
    /// held; the rest stay where they are.
    static func reordered<T: Identifiable>(_ items: [T], _ ids: [Int]) -> [T] where T.ID == Int {
        let listed = Set(ids)
        let byID = Dictionary(items.filter { listed.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var queue = ids.compactMap { byID[$0] }[...]
        return items.map { item in listed.contains(item.id) ? queue.popFirst()! : item }
    }

    /// Applies a keyframe's changes in order, then makes fills and outlines follow their
    /// global colors and keeps groups whole. Returns the indices of changes that didn't
    /// apply (see `apply(_:lookup:)`), which are skipped.
    @discardableResult
    mutating func apply(_ changes: [SceneChange]) -> [Int] {
        guard !changes.isEmpty else { return [] }
        var lookup = SceneLookup(self, indexingVertices: false)
        return apply(changes, lookup: &lookup)
    }

    /// `apply(_:)` with a lookup of this scene, kept up to date, so applying keyframe
    /// after keyframe indexes the scene once.
    @discardableResult
    mutating func apply(_ changes: [SceneChange], lookup: inout SceneLookup) -> [Int] {
        guard !changes.isEmpty else { return [] }
        var failed: [Int] = []
        for (i, change) in changes.enumerated() where !apply(change, lookup: &lookup) {
            failed.append(i)
        }
        syncGlobalColors()
        if !groupsAreValid {
            // Repairing can give groups new ids.
            repairGroups()
            lookup = SceneLookup(self, indexingVertices: lookup.hasVertices)
        }
        return failed
    }

    /// Makes every fill and outline that follows a global color take its color (and a
    /// gradient its first stop), as editing a global color does; a link to a global color
    /// that isn't there is dropped.
    mutating func syncGlobalColors() {
        let colors = Dictionary(globalColors.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        for l in layers.indices {
            guard layers[l].shapes.contains(where: { $0.fillGlobal != nil || $0.stroke?.global != nil }) else { continue }
            for s in layers[l].shapes.indices {
                let shape = layers[l].shapes[s]
                var synced = shape
                if let g = shape.fillGlobal {
                    if let color = colors[g] {
                        if synced.fill != nil {
                            synced.fill = color
                            if synced.gradient != nil, !synced.gradient!.stops.isEmpty { synced.gradient!.stops[0].color = color }
                        }
                    } else {
                        synced.fillGlobal = nil
                    }
                }
                if let g = shape.stroke?.global {
                    if let color = colors[g] { synced.stroke!.color = color } else { synced.stroke!.global = nil }
                }
                if synced != shape { layers[l].shapes[s] = synced }
            }
        }
    }
}

/// Turns two scene states into the changes from one to the other: what a keyframe stores.
enum SceneDiff {
    /// The changes of one layer that is in both states: its own, its groups', its shapes'
    /// and their vertices', by kind.
    struct LayerChanges: Sendable {
        var removals: [SceneChange] = []
        var additions: [SceneChange] = []
        var sets: [SceneChange] = []
        var orders: [SceneChange] = []
    }

    /// The layer changes of the last diff, with the two layers each was made from. A
    /// layer's changes depend only on its two states, so the next diff takes them for
    /// every layer that is the same on both sides (cheaply, when its storage is shared)
    /// and diffs only the rest: a commit at a keyframe that keys many shapes re-diffs the
    /// layers the commit changed.
    struct Memo: Sendable {
        fileprivate var layers: [Int: (old: Layer, new: Layer, changes: LayerChanges)] = [:]
    }

    /// The changes that turn `a` into `b`, so `a.apply(changes) == b` for the keyed parts
    /// of the scene: layers, groups, shapes and vertices, the viewport's background and
    /// global colors' colors. Removals come first, then additions, then property changes
    /// and new orders. Editor hints and layer and group names are left out (they aren't
    /// keyed), as is everything `Presentation` keeps for the whole document.
    static func changes(from a: Drawing, to b: Drawing) -> [SceneChange] {
        var memo = Memo()
        return changes(from: a, to: b, memo: &memo)
    }

    /// `changes(from:to:)`, taking the changes of layers that `memo` holds for the same
    /// two layers, and leaving in `memo` those of this diff.
    static func changes(from a: Drawing, to b: Drawing, memo: inout Memo) -> [SceneChange] {
        var globalSets: [SceneChange] = []
        if a.viewport.id == b.viewport.id {
            set(b.viewport.id, SceneJSON.viewportProps(a.viewport), SceneJSON.viewportProps(b.viewport), into: &globalSets)
        }
        let oldGlobals = Dictionary(a.globalColors.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for global in b.globalColors {
            if let old = oldGlobals[global.id] {
                set(global.id, SceneJSON.globalColorProps(old), SceneJSON.globalColorProps(global), into: &globalSets)
            }
        }

        let oldLayers = Dictionary(a.layers.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let newLayerIDs = Set(b.layers.map(\.id))
        // Each layer of `b` in turn: a new one's create, or the changes of one in both.
        var layers: [(create: SceneChange?, changes: LayerChanges)] = []
        var kept = Memo()
        for (index, layer) in b.layers.enumerated() {
            guard let old = oldLayers[layer.id] else {
                layers.append((.create(.layer(layer), parent: nil, after: index > 0 ? b.layers[index - 1].id : nil), LayerChanges()))
                continue
            }
            if old == layer { continue }
            let changes: LayerChanges
            if let known = memo.layers[layer.id], known.old == old, known.new == layer {
                changes = known.changes
            } else {
                changes = self.changes(from: old, to: layer)
            }
            kept.layers[layer.id] = (old, layer, changes)
            layers.append((nil, changes))
        }
        memo = kept

        var out: [SceneChange] = []
        out.reserveCapacity(globalSets.count + layers.reduce(a.layers.count + 1) {
            $0 + 1 + $1.changes.removals.count + $1.changes.additions.count + $1.changes.sets.count + $1.changes.orders.count
        })
        for layer in a.layers where !newLayerIDs.contains(layer.id) { out.append(.delete(id: layer.id)) }
        for layer in layers { out += layer.changes.removals }
        for layer in layers {
            if let create = layer.create { out.append(create) } else { out += layer.changes.additions }
        }
        out += globalSets
        for layer in layers { out += layer.changes.sets }
        for layer in layers { out += layer.changes.orders }
        let keptLayers = a.layers.map(\.id).filter(newLayerIDs.contains)
        let createdLayers: [(id: Int, after: Int?)] = b.layers.indices.compactMap { i in
            oldLayers[b.layers[i].id] == nil ? (b.layers[i].id, i > 0 ? b.layers[i - 1].id : nil) : nil
        }
        if order(keptLayers, createdLayers, b.layers.map(\.id)) { out.append(.order(parent: nil, ids: b.layers.map(\.id))) }
        return out
    }

    private static func set(_ id: Int, _ old: [(key: String, value: JSONValue)], _ new: [(key: String, value: JSONValue)],
                            into sets: inout [SceneChange]) {
        let props = PropertyPath.changes(from: .object(old), to: .object(new))
        if !props.isEmpty { sets.append(.set(id: id, props: props.map { PropertyChange($0.key, $0.value) })) }
    }

    /// The changes of a layer that is in both states, from `old` to `layer`. Objects move
    /// between layers by a delete in one and a create in the other.
    private static func changes(from old: Layer, to layer: Layer) -> LayerChanges {
        var out = LayerChanges()
        set(layer.id, SceneJSON.layerProps(old), SceneJSON.layerProps(layer), into: &out.sets)

        let oldGroups = Dictionary(old.groups.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let newGroupIDs = Set(layer.groups.map(\.id))
        for group in old.groups where !newGroupIDs.contains(group.id) { out.removals.append(.delete(id: group.id)) }
        for group in layer.groups {
            if let previous = oldGroups[group.id] {
                set(group.id, SceneJSON.groupProps(previous), SceneJSON.groupProps(group), into: &out.sets)
            } else {
                out.additions.append(.create(.group(group), parent: layer.id, after: nil))
            }
        }

        let oldShapes = Dictionary(old.shapes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let newShapeIDs = Set(layer.shapes.map(\.id))
        for shape in old.shapes where !newShapeIDs.contains(shape.id) { out.removals.append(.delete(id: shape.id)) }
        var created: [(id: Int, after: Int?)] = []
        for (index, shape) in layer.shapes.enumerated() {
            let after = index > 0 ? layer.shapes[index - 1].id : nil
            guard let previous = oldShapes[shape.id] else {
                out.additions.append(.create(.shape(shape), parent: layer.id, after: after))
                created.append((shape.id, after))
                continue
            }
            if previous == shape { continue }
            set(shape.id, SceneJSON.shapeProps(previous), SceneJSON.shapeProps(shape), into: &out.sets)
            points(from: previous, to: shape, removals: &out.removals, additions: &out.additions, sets: &out.sets,
                   orders: &out.orders)
        }
        let kept = old.shapes.map(\.id).filter(newShapeIDs.contains)
        if order(kept, created, layer.shapes.map(\.id)) { out.orders.append(.order(parent: layer.id, ids: layer.shapes.map(\.id))) }
        return out
    }

    /// The vertex changes of a shape that is in the same layer in both states.
    private static func points(from old: VectorShape, to new: VectorShape, removals: inout [SceneChange],
                               additions: inout [SceneChange], sets: inout [SceneChange], orders: inout [SceneChange]) {
        let oldPoints = old.path.points, newPoints = new.path.points
        if oldPoints == newPoints { return }
        let oldByID = Dictionary(oldPoints.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let newIDs = Set(newPoints.map(\.id))
        let sameIDs = oldPoints.count == newPoints.count && oldPoints.allSatisfy { newIDs.contains($0.id) }
        let parameters = sameIDs ? [:] : VertexMerge.parameters(from: old.path, to: new.path)
        for point in oldPoints where !newIDs.contains(point.id) {
            removals.append(.delete(id: point.id, t: parameters[point.id]))
        }
        var created: [(id: Int, after: Int?)] = []
        for (index, point) in newPoints.enumerated() {
            if let previous = oldByID[point.id] {
                let props = PropertyPath.changes(from: .object(SceneJSON.vertexProps(previous)), to: .object(SceneJSON.vertexProps(point)))
                if !props.isEmpty { sets.append(.set(id: point.id, props: props.map { PropertyChange($0.key, $0.value) })) }
                continue
            }
            let after = index > 0 ? newPoints[index - 1].id : nil
            // The segment's end: the next vertex present in both states.
            var before: Int?
            for step in 1..<max(newPoints.count, 1) {
                let j = index + step
                guard new.path.closed || j < newPoints.count else { break }
                let candidate = newPoints[j % newPoints.count].id
                if oldByID[candidate] != nil { before = candidate; break }
            }
            additions.append(.create(.vertex(point), parent: new.id, after: after, before: before, t: parameters[point.id]))
            created.append((point.id, after))
        }
        let kept = oldPoints.map(\.id).filter(newIDs.contains)
        if order(kept, created, newPoints.map(\.id)) { orders.append(.order(parent: new.id, ids: newPoints.map(\.id))) }
    }

    /// True when the children `kept` (in their old order), with `created` inserted as
    /// applying the changes inserts them, aren't in the order `target`.
    private static func order(_ kept: [Int], _ created: [(id: Int, after: Int?)], _ target: [Int]) -> Bool {
        var ids = kept
        for (id, after) in created { ids.insert(id, at: Drawing.insertionIndex(after: after, in: ids)) }
        return ids != target
    }
}
