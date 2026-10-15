import Foundation

/// Turns a uniform-width polyline into GPU-ready triangles: one quad (two triangles)
/// per segment. Each vertex carries its segment's endpoints, so the fragment shader
/// draws an anti-aliased capsule by measuring distance to the segment. Overlapping
/// capsules give round joins and caps at any zoom without re-tessellating.
///
/// The vertex shader pushes each corner outward by the radius plus a pixel of
/// anti-aliasing margin, which depends on zoom, so vertices hold only a corner sign.
///
/// A capsule's radius is in world units (ink, whose width zooms with the art) or, with
/// `screenSpace`, in screen points (the editing overlay, which looks the same at any
/// zoom). The vertex shader converts a screen-space radius to world units with the
/// current zoom, so the overlay's vertices don't depend on the exact zoom.
public enum CapsuleTessellator {
    /// Floats per vertex: a.xy, b.xy, corner.xy, radius, flags, color.rgba. `flags` is
    /// 1 when `radius` is in screen points, 0 when it is in world units.
    /// Must match `StrokeVertex` in the Metal shader source.
    public static let floatsPerVertex = 12
    public static let verticesPerSegment = 6

    /// Quad corners as (end, side): end -1 is the segment start, +1 the end.
    private static let corners: [(Float, Float)] = [
        (-1, -1), (1, -1), (1, 1),
        (-1, -1), (1, 1), (-1, 1),
    ]

    public static func segmentCount(pointCount: Int) -> Int {
        pointCount == 0 ? 0 : max(1, pointCount - 1)
    }

    /// Appends vertices for `points` to `out`. A single point becomes a round dot.
    /// `widths`, one per point, multiply `width` (each segment uses the mean of its ends).
    /// With `screenSpace`, `width` is in screen points instead of world units.
    public static func append(points: [Vec2], width: Double, widths: [Double]? = nil, color: RGBAColor,
                              screenSpace: Bool = false, to out: inout [Float]) {
        guard let first = points.first else { return }
        let widths = widths?.count == points.count ? widths : nil
        var radius = Float(width / 2) * Float(widths?[0] ?? 1)
        // Shaders blend premultiplied colors.
        let alpha = Float(color.a)
        let rgba = (Float(color.r) * alpha, Float(color.g) * alpha, Float(color.b) * alpha, alpha)
        let flags: Float = screenSpace ? 1 : 0

        out.reserveAdditional(segmentCount(pointCount: points.count) * verticesPerSegment * floatsPerVertex)

        func emit(_ a: Vec2, _ b: Vec2) {
            for (end, side) in corners {
                out.append(contentsOf: [
                    Float(a.x), Float(a.y), Float(b.x), Float(b.y),
                    end, side, radius, flags,
                    rgba.0, rgba.1, rgba.2, rgba.3,
                ])
            }
        }

        if points.count == 1 {
            emit(first, first)
            return
        }
        for i in 1..<points.count {
            if let widths { radius = Float(width / 2 * (widths[i - 1] + widths[i]) / 2) }
            emit(points[i - 1], points[i])
        }
    }

    public static func vertices(for stroke: InkStroke, includePredicted: Bool = true) -> [Float] {
        var out: [Float] = []
        let widths = stroke.displayWidths.map { includePredicted ? $0 : Array($0.prefix(stroke.points.count)) }
        append(points: includePredicted ? stroke.displayPoints : stroke.points,
               width: stroke.width, widths: widths, color: stroke.color, to: &out)
        return out
    }
}

/// Tessellates the live stroke a frame at a time: the committed points' segments are
/// kept between frames and only the new ones are added, so a long stroke costs the
/// same per frame as a short one. The predicted tail is rebuilt every frame.
/// `committed + tail` equals `CapsuleTessellator.vertices(for:)`.
public struct LiveStrokeTessellator: Sendable {
    private struct Key: Equatable {
        var id: Int, width: Double, color: RGBAColor, showsPressure: Bool
    }

    private var key: Key?
    private var points: [Vec2] = []
    private var widths: [Double]?
    /// Vertices for the segments between `points`.
    public private(set) var committed: [Float] = []

    public init() {}

    /// Brings `committed` up to date with `stroke` and returns the vertices to draw
    /// after it: the predicted tail, or a dot for a stroke of one point.
    public mutating func update(for stroke: InkStroke) -> [Float] {
        let display = stroke.displayWidths
        let widths = display.map { Array($0.prefix(stroke.points.count)) }
        let key = Key(id: stroke.id, width: stroke.width, color: stroke.color, showsPressure: stroke.showsPressure)
        // Anything but new points appended (a new stroke, a quick shape taking over,
        // a style change) starts again.
        if key != self.key || !stroke.points.starts(with: points) || (widths == nil) != (self.widths == nil) ||
            !(widths ?? []).starts(with: self.widths ?? []) {
            self.key = key
            points = []
            self.widths = widths.map { _ in [] }
            committed = []
        }
        let count = stroke.points.count
        if count >= 2, count > points.count {
            let from = max(0, points.count - 1)
            CapsuleTessellator.append(points: Array(stroke.points[from...]), width: stroke.width,
                                      widths: widths.map { Array($0[from...]) }, color: stroke.color, to: &committed)
            points = stroke.points
            self.widths = widths
        }

        var tail: [Float] = []
        guard let last = stroke.points.last else { return tail }
        if !stroke.predicted.isEmpty {
            CapsuleTessellator.append(points: [last] + stroke.predicted, width: stroke.width,
                                      widths: display.map { Array($0[(count - 1)...]) }, color: stroke.color, to: &tail)
        } else if count == 1 {
            CapsuleTessellator.append(points: [last], width: stroke.width, widths: widths, color: stroke.color, to: &tail)
        }
        return tail
    }
}
