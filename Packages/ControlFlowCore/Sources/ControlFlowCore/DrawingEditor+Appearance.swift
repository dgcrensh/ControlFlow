import Foundation

/// The appearance of the first selected shape, beyond its fill and outline colors,
/// for showing in the appearance controls.
public struct ShapeAppearance: Hashable, Sendable {
    public var opacity: Double
    public var gradient: ShapeGradient?
    /// How much of the shape the gradient spans (see `setGradientSpan`).
    public var gradientSpan: Double?
    public var isClipped: Bool
    /// The global colors the fill and outline follow.
    public var fillGlobal: Int?
    public var outlineGlobal: Int?
    /// The shape has an outline, so outline options apply.
    public var hasOutline: Bool
    /// The shape is closed, so it can be filled, have a gradient and align its outline.
    public var isClosed: Bool
}

/// Maps Pencil pressure to outline width.
public enum PressureWidth {
    /// Width multiple for a pressure in 0...1 (the force as a fraction of the most the
    /// Pencil reports). A light touch, around a third of full force, draws at the set width.
    public static func width(forPressure pressure: Double) -> Double {
        min(max(0.2 + 2.4 * pressure, 0.2), 2)
    }

    /// Sets each anchor's width from the pressure near where the Pencil drew it.
    /// Anchors follow the stroke in order, so each is matched to the closest sample
    /// at or after the previous anchor's, and pressure is averaged over a few samples.
    public static func apply(_ pressures: [Double], samples: [Vec2], to path: inout BezierPath) {
        guard !samples.isEmpty, pressures.count == samples.count else { return }
        var from = 0
        for i in path.points.indices {
            let p = path.points[i].position
            var best = from
            var bestDistance = Double.infinity
            for j in from..<samples.count {
                let d = samples[j].distance(to: p)
                if d < bestDistance {
                    bestDistance = d
                    best = j
                }
            }
            from = best
            let window = max(best - 2, 0)...min(best + 2, samples.count - 1)
            let average = window.reduce(0.0) { $0 + pressures[$1] } / Double(window.count)
            path.points[i].width = (width(forPressure: average) * 100).rounded() / 100
        }
    }
}

extension DrawingEditor {
    /// The appearance of the first selected shape.
    public var selectionAppearance: ShapeAppearance? {
        guard let first = drawing.shapeIndices(in: selection).first else { return nil }
        let shape = drawing.layers[first.0].shapes[first.1]
        let gradient = shape.visibleFill != nil ? shape.gradient : nil
        return ShapeAppearance(opacity: shape.opacity, gradient: gradient,
                               gradientSpan: gradient.map { Self.span(of: $0, in: shape.path.bounds()) },
                               isClipped: shape.isClipped, fillGlobal: shape.fillGlobal,
                               outlineGlobal: shape.stroke?.global, hasOutline: shape.stroke != nil,
                               isClosed: shape.path.closed)
    }

    /// True when some selected shape has a shape below it in its layer to clip to.
    public var canClipSelection: Bool {
        drawing.shapeIndices(in: selection).contains { $0.1 > 0 }
    }

    // MARK: Outline options

    /// Changes each selected outline (shapes without one keep none) and the style for new ones.
    private mutating func restyleOutlines(key: String, style change: (inout ShapeStyle) -> Void,
                                          _ outline: @escaping (inout StrokeStyle) -> Void) {
        change(&style)
        restyleSelection(key: key) { shape in
            if shape.stroke != nil { outline(&shape.stroke!) }
        }
    }

    public mutating func setOutlineCap(_ cap: LineCap) {
        restyleOutlines(key: "cap", style: { $0.outlineCap = cap }) { $0.cap = cap }
    }

    public mutating func setOutlineJoin(_ join: LineJoin) {
        restyleOutlines(key: "join", style: { $0.outlineJoin = join }) { $0.join = join }
    }

    public mutating func setMiterLimit(_ limit: Double) {
        let limit = max(limit, 1)
        restyleOutlines(key: "miterLimit", style: { $0.miterLimit = limit }) { $0.miterLimit = limit }
    }

    /// Dash and gap lengths in points; empty for a solid outline.
    public mutating func setOutlineDash(_ dash: [Double]) {
        let dash = dash.map { max($0, 0) }
        restyleOutlines(key: "dash", style: { $0.outlineDash = dash }) { stroke in
            stroke.dash = dash
            if dash.isEmpty { stroke.dashOffset = 0 }
        }
    }

    /// Where closed outlines sit: centered on the path, inside it or outside it.
    public mutating func setOutlineAlignment(_ alignment: StrokeAlignment) {
        restyleOutlines(key: "align", style: { $0.outlineAlignment = alignment }) { $0.alignment = alignment }
    }

    // MARK: Opacity and clipping

    /// Sets the selected shapes' opacity (0...1). A slider drag is one undo step.
    public mutating func setOpacity(_ opacity: Double) {
        let opacity = min(max(opacity, 0), 1)
        restyleSelection(key: "opacity") { $0.opacity = opacity }
    }

    /// Clips the selected shapes to the nearest unclipped shape below each, or stops clipping them.
    public mutating func setClipped(_ clipped: Bool) {
        let targets = drawing.shapeIndices(in: selection)
        guard !targets.isEmpty else { return }
        let before = drawing
        for (p, s) in targets where !clipped || s > 0 {
            drawing.layers[p].shapes[s].isClipped = clipped
        }
        commit(from: before)
    }

    // MARK: Gradients

    /// Gives the selected closed shapes a gradient of `kind`, or a plain fill for nil.
    /// A new gradient runs from the fill color to a darker shade, top to bottom
    /// (linear) or from the middle out (radial), across the shape. Changing the kind
    /// keeps the colors.
    public mutating func setGradient(_ kind: ShapeGradient.Kind?) {
        let fallback = style.fill
        restyleSelection(key: "gradientKind") { shape in
            guard shape.path.closed else { return }
            guard let kind else {
                shape.gradient = nil
                return
            }
            if shape.fill == nil { shape.fill = fallback }
            let base = shape.fill ?? fallback
            let stops = shape.gradient?.stops ?? [GradientStop(offset: 0, color: base),
                                                  GradientStop(offset: 1, color: base.shaded(0.6))]
            let bounds = shape.path.bounds()
            let center = bounds.center
            switch kind {
            case .linear:
                shape.gradient = ShapeGradient(kind: .linear, start: Vec2(center.x, bounds.minPoint.y),
                                          end: Vec2(center.x, bounds.maxPoint.y), stops: stops)
            case .radial:
                let radius = max(bounds.width, bounds.height) / 2
                shape.gradient = ShapeGradient(kind: .radial, start: center, end: center + Vec2(radius, 0), stops: stops)
            }
        }
    }

    /// Sets the color of gradient stop `index` (0 is the start; an index past the end
    /// sets the last stop). The first stop is also the shape's plain fill.
    public mutating func setGradientStop(_ index: Int, color: RGBAColor) {
        restyleSelection(key: "gradientStop\(index)") { shape in
            guard var gradient = shape.gradient, !gradient.stops.isEmpty else { return }
            let i = min(max(index, 0), gradient.stops.count - 1)
            gradient.stops[i].color = color
            shape.gradient = gradient
            if i == 0 {
                shape.fill = color
                shape.fillGlobal = nil
            }
        }
    }

    /// Turns a linear gradient to `degrees` (0 runs left to right, 90 top to bottom,
    /// clockwise on screen) about its middle, keeping its length.
    public mutating func setGradientAngle(_ degrees: Double) {
        let radians = degrees * .pi / 180
        restyleSelection(key: "gradientAngle") { shape in
            guard var gradient = shape.gradient, gradient.kind == .linear else { return }
            let middle = (gradient.start + gradient.end) / 2
            let half = gradient.start.distance(to: gradient.end) / 2
            let direction = Vec2(cos(radians), sin(radians))
            gradient.start = middle - direction * half
            gradient.end = middle + direction * half
            shape.gradient = gradient
        }
    }

    /// Scales a gradient about its middle (the center of a radial one) so it spans
    /// `fraction` of the shape: 1 runs edge to edge.
    public mutating func setGradientSpan(_ fraction: Double) {
        let fraction = max(fraction, 0.05)
        restyleSelection(key: "gradientSpan") { shape in
            guard var gradient = shape.gradient else { return }
            let axis = (gradient.end - gradient.start).normalized
            guard axis != .zero else { return }
            let full = Self.fullLength(of: gradient, in: shape.path.bounds())
            switch gradient.kind {
            case .linear:
                let middle = (gradient.start + gradient.end) / 2
                gradient.start = middle - axis * (full * fraction / 2)
                gradient.end = middle + axis * (full * fraction / 2)
            case .radial:
                gradient.end = gradient.start + axis * (full * fraction)
            }
            shape.gradient = gradient
        }
    }

    /// The gradient's length when it spans the shape: the shape's extent along a linear
    /// gradient's direction, or half the larger side for a radial one's radius.
    static func fullLength(of gradient: ShapeGradient, in bounds: Rect) -> Double {
        switch gradient.kind {
        case .linear:
            let axis = (gradient.end - gradient.start).normalized
            let along = bounds.corners.map { ($0 - bounds.center).dot(axis) }
            return (along.max() ?? 0) - (along.min() ?? 0)
        case .radial:
            return max(bounds.width, bounds.height) / 2
        }
    }

    static func span(of gradient: ShapeGradient, in bounds: Rect) -> Double {
        let full = fullLength(of: gradient, in: bounds)
        return full > 1e-9 ? gradient.start.distance(to: gradient.end) / full : 1
    }

    /// Swaps the gradient's colors end for end.
    public mutating func reverseGradient() {
        restyleSelection(key: "gradientReverse") { shape in
            guard var gradient = shape.gradient else { return }
            gradient.stops = gradient.stops.reversed().map { GradientStop(offset: 1 - $0.offset, color: $0.color) }
            shape.gradient = gradient
            shape.fill = gradient.stops[0].color
            shape.fillGlobal = nil
        }
    }

    // MARK: Variable width

    /// Sets the outline width multiple (0...4) at the selected anchors of the shape
    /// being point-edited. A slider drag is one undo step.
    public mutating func setSelectedAnchorsWidth(_ width: Double) {
        guard let ref = activeShape, let idx = drawing.indices(ref), !selectedAnchors.isEmpty else { return }
        let width = min(max(width, 0), 4)
        let before = drawing
        for i in selectedAnchors where drawing.layers[idx.0].shapes[idx.1].path.points.indices.contains(i) {
            drawing.layers[idx.0].shapes[idx.1].path.points[i].width = width
        }
        commit(from: before, key: "anchorWidth-\(ref)")
    }

    /// The width multiple the selected anchors share, or their average.
    public var selectedAnchorsWidth: Double? {
        guard let ref = activeShape, let shape = drawing.shape(ref), !selectedAnchors.isEmpty else { return nil }
        let widths = selectedAnchors.compactMap { shape.path.points.indices.contains($0) ? shape.path.points[$0].width : nil }
        return widths.isEmpty ? nil : widths.reduce(0, +) / Double(widths.count)
    }

    /// Resets every anchor of the selected shapes to the plain outline width.
    public mutating func resetOutlineWidths() {
        restyleSelection(key: "resetWidths") { shape in
            for i in shape.path.points.indices { shape.path.points[i].width = 1 }
        }
    }

    // MARK: Global colors

    /// Adds a global color, named `name` or "Color N", and returns its id.
    @discardableResult
    public mutating func addGlobalColor(_ color: RGBAColor, name: String? = nil) -> Int {
        let before = drawing
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? "Color \(drawing.globalColors.count + 1)" : trimmed
        let id = drawing.makeID()
        drawing.globalColors.append(GlobalColor(id: id, name: drawing.uniqueGlobalColorName(base), color: color))
        commit(from: before)
        return id
    }

    /// Renames a global color; names stay unique and an empty name is ignored.
    public mutating func renameGlobalColor(_ id: Int, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = drawing.globalColors.firstIndex(where: { $0.id == id }) else { return }
        let before = drawing
        drawing.globalColors[i].name = drawing.uniqueGlobalColorName(trimmed, excluding: id)
        commit(from: before)
    }

    /// Changes a global color and every fill and outline that follows it, as one undo
    /// step (`continuous` merges a color picker drag into one).
    public mutating func setGlobalColor(_ id: Int, to color: RGBAColor, continuous: Bool = false) {
        guard let i = drawing.globalColors.firstIndex(where: { $0.id == id }) else { return }
        let before = drawing
        drawing.globalColors[i].color = color
        for p in drawing.layers.indices {
            drawing.layers[p].updateAllShapes { shape in
                if shape.fillGlobal == id, shape.fill != nil {
                    shape.fill = color
                    if shape.gradient != nil { shape.gradient!.stops[0].color = color }
                }
                if shape.stroke?.global == id { shape.stroke!.color = color }
            }
        }
        if let selected = selectionStyle { style = selected }
        commit(from: before, key: continuous ? "globalColor-\(id)" : nil)
    }

    /// Removes a global color. Shapes that followed it keep its color as a plain color.
    public mutating func removeGlobalColor(_ id: Int) {
        guard drawing.globalColor(id) != nil else { return }
        let before = drawing
        drawing.globalColors.removeAll { $0.id == id }
        for p in drawing.layers.indices {
            drawing.layers[p].updateAllShapes { shape in
                if shape.fillGlobal == id { shape.fillGlobal = nil }
                if shape.stroke?.global == id { shape.stroke!.global = nil }
            }
        }
        commit(from: before)
    }

    /// Fills the selection with a global color, which its fills then follow.
    public mutating func applyGlobalFill(_ id: Int) {
        guard let color = drawing.globalColor(id)?.color else { return }
        style.fill = color
        style.fillEnabled = true
        restyleSelection(key: "globalFill") { shape in
            guard shape.path.closed else { return }
            shape.fill = color
            shape.fillGlobal = id
            if shape.gradient != nil { shape.gradient!.stops[0].color = color }
        }
    }

    /// Outlines the selection in a global color, which its outlines then follow.
    public mutating func applyGlobalOutline(_ id: Int) {
        guard let color = drawing.globalColor(id)?.color else { return }
        style.outline = color
        style.outlineEnabled = true
        let template = style
        restyleSelection(key: "globalOutline") { shape in
            if shape.stroke == nil { shape.stroke = template.makeStroke() }
            shape.stroke!.color = color
            shape.stroke!.global = id
        }
    }
}

extension RGBAColor {
    /// The color with its red, green and blue scaled by `k` (below 1 darkens).
    public func shaded(_ k: Double) -> RGBAColor {
        RGBAColor(r: min(r * k, 1), g: min(g * k, 1), b: min(b * k, 1), a: a)
    }
}
