import Foundation

/// Writes the art as an SVG 1.1 document, one group per layer, back to front,
/// with a named group inside it for each group of shapes.
///
/// Everything the canvas draws comes across: fills and gradients (in user space, so
/// they keep their place), outlines with their caps, joins, miter limit and dashes,
/// opacity, and clipping (as a mask made of the base shape). What SVG can't say
/// directly is drawn the way the canvas draws it: an inside or outside outline is
/// stroked twice as wide and clipped or masked by the path, and an outline whose width
/// varies is written as the stroker's triangles in one filled path. Hidden art and
/// reference images are left out.
public enum SVGWriter {
    /// How finely variable-width outlines are flattened, in points.
    public static let tolerance = 0.1

    /// The SVG text. `area` is the layer of the canvas the document shows; by default the
    /// viewport (see `Drawing.exportArea`). Nil when the area is empty.
    public static func document(for drawing: Drawing, area: Rect? = nil) -> String? {
        guard let area = area ?? drawing.exportArea(), area.width > 0, area.height > 0 else { return nil }
        var writer = Writer(area: area)
        let names = Dictionary(zip(drawing.layers.map(\.id), CharacterFormat.slotNames(for: drawing.layers)),
                               uniquingKeysWith: { a, _ in a })
        for layer in drawing.layers where !layer.isHidden {
            writer.layer(layer, name: names[layer.id] ?? layer.name)
        }
        return writer.finish(title: drawing.name)
    }

    /// `x` with at most three decimals and no trailing zeros.
    static func number(_ x: Double) -> String {
        guard x.isFinite else { return "0" }
        let r = (x * 1000).rounded() / 1000
        if r == r.rounded(), abs(r) < 1e15 { return String(Int(r)) }
        return String(r)
    }

    /// Escapes text for an attribute value or element content.
    static func escaped(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    /// An XML id from a layer name: letters, digits, `-`, `_` and `.`, starting with a letter.
    static func identifier(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            let ok = (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "-_.".unicodeScalars.contains(scalar))
                && scalar.isASCII
            out.unicodeScalars.append(ok ? scalar : "_")
        }
        if let first = out.unicodeScalars.first, !first.properties.isAlphabetic { out = "_" + out }
        return out.isEmpty ? "_" : out
    }

    /// Path data for a Bézier path: straight segments as lines, curves as cubics.
    static func pathData(_ path: BezierPath) -> String {
        guard let first = path.points.first else { return "" }
        var d = "M" + pair(first.position)
        for i in 0..<path.segmentCount {
            let s = path.segment(i)
            if s.p1.isApproximately(s.p0, tolerance: 1e-9), s.p2.isApproximately(s.p3, tolerance: 1e-9) {
                // Z draws a straight closing segment.
                if path.closed, i == path.segmentCount - 1 { break }
                d += "L" + pair(s.p3)
            } else {
                d += "C" + pair(s.p1) + " " + pair(s.p2) + " " + pair(s.p3)
            }
        }
        if path.closed { d += "Z" }
        return d
    }

    /// Path data for the outlined parts of a path: the whole path, or one open
    /// subpath per run of stroked segments when some segments are bare.
    static func strokeData(_ path: BezierPath) -> String {
        path.hasUnstrokedSegments ? path.strokedRuns().map(pathData).joined() : pathData(path)
    }

    /// Path data for triangles (three points each).
    static func triangleData(_ triangles: [Vec2]) -> String {
        var d = ""
        for i in stride(from: 0, to: triangles.count - 2, by: 3) {
            d += "M" + pair(triangles[i]) + "L" + pair(triangles[i + 1]) + "L" + pair(triangles[i + 2]) + "Z"
        }
        return d
    }

    private static func pair(_ p: Vec2) -> String { number(p.x) + " " + number(p.y) }

    /// `#RRGGBB`, with the alpha written separately as an opacity.
    static func rgb(_ c: RGBAColor) -> String { String(c.hexString.prefix(7)) }

    private struct Writer {
        let area: Rect
        var defs: [String] = []
        var body: [String] = []
        var nextID = 1

        init(area: Rect) {
            self.area = area
        }

        mutating func makeID(_ prefix: String) -> String {
            defer { nextID += 1 }
            return "\(prefix)\(nextID)"
        }

        mutating func layer(_ layer: Layer, name: String) {
            let id = SVGWriter.identifier(name)
            var open = "<g id=\"\(SVGWriter.escaped(id))\""
            if id != name { open += " data-name=\"\(SVGWriter.escaped(name))\"" }
            body.append("  " + open + ">")
            // Shape groups nest as named groups. A clip runs in its own masked group, which
            // is closed and opened again where a shape group starts or ends.
            var openGroup: Int?
            var clipGroup: (base: Int, mask: String)?
            var masks: [Int: String] = [:]
            let clips = layer.clipPlan()
            for index in layer.shapes.indices where layer.isShown(index) {
                let base = clips.base(of: index)
                if let base, !layer.isShown(base) { continue }
                let groupBase = clips.groupBase(of: index)
                if let groupBase, !layer.isShown(groupBase) { continue }
                let group = layer.shapes[index].group.flatMap { layer.group($0) }
                if group?.id != openGroup {
                    if clipGroup != nil { body.append((openGroup == nil ? "    " : "      ") + "</g>") }
                    clipGroup = nil
                    if openGroup != nil { body.append("    </g>") }
                    openGroup = group?.id
                    if let group {
                        var open = "    <g data-name=\"\(SVGWriter.escaped(group.name))\""
                        // A clipped group is masked by its base as a whole.
                        if let groupBase {
                            let mask = masks[groupBase] ?? clipMask(layer.shapes[groupBase])
                            masks[groupBase] = mask
                            open += " mask=\"url(#\(mask))\""
                        }
                        body.append(open + ">")
                    }
                }
                let indent = openGroup == nil ? "    " : "      "
                if clipGroup?.base != base {
                    if clipGroup != nil { body.append(indent + "</g>") }
                    clipGroup = nil
                    if let base {
                        let mask = masks[base] ?? clipMask(layer.shapes[base])
                        masks[base] = mask
                        clipGroup = (base, mask)
                        body.append(indent + "<g mask=\"url(#\(mask))\">")
                    }
                }
                shape(layer.shapes[index], indent: clipGroup == nil ? indent : indent + "  ")
            }
            if clipGroup != nil { body.append((openGroup == nil ? "    " : "      ") + "</g>") }
            if openGroup != nil { body.append("    </g>") }
            body.append("  </g>")
        }

        /// A mask that is white wherever `base` draws: its fill and its outline.
        mutating func clipMask(_ base: VectorShape) -> String {
            let id = makeID("clip")
            var lines = ["    <mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"\(SVGWriter.number(area.minPoint.x))\" " +
                "y=\"\(SVGWriter.number(area.minPoint.y))\" width=\"\(SVGWriter.number(area.width))\" " +
                "height=\"\(SVGWriter.number(area.height))\">"]
            let d = SVGWriter.pathData(base.path)
            if base.visibleFill != nil { lines.append("      <path d=\"\(d)\" fill=\"#FFFFFF\"/>") }
            if let stroke = base.stroke, stroke.width > 0 {
                let alignment = base.path.closed ? stroke.alignment : .center
                // An inside outline lies within the fill; an outside one is the far half of a doubled one.
                if alignment != .inside || base.visibleFill == nil {
                    let scale = alignment == .outside ? 2.0 : 1.0
                    if base.path.hasVariableWidth {
                        let triangles = Stroker.triangles(for: base.path, style: stroke, widthScale: scale,
                                                          tolerance: SVGWriter.tolerance)
                        lines.append("      <path d=\"\(SVGWriter.triangleData(triangles))\" fill=\"#FFFFFF\"/>")
                    } else if !base.path.strokedRuns().isEmpty {
                        lines.append("      <path d=\"\(SVGWriter.strokeData(base.path))\" fill=\"none\" stroke=\"#FFFFFF\"" +
                            strokeAttributes(stroke, widthScale: scale) + "/>")
                    }
                }
            }
            lines.append("    </mask>")
            defs += lines
            return id
        }

        mutating func shape(_ shape: VectorShape, indent: String) {
            let d = SVGWriter.pathData(shape.path)
            let opacity = min(max(shape.opacity, 0), 1)
            var fill = "fill=\"none\""
            if let color = shape.visibleFill {
                if let gradient = shape.gradient, !gradient.stops.isEmpty {
                    fill = "fill=\"url(#\(self.gradient(gradient)))\""
                    if opacity < 1 { fill += " fill-opacity=\"\(SVGWriter.number(opacity))\"" }
                } else {
                    fill = "fill=\"\(SVGWriter.rgb(color))\""
                    let alpha = color.a * opacity
                    if alpha < 1 { fill += " fill-opacity=\"\(SVGWriter.number(alpha))\"" }
                }
            }
            guard let stroke = shape.stroke, stroke.width > 0 else {
                if shape.visibleFill != nil { body.append(indent + "<path d=\"\(d)\" \(fill)/>") }
                return
            }
            // As on the canvas: aligned only when the path encloses an area.
            let encloses = shape.path.closed && shape.path.flattened(tolerance: SVGWriter.tolerance).count >= 3
            let alignment = encloses ? stroke.alignment : .center
            let strokeAlpha = stroke.color.a * opacity
            if alignment == .center, !shape.path.hasVariableWidth, !shape.path.hasUnstrokedSegments {
                var line = indent + "<path d=\"\(d)\" \(fill) stroke=\"\(SVGWriter.rgb(stroke.color))\""
                if strokeAlpha < 1 { line += " stroke-opacity=\"\(SVGWriter.number(strokeAlpha))\"" }
                body.append(line + strokeAttributes(stroke, widthScale: 1) + "/>")
                return
            }
            if shape.visibleFill != nil { body.append(indent + "<path d=\"\(d)\" \(fill)/>") }
            // The outline on its own: doubled and cut to one side of the path when aligned.
            var limit = ""
            switch alignment {
            case .center:
                break
            case .inside:
                let id = makeID("inside")
                defs.append("    <clipPath id=\"\(id)\"><path d=\"\(d)\"/></clipPath>")
                limit = " clip-path=\"url(#\(id))\""
            case .outside:
                let id = makeID("outside")
                defs.append("    <mask id=\"\(id)\" maskUnits=\"userSpaceOnUse\" x=\"\(SVGWriter.number(area.minPoint.x))\" " +
                    "y=\"\(SVGWriter.number(area.minPoint.y))\" width=\"\(SVGWriter.number(area.width))\" " +
                    "height=\"\(SVGWriter.number(area.height))\">")
                defs.append("      <rect x=\"\(SVGWriter.number(area.minPoint.x))\" y=\"\(SVGWriter.number(area.minPoint.y))\" " +
                    "width=\"\(SVGWriter.number(area.width))\" height=\"\(SVGWriter.number(area.height))\" fill=\"#FFFFFF\"/>")
                defs.append("      <path d=\"\(d)\" fill=\"#000000\"/>")
                defs.append("    </mask>")
                limit = " mask=\"url(#\(id))\""
            }
            let scale = alignment == .center ? 1.0 : 2.0
            var paint = SVGWriter.rgb(stroke.color) + "\""
            if strokeAlpha < 1 { paint += " fill-opacity=\"\(SVGWriter.number(strokeAlpha))\"" }
            if shape.path.hasVariableWidth {
                // SVG strokes have one width, so the outline is written as its area.
                let triangles = Stroker.triangles(for: shape.path, style: stroke, widthScale: scale,
                                                  tolerance: SVGWriter.tolerance)
                guard !triangles.isEmpty else { return }
                body.append(indent + "<path d=\"\(SVGWriter.triangleData(triangles))\" fill=\"" + paint + limit + "/>")
            } else {
                let strokeData = SVGWriter.strokeData(shape.path)
                guard !strokeData.isEmpty else { return }
                var line = indent + "<path d=\"\(strokeData)\" fill=\"none\" " +
                    "stroke=\"\(SVGWriter.rgb(stroke.color))\""
                if strokeAlpha < 1 { line += " stroke-opacity=\"\(SVGWriter.number(strokeAlpha))\"" }
                body.append(line + strokeAttributes(stroke, widthScale: scale) + limit + "/>")
            }
        }

        func strokeAttributes(_ stroke: StrokeStyle, widthScale: Double) -> String {
            var out = " stroke-width=\"\(SVGWriter.number(stroke.width * widthScale))\""
            out += " stroke-linecap=\"\(stroke.cap.rawValue)\" stroke-linejoin=\"\(stroke.join.rawValue)\""
            if stroke.join == .miter { out += " stroke-miterlimit=\"\(SVGWriter.number(stroke.miterLimit))\"" }
            if let pattern = stroke.dashPattern {
                out += " stroke-dasharray=\"\(pattern.map(SVGWriter.number).joined(separator: " "))\""
                if stroke.dashOffset != 0 { out += " stroke-dashoffset=\"\(SVGWriter.number(stroke.dashOffset))\"" }
            }
            return out
        }

        /// Adds a gradient in user space and returns its id.
        mutating func gradient(_ gradient: ShapeGradient) -> String {
            let id = makeID("gradient")
            let n = SVGWriter.number
            switch gradient.kind {
            case .linear:
                defs.append("    <linearGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(n(gradient.start.x))\" " +
                    "y1=\"\(n(gradient.start.y))\" x2=\"\(n(gradient.end.x))\" y2=\"\(n(gradient.end.y))\">")
            case .radial:
                let r = gradient.start.distance(to: gradient.end)
                defs.append("    <radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(n(gradient.start.x))\" " +
                    "cy=\"\(n(gradient.start.y))\" r=\"\(n(r))\">")
            }
            for stop in gradient.stops.prefix(ShapeGradient.maxStops) {
                var line = "      <stop offset=\"\(n(stop.offset))\" stop-color=\"\(SVGWriter.rgb(stop.color))\""
                if stop.color.a < 1 { line += " stop-opacity=\"\(n(stop.color.a))\"" }
                defs.append(line + "/>")
            }
            defs.append(gradient.kind == .linear ? "    </linearGradient>" : "    </radialGradient>")
            return id
        }

        func finish(title: String) -> String {
            let n = SVGWriter.number
            var lines = [
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                "<svg xmlns=\"http://www.w3.org/2000/svg\" version=\"1.1\" width=\"\(n(area.width))\" " +
                    "height=\"\(n(area.height))\" viewBox=\"\(n(area.minPoint.x)) \(n(area.minPoint.y)) " +
                    "\(n(area.width)) \(n(area.height))\">",
                "  <title>\(SVGWriter.escaped(title))</title>",
            ]
            if !defs.isEmpty {
                lines.append("  <defs>")
                lines += defs
                lines.append("  </defs>")
            }
            lines += body
            lines.append("</svg>")
            return lines.joined(separator: "\n") + "\n"
        }
    }
}
