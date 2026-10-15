import Foundation

/// What the timeline strip shows: the opening chip, then each sequence as a block of
/// keyframe chips, each with the transition that leads into it.
public struct TimelineStrip: Hashable, Sendable {
    /// A keyframe's chip.
    public struct Chip: Hashable, Sendable, Identifiable {
        public var id: Int
        /// Its place in the chain, from 1: the number the chip shows when it has no name.
        public var number: Int
        public var name: String?
        /// The transition into it, which the handle before the chip shows.
        public var transition: Transition
        /// How many changes the keyframe makes; 0 for a hold.
        public var changeCount: Int
        public var isCurrent: Bool

        /// The name, or the number.
        public var title: String { name ?? "\(number)" }
    }

    /// A sequence's block.
    public struct Block: Hashable, Sendable, Identifiable {
        public var id: Int
        /// Its place among the sequences, from 1.
        public var number: Int
        public var name: String?
        public var chips: [Chip]
        /// The seconds it takes to play.
        public var duration: Double
        /// It holds the current keyframe.
        public var isCurrent: Bool
        /// There is a sequence after it to merge with.
        public var canMergeWithNext: Bool

        /// The name, or "Sequence" and the number.
        public var title: String { name ?? "Sequence \(number)" }
    }

    public var openingIsCurrent: Bool
    public var sequences: [Block]

    public init() {
        openingIsCurrent = true
        sequences = []
    }

    public init(presentation: Presentation, currentKeyframe: Int?) {
        openingIsCurrent = currentKeyframe == nil
        var number = 0
        sequences = presentation.sequences.enumerated().map { index, sequence in
            let chips = sequence.keyframes.map { keyframe in
                number += 1
                return Chip(id: keyframe.id, number: number, name: keyframe.name, transition: keyframe.transition,
                            changeCount: keyframe.changes.count, isCurrent: keyframe.id == currentKeyframe)
            }
            return Block(id: sequence.id, number: index + 1, name: sequence.name, chips: chips,
                         duration: sequence.keyframes.reduce(0) { $0 + $1.transition.duration },
                         isCurrent: chips.contains(where: \.isCurrent),
                         canMergeWithNext: index + 1 < presentation.sequences.count)
        }
    }

    /// The names the Inspector lists for keys from `DrawingEditor.keyedProperties()`, in
    /// a fixed order, each once: "Transform", "Points", "Fill", "Outline" and so on.
    public static func propertyNames(_ keys: Set<String>) -> [String] {
        let order = ["Created here", "Transform", "Points", "Fill", "Gradient", "Outline", "Opacity", "Clipping", "Closed",
                     "Group", "Order"]
        let names = Set(keys.map { key -> String in
            switch key.split(separator: ".").first.map(String.init) ?? key {
            case "created": "Created here"
            case "transform": "Transform"
            case "points": "Points"
            case "fill", "fillGlobal": "Fill"
            case "gradient": "Gradient"
            case "stroke": "Outline"
            case "opacity": "Opacity"
            case "clipped": "Clipping"
            case "closed": "Closed"
            case "group": "Group"
            case "order": "Order"
            default: key
            }
        })
        return order.filter(names.contains) + names.subtracting(order).sorted()
    }

    /// Every keyframe's chip, in playing order.
    public var chips: [Chip] { sequences.flatMap(\.chips) }

    /// The current keyframe's chip, if a keyframe is current.
    public var currentChip: Chip? { chips.first(where: \.isCurrent) }
}

extension Transition {
    /// The duration as the strip writes it: seconds with up to two decimals, such as
    /// "0.5s", "1s" or "0.25s", and "Cut" for 0.
    public var durationLabel: String {
        guard duration > 0 else { return "Cut" }
        return Transition.seconds(duration) + "s"
    }

    /// Seconds rounded to two decimals, without trailing zeros.
    public static func seconds(_ value: Double) -> String {
        let hundredths = Int((max(value, 0) * 100).rounded())
        let whole = hundredths / 100, fraction = hundredths % 100
        if fraction == 0 { return "\(whole)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }

    /// The longest duration the transition popover offers, in seconds.
    public static let maxDuration = 10.0
}

extension TimingCurve {
    /// The preset with the same control points, or the curve itself. A custom curve
    /// dragged onto a preset's shape becomes that preset.
    public var normalized: TimingCurve {
        guard case .custom = self else { return self }
        let c = controlPoints
        return TimingCurve.presets.first { preset in
            let p = preset.controlPoints
            return abs(p.x1 - c.x1) < 1e-9 && abs(p.y1 - c.y1) < 1e-9 && abs(p.x2 - c.x2) < 1e-9 && abs(p.y2 - c.y2) < 1e-9
        } ?? self
    }

    /// The curve with its first (`first`) or second control point moved to `point`
    /// (x is time, clamped to 0...1; y is progress, clamped to -1...2 so the handle stays
    /// reachable). Always custom, unless it lands on a preset.
    public func moving(controlPoint first: Bool, to point: Vec2) -> TimingCurve {
        let c = controlPoints
        let x = min(max(point.x.isFinite ? point.x : 0, 0), 1)
        let y = min(max(point.y.isFinite ? point.y : 0, -1), 2)
        let moved: TimingCurve = first ? .custom(x1: x, y1: y, x2: c.x2, y2: c.y2) : .custom(x1: c.x1, y1: c.y1, x2: x, y2: y)
        return moved.normalized
    }

    /// The curve's name for the popover: the preset's CSS name, or "Custom".
    public var displayName: String {
        switch self {
        case .linear: "Linear"
        case .ease: "Ease"
        case .easeIn: "Ease In"
        case .easeOut: "Ease Out"
        case .easeInOut: "Ease In Out"
        case .custom: "Custom"
        }
    }

    /// `count` points along the curve (at least 2), from (0, 0) to (1, 1): x is time and
    /// y progress, which a custom curve can take outside 0...1. For drawing its glyph.
    public func samples(count: Int) -> [Vec2] {
        let n = max(count, 2)
        return (0..<n).map { i in
            let x = Double(i) / Double(n - 1)
            return Vec2(x, progress(at: x))
        }
    }
}
