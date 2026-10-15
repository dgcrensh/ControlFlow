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
    /// The rotation in degrees clockwise, in [0, 360).
    public var rotationDegrees: Double { RotationLock.unsignedDegrees(rotation * 180 / .pi) }

    public func toWorld(_ screenPoint: Vec2) -> Vec2 { screenToWorld.apply(screenPoint) }
    public func toScreen(_ worldPoint: Vec2) -> Vec2 { worldToScreen.apply(worldPoint) }

    /// A camera at 100% zoom, unrotated, with the world origin at the center of the view.
    public static func centered(in viewSize: Vec2) -> CanvasCamera {
        CanvasCamera(worldToScreen: .translation(viewSize / 2))
    }

    /// The camera turned `degrees` clockwise about `anchor`, a screen point.
    public func rotated(by degrees: Double, about anchor: Vec2) -> CanvasCamera {
        let turn = Affine2D.translation(anchor) * .rotation(degrees: degrees) * Affine2D.translation(-anchor)
        return CanvasCamera(worldToScreen: turn * worldToScreen)
    }

    /// The camera at rotation `degrees` (clockwise), with the same zoom and the same world
    /// point at `anchor`. Quarter turns come out exact, with no rounding in the matrix.
    public func turned(to degrees: Double, about anchor: Vec2) -> CanvasCamera {
        CanvasCamera(worldToScreen: Affine2D.translation(anchor) * .rotation(degrees: degrees) *
            Affine2D.scale(zoom) * Affine2D.translation(-toWorld(anchor)))
    }

    /// The camera that fits `rect` (world space) in a view of `viewSize` points, centered,
    /// at rotation `degrees`, with `margin` screen points to spare on the tighter side.
    /// Nil when the view is too small for the margin.
    public static func fitting(_ rect: Rect, in viewSize: Vec2, rotation degrees: Double = 0,
                               margin: Double = 0) -> CanvasCamera? {
        guard !rect.isNull, viewSize.x > 2 * margin, viewSize.y > 2 * margin else { return nil }
        let turn = Affine2D.rotation(degrees: degrees)
        // The rect's extent on screen at 100%, turned.
        let width = abs(turn.a) * max(rect.width, 1) + abs(turn.c) * max(rect.height, 1)
        let height = abs(turn.b) * max(rect.width, 1) + abs(turn.d) * max(rect.height, 1)
        let fit = min((viewSize.x - 2 * margin) / width, (viewSize.y - 2 * margin) / height)
        let zoom = min(max(fit, zoomRange.lowerBound), zoomRange.upperBound)
        return CanvasCamera(worldToScreen: Affine2D.translation(viewSize / 2) * turn * Affine2D.scale(zoom) *
            Affine2D.translation(-rect.center))
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

/// The screen-space pan and zoom, with no rotation, that a two-finger gesture from
/// (p0, p1) to (q0, q1) describes while the rotation is locked: the scale is the ratio
/// of the fingers' distances, and the midpoint stays under the fingers.
public func rotationFreeTransform(from p0: Vec2, _ p1: Vec2, to q0: Vec2, _ q1: Vec2) -> Affine2D {
    let start = Vec2.lerp(p0, p1, 0.5), end = Vec2.lerp(q0, q1, 0.5)
    let before = (p1 - p0).length
    let k = before > 1e-9 ? (q1 - q0).length / before : 1
    return Affine2D.translation(end) * Affine2D.scale(k) * Affine2D.translation(-start)
}

/// A two-finger navigation in progress: remembers where it started so each update
/// is computed from the start, which avoids drift from accumulating small steps.
public struct TwoFingerNavigation: Hashable, Sendable {
    public let startCamera: CanvasCamera
    public let start0: Vec2
    public let start1: Vec2
    /// False while the rotation is locked: the fingers pan and zoom only.
    public let rotates: Bool

    public init(startCamera: CanvasCamera, start0: Vec2, start1: Vec2, rotates: Bool = true) {
        self.startCamera = startCamera
        self.start0 = start0
        self.start1 = start1
        self.rotates = rotates
    }

    public func camera(current0: Vec2, current1: Vec2) -> CanvasCamera {
        let s = rotates ? similarityTransform(from: start0, start1, to: current0, current1)
            : rotationFreeTransform(from: start0, start1, to: current0, current1)
        return startCamera.applying(screenTransform: s, anchor: Vec2.lerp(current0, current1, 0.5))
    }
}
