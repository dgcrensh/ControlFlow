import Foundation

extension MathLayout {
    /// Reads MathJax's SVG output for `content` (its `source` and `display` typeset, as
    /// `MathTypesetter.typeset` returns it), at `content.size` points per em.
    ///
    /// The `<defs>` give each glyph's outline, keyed by its id without MathJax's
    /// `MJX-<n>-` prefix. The tree under them is walked with its transforms: a `<use>` is a
    /// glyph, a `<rect>` a rule, a nested `<svg>` (how MathJax clips a stretched extender)
    /// fits the glyphs in it to its window, `class` names tag the glyphs inside and
    /// `data-latex` gives their source. Colors and anything else are ignored. Throws a
    /// `MathError` when the SVG doesn't read or has no `viewBox`.
    public static func parse(svg: String, content: MathContent) throws(MathError) -> MathLayout {
        let document: MarkupElement
        do {
            document = try XMLReader.parse(svg)
        } catch {
            throw MathError(message: "The typeset formula doesn't read: \((error as? XMLReader.Failure)?.message ?? "\(error)")")
        }
        guard let root = Self.firstElement(named: "svg", in: document),
              let viewBox = root.attributes["viewBox"].map(Self.numbers), viewBox.count == 4,
              viewBox[2] >= 0, viewBox[3] >= 0 else {
            throw MathError(message: "The typeset formula has no box")
        }
        var outlines: [String: [BezierPath]] = [:]
        var bounds: [String: Rect] = [:]
        Self.readDefs(root, into: &outlines, bounds: &bounds)

        // SVG units (y down, the viewBox's) to points with the box's top-left at the origin.
        let k = content.size / 1000
        let toPoints = Affine2D.scale(k) * Affine2D.translation(Vec2(-viewBox[0], -viewBox[1]))
        var walker = Walker(outlines: outlines, bounds: bounds)
        for child in root.children where child.name != "defs" {
            walker.walk(child, matrix: toPoints, tags: [], source: nil, clip: nil)
        }
        let used = Set(walker.glyphs.map(\.key))
        return MathLayout(outlines: outlines.filter { used.contains($0.key) }, glyphs: walker.glyphs, rules: walker.rules,
                          bounds: Rect(minPoint: .zero, maxPoint: Vec2(viewBox[2] * k, viewBox[3] * k)),
                          baseline: -viewBox[1] * k)
    }

    /// A glyph id without MathJax's per-call `MJX-<n>-` prefix.
    static func glyphKey(_ id: String) -> String {
        guard id.hasPrefix("MJX-") else { return id }
        let rest = id.dropFirst(4)
        guard let dash = rest.firstIndex(of: "-"), rest[..<dash].allSatisfy(\.isNumber) else { return id }
        return String(rest[rest.index(after: dash)...])
    }

    private static func firstElement(named name: String, in element: MarkupElement) -> MarkupElement? {
        if element.name == name { return element }
        for child in element.children {
            if let found = firstElement(named: name, in: child) { return found }
        }
        return nil
    }

    private static func readDefs(_ element: MarkupElement, into outlines: inout [String: [BezierPath]], bounds: inout [String: Rect]) {
        for child in element.children {
            if child.name == "path", let id = child.attributes["id"] {
                let contours = SVGPathParser.parse(child.attributes["d"] ?? "").compactMap(\.bezierPath).map { path -> BezierPath in
                    var ring = path
                    ring.closed = true
                    return ring
                }
                let key = glyphKey(id)
                outlines[key] = contours
                bounds[key] = contours.reduce(Rect.null) { $0.union($1.controlBounds) }
            } else if child.name == "defs" || child.name == "g" {
                readDefs(child, into: &outlines, bounds: &bounds)
            }
        }
    }

    static func numbers(_ text: String) -> [Double] {
        var scanner = NumberScanner(text)
        return scanner.numbers()
    }

    private struct Walker {
        let outlines: [String: [BezierPath]]
        let bounds: [String: Rect]
        var glyphs: [Glyph] = []
        var rules: [Rect] = []

        mutating func walk(_ element: MarkupElement, matrix parent: Affine2D, tags parentTags: [String], source parentSource: String?,
                           clip parentClip: Rect?) {
            var matrix = parent
            if let transform = element.attributes["transform"] { matrix = matrix * SVGImporter.transform(transform) }
            var tags = parentTags
            if let names = element.attributes["class"] {
                tags += names.split(whereSeparator: \.isWhitespace).map(String.init)
                    .filter { $0 != "MathJax" && !$0.hasPrefix("mjx-") }
            }
            let source = element.attributes["data-latex"] ?? parentSource
            var clip = parentClip
            switch element.name {
            case "use":
                guard let href = element.attributes["xlink:href"] ?? element.attributes["href"], href.hasPrefix("#") else { return }
                let key = MathLayout.glyphKey(String(href.dropFirst()))
                guard outlines[key] != nil else { return }
                var place = matrix
                let x = element.attributes["x"].flatMap { MathLayout.numbers($0).first } ?? 0
                let y = element.attributes["y"].flatMap { MathLayout.numbers($0).first } ?? 0
                if x != 0 || y != 0 { place = place * .translation(Vec2(x, y)) }
                if let clip, let box = bounds[key], !box.isNull { place = Self.fit(place, box: box, to: clip) }
                glyphs.append(Glyph(key: key, place: place, tags: tags, source: element.attributes["data-latex"] ?? source))
                return
            case "rect":
                let a = element.attributes
                func value(_ name: String) -> Double { a[name].flatMap { MathLayout.numbers($0).first } ?? 0 }
                let x = value("x"), y = value("y"), w = value("width"), h = value("height")
                guard w > 0, h > 0 else { return }
                var rect = Rect(points: [Vec2(x, y), Vec2(x + w, y), Vec2(x + w, y + h), Vec2(x, y + h)].map(matrix.apply))
                if let clip { rect = rect.intersection(clip) }
                if !rect.isNull, rect.width > 0, rect.height > 0 { rules.append(rect) }
                return
            case "svg":
                // A window onto its own viewBox, which MathJax uses to cut a stretched
                // extender to length.
                let a = element.attributes
                func value(_ name: String) -> Double? { a[name].flatMap { MathLayout.numbers($0).first } }
                let x = value("x") ?? 0, y = value("y") ?? 0
                let viewBox = a["viewBox"].map(MathLayout.numbers) ?? []
                let w = value("width") ?? (viewBox.count == 4 ? viewBox[2] : 0)
                let h = value("height") ?? (viewBox.count == 4 ? viewBox[3] : 0)
                if viewBox.count == 4, viewBox[2] > 0, viewBox[3] > 0 {
                    matrix = matrix * .translation(Vec2(x, y)) * .scale(x: w / viewBox[2], y: h / viewBox[3])
                        * .translation(Vec2(-viewBox[0], -viewBox[1]))
                    let window = Rect(minPoint: Vec2(viewBox[0], viewBox[1]), maxPoint: Vec2(viewBox[0] + viewBox[2], viewBox[1] + viewBox[3]))
                    let placed = Rect(points: window.corners.map(matrix.apply))
                    clip = clip.map { $0.intersection(placed) } ?? placed
                } else if w > 0, h > 0 {
                    matrix = matrix * .translation(Vec2(x, y))
                    let placed = Rect(points: Rect(minPoint: .zero, maxPoint: Vec2(w, h)).corners.map(matrix.apply))
                    clip = clip.map { $0.intersection(placed) } ?? placed
                }
            case "g", "a":
                break
            default:
                return
            }
            for child in element.children {
                walk(child, matrix: matrix, tags: tags, source: source, clip: clip)
            }
        }

        /// `place` changed so the glyph (whose outline spans `box`) reaches no further than
        /// `clip` (in points) on either axis: MathJax stretches an extender past its window
        /// and lets the window cut it, and an extender is the same all along, so squeezing
        /// it into the window draws the same thing.
        static func fit(_ place: Affine2D, box: Rect, to clip: Rect) -> Affine2D {
            let placed = Rect(points: box.corners.map(place.apply))
            let target = placed.intersection(clip)
            guard !target.isNull, placed.width > 0 || placed.height > 0 else { return place }
            let sx = placed.width > 0 ? target.width / placed.width : 1
            let sy = placed.height > 0 ? target.height / placed.height : 1
            guard sx != 1 || sy != 1 else { return place }
            // Maps the placed box onto the target, axis by axis.
            let squeeze = Affine2D.translation(target.minPoint) * .scale(x: sx, y: sy) * .translation(-placed.minPoint)
            return squeeze * place
        }
    }
}

extension Rect {
    /// The overlap of two rectangles; null when they don't overlap.
    func intersection(_ other: Rect) -> Rect {
        let r = Rect(minPoint: Vec2(Swift.max(minPoint.x, other.minPoint.x), Swift.max(minPoint.y, other.minPoint.y)),
                     maxPoint: Vec2(Swift.min(maxPoint.x, other.maxPoint.x), Swift.min(maxPoint.y, other.maxPoint.y)))
        return r.isNull ? .null : r
    }
}
