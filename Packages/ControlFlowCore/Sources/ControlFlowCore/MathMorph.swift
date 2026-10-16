import Foundation

/// A formula partway through a transition to another (see `MathContent.morph`): the two
/// layouts matched glyph by glyph, the matched glyphs moving between their places and the
/// rest shrinking away or growing in. `player.js` ports this line for line (`pairMath`
/// and `morphMath`), checked by the test vectors.
///
/// Glyphs are matched in three passes, each in reading order:
/// 1. **Tagged parts.** A glyph whose innermost `\class` name is in both formulas is
///    matched only within that name: the k-th glyph with a key there in one with the k-th
///    with the same key there in the other. Those left over shrink or grow.
/// 2. **The same glyph.** The rest pair by key: the k-th `b` with the k-th `b`.
/// 3. **The same symbol.** What is still left pairs by font and code point whatever the
///    variant, so a parenthesis that grows to a larger size (`NCM-N-28` to `NCM-S3-28`)
///    or a sum that changes style (`NCM-SO-2211` to `NCM-LO-2211`) moves rather than
///    being replaced. Its outline swaps from the old one to the new halfway.
///
/// Rules pair in order. A matched glyph's place (the whole matrix, so a script that comes
/// down to the baseline grows too) and a matched rule's rectangle lerp with the progress;
/// an unmatched one scales about its own center, from 1 to 0 when it is leaving and 0 to 1
/// when it is new. Everything is drawn as one path, as a static formula is
/// (`MathLayout.outline`).
public enum MathMorph {
    /// Indices into the two layouts' glyphs or rules: both for a match, one for a glyph or
    /// rule that is leaving (`from`) or new (`to`).
    public struct Pair: Hashable, Sendable {
        public var from: Int?
        public var to: Int?
    }

    /// How two layouts match: matched and new glyphs (and rules) in the order of the
    /// formula they go to, then those leaving in the order of the one they come from.
    public struct Pairing: Hashable, Sendable {
        public var glyphs: [Pair]
        public var rules: [Pair]
    }

    public static func pair(_ a: MathLayout, _ b: MathLayout) -> Pairing {
        var fromOf = [Int?](repeating: nil, count: b.glyphs.count)
        var paired = [Bool](repeating: false, count: a.glyphs.count)
        let shared = Set(a.glyphs.compactMap(\.tags.last)).intersection(b.glyphs.compactMap(\.tags.last))
        func tagged(_ g: MathLayout.Glyph) -> Bool { g.tags.last.map(shared.contains) ?? false }

        // Pairs the glyphs left on both sides that have the same name, in order; a glyph
        // with no name takes no part.
        func match(_ name: (MathLayout.Glyph) -> String?) {
            var queues: [String: [Int]] = [:]
            for (j, g) in b.glyphs.enumerated() where fromOf[j] == nil {
                if let n = name(g) { queues[n, default: []].append(j) }
            }
            var next: [String: Int] = [:]
            for (i, g) in a.glyphs.enumerated() where !paired[i] {
                guard let n = name(g), let queue = queues[n] else { continue }
                let k = next[n, default: 0]
                guard k < queue.count else { continue }
                next[n] = k + 1
                fromOf[queue[k]] = i
                paired[i] = true
            }
        }
        match { g in tagged(g) ? "\(g.tags.last!)\u{0}\(g.key)" : nil }
        match { g in tagged(g) ? nil : g.key }
        match { g in tagged(g) ? nil : symbol(g.key) }

        var glyphs = b.glyphs.indices.map { Pair(from: fromOf[$0], to: $0) }
        glyphs += a.glyphs.indices.filter { !paired[$0] }.map { Pair(from: $0, to: nil) }
        var rules = b.rules.indices.map { Pair(from: $0 < a.rules.count ? $0 : nil, to: $0) }
        rules += (min(b.rules.count, a.rules.count)..<a.rules.count).map { Pair(from: $0, to: nil) }
        return Pairing(glyphs: glyphs, rules: rules)
    }

    /// A glyph key without its variant: `NCM-S6-28` → `NCM-28`.
    static func symbol(_ key: String) -> String {
        let parts = key.components(separatedBy: "-")
        return parts.count >= 3 ? "\(parts[0])-\(parts[parts.count - 1])" : key
    }

    /// The formula `p` of the way from `a` to `b` as one path: exactly `a.outline` at 0
    /// and `b.outline` at 1.
    public static func outline(_ a: MathLayout, _ b: MathLayout, _ pairing: Pairing, progress p: Double) -> BezierPath {
        if p == 0 { return a.outline }
        if p == 1 { return b.outline }
        let lerp = Interpolation.lerp
        let grow = min(max(p, 0), 1), shrink = min(max(1 - p, 0), 1)
        var placed: [(contours: [BezierPath], place: Affine2D)] = []
        placed.reserveCapacity(pairing.glyphs.count)
        for pair in pairing.glyphs {
            switch (pair.from, pair.to) {
            case let (i?, j?):
                let ga = a.glyphs[i], gb = b.glyphs[j]
                let contours = ga.key == gb.key || p >= 0.5 ? b.outlines[gb.key] ?? [] : a.outlines[ga.key] ?? []
                let m = ga.place, n = gb.place
                placed.append((contours, Affine2D(a: lerp(m.a, n.a, p), b: lerp(m.b, n.b, p), c: lerp(m.c, n.c, p),
                                                  d: lerp(m.d, n.d, p), tx: lerp(m.tx, n.tx, p), ty: lerp(m.ty, n.ty, p))))
            case let (i?, nil):
                let g = a.glyphs[i], contours = a.outlines[g.key] ?? []
                if shrink > 0 { placed.append((contours, scaled(g.place, contours: contours, by: shrink))) }
            case let (nil, j?):
                let g = b.glyphs[j], contours = b.outlines[g.key] ?? []
                if grow > 0 { placed.append((contours, scaled(g.place, contours: contours, by: grow))) }
            case (nil, nil):
                break
            }
        }
        var rules: [Rect] = []
        for pair in pairing.rules {
            switch (pair.from, pair.to) {
            case let (i?, j?):
                let r = a.rules[i], s = b.rules[j]
                rules.append(rect(x: lerp(r.minPoint.x, s.minPoint.x, p), y: lerp(r.minPoint.y, s.minPoint.y, p),
                                  w: lerp(r.width, s.width, p), h: lerp(r.height, s.height, p)))
            case let (i?, nil):
                rules.append(scaled(a.rules[i], by: shrink))
            case let (nil, j?):
                rules.append(scaled(b.rules[j], by: grow))
            case (nil, nil):
                break
            }
        }
        return MathLayout.outline(placed: placed, rules: rules)
    }

    /// The box `p` of the way from `a`'s to `b`'s, for picking a formula mid-transition.
    public static func bounds(_ a: MathLayout, _ b: MathLayout, progress p: Double) -> Rect {
        Rect(points: [Vec2.lerp(a.bounds.minPoint, b.bounds.minPoint, p), Vec2.lerp(a.bounds.maxPoint, b.bounds.maxPoint, p)])
    }

    private static func rect(x: Double, y: Double, w: Double, h: Double) -> Rect {
        Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h))
    }

    /// `place` scaled by `s` about the center of the glyph's control points.
    static func scaled(_ place: Affine2D, contours: [BezierPath], by s: Double) -> Affine2D {
        var box = Rect.null
        for contour in contours { box = box.union(contour.controlBounds) }
        let center = box.isNull ? place.apply(.zero)
            : place.apply(Vec2((box.minPoint.x + box.maxPoint.x) / 2, (box.minPoint.y + box.maxPoint.y) / 2))
        return Affine2D(a: place.a * s, b: place.b * s, c: place.c * s, d: place.d * s,
                        tx: place.tx * s + center.x * (1 - s), ty: place.ty * s + center.y * (1 - s))
    }

    /// `rule` scaled by `s` about its center.
    static func scaled(_ rule: Rect, by s: Double) -> Rect {
        let w = rule.width * s, h = rule.height * s
        let cx = rule.minPoint.x + rule.width / 2, cy = rule.minPoint.y + rule.height / 2
        return rect(x: cx - w / 2, y: cy - h / 2, w: w, h: h)
    }

    // MARK: Frames

    /// A morphing formula as it is drawn: its outline and box.
    struct Frame: Sendable {
        var outline: BezierPath
        var bounds: Rect
    }

    private struct Key: Hashable {
        var from: MathContent
        var to: MathContent
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        /// `MathTypesetting.generation` when these were made.
        var generation = -1
        var pairings: [Key: Pairing] = [:]
        var frames: [MathContent: Frame] = [:]
    }

    private static let cache = Cache()
    /// Frames kept: enough for every formula morphing at once to hit its own frame again
    /// when the display draws it twice, as for text tweens.
    static let frameLimit = 32
    static let pairingLimit = 256

    /// The frame of `math`, a formula with `morph`, or nil when it has none or either
    /// layout isn't known (it then draws as it is at the end). The pairing of each two
    /// formulas is made once, since a transition asks for the same pair every frame.
    static func frame(_ math: MathContent) -> Frame? {
        guard let morph = math.morph else { return nil }
        let generation = MathTypesetting.generation
        cache.lock.lock()
        if cache.generation != generation {
            cache.generation = generation
            cache.pairings.removeAll()
            cache.frames.removeAll()
        }
        if let frame = cache.frames[math] {
            cache.lock.unlock()
            return frame
        }
        cache.lock.unlock()
        let to = math.unmorphed
        guard let a = MathTypesetting.layout(morph.from), let b = MathTypesetting.layout(to) else { return nil }
        let key = Key(from: morph.from, to: to)
        cache.lock.lock()
        var pairing = cache.pairings[key]
        cache.lock.unlock()
        if pairing == nil { pairing = pair(a, b) }
        let frame = Frame(outline: outline(a, b, pairing!, progress: morph.progress), bounds: bounds(a, b, progress: morph.progress))
        cache.lock.lock()
        if cache.generation == generation {
            if cache.pairings.count >= pairingLimit { cache.pairings.removeAll() }
            cache.pairings[key] = pairing
            if cache.frames.count >= frameLimit { cache.frames.removeAll() }
            cache.frames[math] = frame
        }
        cache.lock.unlock()
        return frame
    }
}
