import ControlFlowCore
import CoreGraphics
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Draws the art into the package's `thumbnail.png`, and into PNG exports,
/// with Core Graphics. Safe to call off the main thread, where documents are written.
enum ThumbnailRenderer {
    /// The longest side an exported PNG may have, in pixels.
    static let maxExportSide = 8192.0

    /// The last thumbnail made, and what it was made from: a save with no change to the
    /// art since the last one reuses it. Comparing is cheap when nothing changed, since
    /// the drawing's arrays then share storage.
    private static let lastThumbnail = Mutex<(drawing: Drawing, size: Int, png: Data?)?>(nil)

    static func png(for drawing: Drawing, size: Int = 512) -> Data? {
        if let last = lastThumbnail.withLock({ $0 }), last.size == size, last.drawing == drawing { return last.png }
        let png = Signposts.canvas.withIntervalSignpost("Thumbnail") { renderPNG(for: drawing, size: size) }
        lastThumbnail.withLock { $0 = (drawing, size, png) }
        return png
    }

    private static func renderPNG(for drawing: Drawing, size: Int) -> Data? {
        // Drawn as it looks: the transforms go into the points.
        let drawing = drawing.world
        let bounds = drawing.layers.reduce(Rect.null) { $0.union($1.bounds) }
        guard !bounds.isNull, max(bounds.width, bounds.height) > 0 else { return nil }
        guard let context = makeContext(width: size, height: size) else { return nil }

        // Fit the art with a margin; flip so y points down like the canvas.
        let side = Double(size)
        let k = side * 0.9 / max(bounds.width, bounds.height)
        context.translateBy(x: 0, y: CGFloat(side))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: CGFloat(side / 2), y: CGFloat(side / 2))
        context.scaleBy(x: CGFloat(k), y: CGFloat(k))
        context.translateBy(x: CGFloat(-bounds.center.x), y: CGFloat(-bounds.center.y))
        // A pixel's tolerance: finer flattening and joins don't show at this size.
        drawArt(drawing, in: context, tolerance: 1 / k, skipHidden: false)
        return encode(context)
    }

    /// The visible art over `area` (world points) on the viewport's background, at
    /// `scale` pixels per point (less if the image would pass `maxExportSide`).
    static func exportPNG(for drawing: Drawing, area: Rect, scale: Double) -> Data? {
        guard !area.isNull, area.width > 0, area.height > 0, scale > 0 else { return nil }
        let drawing = drawing.world
        let k = min(scale, maxExportSide / max(area.width, area.height))
        let width = max(Int((area.width * k).rounded()), 1), height = max(Int((area.height * k).rounded()), 1)
        guard let context = makeContext(width: width, height: height) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(k), y: CGFloat(-k))
        context.translateBy(x: CGFloat(-area.minPoint.x), y: CGFloat(-area.minPoint.y))
        context.setFillColor(cgColor(drawing.viewport.background))
        context.fill(CGRect(x: area.minPoint.x, y: area.minPoint.y, width: area.width, height: area.height))
        drawArt(drawing, in: context, tolerance: 0.25 / k, skipHidden: true)
        return encode(context)
    }

    private static func makeContext(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Draws every layer back to front. Hidden art is left out when `skipHidden` is set.
    private static func drawArt(_ drawing: Drawing, in context: CGContext, tolerance: Double, skipHidden: Bool) {
        for layer in drawing.layers {
            let clips = layer.clipPlan()
            // Each base's mask, made once for all the shapes it clips.
            var masks: [Int: CGPath] = [:]
            for (index, shape) in layer.shapes.enumerated() {
                if skipHidden, !layer.isShown(index) { continue }
                // Clipped shapes draw only where their base draws, and shapes in a clipped
                // group only where the group's base draws.
                let bases = [clips.groupBase(of: index), clips.base(of: index)].compactMap { $0 }
                if skipHidden, bases.contains(where: { !layer.isShown($0) }) { continue }
                context.saveGState()
                for base in bases {
                    let mask = masks[base] ?? clipMask(layer.shapes[base], tolerance: tolerance)
                    masks[base] = mask
                    context.addPath(mask)
                    context.clip(using: .winding)
                }
                draw(shape, in: context, tolerance: tolerance)
                context.restoreGState()
            }
        }
    }

    private static func encode(_ context: CGContext) -> Data? {
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Draws one shape's fill and outline. Outlines come from the same stroker as the
    /// canvas, so caps, joins, dashes and varying width match it.
    private static func draw(_ shape: VectorShape, in context: CGContext, tolerance: Double) {
        let opacity = CGFloat(min(max(shape.opacity, 0), 1))
        let path = cgPath(shape.path)
        if let fill = shape.visibleFill {
            context.saveGState()
            context.setAlpha(opacity)
            context.addPath(path)
            if let gradient = shape.gradient, let cg = cgGradient(gradient) {
                context.clip(using: .winding)
                let start = CGPoint(gradient.start), end = CGPoint(gradient.end)
                let options: CGGradientDrawingOptions = [.drawsBeforeStartLocation, .drawsAfterEndLocation]
                switch gradient.kind {
                case .linear:
                    context.drawLinearGradient(cg, start: start, end: end, options: options)
                case .radial:
                    let radius = CGFloat(gradient.start.distance(to: gradient.end))
                    context.drawRadialGradient(cg, startCenter: start, startRadius: 0, endCenter: start,
                                               endRadius: radius, options: options)
                }
            } else {
                context.setFillColor(cgColor(fill))
                context.fillPath(using: .winding)
            }
            context.restoreGState()
        }
        guard let stroke = shape.stroke, stroke.width > 0 else { return }
        let alignment = shape.path.closed ? stroke.alignment : .center
        let triangles = Stroker.triangles(for: shape.path, style: stroke, widthScale: alignment == .center ? 1 : 2,
                                          tolerance: tolerance)
        guard !triangles.isEmpty else { return }
        context.saveGState()
        context.setAlpha(opacity)
        switch alignment {
        case .center:
            break
        case .inside:
            context.addPath(path)
            context.clip(using: .winding)
        case .outside:
            // Everything but the path's inside: a large rectangle with the path cut out.
            let bounds = Rect(points: triangles).outset(by: 1)
            context.addRect(CGRect(x: bounds.minPoint.x, y: bounds.minPoint.y, width: bounds.width, height: bounds.height))
            context.addPath(path)
            context.clip(using: .evenOdd)
        }
        let outline = CGMutablePath()
        addTriangles(triangles, to: outline)
        context.addPath(outline)
        context.setFillColor(cgColor(stroke.color))
        // The stroker winds every triangle the same way, so non-zero fills their union.
        context.fillPath(using: .winding)
        context.restoreGState()
    }

    /// Where a clip base draws: its fill and its outline, all wound the same way so a
    /// non-zero fill is their union.
    private static func clipMask(_ base: VectorShape, tolerance: Double) -> CGPath {
        let mask = CGMutablePath()
        if base.visibleFill != nil {
            let poly = base.path.flattened(tolerance: tolerance)
            var area = 0.0
            for i in poly.indices { area += poly[i].cross(poly[(i + 1) % poly.count]) }
            mask.addPath(cgPath(area >= 0 ? base.path : base.path.reversed()))
        }
        if let stroke = base.stroke, stroke.width > 0 {
            let alignment = base.path.closed ? stroke.alignment : .center
            // An inside outline lies within the fill; an outside one is the far half of a doubled one.
            if alignment != .inside || base.visibleFill == nil {
                let triangles = Stroker.triangles(for: base.path, style: stroke,
                                                  widthScale: alignment == .outside ? 2 : 1, tolerance: tolerance)
                addTriangles(triangles, to: mask)
            }
        }
        return mask
    }

    private static func addTriangles(_ triangles: [Vec2], to path: CGMutablePath) {
        for i in stride(from: 0, to: triangles.count, by: 3) {
            path.addLines(between: [CGPoint(triangles[i]), CGPoint(triangles[i + 1]), CGPoint(triangles[i + 2])])
            path.closeSubpath()
        }
    }

    private static func cgGradient(_ gradient: ShapeGradient) -> CGGradient? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let stops = Array(gradient.stops.prefix(ShapeGradient.maxStops))
        let colors = stops.map { cgColor($0.color) } as CFArray
        let locations = stops.map { CGFloat($0.offset) }
        return CGGradient(colorsSpace: space, colors: colors, locations: locations)
    }

    private static func cgPath(_ path: BezierPath) -> CGPath {
        let out = CGMutablePath()
        guard let first = path.points.first else { return out }
        out.move(to: CGPoint(first.position))
        for i in 0..<path.segmentCount {
            let s = path.segment(i)
            out.addCurve(to: CGPoint(s.p3), control1: CGPoint(s.p1), control2: CGPoint(s.p2))
        }
        if path.closed { out.closeSubpath() }
        return out
    }

    private static func cgColor(_ c: RGBAColor) -> CGColor {
        CGColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }
}

private extension CGPoint {
    init(_ v: Vec2) { self.init(x: CGFloat(v.x), y: CGFloat(v.y)) }
}
