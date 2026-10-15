import Foundation

/// A 2D affine transform using the same convention as `CGAffineTransform`:
///
///     x' = a * x + c * y + tx
///     y' = b * x + d * y + ty
public struct Affine2D: Hashable, Sendable, Codable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public static let identity = Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ t: Vec2) -> Affine2D {
        Affine2D(a: 1, b: 0, c: 0, d: 1, tx: t.x, ty: t.y)
    }

    public static func scale(_ s: Double) -> Affine2D {
        Affine2D(a: s, b: 0, c: 0, d: s, tx: 0, ty: 0)
    }

    /// Scale by different factors along x and y.
    public static func scale(x: Double, y: Double) -> Affine2D {
        Affine2D(a: x, b: 0, c: 0, d: y, tx: 0, ty: 0)
    }

    /// Rotation by `radians`. Positive angles turn clockwise on a y-down screen.
    public static func rotation(_ radians: Double) -> Affine2D {
        let cs = cos(radians), sn = sin(radians)
        return Affine2D(a: cs, b: sn, c: -sn, d: cs, tx: 0, ty: 0)
    }

    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(a * p.x + c * p.y + tx, b * p.x + d * p.y + ty)
    }

    /// Applies only the linear part, for direction vectors.
    public func applyToVector(_ v: Vec2) -> Vec2 {
        Vec2(a * v.x + c * v.y, b * v.x + d * v.y)
    }

    /// `self` applied after `other`: `(self * other).apply(p) == self.apply(other.apply(p))`.
    public static func * (lhs: Affine2D, rhs: Affine2D) -> Affine2D {
        Affine2D(
            a: lhs.a * rhs.a + lhs.c * rhs.b,
            b: lhs.b * rhs.a + lhs.d * rhs.b,
            c: lhs.a * rhs.c + lhs.c * rhs.d,
            d: lhs.b * rhs.c + lhs.d * rhs.d,
            tx: lhs.a * rhs.tx + lhs.c * rhs.ty + lhs.tx,
            ty: lhs.b * rhs.tx + lhs.d * rhs.ty + lhs.ty
        )
    }

    public var determinant: Double { a * d - b * c }

    /// The inverse transform, or nil when the transform is singular.
    public var inverted: Affine2D? {
        let det = determinant
        guard abs(det) > 1e-12 else { return nil }
        let ia = d / det, ib = -b / det, ic = -c / det, id = a / det
        return Affine2D(
            a: ia, b: ib, c: ic, d: id,
            tx: -(ia * tx + ic * ty),
            ty: -(ib * tx + id * ty)
        )
    }

    /// Uniform scale factor, assuming the transform is a similarity (no shear).
    public var uniformScale: Double { (a * a + b * b).squareRoot() }

    /// Rotation angle in radians, assuming the transform is a similarity.
    public var rotationAngle: Double { atan2(b, a) }

    public func isApproximately(_ o: Affine2D, tolerance: Double = 1e-9) -> Bool {
        abs(a - o.a) <= tolerance && abs(b - o.b) <= tolerance &&
            abs(c - o.c) <= tolerance && abs(d - o.d) <= tolerance &&
            abs(tx - o.tx) <= tolerance && abs(ty - o.ty) <= tolerance
    }
}
