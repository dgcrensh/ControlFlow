import Foundation

/// The transform of a layer, group or shape: it scales by `scale` and turns by
/// `rotation` about `pivot`, then moves by `position`. Layers, groups and shapes
/// compose (layer, then group, then shape), and a shape's points are stored in its own
/// space, before its transform.
///
/// The pivot is in the object's own space, and with `position` at zero it stays put:
/// `matrix.apply(pivot) == pivot + position`.
public struct Transform: Hashable, Sendable, Codable {
    public var position: Vec2
    /// Degrees, clockwise on screen. Not wrapped, so 720 is two turns.
    public var rotation: Double
    public var scale: Vec2
    public var pivot: Vec2

    public init(position: Vec2 = .zero, rotation: Double = 0, scale: Vec2 = Vec2(1, 1), pivot: Vec2 = .zero) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
        self.pivot = pivot
    }

    public static let identity = Transform()

    /// True when the transform leaves every point where it is, whatever its pivot.
    public var isIdentity: Bool { position == .zero && rotation == 0 && scale == Vec2(1, 1) }

    /// The transform as a matrix: `translate(position + pivot) · rotate · scale · translate(-pivot)`.
    public var matrix: Affine2D {
        if isIdentity { return .identity }
        return Affine2D.translation(position + pivot) * Affine2D.rotation(rotation * .pi / 180) *
            Affine2D.scale(x: scale.x, y: scale.y) * Affine2D.translation(-pivot)
    }

    /// The same transform about another pivot: `position` changes so `matrix` doesn't.
    public func withPivot(_ newPivot: Vec2) -> Transform {
        var t = self
        t.pivot = newPivot
        let m = matrix
        t.position = position + m.applyToVector(newPivot - pivot) - (newPivot - pivot)
        return t
    }

    /// The transform about `pivot` whose matrix is `m`, with its rotation the turn
    /// closest to `rotation` (so a drag past 180 degrees keeps counting, and a flip
    /// shows as a negative scale rather than a half turn). Nil when `m` skews or
    /// collapses, which these fields can't express.
    public init?(matrix m: Affine2D, pivot: Vec2, near rotation: Double = 0) {
        let sx = (m.a * m.a + m.b * m.b).squareRoot()
        guard sx > 1e-9 else { return nil }
        let cs = m.a / sx, sn = m.b / sx
        // The second column in the rotated frame: (skew, scale y).
        let skew = m.c * cs + m.d * sn
        let sy = -m.c * sn + m.d * cs
        let size = max(sx, abs(sy))
        guard abs(skew) <= 1e-9 * max(size, 1), abs(sy) > 1e-9 else { return nil }
        var angle = atan2(sn, cs) * 180 / .pi
        var sc = Vec2(sx, sy)
        // A half turn with both scales negated is the same matrix: take whichever turn
        // is closer, preferring a positive x scale on a tie.
        let a1 = Transform.unwrap(angle, near: rotation), a2 = Transform.unwrap(angle + 180, near: rotation)
        if abs(a2 - rotation) < abs(a1 - rotation) - 1e-9 {
            angle = a2
            sc = Vec2(-sx, -sy)
        } else {
            angle = a1
        }
        if abs(angle.rounded() - angle) < 1e-9 { angle = angle.rounded() }
        self.init(position: m.apply(pivot) - pivot, rotation: angle, scale: sc, pivot: pivot)
    }

    /// `angle` plus or minus whole turns, as close as possible to `near`.
    static func unwrap(_ angle: Double, near: Double) -> Double {
        angle + 360 * ((near - angle) / 360).rounded()
    }
}
