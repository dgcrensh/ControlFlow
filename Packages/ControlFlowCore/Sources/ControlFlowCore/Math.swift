import Foundation

/// What a formula shape shows: LaTeX math and how it is set. A `VectorShape` with this
/// payload draws its typeset glyphs (see `MathTypesetting`) in place of its (empty)
/// path. Its origin is the top-left of the formula's box, in the shape's own space.
public struct MathContent: Hashable, Sendable, Codable {
    /// LaTeX math, without `$` or `\[ \]`.
    public var source: String
    /// Points per em, kept in `TextContent.sizeRange`.
    public var size: Double
    /// True: display style, as in `\[ \]`. False: inline style, as in `$ $` (smaller
    /// fractions and limits).
    public var display: Bool

    public init(source: String, size: Double = 72, display: Bool = true) {
        self.source = source
        self.size = size
        self.display = display
    }

    /// The size and style without the source: what new formulas are set in.
    public var style: MathContent {
        var copy = self
        copy.source = ""
        return copy
    }
}

/// A formula typeset: each glyph's outline once, where every glyph goes, the rules
/// (fraction bars, radical overbars), all in the formula's own space in points (y down,
/// the box's top-left at the origin). Made from MathJax's SVG by `parse(svg:content:)`.
public struct MathLayout: Hashable, Sendable {
    public struct Glyph: Hashable, Sendable {
        /// Names the font, variant and code point, such as `NCM-I-1D44E` (italic 𝑎): the
        /// key of its outline in `outlines`.
        public var key: String
        /// Maps the glyph's outline (glyph units, y up, 1000 per em) into the formula's points.
        public var place: Affine2D
        /// The `\class` names the glyph sits in, outermost first.
        public var tags: [String]
        /// The LaTeX it came from (MathJax's `data-latex`), if known.
        public var source: String?

        public init(key: String, place: Affine2D, tags: [String] = [], source: String? = nil) {
            self.key = key
            self.place = place
            self.tags = tags
            self.source = source
        }
    }

    /// Each glyph key's closed contours, once, in glyph units.
    public var outlines: [String: [BezierPath]]
    /// In reading (document) order.
    public var glyphs: [Glyph]
    /// Fraction bars and overlines, in points, in document order.
    public var rules: [Rect]
    /// The formula's box, its top-left at the origin.
    public var bounds: Rect
    /// How far below the box's top the baseline is, in points.
    public var baseline: Double
    /// Every glyph and rule in place, as one closed path that fills like them all (see
    /// `BezierPath.bridging`). Empty when there is nothing to draw.
    public var outline: BezierPath

    public init(outlines: [String: [BezierPath]], glyphs: [Glyph], rules: [Rect], bounds: Rect, baseline: Double) {
        self.outlines = outlines
        self.glyphs = glyphs
        self.rules = rules
        self.bounds = bounds
        self.baseline = baseline
        self.outline = Self.outline(outlines: outlines, glyphs: glyphs, rules: rules)
    }

    /// Each glyph's contours placed, then each rule as a rectangle wound the same way as
    /// the glyphs (so a rule that overlaps a glyph, such as a radical's bar, adds to it
    /// rather than cutting a hole), bridged into one path.
    static func outline(outlines: [String: [BezierPath]], glyphs: [Glyph], rules: [Rect]) -> BezierPath {
        var rings: [BezierPath] = []
        var area = 0.0
        for glyph in glyphs {
            for contour in outlines[glyph.key] ?? [] where contour.points.count >= 2 {
                var ring = contour
                ring.closed = true
                ring.apply(glyph.place)
                area += signedArea(ring)
                rings.append(ring)
            }
        }
        for rule in rules where rule.width > 0 && rule.height > 0 {
            let corners = rule.corners
            let ring = BezierPath(points: corners.map { PathPoint($0, smooth: false) }, closed: true)
            rings.append(area != 0 && (signedArea(ring) > 0) != (area > 0)
                ? BezierPath(points: corners.reversed().map { PathPoint($0, smooth: false) }, closed: true) : ring)
        }
        return BezierPath.bridging(rings)
    }

    /// The signed area of a ring's anchor polygon: enough to tell its direction.
    private static func signedArea(_ ring: BezierPath) -> Double {
        let p = ring.points.map(\.position)
        guard p.count >= 3 else { return 0 }
        var sum = 0.0
        for i in p.indices { sum += p[i].cross(p[(i + 1) % p.count]) }
        return sum / 2
    }

    /// The box a formula with no layout yet stands in (`size` square, at the origin), so
    /// it can be found and selected.
    public static func placeholder(_ math: MathContent) -> Rect {
        Rect(minPoint: .zero, maxPoint: Vec2(math.size, math.size))
    }
}

extension VectorShape {
    /// What the canvas and thumbnails draw for a resolved formula whose layout isn't
    /// known yet (being typeset, or failed): its placeholder box, lightly filled with the
    /// formula's color and outlined with a hairline. Nil for any other shape, and for
    /// exports, which leave such a formula out.
    public var placeholderForMissingLayout: VectorShape? {
        guard let math, let frame = layoutFrame, frame.count >= 3, MathTypesetting.layout(math) == nil else { return nil }
        var copy = self
        copy.path = BezierPath(points: frame.map { PathPoint($0, smooth: false) }, closed: true)
        let color = fill ?? gradient?.stops.first?.color ?? .black
        copy.fill = color.withAlpha(color.a * 0.12)
        copy.fillGlobal = nil
        copy.gradient = nil
        copy.stroke = StrokeStyle(color: color.withAlpha(color.a * 0.35), width: max(math.size / 72, 0.5), join: .miter)
        return copy
    }
}

extension Drawing {
    /// True when any shape is a formula.
    public var hasMath: Bool { layers.contains { $0.shapes.contains { $0.math != nil } } }
}

extension Presentation {
    /// Every distinct formula the presentation shows at a keyframe, in draw order, the
    /// first keyframe first: the formulas `math.json` keeps.
    public var mathContents: [MathContent] {
        var timeline = Timeline(self)
        var seen = Set<MathContent>()
        var out: [MathContent] = []
        for index in 0..<timeline.count {
            for layer in timeline.state(at: index).layers {
                for shape in layer.shapes {
                    if let math = shape.math, seen.insert(math).inserted { out.append(math) }
                }
            }
        }
        return out
    }
}
