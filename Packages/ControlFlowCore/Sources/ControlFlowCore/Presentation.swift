import Foundation

/// How a transition's progress follows time: one of CSS's named curves, or a custom
/// cubic Bézier through (0, 0), (x1, y1), (x2, y2) and (1, 1), as CSS's `cubic-bezier`.
public enum TimingCurve: Hashable, Sendable {
    case linear
    case ease
    case easeIn
    case easeOut
    case easeInOut
    /// x1 and x2 are clamped to 0...1; y1 and y2 may leave 0...1 to overshoot.
    case custom(x1: Double, y1: Double, x2: Double, y2: Double)

    /// The named curves, in the order the curve editor shows them.
    public static let presets: [TimingCurve] = [.linear, .ease, .easeIn, .easeOut, .easeInOut]

    /// The name the file uses for a named curve, or nil for a custom one.
    public var name: String? {
        switch self {
        case .linear: "linear"
        case .ease: "ease"
        case .easeIn: "ease-in"
        case .easeOut: "ease-out"
        case .easeInOut: "ease-in-out"
        case .custom: nil
        }
    }

    public init?(name: String) {
        guard let curve = TimingCurve.presets.first(where: { $0.name == name }) else { return nil }
        self = curve
    }

    /// The curve's two control points, as CSS defines the named curves.
    public var controlPoints: (x1: Double, y1: Double, x2: Double, y2: Double) {
        switch self {
        case .linear: (0, 0, 1, 1)
        case .ease: (0.25, 0.1, 0.25, 1)
        case .easeIn: (0.42, 0, 1, 1)
        case .easeOut: (0, 0, 0.58, 1)
        case .easeInOut: (0.42, 0, 0.58, 1)
        case .custom(let x1, let y1, let x2, let y2): (min(max(x1, 0), 1), y1, min(max(x2, 0), 1), y2)
        }
    }

    /// The progress at time fraction `x` (clamped to 0...1): the curve's y where its x is
    /// `x`. 0 at 0 and 1 at 1; a custom curve can leave 0...1 in between.
    public func progress(at x: Double) -> Double {
        let x = min(max(x.isFinite ? x : 1, 0), 1)
        if x == 0 { return 0 }
        if x == 1 { return 1 }
        if case .linear = self { return x }
        let (x1, y1, x2, y2) = controlPoints
        // The Bézier's x(s) and y(s) for parameter s, with p0 = (0, 0) and p3 = (1, 1).
        func bezier(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let ms = 1 - s
            return 3 * ms * ms * s * a + 3 * ms * s * s * b + s * s * s
        }
        func slope(_ s: Double, _ a: Double, _ b: Double) -> Double {
            let ms = 1 - s
            return 3 * ms * ms * a + 6 * ms * s * (b - a) + 3 * s * s * (1 - b)
        }
        // Newton's method from s = x, falling back to bisection (x(s) rises with s since
        // x1 and x2 are in 0...1).
        var s = x
        for _ in 0..<8 {
            let error = bezier(s, x1, x2) - x
            if abs(error) < 1e-12 { return bezier(s, y1, y2) }
            let d = slope(s, x1, x2)
            guard abs(d) > 1e-9 else { break }
            s = min(max(s - error / d, 0), 1)
        }
        var lo = 0.0, hi = 1.0
        s = x
        for _ in 0..<60 {
            let value = bezier(s, x1, x2)
            if abs(value - x) < 1e-12 { break }
            if value < x { lo = s } else { hi = s }
            s = (lo + hi) / 2
        }
        return bezier(s, y1, y2)
    }
}

/// The animation into a keyframe from the state before it: one duration and one curve
/// for everything that changes.
public struct Transition: Hashable, Sendable {
    /// Seconds; 0 is a cut.
    public var duration: Double
    public var curve: TimingCurve

    public init(duration: Double = 0.5, curve: TimingCurve = .easeInOut) {
        self.duration = max(duration.isFinite ? duration : 0, 0)
        self.curve = curve
    }

    /// The transition a new keyframe gets before any has been chosen.
    public static let standard = Transition()
}

/// An object a keyframe can create.
public enum SceneObject: Hashable, Sendable {
    /// A layer with its groups and shapes, at the top of the scene.
    case layer(Layer)
    case group(ShapeGroup)
    /// A shape with its points.
    case shape(VectorShape)
    case vertex(PathPoint)

    public var id: Int {
        switch self {
        case .layer(let l): l.id
        case .group(let g): g.id
        case .shape(let s): s.id
        case .vertex(let p): p.id
        }
    }
}

/// One property set by a keyframe: a dotted key into the object's JSON (see
/// `Schema/README.md`) and its new value; `null` removes the key, restoring its default.
public struct PropertyChange: Hashable, Sendable {
    public var key: String
    public var value: JSONValue

    public init(_ key: String, _ value: JSONValue) {
        self.key = key
        self.value = value
    }
}

/// One change a keyframe makes to the state before it.
public enum SceneChange: Hashable, Sendable {
    /// Sets properties of an existing object: a layer, group, shape or vertex, the
    /// viewport (`background`) or a global color (`color`).
    case set(id: Int, props: [PropertyChange])
    /// Adds an object under `parent` (a layer for groups and shapes, a shape for vertices,
    /// nil for a layer), placed after the sibling `after` (first when nil). Groups are
    /// unordered and ignore `after`. A vertex born on a segment records the segment's end
    /// `before` (its next neighbour present in both states) and the curve parameter `t`
    /// where it was born; see `VertexMerge`.
    case create(SceneObject, parent: Int?, after: Int?, before: Int? = nil, t: Double? = nil)
    /// Removes an object and its children (a layer's groups and shapes, a shape's
    /// points). A group's shapes are not its children: they stay, ungrouped. A dying
    /// vertex records the parameter `t` on the healed segment it rides to.
    case delete(id: Int, t: Double? = nil)
    /// A new order for a parent's children (nil: the scene's layers; a layer: its shapes;
    /// a shape: its points). Children not listed keep their places.
    case order(parent: Int?, ids: [Int])

    /// The object the change is about.
    public var target: Int? {
        switch self {
        case .set(let id, _): id
        case .create(let object, _, _, _, _): object.id
        case .delete(let id, _): id
        case .order(let parent, _): parent
        }
    }
}

/// A scene state, stored as the changes from the keyframe before it, with the transition
/// that leads into it.
public struct Keyframe: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String?
    public var transition: Transition
    public var changes: [SceneChange]

    public init(id: Int, name: String? = nil, transition: Transition = .standard, changes: [SceneChange] = []) {
        self.id = id
        self.name = name
        self.transition = transition
        self.changes = changes
    }
}

/// A run of keyframes that plays as a unit: one Advance plays one sequence.
public struct KeyframeSequence: Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String?
    public var keyframes: [Keyframe]

    public init(id: Int, name: String? = nil, keyframes: [Keyframe] = []) {
        self.id = id
        self.name = name
        self.keyframes = keyframes
    }
}

/// A whole document: the opening state in full, then sequences of keyframes, each a
/// change from the one before. The opening drawing also holds what isn't keyed: the
/// name, the viewport's size, the palette, reference images, the global colors (whose
/// colors are keyed but whose names aren't), editor hints and layer and group names.
/// Ids, keyframes' and sequences' included, come from `opening.nextID`.
public struct Presentation: Hashable, Sendable {
    public var opening: Drawing
    public var sequences: [KeyframeSequence]

    public init(opening: Drawing = Drawing(), sequences: [KeyframeSequence] = []) {
        self.opening = opening
        self.sequences = sequences
        if self.opening.viewport.id == 0 {
            // Past every id already used, in case the drawing's own count is behind (a copy).
            let used = self.opening.objectIDs.union(self.opening.references.map(\.id)).max() ?? 0
            self.opening.nextID = max(self.opening.nextID, used + 1)
            self.opening.viewport.id = self.opening.makeID()
        }
        if !self.opening.vertexIDsAreValid { self.opening.assignVertexIDs() }
    }

    /// Every keyframe, in playing order (the chain after the opening state).
    public var keyframes: [Keyframe] { sequences.flatMap(\.keyframes) }

    public var keyframeCount: Int { sequences.reduce(0) { $0 + $1.keyframes.count } }

    /// Where keyframe `id` is: its sequence's index and its index there.
    public func location(ofKeyframe id: Int) -> (sequence: Int, index: Int)? {
        for (s, sequence) in sequences.enumerated() {
            if let k = sequence.keyframes.firstIndex(where: { $0.id == id }) { return (s, k) }
        }
        return nil
    }

    /// The keyframe's place in the chain: 0 is the opening state, 1 the first keyframe.
    /// Nil (the opening) gives 0.
    public func chainIndex(of keyframe: Int?) -> Int? {
        guard let keyframe else { return 0 }
        var index = 0
        for sequence in sequences {
            for k in sequence.keyframes {
                index += 1
                if k.id == keyframe { return index }
            }
        }
        return nil
    }

    /// The keyframe at chain index `index` (1 or more), or nil for the opening state.
    public func keyframe(atChainIndex index: Int) -> Keyframe? {
        guard index > 0 else { return nil }
        var remaining = index
        for sequence in sequences {
            if remaining <= sequence.keyframes.count { return sequence.keyframes[remaining - 1] }
            remaining -= sequence.keyframes.count
        }
        return nil
    }

    public func keyframe(_ id: Int) -> Keyframe? {
        location(ofKeyframe: id).map { sequences[$0.sequence].keyframes[$0.index] }
    }

    /// The chain indices of sequence `index`'s keyframes.
    public func chainRange(ofSequence index: Int) -> ClosedRange<Int>? {
        guard sequences.indices.contains(index), !sequences[index].keyframes.isEmpty else { return nil }
        let start = sequences[..<index].reduce(1) { $0 + $1.keyframes.count }
        return start...(start + sequences[index].keyframes.count - 1)
    }

    mutating func updateKeyframe(atChainIndex index: Int, _ change: (inout Keyframe) -> Void) {
        guard index > 0 else { return }
        var remaining = index
        for s in sequences.indices {
            if remaining <= sequences[s].keyframes.count {
                change(&sequences[s].keyframes[remaining - 1])
                return
            }
            remaining -= sequences[s].keyframes.count
        }
    }
}
