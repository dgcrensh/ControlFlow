import Foundation

/// The window scene's interface orientation, as the app reads it from UIKit.
public enum DisplayOrientation: Hashable, Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    /// How far the interface is turned on the glass from portrait, in degrees clockwise.
    /// Landscape Right has the Home side on the right: the iPad turned counterclockwise,
    /// so the interface turned clockwise to stay upright.
    public var angle: Double {
        switch self {
        case .portrait: 0
        case .landscapeRight: 90
        case .portraitUpsideDown: 180
        case .landscapeLeft: 270
        }
    }

    /// How far the interface turned on the glass going from `old` to `new`, in degrees
    /// clockwise, in (-180, 180].
    public static func turn(from old: DisplayOrientation, to new: DisplayOrientation) -> Double {
        RotationLock.signedDegrees(new.angle - old.angle)
    }
}

/// The canvas rotation lock: with it on, the camera's rotation is a quarter turn chosen
/// so the viewport's long side lies along the canvas view's long side.
///
/// - Sides that already agree give 0 degrees, never 180, so the art is never upside down.
/// - Sides that disagree give 90 or 270. When the interface has just turned a quarter
///   turn, the camera turns the other way, so the art stays still on the glass while the
///   toolbars swing round it. Otherwise it keeps whichever of the two is closer to the
///   current rotation, and 90 (the deck's top on the right) from 0 or 180.
/// - A viewport within 2% of square, or a view within 2% of square, gives 0.
public enum RotationLock {
    /// How close to square (as a ratio of the long side to the short) counts as square.
    public static let squareTolerance = 0.02
    /// How long turning the lock on takes to snap the rotation, in seconds.
    public static let snapDuration = 0.25

    /// The locked rotation, in degrees clockwise: 0, 90 or 270. `current` is the camera's
    /// rotation in degrees, and `interfaceTurn` the interface's turn on the glass (see
    /// `DisplayOrientation.turn(from:to:)`) when the view changed size because the
    /// iPad turned.
    public static func targetRotation(viewport: Viewport, viewSize: Vec2, current: Double,
                                      interfaceTurn: Double? = nil) -> Double {
        guard let viewportLandscape = orientation(viewport.width, viewport.height),
              let viewLandscape = orientation(viewSize.x, viewSize.y),
              viewportLandscape != viewLandscape else { return 0 }
        var rotation = current
        // A quarter turn of the interface turns the art back the other way. A half turn
        // (one landscape to the other) keeps it upright, as UIKit does for everything else.
        if let turn = interfaceTurn, abs(abs(signedDegrees(turn)) - 90) < 1 {
            rotation -= turn
        }
        let r = unsignedDegrees(rotation)
        // The closer of 90 and 270; exactly between them (0 or 180) goes to 90.
        return abs(r - 270) < abs(r - 90) - 1e-9 ? 270 : 90
    }

    /// True for landscape, false for portrait, nil for square or empty.
    private static func orientation(_ width: Double, _ height: Double) -> Bool? {
        guard width > 0, height > 0 else { return nil }
        let long = max(width, height), short = min(width, height)
        guard long / short > 1 + squareTolerance else { return nil }
        return width > height
    }

    /// `degrees` in [0, 360).
    public static func unsignedDegrees(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        let result = r < 0 ? r + 360 : r
        return result >= 360 ? 0 : result
    }

    /// `degrees` in (-180, 180].
    public static func signedDegrees(_ degrees: Double) -> Double {
        let r = unsignedDegrees(degrees)
        return r > 180 ? r - 360 : r
    }
}

/// A camera turning to a new rotation about a screen point, animated: the lock snapping
/// the rotation when it is turned on. Zoom and the world point at `anchor` stay fixed.
public struct CameraTurn: Hashable, Sendable {
    public let start: CanvasCamera
    /// The turn, in degrees clockwise, the short way round.
    public let degrees: Double
    public let anchor: Vec2
    public let duration: Double
    /// The display time of the first frame, which starts the clock.
    public private(set) var startTime: Double?

    public init(start: CanvasCamera, to rotation: Double, about anchor: Vec2, duration: Double = RotationLock.snapDuration) {
        self.start = start
        degrees = RotationLock.signedDegrees(rotation - start.rotationDegrees)
        self.anchor = anchor
        self.duration = duration
    }

    public var end: CanvasCamera { start.turned(to: start.rotationDegrees + degrees, about: anchor) }

    /// The camera at display time `time`, and whether the turn has finished.
    public mutating func camera(at time: Double) -> (camera: CanvasCamera, finished: Bool) {
        let begin = startTime ?? time
        startTime = begin
        let t = duration > 0 ? min(max((time - begin) / duration, 0), 1) : 1
        guard t < 1 else { return (end, true) }
        // Ease in and out.
        let eased = t * t * (3 - 2 * t)
        return (start.rotated(by: degrees * eased, about: anchor), false)
    }
}
