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

/// A stretch of a text set in another weight than the text's own.
public struct TextWeightRun: Hashable, Sendable, Codable {
    /// UTF-16 offsets into the text's string.
    public var range: Range<Int>
    /// 100 to 900.
    public var weight: Int

    public init(_ range: Range<Int>, weight: Int) {
        self.range = range
        self.weight = weight
    }
}

/// What a text shape says and how it is set: one style for the whole text but its
/// weight, which can change from one stretch of the words to the next (`weights`). A
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
    /// The stretches of `string` set in another weight than `weight`: in order, apart,
    /// within the string, and none empty or in `weight` itself. Only for the system font.
    /// The mutating methods below keep them so; after setting `string` or `weight`
    /// directly, call `normalizeWeights`.
    public var weights: [TextWeightRun] = []
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
                tracking: Double = 0, weights: [TextWeightRun] = []) {
        self.string = string
        self.font = font
        self.weight = weight
        self.italic = italic
        self.size = size
        self.align = align
        self.width = width
        self.lineHeight = lineHeight
        self.tracking = tracking
        self.weights = weights
        normalizeWeights()
    }

    public var isSystemFont: Bool { font == Self.systemFont }

    /// The style without the words: what new text is set in.
    public var style: TextContent {
        var copy = self
        copy.string = ""
        copy.weights = []
        copy.held = nil
        return copy
    }

    // MARK: Weights

    /// The weight of each of the string's UTF-16 units.
    public var unitWeights: [Int] {
        var out = [Int](repeating: weight, count: string.utf16.count)
        for run in weights {
            let lower = min(max(run.range.lowerBound, 0), out.count), upper = min(max(run.range.upperBound, lower), out.count)
            for i in lower..<upper { out[i] = run.weight }
        }
        return out
    }

    /// Sets `weights` from each UTF-16 unit's weight (`units` as long as the string).
    public mutating func setUnitWeights(_ units: [Int]) {
        var runs: [TextWeightRun] = []
        var i = 0
        while i < units.count {
            let w = Self.clampedWeight(units[i])
            var j = i + 1
            while j < units.count, Self.clampedWeight(units[j]) == w { j += 1 }
            if w != weight { runs.append(TextWeightRun(i..<j, weight: w)) }
            i = j
        }
        weights = runs
    }

    /// Puts `weights` in order within the string, as `weights` says they are kept: where
    /// two overlap, the later one wins. The player does the same (`player.js`, `readText`).
    public mutating func normalizeWeights() {
        weight = Self.clampedWeight(weight)
        guard !weights.isEmpty else { return }
        setUnitWeights(unitWeights)
    }

    /// The stretches of the string with their weights, in order, covering it (none for an
    /// empty string): what a shaper sets.
    public var weightRuns: [TextWeightRun] {
        let n = string.utf16.count
        var out: [TextWeightRun] = []
        var at = 0
        for run in weights {
            let lower = min(max(run.range.lowerBound, at), n), upper = min(max(run.range.upperBound, lower), n)
            guard lower < upper else { continue }
            if at < lower { out.append(TextWeightRun(at..<lower, weight: weight)) }
            out.append(TextWeightRun(lower..<upper, weight: run.weight))
            at = upper
        }
        if at < n { out.append(TextWeightRun(at..<n, weight: weight)) }
        return out
    }

    /// The weight of the character at UTF-16 offset `offset`: the last one's past the end,
    /// and `weight` for an empty string.
    public func weight(at offset: Int) -> Int {
        let n = string.utf16.count
        guard n > 0 else { return weight }
        let i = min(max(offset, 0), n - 1)
        return weights.first { $0.range.contains(i) }?.weight ?? weight
    }

    /// The weight new words typed at `range` take: the character's before it, or after it
    /// at the start.
    public func insertionWeight(at range: Range<Int>) -> Int {
        range.lowerBound > 0 ? weight(at: range.lowerBound - 1) : weight(at: range.upperBound)
    }

    /// The weight every character in `range` has, or nil when they differ. For an empty
    /// range, the weight typing there takes.
    public func uniformWeight(in range: Range<Int>) -> Int? {
        let n = string.utf16.count
        let lower = min(max(range.lowerBound, 0), n), upper = min(max(range.upperBound, lower), n)
        guard lower < upper else { return insertionWeight(at: lower..<lower) }
        let units = unitWeights[lower..<upper]
        let first = units.first!
        return units.allSatisfy { $0 == first } ? first : nil
    }

    /// Sets the characters in UTF-16 range `range` in `weight`.
    public mutating func setWeight(_ weight: Int, in range: Range<Int>) {
        var units = unitWeights
        let lower = min(max(range.lowerBound, 0), units.count), upper = min(max(range.upperBound, lower), units.count)
        guard lower < upper else { return }
        for i in lower..<upper { units[i] = Self.clampedWeight(weight) }
        setUnitWeights(units)
    }

    /// Changes the string to `new`, as a keyboard did with the selection `selection`
    /// before the change, keeping every character's weight and setting what was typed in
    /// `typing` (or the weight of the character before it, see `insertionWeight`).
    ///
    /// The change is taken to be one stretch replaced, starting no later than the
    /// selection and the caret after it (`newSelection`): typing "l" after the "l" of
    /// "Hel" in "Hello" adds it there, not after the next "l". Characters at either end of
    /// the stretch that didn't change keep their weights.
    public mutating func replaceString(with new: String, selection: Range<Int>, newSelection: Range<Int>, typing: Int? = nil) {
        guard new != string else { return }
        let old = Array(string.utf16), now = Array(new.utf16)
        guard !weights.isEmpty || (typing != nil && typing != weight) else {
            string = new
            return
        }
        let units = unitWeights
        var prefix = 0
        while prefix < min(old.count, now.count), old[prefix] == now[prefix] { prefix += 1 }
        let a = max(min(prefix, selection.lowerBound, newSelection.lowerBound), 0)
        var suffix = 0
        while suffix < min(old.count, now.count) - a, old[old.count - 1 - suffix] == now[now.count - 1 - suffix] { suffix += 1 }
        let b = old.count - suffix, c = now.count - suffix
        let typed = typing.map(Self.clampedWeight) ?? insertionWeight(at: a..<b)
        // Within the replaced stretch, the characters that stayed the same at its ends.
        var keepStart = 0
        while keepStart < min(b - a, c - a), old[a + keepStart] == now[a + keepStart] { keepStart += 1 }
        var keepEnd = 0
        while keepEnd < min(b - a, c - a) - keepStart, old[b - 1 - keepEnd] == now[c - 1 - keepEnd] { keepEnd += 1 }
        var out = Array(units[..<a])
        for k in 0..<(c - a) {
            if k < keepStart {
                out.append(units[a + k])
            } else if k >= c - a - keepEnd {
                out.append(units[b - (c - a - k)])
            } else {
                out.append(typed)
            }
        }
        out += units[b...]
        string = new
        setUnitWeights(out)
    }

    static func clampedWeight(_ weight: Int) -> Int {
        min(max(weight, weightRange.lowerBound), weightRange.upperBound)
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
///
/// The caches drop the texts used least recently when full, so a long presentation
/// keeps its static texts laid out. A text partway through a tracking or line-height
/// tween (one with `held` metrics) is new on every frame and never seen again, so those
/// go in small caches of their own and can't push the static texts out.
public enum TextShaping {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var shaper: any TextShaper = StubTextShaper()
        var layouts = TextCache<TextLayout>(limit: TextShaping.cacheLimit)
        var outlines = TextCache<BezierPath>(limit: TextShaping.cacheLimit)
        var heldLayouts = TextCache<TextLayout>(limit: TextShaping.heldCacheLimit)
        var heldOutlines = TextCache<BezierPath>(limit: TextShaping.heldCacheLimit)
        /// By the text a tween holds its lines at: its glyphs' outlines flattened.
        var flatGlyphs = TextCache<FlatGlyphs>(limit: TextShaping.heldCacheLimit)

        func clear() {
            layouts.removeAll()
            outlines.removeAll()
            heldLayouts.removeAll()
            heldOutlines.removeAll()
            flatGlyphs.removeAll()
        }
    }

    private static let state = State()
    /// Texts whose layouts and outlines are kept.
    static let cacheLimit = 512
    /// Tweened (`held`) texts kept: enough for every text tweening at once to hit its
    /// own frame again when the display draws it twice.
    static let heldCacheLimit = 32

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
            state.clear()
        }
    }

    /// `text` laid out by the shaper in use, cached. A text with `held` metrics is laid
    /// out at them and then `adjusted` to its own.
    public static func layout(_ text: TextContent) -> TextLayout {
        let held = text.held != nil
        state.lock.lock()
        if let cached = held ? state.heldLayouts.value(for: text) : state.layouts.value(for: text) {
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
        if held {
            state.heldLayouts.set(layout, for: text)
        } else {
            state.layouts.set(layout, for: text)
        }
        state.lock.unlock()
        return layout
    }

    /// The glyph outlines of `text` as one path (`TextLayout.outline`), cached.
    public static func outline(_ text: TextContent) -> BezierPath {
        let held = text.held != nil
        state.lock.lock()
        if let cached = held ? state.heldOutlines.value(for: text) : state.outlines.value(for: text) {
            state.lock.unlock()
            return cached
        }
        state.lock.unlock()
        let path = layout(text).outline
        state.lock.lock()
        if held {
            state.heldOutlines.set(path, for: text)
        } else {
            state.outlines.set(path, for: text)
        }
        state.lock.unlock()
        return path
    }

    /// Each glyph's closed outlines flattened at `tolerance`, relative to the glyph's
    /// origin, each ring back at its first point: one ring per outline that `outline`
    /// draws, with the index of its glyph.
    struct FlatGlyphs {
        var tolerance: Double
        var rings: [(glyph: Int, points: [Vec2])]
    }

    /// `outline(text).flattened(tolerance:)`. For a text partway through a tracking or
    /// line-height tween (one with `held` metrics), whose glyphs only move from frame to
    /// frame (see `TextLayout.adjusted`), each glyph's outlines are flattened once, at
    /// the held metrics, and moved where this frame puts the glyph. The result follows
    /// `BezierPath.bridging`: each ring back to its first point, and every ring after the
    /// first followed by the first ring's first point, which the bridges pass through.
    public static func flattenedOutline(_ text: TextContent, tolerance: Double) -> [Vec2] {
        guard let held = text.held else { return outline(text).flattened(tolerance: tolerance) }
        var base = text
        base.held = nil
        base.tracking = held.tracking
        base.lineHeight = held.lineHeight
        state.lock.lock()
        var flat = state.flatGlyphs.value(for: base)
        state.lock.unlock()
        if flat?.tolerance != tolerance {
            var rings: [(glyph: Int, points: [Vec2])] = []
            for (g, glyph) in layout(base).glyphs.enumerated() {
                for contour in glyph.contours where contour.points.count >= 2 {
                    var ring = contour
                    ring.closed = true
                    rings.append((g, ring.flattened(tolerance: tolerance) + [ring.points[0].position]))
                }
            }
            flat = FlatGlyphs(tolerance: tolerance, rings: rings)
            state.lock.lock()
            state.flatGlyphs.set(flat!, for: base)
            state.lock.unlock()
        }
        let glyphs = layout(text).glyphs
        var out: [Vec2] = []
        out.reserveCapacity(flat!.rings.reduce(0) { $0 + $1.points.count + 1 })
        for (k, ring) in flat!.rings.enumerated() {
            let origin = glyphs[ring.glyph].origin
            for p in ring.points { out.append(p + origin) }
            if k > 0 { out.append(out[0]) }
        }
        return out
    }

    /// How many texts the caches hold, for tests: static layouts and tweened ones.
    static var cachedCounts: (layouts: Int, held: Int) {
        state.lock.lock()
        defer { state.lock.unlock() }
        return (state.layouts.count, state.heldLayouts.count)
    }

    /// False when the shaper in use doesn't have `text`'s font.
    public static func hasFont(_ text: TextContent) -> Bool {
        text.isSystemFont || shaper.hasFont(text.font)
    }
}

/// A cache by text that drops the least recently used quarter when it is full, so
/// eviction costs a sort every `limit / 4` insertions rather than a wipe.
struct TextCache<Value> {
    let limit: Int
    private var entries: [TextContent: (value: Value, use: Int)] = [:]
    private var clock = 0

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var count: Int { entries.count }

    /// The value for `text`, marking it as just used.
    mutating func value(for text: TextContent) -> Value? {
        guard let index = entries.index(forKey: text) else { return nil }
        clock += 1
        entries.values[index].use = clock
        return entries.values[index].value
    }

    mutating func set(_ value: Value, for text: TextContent) {
        if entries.count >= limit, entries[text] == nil {
            let drop = max(limit / 4, 1)
            let oldest = entries.lazy.map { ($0.key, $0.value.use) }.sorted { $0.1 < $1.1 }.prefix(drop)
            for (key, _) in oldest { entries[key] = nil }
        }
        clock += 1
        entries[text] = (value, clock)
    }

    mutating func removeAll() {
        entries = [:]
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
