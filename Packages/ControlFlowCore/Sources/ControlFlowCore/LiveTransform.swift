import Foundation

/// A select-tool drag that moves, scales or rotates shapes, as renderers see it. The
/// editor applies the transform to `drawing` on every sample, which re-tessellates
/// every moved shape; a renderer can instead keep drawing `base`, the drawing as the
/// drag began, and apply `transform` to the `shapes` it moves when it draws them.
/// That is exact when the transform is a similarity (outline widths and dashes scale
/// with it, as `VectorShape.apply` does), so `movesTessellation` says when to use it.
public struct LiveTransform: Sendable {
    /// Distinguishes one drag from the next, so a renderer builds `base` once per drag.
    public var id: Int
    public var base: Drawing
    /// Ids of the shapes the drag moves.
    public var shapes: Set<Int>
    /// From `base` to where the shapes are now.
    public var transform: Affine2D

    /// How far a similarity may enlarge the shapes before their flattening, made for
    /// `base`, would show its corners.
    public static let maximumScale = 2.0

    /// True when drawing `base`'s triangles through `transform` looks like drawing the
    /// transformed drawing: the transform is a similarity (rotation, uniform scale,
    /// reflection), and enlarges by at most `maximumScale`.
    public var movesTessellation: Bool {
        let t = transform
        let x = t.a * t.a + t.b * t.b, y = t.c * t.c + t.d * t.d
        let scale = x.squareRoot()
        guard scale > 1e-9, scale <= Self.maximumScale else { return false }
        // Columns of equal length at right angles.
        return abs(x - y) <= 1e-6 * x && abs(t.a * t.c + t.b * t.d) <= 1e-6 * x
    }

    /// The shape ids `selection` moves in `drawing`. Nil when it moves no shapes (a
    /// reference image, or nothing).
    static func shapes(of selection: Selection, in drawing: Drawing) -> Set<Int>? {
        let ids = Set(drawing.shapeRefs(in: selection).map(\.shape))
        return ids.isEmpty ? nil : ids
    }
}
