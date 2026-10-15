import Foundation

/// The view onto the infinite canvas: a similarity transform (pan, uniform zoom,
/// rotation) from world points to screen points.
public struct CanvasCamera: Hashable, Sendable {
    public static let zoomRange: ClosedRange<Double> = 0.05...64

    public var worldToScreen: Affine2D

    public init(worldToScreen: Affine2D = .identity) {
        self.worldToScreen = worldToScreen
    }

    public var screenToWorld: Affine2D { worldToScreen.inverted ?? .identity }
    public var zoom: Double { worldToScreen.uniformScale }
    public var rotation: Double { worldToScreen.rotationAngle }

    public func toWorld(_ screenPoint: Vec2) -> Vec2 { screenToWorld.apply(screenPoint) }
    public func toScreen(_ worldPoint: Vec2) -> Vec2 { worldToScreen.apply(worldPoint) }

    /// A camera at 100% zoom, unrotated, with the world origin at the center of the view.
    public static func centered(in viewSize: Vec2) -> CanvasCamera {
        CanvasCamera(worldToScreen: .translation(viewSize / 2))
    }

    /// Applies a screen-space similarity on top of the current view, then clamps the
    /// zoom to `zoomRange` while keeping `anchor` (a screen point) fixed.
    public func applying(screenTransform s: Affine2D, anchor: Vec2) -> CanvasCamera {
        var result = s * worldToScreen
        let z = result.uniformScale
        let clamped = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        if z > 0, clamped != z {
            let k = clamped / z
            let fix = Affine2D.translation(anchor) * Affine2D.scale(k) * Affine2D.translation(-anchor)
            result = fix * result
        }
        return CanvasCamera(worldToScreen: result)
    }
}

/// The screen-space similarity that maps segment (p0, p1) onto (q0, q1): the
/// transform a two-finger pan, pinch and rotate describes.
/// Falls back to a pure translation when the start points coincide.
public func similarityTransform(from p0: Vec2, _ p1: Vec2, to q0: Vec2, _ q1: Vec2) -> Affine2D {
    let u = q1 - q0
    let v = p1 - p0
    let vv = v.lengthSquared
    guard vv > 1e-9 else {
        return .translation(Vec2.lerp(q0, q1, 0.5) - Vec2.lerp(p0, p1, 0.5))
    }
    // Complex division u / v gives the combined scale and rotation.
    let sr = (u.x * v.x + u.y * v.y) / vv
    let si = (u.y * v.x - u.x * v.y) / vv
    let linear = Affine2D(a: sr, b: si, c: -si, d: sr, tx: 0, ty: 0)
    let t = q0 - linear.apply(p0)
    return Affine2D(a: sr, b: si, c: -si, d: sr, tx: t.x, ty: t.y)
}

/// A two-finger navigation in progress: remembers where it started so each update
/// is computed from the start, which avoids drift from accumulating small steps.
public struct TwoFingerNavigation: Hashable, Sendable {
    public let startCamera: CanvasCamera
    public let start0: Vec2
    public let start1: Vec2

    public init(startCamera: CanvasCamera, start0: Vec2, start1: Vec2) {
        self.startCamera = startCamera
        self.start0 = start0
        self.start1 = start1
    }

    public func camera(current0: Vec2, current1: Vec2) -> CanvasCamera {
        let s = similarityTransform(from: start0, start1, to: current0, current1)
        return startCamera.applying(screenTransform: s, anchor: Vec2.lerp(current0, current1, 0.5))
    }
}
