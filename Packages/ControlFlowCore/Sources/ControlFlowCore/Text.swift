import Foundation

/// How the lines of a text sit in its box.
public enum TextAlignment: String, Hashable, Sendable, Codable, CaseIterable {
    case left, center, right

    /// How far across the spare width a line moves: 0, half or all of it.
    public var fraction: Double {
        switch self {
        case .left: 0
        case .center: 0.5
        case .right: 1
        }
    }
}

/// The tracking and line height a text's lines were broken at, held while a transition
/// changes them (see `TextContent.held`).
public struct TextMetrics: Hashable, Sendable, Codable {
    public var tracking: Double
    public var lineHeight: Double

    public init(tracking: Double, lineHeight: Double) {
        self.tracking = tracking
        self.lineHeight = lineHeight
    }
}

/// What a text shape says and how it is set: one style for the whole text. A
/// `VectorShape` with this payload draws its glyph outlines, laid out by
/// `TextShaping`, in place of its (empty) path. Its origin is the top-left of the
/// first line's box, in the shape's own space.
public struct TextContent: Hashable, Sendable, Codable {
    /// The `font` that means the system font, in `weight` and `italic`.
    public static let systemFont = "system"

    public var string: String
    /// A PostScript name, or `systemFont`.
    public var font: String
    /// 100 to 900; only for the system font.
    public var weight: Int
    /// Only for the system font.
    public var italic: Bool
    /// The type size in points.
    public var size: Double
    public var align: TextAlignment
    /// Nil: one line per paragraph, as wide as it runs. A number: a box that wraps at
    /// that width.
    public var width: Double?
    /// The distance from one line to the next, as a multiple of `size`.
    public var lineHeight: Double
    /// Extra space between letters, in points.
    public var tracking: Double
    /// Partway through a transition that changes `tracking` or `lineHeight`: the
    /// values the lines are broken at (the end keyframe's), so words never jump between
    /// lines midway. Never saved.
    public var held: TextMetrics?

    public init(string: String = "", font: String = TextContent.systemFont, weight: Int = 400, italic: Bool = false,
                size: Double = 72, align: TextAlignment = .left, width: Double? = nil, lineHeight: Double = 1.2,
                tracking: Double = 0) {
        self.string = string
        self.font = font
        self.weight = weight
        self.italic = italic
        self.size = size
        self.align = align
        self.width = width
        self.lineHeight = lineHeight
        self.tracking = tracking
    }

    public var isSystemFont: Bool { font == Self.systemFont }

    /// The style without the words: what new text is set in.
    public var style: TextContent {
        var copy = self
        copy.string = ""
        copy.held = nil
        return copy
    }

    /// The distance between baselines, in points.
    public var lineSpacing: Double { lineHeight * size }

    /// The range the type size is kept in.
    public static let sizeRange = 1.0...2000.0
    public static let weightRange = 100...900
    public static let lineHeightRange = 0.1...10.0
}

/// A text laid out: glyph outlines, lines and caret positions, in the text's own space
/// (y down, the first line's box at the top-left, at the origin).
public struct TextLayout: Hashable, Sendable {
    public struct Glyph: Hashable, Sendable {
        /// Closed outlines, relative to `origin`. Empty for a space.
        public var contours: [BezierPath]
        /// Where the glyph sits on its line's baseline.
        public var origin: Vec2
        /// Its line, and its place on that line counting from 0, for tracking: glyph `i`
        /// of a line sits `i * tracking` points further on.
        public var line: Int
        public var index: Int

        public init(contours: [BezierPath], origin: Vec2, line: Int, index: Int) {
            self.contours = contours
            self.origin = origin
            self.line = line
            self.index = index
        }
    }

    public struct Line: Hashable, Sendable {
        /// The UTF-16 offsets of the line's characters, not counting a line break.
        public var range: Range<Int>
        /// Where the line starts (from alignment) and how wide it runs, trailing spaces
        /// left out.
        public var x: Double
        public var width: Double
        /// The top of the line's box, its height (the line spacing) and its baseline.
        public var top: Double
        public var height: Double
        public var baseline: Double
        /// How many glyphs `width` covers: those on the line up to its last one that
        /// isn't a trailing space. Tracking adds `glyphCount - 1` gaps to the width.
        public var glyphCount: Int

        public init(range: Range<Int>, x: Double, width: Double, top: Double, height: Double, baseline: Double,
                    glyphCount: Int) {
            self.range = range
            self.x = x
            self.width = width
            self.top = top
            self.height = height
            self.baseline = baseline
            self.glyphCount = glyphCount
        }
    }

    /// Where the caret goes before UTF-16 offset `i` (`carets[i]`), as an x on a line.
    public struct Caret: Hashable, Sendable {
        public var x: Double
        public var line: Int

        public init(x: Double, line: Int) {
            self.x = x
            self.line = line
        }
    }

    public var glyphs: [Glyph]
    /// At least one, even for an empty text.
    public var lines: [Line]
    /// One more than the string's UTF-16 length.
    public var carets: [Caret]
    /// The box's width: the text's `width`, or its widest line.
    public var boxWidth: Double

    public init(glyphs: [Glyph], lines: [Line], carets: [Caret], boxWidth: Double) {
        self.glyphs = glyphs
        self.lines = lines
        self.carets = carets
        self.boxWidth = boxWidth
    }

    /// The text's box: as wide as `boxWidth`, as tall as its lines.
    public var bounds: Rect {
        let bottom = lines.last.map { $0.top + $0.height } ?? 0
        return Rect(minPoint: .zero, maxPoint: Vec2(max(boxWidth, 0), max(bottom, 0)))
    }

    /// The box a tap selects the text in: `bounds`, at least a line tall and a little
    /// wide, so an empty text can still be found.
    public var frame: Rect {
        let b = bounds
        let height = max(b.height, lines.first?.height ?? 0)
        let width = max(b.width, height * 0.25)
        return Rect(minPoint: .zero, maxPoint: Vec2(width, height))
    }

    /// The layout with `tracking` and `lineHeight` changed from `base`'s, lines broken as
    /// they are: glyph `i` of each line moves `i` times the change in tracking, lines
    /// realign, and line `n`'s box moves down `n` times the change in line spacing (its
    /// baseline `n + 1/2` times, since shapers center the type in the line's box). The
    /// player does the same (`player.js`, `adjustedLayout`).
    public func adjusted(from base: TextContent, tracking: Double, lineHeight: Double) -> TextLayout {
        let dt = tracking - base.tracking
        let spacing = lineHeight * base.size, dh = spacing - base.lineSpacing
        guard dt != 0 || dh != 0 else { return self }
        var out = self
        let widths = lines.map { $0.width + dt * Double(max($0.glyphCount - 1, 0)) }
        out.boxWidth = base.width ?? max(widths.max() ?? 0, 0)
        let f = base.align.fraction
        var shifts: [Double] = []
        for i in lines.indices {
            let x = (out.boxWidth - widths[i]) * f
            shifts.append(x - lines[i].x)
            let dy = dh * Double(i)
            out.lines[i].x = x
            out.lines[i].width = widths[i]
            out.lines[i].top += dy
            out.lines[i].baseline += dy + dh / 2
            out.lines[i].height = spacing
        }
        for g in out.glyphs.indices {
            let line = out.glyphs[g].line
            guard lines.indices.contains(line) else { continue }
            out.glyphs[g].origin += Vec2(shifts[line] + dt * Double(out.glyphs[g].index), dh * (Double(line) + 0.5))
        }
        for c in out.carets.indices {
            let line = out.carets[c].line
            guard lines.indices.contains(line) else { continue }
            out.carets[c].x += shifts[line]
        }
        return out
    }

    /// Every glyph's outlines in place, as one closed path that fills like them all
    /// (see `BezierPath.bridging`). Empty when there is nothing to draw.
    public var outline: BezierPath {
        var rings: [BezierPath] = []
        for glyph in glyphs {
            for contour in glyph.contours where contour.points.count >= 2 {
                var ring = contour
                ring.apply(.translation(glyph.origin))
                rings.append(ring)
            }
        }
        return BezierPath.bridging(rings)
    }

    // MARK: Carets

    /// The caret before UTF-16 offset `offset` (clamped) as a line from the top of its
    /// line to the bottom.
    public func caret(at offset: Int) -> (top: Vec2, bottom: Vec2) {
        let c = carets[min(max(offset, 0), carets.count - 1)]
        let line = lines[min(max(c.line, 0), lines.count - 1)]
        return (Vec2(c.x, line.top), Vec2(c.x, line.top + line.height))
    }

    /// The UTF-16 offset whose caret is nearest `p` (text space): on the line `p` is
    /// level with, the nearest caret.
    public func offset(nearest p: Vec2) -> Int {
        guard !carets.isEmpty else { return 0 }
        var lineIndex = lines.count - 1
        for (i, line) in lines.enumerated() where p.y < line.top + line.height {
            lineIndex = i
            break
        }
        var best = 0, bestDistance = Double.infinity
        for (i, c) in carets.enumerated() where c.line == lineIndex {
            let d = abs(c.x - p.x)
            if d < bestDistance {
                best = i
                bestDistance = d
            }
        }
        return bestDistance.isFinite ? best : carets.count - 1
    }

    /// The offset one line up (`-1`) or down (`1`) from `offset`, at the same x; the
    /// start or the end of the text past the first or last line.
    public func offset(from offset: Int, lines delta: Int) -> Int {
        let c = carets[min(max(offset, 0), carets.count - 1)]
        let target = c.line + delta
        if target < 0 { return 0 }
        if target >= lines.count { return carets.count - 1 }
        let line = lines[target]
        return self.offset(nearest: Vec2(c.x, line.top + line.height / 2))
    }

    /// The highlighted boxes of the UTF-16 range `range`, one per line it touches.
    public func selectionRects(_ range: Range<Int>) -> [Rect] {
        guard !range.isEmpty, !carets.isEmpty else { return [] }
        let lower = min(max(range.lowerBound, 0), carets.count - 1)
        let upper = min(max(range.upperBound, 0), carets.count - 1)
        guard lower < upper else { return [] }
        var rects: [Rect] = []
        for (i, line) in lines.enumerated() {
            let start = max(lower, line.range.lowerBound), end = min(upper, line.range.upperBound)
            let touches = start < end || (lower <= line.range.upperBound && upper > line.range.upperBound)
            guard touches else { continue }
            let x0 = carets[start].line == i ? carets[start].x : line.x
            var x1 = carets[end].line == i ? carets[end].x : line.x + line.width
            // A selection running on past the line's end takes in its line break.
            if upper > line.range.upperBound { x1 = max(x1, line.x + line.width) + line.height * 0.25 }
            guard x1 > x0 else { continue }
            rects.append(Rect(minPoint: Vec2(x0, line.top), maxPoint: Vec2(x1, line.top + line.height)))
        }
        return rects
    }
}

/// Lays out text: the app's uses CoreText; `StubTextShaper` stands in for tests and
/// on Linux. `TextShaping.shaper` is the one in use.
public protocol TextShaper: Sendable {
    /// `text` laid out, ignoring `held` (`TextShaping.layout` handles that). Line `n`'s
    /// box is `n` line spacings down, and the type is centered in it, so its baseline is
    /// `(spacing - ascent - descent) / 2 + ascent` below the box's top.
    func layout(_ text: TextContent) -> TextLayout
    /// False when the shaper doesn't have the font `text.font` names, and draws it in
    /// the system font instead.
    func hasFont(_ name: String) -> Bool
}

extension TextShaper {
    public func hasFont(_ name: String) -> Bool { true }
}

/// The text shaper in use and a cache of its layouts. The app sets its CoreText shaper
/// at launch; until then, and in tests, it is `StubTextShaper`.
public enum TextShaping {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var shaper: any TextShaper = StubTextShaper()
        var layouts: [TextContent: TextLayout] = [:]
        var outlines: [TextContent: BezierPath] = [:]
    }

    private static let state = State()
    /// Layouts kept before the cache starts again.
    static let cacheLimit = 512

    public static var shaper: any TextShaper {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.shaper
        }
        set {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.shaper = newValue
            state.layouts = [:]
            state.outlines = [:]
        }
    }

    /// `text` laid out by the shaper in use, cached. A text with `held` metrics is laid
    /// out at them and then `adjusted` to its own.
    public static func layout(_ text: TextContent) -> TextLayout {
        state.lock.lock()
        if let cached = state.layouts[text] {
            state.lock.unlock()
            return cached
        }
        let shaper = state.shaper
        state.lock.unlock()
        let layout: TextLayout
        if let held = text.held {
            var base = text
            base.held = nil
            base.tracking = held.tracking
            base.lineHeight = held.lineHeight
            layout = self.layout(base).adjusted(from: base, tracking: text.tracking, lineHeight: text.lineHeight)
        } else {
            layout = shaper.layout(text)
        }
        state.lock.lock()
        if state.layouts.count >= cacheLimit { state.layouts = [:] }
        state.layouts[text] = layout
        state.lock.unlock()
        return layout
    }

    /// The glyph outlines of `text` as one path (`TextLayout.outline`), cached.
    public static func outline(_ text: TextContent) -> BezierPath {
        state.lock.lock()
        if let cached = state.outlines[text] {
            state.lock.unlock()
            return cached
        }
        state.lock.unlock()
        let path = layout(text).outline
        state.lock.lock()
        if state.outlines.count >= cacheLimit { state.outlines = [:] }
        state.outlines[text] = path
        state.lock.unlock()
        return path
    }

    /// False when the shaper in use doesn't have `text`'s font.
    public static func hasFont(_ text: TextContent) -> Bool {
        text.isSystemFont || shaper.hasFont(text.font)
    }
}

/// A shaper with no fonts, for tests and Linux: every character is a box with a
/// square hole, advancing `0.6 * size` (a space advances as much and draws nothing).
/// Lines break at newlines and, in a box, before the word that would overflow it.
public struct StubTextShaper: TextShaper {
    public init() {}

    /// The ascent and descent as fractions of the size.
    public static let ascent = 0.8
    public static let descent = 0.2
    public static let advance = 0.6

    public func layout(_ text: TextContent) -> TextLayout {
        let size = text.size
        let advance = Self.advance * size
        // Characters with their UTF-16 offsets.
        var characters: [(character: Character, offset: Int, length: Int)] = []
        var offset = 0
        for ch in text.string {
            let length = ch.utf16.count
            characters.append((ch, offset, length))
            offset += length
        }
        let total = offset

        // Break into lines: each a run of character indices.
        var runs: [Range<Int>] = []
        var start = 0
        func inked(_ run: Range<Int>) -> Int {
            var end = run.upperBound
            while end > run.lowerBound, characters[end - 1].character == " " { end -= 1 }
            return end - run.lowerBound
        }
        func width(of run: Range<Int>) -> Double {
            let n = inked(run)
            return n == 0 ? 0 : Double(n) * advance + Double(n - 1) * text.tracking
        }
        var i = 0
        while i <= characters.count {
            if i == characters.count || characters[i].character.isNewline {
                runs.append(start..<i)
                start = i + 1
                i += 1
                continue
            }
            if let limit = text.width, i > start, width(of: start..<(i + 1)) > limit, characters[i].character != " " {
                // Break before the word holding character i, or at i in a word too long for a line.
                var wordStart = i
                while wordStart > start, characters[wordStart - 1].character != " " { wordStart -= 1 }
                let breakAt = wordStart > start ? wordStart : i
                runs.append(start..<breakAt)
                start = breakAt
            }
            i += 1
        }

        let spacing = text.lineSpacing
        let widths = runs.map(width(of:))
        let boxWidth = text.width ?? (widths.max() ?? 0)
        var glyphs: [TextLayout.Glyph] = []
        var lines: [TextLayout.Line] = []
        var carets = [TextLayout.Caret](repeating: TextLayout.Caret(x: 0, line: 0), count: total + 1)
        for (l, run) in runs.enumerated() {
            let x = (boxWidth - widths[l]) * text.align.fraction
            let top = Double(l) * spacing
            let baseline = top + (spacing - (Self.ascent + Self.descent) * size) / 2 + Self.ascent * size
            let lower = run.isEmpty ? (run.lowerBound < characters.count ? characters[run.lowerBound].offset : total)
                : characters[run.lowerBound].offset
            let upper = run.isEmpty ? lower : characters[run.upperBound - 1].offset + characters[run.upperBound - 1].length
            lines.append(TextLayout.Line(range: lower..<upper, x: x, width: widths[l], top: top, height: spacing,
                                         baseline: baseline, glyphCount: inked(run)))
            var pen = x
            for (index, c) in run.enumerated() {
                let ch = characters[c]
                for k in 0..<ch.length { carets[ch.offset + k] = TextLayout.Caret(x: pen, line: l) }
                let contours = ch.character == " " ? [] : Self.box(size: size, advance: advance)
                glyphs.append(TextLayout.Glyph(contours: contours, origin: Vec2(pen, baseline), line: l, index: index))
                pen += advance + text.tracking
            }
            // The caret after the line's last character: before its line break, or at the
            // end. (After a wrapped line, the next line's first caret is the next line's.)
            let endX = run.isEmpty ? x : pen - text.tracking
            if run.upperBound == characters.count {
                carets[total] = TextLayout.Caret(x: endX, line: l)
            } else if characters[run.upperBound].character.isNewline {
                let ch = characters[run.upperBound]
                for k in 0..<ch.length { carets[ch.offset + k] = TextLayout.Caret(x: endX, line: l) }
            }
        }
        return TextLayout(glyphs: glyphs, lines: lines, carets: carets, boxWidth: boxWidth)
    }

    /// A box glyph with a square hole, on the baseline at the origin.
    static func box(size: Double, advance: Double) -> [BezierPath] {
        let outer = Rect(minPoint: Vec2(advance * 0.1, -ascent * size), maxPoint: Vec2(advance * 0.9, 0))
        let inner = outer.outset(by: -min(outer.width, outer.height) * 0.25)
        func ring(_ r: Rect, clockwise: Bool) -> BezierPath {
            let c = r.corners
            let order = clockwise ? c : c.reversed()
            return BezierPath(points: order.map { PathPoint($0, smooth: false) }, closed: true)
        }
        return [ring(outer, clockwise: true), ring(inner, clockwise: false)]
    }
}

extension BezierPath {
    /// One closed path that fills (non-zero) like the closed `rings` together, each
    /// keeping its own direction: every ring after the first is reached by a hairline
    /// bridge from the first ring's start and back along the same line, so the bridges
    /// add no area. Empty for no rings.
    public static func bridging(_ rings: [BezierPath]) -> BezierPath {
        var out: [PathPoint] = []
        var hub: PathPoint?
        for ring in rings where !ring.points.isEmpty {
            var points = ring.points
            // Enter at the first point and come back to it along straight bridges.
            var back = points[0]
            back.outHandle = .zero
            back.mode = .corner
            points[0].inHandle = .zero
            points[0].mode = .corner
            out += points
            out.append(back)
            if let hub {
                out.append(hub)
            } else {
                var corner = points[0]
                corner.inHandle = .zero
                corner.outHandle = .zero
                hub = corner
            }
        }
        return BezierPath(points: out, closed: true)
    }
}
