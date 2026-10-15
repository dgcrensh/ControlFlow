import ControlFlowCore
import QuartzCore
import SwiftUI
import UIKit

/// A presentation's scene, filling the view with the viewport, letterboxed in black.
/// It draws on its screen's refresh (120 Hz on a ProMotion iPad, the display's own rate
/// on an external one) while a sequence plays, and only when the scene jumps otherwise.
///
/// With `takesInput`, it is the presentation's controls: a tap on the right half
/// advances and on the left half goes back, a two-finger pinch-in exits, and so do the
/// keys in `PresentationKey`.
final class PresentationCanvasView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let controller: PresentationController
    private let takesInput: Bool
    private let renderer: CanvasRenderer?
    /// A canvas of its own, which shows each frame's scene as a view-only preview.
    private var session = CanvasSession()
    private var displayLink: CADisplayLink?
    private var needsRender = true
    private var touches = PresentationTouches()
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1

    init(controller: PresentationController, takesInput: Bool) {
        self.controller = controller
        self.takesInput = takesInput
        renderer = CanvasRenderer()
        super.init(frame: .zero)
        renderer?.attach(to: metalLayer)
        renderer?.onNeedsRender = { [weak self] in self?.setNeedsRender() }
        isOpaque = true
        backgroundColor = .black
        isMultipleTouchEnabled = takesInput
        isUserInteractionEnabled = takesInput
        controller.addDisplay(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout and display link

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard let window else { return }
        contentScaleFactor = window.traitCollection.displayScale
        setNeedsLayout()
        // The link of the screen the view is on, so an external display gets its own rate.
        let link = window.windowScene?.screen.displayLink(withTarget: self, selector: #selector(displayLinkFired))
            ?? CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        setNeedsRender()
        if takesInput {
            // Keys go to the first responder; take that role once on screen.
            Task { @MainActor [weak self] in _ = self?.becomeFirstResponder() }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        session.camera = Presenter.camera(fitting: controller.viewport, in: Vec2(bounds.size))
        setNeedsRender()
    }

    func setNeedsRender() {
        needsRender = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired() {
        guard let link = displayLink else { return }
        guard needsRender || controller.isPlaying else {
            // Resting on a sequence's end: stop ticking until the scene jumps.
            link.isPaused = true
            return
        }
        needsRender = false
        // Each frame shows the scene at the time it reaches the screen.
        session.editor.showScene(controller.scene(at: link.targetTimestamp))
        let drawn = renderer?.render(session: session, viewSize: bounds.size, scale: contentScaleFactor,
                                     darkMode: false, presenting: true) ?? true
        // A dropped frame is retried on the next tick.
        if !drawn { needsRender = true }
    }

    // MARK: Keys

    override var canBecomeFirstResponder: Bool { takesInput }

    /// The system's three-finger editing gestures have nothing to act on here.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    private static let keyInputs: [(input: String, key: PresentationKey)] = [
        (" ", .space), ("\r", .returnKey),
        (UIKeyCommand.inputRightArrow, .rightArrow), (UIKeyCommand.inputDownArrow, .downArrow),
        (UIKeyCommand.inputPageDown, .pageDown),
        (UIKeyCommand.inputLeftArrow, .leftArrow), (UIKeyCommand.inputUpArrow, .upArrow),
        (UIKeyCommand.inputPageUp, .pageUp),
        (UIKeyCommand.inputEscape, .escape),
    ]

    override var keyCommands: [UIKeyCommand]? {
        guard takesInput else { return nil }
        return Self.keyInputs.map { entry in
            let command = UIKeyCommand(input: entry.input, modifierFlags: [], action: #selector(keyPressed(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func keyPressed(_ command: UIKeyCommand) {
        guard let key = Self.keyInputs.first(where: { $0.input == command.input })?.key else { return }
        controller.perform(key.action)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder { becomeFirstResponder() }
        for touch in touches {
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            self.touches.began(id: id, at: Vec2(touch.location(in: self)), time: touch.timestamp)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)],
                  let action = self.touches.moved(id: id, to: Vec2(touch.location(in: self))) else { continue }
            controller.perform(action)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)),
                  let action = self.touches.ended(id: id, at: Vec2(touch.location(in: self)), time: touch.timestamp,
                                                  width: Double(bounds.width)) else { continue }
            controller.perform(action)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            self.touches.cancelled(id: id)
        }
    }
}

/// `PresentationCanvasView` in SwiftUI.
struct PresentationCanvas: UIViewRepresentable {
    let controller: PresentationController
    var takesInput = true

    func makeUIView(context: Context) -> PresentationCanvasView {
        PresentationCanvasView(controller: controller, takesInput: takesInput)
    }

    func updateUIView(_ view: PresentationCanvasView, context: Context) {}
}
