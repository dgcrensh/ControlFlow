import Foundation

/// How an outline ends at the two ends of an open path (and of each dash).
public enum LineCap: String, Hashable, Sendable, Codable, CaseIterable {
    /// Ends square at the end point.
    case butt
    /// A half circle past the end point.
    case round
    /// A half square past the end point.
    case square
}

/// How an outline turns a corner.
public enum LineJoin: String, Hashable, Sendable, Codable, CaseIterable {
    /// A sharp point, cut to a bevel when it would be longer than the miter limit.
    case miter
    case round
    case bevel
}

/// Where a closed path's outline sits relative to the path. Open paths always center it.
public enum StrokeAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case center
    /// The whole width inside the fill area.
    case inside
    /// The whole width outside the fill area.
    case outside
}

/// An outline. The width can vary along the path: each anchor's `width` multiplies it.
public struct StrokeStyle: Hashable, Sendable, Codable {
    public var color: RGBAColor
    public var width: Double
    public var cap: LineCap = .round
    public var join: LineJoin = .round
    /// A miter join longer than this many half-widths becomes a bevel.
    public var miterLimit: Double = 4
    /// Dash and gap lengths in points, alternating, starting with a dash. Empty is solid.
    public var dash: [Double] = []
    /// How far into the dash pattern the path starts, in points.
    public var dashOffset: Double = 0
    public var alignment: StrokeAlignment = .center
    /// The global color `color` follows, if any (a `GlobalColor` id).
    public var global: Int?

    public init(color: RGBAColor, width: Double, cap: LineCap = .round, join: LineJoin = .round,
                miterLimit: Double = 4, dash: [Double] = [], dashOffset: Double = 0,
                alignment: StrokeAlignment = .center, global: Int? = nil) {
        self.color = color
        self.width = width
        self.cap = cap
        self.join = join
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashOffset = dashOffset
        self.alignment = alignment
        self.global = global
    }

    /// True when `dash` describes a pattern with gaps. An odd-length pattern repeats
    /// twice, as in SVG, so its dashes and gaps alternate.
    public var isDashed: Bool { dashPattern != nil }

    /// The dash pattern with an even number of entries, or nil when the outline is solid.
    public var dashPattern: [Double]? {
        guard !dash.isEmpty, dash.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let pattern = dash.count % 2 == 1 ? dash + dash : dash
        let gaps = stride(from: 1, to: pattern.count, by: 2).reduce(0.0) { $0 + pattern[$1] }
        return gaps > 0 ? pattern : nil
    }
}

/// One color of a gradient, at `offset` (0 at the start, 1 at the end).
public struct GradientStop: Hashable, Sendable, Codable {
    public var offset: Double
    public var color: RGBAColor

    public init(offset: Double, color: RGBAColor) {
        self.offset = offset
        self.color = color
    }
}

/// A gradient fill. Its points are in the same space as the path's points, so the
/// gradient moves, turns and scales with the shape.
public struct ShapeGradient: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// Colors change along the line from `start` to `end`.
        case linear
        /// Colors change outward from `start` (the center) to the circle through `end`.
        case radial
    }

    /// The most stops the canvas draws; any beyond are ignored.
    public static let maxStops = 8

    public var kind: Kind
    public var start: Vec2
    public var end: Vec2
    /// Sorted by offset.
    public var stops: [GradientStop]

    public init(kind: Kind, start: Vec2, end: Vec2, stops: [GradientStop]) {
        self.kind = kind
        self.start = start
        self.end = end
        self.stops = stops.sorted { $0.offset < $1.offset }
    }

    /// The gradient's color at parameter `t`, interpolated in straight alpha.
    public func color(at t: Double) -> RGBAColor {
        guard let first = stops.first, let last = stops.last else { return .black }
        if t <= first.offset { return first.color }
        if t >= last.offset { return last.color }
        for i in 1..<stops.count where t <= stops[i].offset {
            let a = stops[i - 1], b = stops[i]
            let span = b.offset - a.offset
            let k = span > 1e-12 ? (t - a.offset) / span : 1
            return RGBAColor(r: a.color.r + (b.color.r - a.color.r) * k,
                             g: a.color.g + (b.color.g - a.color.g) * k,
                             b: a.color.b + (b.color.b - a.color.b) * k,
                             a: a.color.a + (b.color.a - a.color.a) * k)
        }
        return last.color
    }

    /// The gradient parameter at world point `p`, clamped to 0...1.
    public func parameter(at p: Vec2) -> Double {
        let axis = end - start
        let t: Double
        switch kind {
        case .linear:
            let len2 = axis.lengthSquared
            t = len2 > 1e-12 ? (p - start).dot(axis) / len2 : 0
        case .radial:
            let radius = axis.length
            t = radius > 1e-12 ? p.distance(to: start) / radius : 0
        }
        return min(max(t, 0), 1)
    }

    public mutating func apply(_ t: Affine2D) {
        start = t.apply(start)
        end = t.apply(end)
    }
}

/// A named color shapes can follow, so recoloring every shape that uses it is one edit.
/// Saved as a named entry of the file's `palette`; shapes refer to it by name.
public struct GlobalColor: Hashable, Sendable, Codable, Identifiable {
    public var id: Int
    public var name: String
    public var color: RGBAColor

    public init(id: Int, name: String, color: RGBAColor) {
        self.id = id
        self.name = name
        self.color = color
    }
}
