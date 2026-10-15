import Foundation

/// A 2D point or vector in points. Screen and world space both use y-down.
public struct Vec2: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }
    public var lengthSquared: Double { x * x + y * y }

    /// Unit vector in the same direction, or `.zero` for a zero-length vector.
    public var normalized: Vec2 {
        let len = length
        return len > 0 ? Vec2(x / len, y / len) : .zero
    }

    /// The vector rotated 90 degrees (clockwise on a y-down screen).
    public var perpendicular: Vec2 { Vec2(-y, x) }

    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }
    public func cross(_ other: Vec2) -> Double { x * other.y - y * other.x }
    public func distance(to other: Vec2) -> Double { (self - other).length }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func * (s: Double, a: Vec2) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
    public static func -= (a: inout Vec2, b: Vec2) { a = a - b }

    /// Linear interpolation from `a` (t = 0) to `b` (t = 1).
    public static func lerp(_ a: Vec2, _ b: Vec2, _ t: Double) -> Vec2 { a + (b - a) * t }

    /// True when both components are within `tolerance` of `other`.
    public func isApproximately(_ other: Vec2, tolerance: Double = 1e-9) -> Bool {
        abs(x - other.x) <= tolerance && abs(y - other.y) <= tolerance
    }
}
