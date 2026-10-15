import ControlFlowCore
import CoreText
import UIKit

/// Lays out text with CoreText for `TextShaping`: lines broken by a typesetter, glyph
/// outlines from `CTFontCreatePathForGlyph`. It follows the conventions in
/// `TextShaper`'s documentation (line `n`'s box is `n` line spacings down, with the
/// type centered in it, and tracking after every character but a line's last), so the
/// core's carets, hit tests and `TextLayout.adjusted` agree with what is drawn. Glyph
/// outlines are cached by font and glyph, so laying out a string again is cheap.
///
/// A font that isn't installed is drawn in the system font (`hasFont` says so).
struct CoreTextShaper: TextShaper {
    private let cache = GlyphCache()

    func hasFont(_ name: String) -> Bool { cache.hasFont(name) }

    func layout(_ text: TextContent) -> TextLayout {
        let font = font(for: text)
        let spacing = text.lineSpacing
        let ascent = Double(CTFontGetAscent(font)), descent = Double(CTFontGetDescent(font))
        let string = text.string as NSString
        let total = string.length

        // Paragraphs, by UTF-16 range, without their line breaks.
        var paragraphs: [NSRange] = []
        var start = 0
        var index = 0
        while index < total {
            let range = string.rangeOfComposedCharacterSequence(at: index)
            if string.substring(with: range).first?.isNewline == true {
                paragraphs.append(NSRange(location: start, length: index - start))
                start = range.location + range.length
            }
            index = range.location + range.length
        }
        paragraphs.append(NSRange(location: start, length: total - start))

        var laid: [TypesetLine] = []
        // The lines that end a paragraph followed by a line break.
        var breaks = Set<Int>()
        for (p, paragraph) in paragraphs.enumerated() {
            let words = string.substring(with: paragraph) as NSString
            let attributed = NSAttributedString(string: words as String,
                                                attributes: [.font: font, .kern: NSNumber(value: text.tracking)])
            let typesetter = CTTypesetterCreateWithAttributedString(attributed as CFAttributedString)
            let length = paragraph.length
            var lineStart = 0
            repeat {
                var count = length - lineStart
                if let width = text.width, count > 0 {
                    // The last letter's tracking isn't part of the line's width.
                    count = min(max(CTTypesetterSuggestLineBreak(typesetter, lineStart, width + text.tracking), 1), count)
                }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: lineStart, length: count))
                laid.append(TypesetLine(line, range: lineStart..<(lineStart + count), in: words, at: paragraph.location,
                                        tracking: text.tracking, font: font))
                lineStart += count
            } while lineStart < length
            if p < paragraphs.count - 1 { breaks.insert(laid.count - 1) }
        }

        let boxWidth = text.width ?? max(laid.map(\.width).max() ?? 0, 0)
        var glyphs: [TextLayout.Glyph] = []
        var lines: [TextLayout.Line] = []
        var carets = [TextLayout.Caret](repeating: TextLayout.Caret(x: 0, line: 0), count: total + 1)
        for (l, line) in laid.enumerated() {
            let x = (boxWidth - line.width) * text.align.fraction
            let top = Double(l) * spacing
            let baseline = top + (spacing - ascent - descent) / 2 + ascent
            lines.append(TextLayout.Line(range: line.range, x: x, width: line.width, top: top, height: spacing,
                                         baseline: baseline, glyphCount: line.glyphCount))
            for (i, g) in line.glyphs.enumerated() {
                glyphs.append(TextLayout.Glyph(contours: cache.contours(g.glyph, in: g.font),
                                               origin: Vec2(x + g.x, baseline - g.y), line: l, index: i))
            }
            for c in line.carets where c.offset < total { carets[c.offset] = TextLayout.Caret(x: x + c.x, line: l) }
            if breaks.contains(l) {
                // The caret before the line break (each of its UTF-16 units).
                let newline = line.range.upperBound
                let length = newline < total ? string.rangeOfComposedCharacterSequence(at: newline).length : 1
                for k in 0..<length where newline + k <= total {
                    carets[newline + k] = TextLayout.Caret(x: x + line.endX, line: l)
                }
            }
            if l == laid.count - 1 { carets[total] = TextLayout.Caret(x: x + line.endX, line: l) }
        }
        return TextLayout(glyphs: glyphs, lines: lines, carets: carets, boxWidth: boxWidth)
    }

    /// The font `text` is set in: its named font, or the system font in its weight and
    /// slant (also for a font that isn't installed).
    private func font(for text: TextContent) -> CTFont {
        let size = CGFloat(text.size)
        if !text.isSystemFont, cache.hasFont(text.font) {
            return CTFontCreateWithName(text.font as CFString, size, nil)
        }
        var font = UIFont.systemFont(ofSize: size, weight: Self.weight(text.weight))
        if text.italic, let italic = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
            font = UIFont(descriptor: italic, size: size)
        }
        return font as CTFont
    }

    /// The system font weight nearest a 100 to 900 weight.
    static func weight(_ value: Int) -> UIFont.Weight {
        let weights: [UIFont.Weight] = [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black]
        return weights[min(max((value + 50) / 100 - 1, 0), weights.count - 1)]
    }
}

/// One typeset line of a paragraph.
private struct TypesetLine {
    /// The line's characters in the whole string, not counting a line break.
    var range: Range<Int>
    /// How wide its inked characters run, trailing spaces and the last tracking left out.
    var width: Double
    /// Its glyphs up to the last that isn't a trailing space.
    var glyphCount: Int
    /// Each glyph with its font, its x from the line's start and its height above the baseline.
    var glyphs: [(font: CTFont, glyph: CGGlyph, x: Double, y: Double)] = []
    /// The caret before each of the line's UTF-16 offsets (in the whole string), from the line's start.
    var carets: [(offset: Int, x: Double)] = []
    /// The caret after the line's last character.
    var endX: Double

    /// `line`, typeset from `range` of `paragraph`, which starts at `offset` in the whole string.
    init(_ line: CTLine, range: Range<Int>, in paragraph: NSString, at offset: Int, tracking: Double, font: CTFont) {
        var stringIndices: [Int] = []
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let all = CFRange(location: 0, length: 0)
            var ids = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            CTRunGetGlyphs(run, all, &ids)
            CTRunGetPositions(run, all, &positions)
            CTRunGetStringIndices(run, all, &indices)
            // A fallback font (emoji, other scripts) when the text's font lacks a character.
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont = attributes[kCTFontAttributeName].map { $0 as! CTFont } ?? font
            for i in 0..<count {
                glyphs.append((runFont, ids[i], Double(positions[i].x), Double(positions[i].y)))
                stringIndices.append(indices[i])
            }
        }
        // Trailing spaces and tabs.
        var inkedEnd = range.upperBound
        while inkedEnd > range.lowerBound, let scalar = Unicode.Scalar(paragraph.character(at: inkedEnd - 1)),
              CharacterSet.whitespaces.contains(scalar) {
            inkedEnd -= 1
        }
        glyphCount = stringIndices.filter { $0 < inkedEnd }.count
        let typographic = Double(CTLineGetTypographicBounds(line, nil, nil, nil))
        let trailing = Double(CTLineGetTrailingWhitespaceWidth(line))
        // Every character carries its tracking, the last inked one's included.
        width = inkedEnd == range.lowerBound ? 0 : max(typographic - trailing - tracking, 0)
        for i in range {
            carets.append((offset + i, Double(CTLineGetOffsetForStringIndex(line, i, nil))))
        }
        endX = range.isEmpty ? 0 : max(Double(CTLineGetOffsetForStringIndex(line, range.upperBound, nil)) - tracking, 0)
        self.range = (offset + range.lowerBound)..<(offset + range.upperBound)
    }
}

/// Glyph outlines by font and glyph, and which fonts are installed. Locked, since the
/// shaper is called from the main thread and from the renderer's background builds.
private final class GlyphCache: @unchecked Sendable {
    private struct Key: Hashable {
        var font: String
        var size: Double
        var glyph: CGGlyph
    }

    private let lock = NSLock()
    private var outlines: [Key: [BezierPath]] = [:]
    private var installed: [String: Bool] = [:]
    /// Outlines kept before the cache starts again.
    private let limit = 8192

    func hasFont(_ name: String) -> Bool {
        lock.lock()
        if let known = installed[name] {
            lock.unlock()
            return known
        }
        lock.unlock()
        // CoreText stands in another font for a name it doesn't have.
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        let found = (CTFontCopyPostScriptName(font) as String) == name
        lock.lock()
        installed[name] = found
        lock.unlock()
        return found
    }

    func contours(_ glyph: CGGlyph, in font: CTFont) -> [BezierPath] {
        let key = Key(font: CTFontCopyPostScriptName(font) as String, size: Double(CTFontGetSize(font)), glyph: glyph)
        lock.lock()
        if let cached = outlines[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let contours = Self.contours(of: CTFontCreatePathForGlyph(font, glyph, nil))
        lock.lock()
        if outlines.count >= limit { outlines = [:] }
        outlines[key] = contours
        lock.unlock()
        return contours
    }

    /// A glyph's `CGPath` (y up) as closed contours with y down, quadratic curves raised
    /// to cubics. Color glyphs (emoji) have no path and draw nothing.
    static func contours(of path: CGPath?) -> [BezierPath] {
        guard let path else { return [] }
        var rings: [BezierPath] = []
        var points: [PathPoint] = []
        var current = Vec2.zero
        func point(_ p: CGPoint) -> Vec2 { Vec2(Double(p.x), -Double(p.y)) }
        func finish() {
            // A contour that comes back to its start ends on a copy of its first point.
            if points.count > 1, let first = points.first, let last = points.last,
               (first.position - last.position).length < 1e-9 {
                points[0].inHandle = last.inHandle
                points.removeLast()
            }
            if points.count >= 2 { rings.append(BezierPath(points: points, closed: true)) }
            points = []
        }
        func curve(_ c1: Vec2, _ c2: Vec2, _ end: Vec2) {
            guard !points.isEmpty else { return }
            points[points.count - 1].outHandle = c1 - current
            points.append(PathPoint(end, in: c2 - end, smooth: false))
            current = end
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                finish()
                current = point(e.points[0])
                points.append(PathPoint(current, smooth: false))
            case .addLineToPoint:
                current = point(e.points[0])
                points.append(PathPoint(current, smooth: false))
            case .addQuadCurveToPoint:
                let q = point(e.points[0]), end = point(e.points[1])
                curve(current + (q - current) * (2.0 / 3.0), end + (q - end) * (2.0 / 3.0), end)
            case .addCurveToPoint:
                curve(point(e.points[0]), point(e.points[1]), point(e.points[2]))
            case .closeSubpath:
                finish()
            @unknown default:
                break
            }
        }
        finish()
        return rings
    }
}
