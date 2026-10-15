import ControlFlowCore
import QuartzCore
import UIKit
import os

private let touchLog = Logger(subsystem: "com.dgcrensh.controlflow", category: "touches")

/// The drawing surface: a `CAMetalLayer`-backed view that forwards raw touches to
/// the canvas session and redraws on the display's refresh (up to 120 Hz).
///
/// Latency: every move event feeds all coalesced samples plus the system's predicted
/// samples into the live stroke, and the next display-link tick draws them, so ink
/// stays under the nib. Predicted samples are replaced on each event and dropped
/// when the stroke ends.
final class MetalCanvasView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private let store: CanvasStore
    private let renderer: CanvasRenderer?
    private var displayLink: CADisplayLink?
    private var needsRender = true
    /// The "Render wait" signpost: from the first request for a frame to the tick that
    /// draws it, which is the input-to-render latency on the CPU side.
    private var renderWait: OSSignpostIntervalState?
    private var hasLaidOut = false
    /// The size and interface orientation at the last layout, to tell a resize, and
    /// which way the iPad turned, from the next.
    private var laidOutSize: CGSize = .zero
    private var laidOutOrientation: DisplayOrientation?

    /// Stable small integer ids for live `UITouch` objects.
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 1
    /// Polls for a QuickShape hold while a stroke is drawn: a Pencil held still sends
    /// no events of its own to react to.
    private var quickShapeWatch: Task<Void, Never>?
    /// Recognizers on views above the canvas that it switched off, to switch back on
    /// when the canvas leaves the window.
    private var disabledAncestorRecognizers: [UIGestureRecognizer] = []
    /// The keyboard's way into a text on the canvas: an invisible text view holding the
    /// words being edited, so the software and hardware keyboards, dictation, marked
    /// text and autocorrect all work. The canvas draws the text, caret and selection.
    private let textInput = TextInputView()
    /// The edit session and revision `textInput` was last copied from.
    private var syncedTextEdit: (session: Int, revision: Int)?
    /// True while copying the editor's words into `textInput`, so its delegate calls
    /// aren't sent back.
    private var copyingTextEdit = false

    init(store: CanvasStore) {
        self.store = store
        self.renderer = CanvasRenderer()
        super.init(frame: .zero)
        renderer?.attach(to: metalLayer)
        renderer?.referenceImage = { [weak store] id in store?.referenceImage(id) }
        renderer?.onNeedsRender = { [weak self] in self?.setNeedsRender() }
        isMultipleTouchEnabled = true
        // Pencil (and pointer) hover drives the pen tool's rubber band and the hover highlights.
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        // The Pencil's double tap and squeeze.
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
        isOpaque = true
        backgroundColor = .systemBackground
        store.onChange = { [weak self] in
            self?.setNeedsRender()
            self?.syncTextInput()
        }
        textInput.delegate = self
        textInput.onEscape = { [weak store] in store?.endTextEdit() }
        addSubview(textInput)
        // Scribble: writing into a text with the Pencil while the text tool is chosen.
        addInteraction(UIIndirectScribbleInteraction(delegate: self))
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MetalCanvasView, _: UITraitCollection) in
            view.setNeedsRender()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout and display link

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            contentScaleFactor = window.traitCollection.displayScale
            setNeedsLayout()
            startDisplayLink()
            disableAncestorPinches()
        } else {
            displayLink?.invalidate()
            displayLink = nil
            for recognizer in disabledAncestorRecognizers { recognizer.isEnabled = true }
            disabledAncestorRecognizers = []
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = contentScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        store.viewSize = bounds.size
        let orientation = window?.windowScene.flatMap { DisplayOrientation($0.effectiveGeometry.interfaceOrientation) }
        if bounds.width > 0, bounds.height > 0 {
            if !hasLaidOut {
                hasLaidOut = true
                store.session.resetView(viewSize: Vec2(bounds.size))
            } else if bounds.size != laidOutSize {
                // Keep the middle of the view still, and with the lock on, keep the art
                // lined up with the screen.
                var turn: Double?
                if let old = laidOutOrientation, let orientation { turn = DisplayOrientation.turn(from: old, to: orientation) }
                store.viewDidResize(from: laidOutSize, to: bounds.size, interfaceTurn: turn)
            }
            laidOutSize = bounds.size
            laidOutOrientation = orientation
        }
        setNeedsRender()
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func setNeedsRender() {
        if renderWait == nil { renderWait = Signposts.canvas.beginInterval("Render wait") }
        needsRender = true
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired() {
        // Play Sequence: each frame shows the scene at the time it reaches the screen.
        if store.isPlaying, let link = displayLink {
            store.playbackFrame(at: link.targetTimestamp)
            needsRender = true
        }
        // The rotation lock snapping the canvas to a quarter turn.
        if store.session.isTurning, let link = displayLink {
            store.stepTurn(at: link.targetTimestamp)
            needsRender = true
        }
        guard needsRender else {
            // Idle: stop ticking until something changes.
            displayLink?.isPaused = true
            return
        }
        needsRender = false
        if let renderWait {
            Signposts.canvas.endInterval("Render wait", renderWait)
            self.renderWait = nil
        }
        let drawn = renderer?.render(
            session: store.session,
            viewSize: bounds.size,
            scale: contentScaleFactor,
            darkMode: traitCollection.userInterfaceStyle == .dark
        ) ?? true
        // A dropped frame is retried on the next tick; otherwise the overlay could stay stale.
        if !drawn { needsRender = true }
        // The frame's CPU work ran past the display's next refresh.
        if let link = displayLink, CACurrentMediaTime() > link.targetTimestamp {
            Signposts.canvas.emitEvent("Missed frame deadline")
        }
    }

    @objc private func hovered(_ recognizer: UIHoverGestureRecognizer) {
        let interval = Signposts.canvas.beginInterval("Hover")
        defer { Signposts.canvas.endInterval("Hover", interval) }
        switch recognizer.state {
        case .began, .changed:
            store.session.pencilHovered(at: Vec2(recognizer.location(in: self)))
        default:
            store.session.pencilHovered(at: nil)
        }
        setNeedsRender()
    }

    // MARK: Touches

    /// Navigation is the canvas's own: `CanvasSession` pans, zooms and rotates with two
    /// fingers. UIKit also asks the touched view before a recognizer on one of its
    /// ancestors begins, such as the document's pinch-to-close (the zoom transition back
    /// to the browser) or the edge swipe back. Those would cancel a two-finger pinch's
    /// touches, so over the canvas only its own recognizers may begin. The back button
    /// still closes the document.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer.view === self && super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    /// Refusing in `gestureRecognizerShouldBegin` is not enough for every system
    /// recognizer: one that holds back or cancels touches while it decides still takes
    /// a two-finger pinch (a three-finger one got through because a pinch recognizer
    /// fails on a third touch). So pinch, rotation and edge-swipe recognizers on the
    /// views above the canvas are switched off while it is on screen. Called again on
    /// each touch, since the document's zoom transition adds its recognizers late.
    private func disableAncestorPinches() {
        var view = superview
        while let current = view {
            for recognizer in current.gestureRecognizers ?? [] where recognizer.isEnabled {
                let name = String(describing: type(of: recognizer))
                let steals = recognizer is UIPinchGestureRecognizer || recognizer is UIRotationGestureRecognizer
                    || recognizer is UIScreenEdgePanGestureRecognizer
                    || name.contains("Pinch") || name.contains("Zoom")
                guard steals else { continue }
                touchLog.debug("Switching off \(name, privacy: .public) on \(String(describing: type(of: current)), privacy: .public)")
                recognizer.isEnabled = false
                disabledAncestorRecognizers.append(recognizer)
            }
            view = current.superview
        }
    }

    /// The system's three-finger editing gestures (swipe to undo, pinch to copy) would
    /// act on the document behind the editor's back and fight three-finger navigation.
    /// The canvas has its own two- and three-finger taps for undo and redo.
    /// The system asks the first responder, so the canvas takes that role on touch.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var canBecomeFirstResponder: Bool { true }

    /// What touches are doing, for the touch signposts.
    private var phase: String {
        store.session.isDrawing ? "draw" : store.session.isNavigating ? "navigate"
            : store.session.isPencilActive ? "edit" : "other"
    }

    private func kind(of touch: UITouch) -> TouchKind? {
        switch touch.type {
        case .pencil: .pencil
        case .direct: .finger
        default: nil
        }
    }

    private func location(of touch: UITouch) -> Vec2 {
        Vec2(touch.type == .pencil ? touch.preciseLocation(in: self) : touch.location(in: self))
    }

    /// The Pencil's force as a fraction of the most it reports, or nil for fingers.
    private func pressure(of touch: UITouch) -> Double? {
        guard touch.type == .pencil, touch.maximumPossibleForce > 0 else { return nil }
        let fraction = Double(touch.force / touch.maximumPossibleForce)
        return min(max(fraction, 0), 1)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let interval = Signposts.canvas.beginInterval("Touches began")
        defer { Signposts.canvas.endInterval("Touches began", interval) }
        // Shift and Option on a hardware keyboard constrain and duplicate.
        if let event { store.setKeyboardModifiers(event.modifierFlags) }
        if store.ui.palettePoint != nil { store.hidePalette() }
        // Touching the canvas stops Play Sequence, so the Pencil can draw at once.
        if store.isPlaying { store.stopPlaying() }
        disableAncestorPinches()
        // While a text is being typed into, the keyboard stays with it.
        if !isFirstResponder, !textInput.isFirstResponder { becomeFirstResponder() }
        for touch in touches {
            guard let touchKind = kind(of: touch) else { continue }
            let id = nextTouchID
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = id
            store.session.touchBegan(
                id: id,
                kind: touchKind,
                location: location(of: touch),
                majorRadius: Double(touch.majorRadius),
                time: touch.timestamp,
                pressure: pressure(of: touch)
            )
        }
        if store.session.isDrawing, quickShapeWatch == nil { watchForQuickShape() }
        setNeedsRender()
    }

    private func watchForQuickShape() {
        quickShapeWatch = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.store.session.isDrawing else { break }
                // Touch timestamps count from system start, like systemUptime.
                let snapped = Signposts.canvas.withIntervalSignpost("Quick shape check") {
                    self.store.session.checkQuickShape(time: ProcessInfo.processInfo.systemUptime)
                }
                if snapped {
                    self.setNeedsRender()
                }
            }
            if !Task.isCancelled { self?.quickShapeWatch = nil }
        }
    }

    private func stopWatchingForQuickShape() {
        quickShapeWatch?.cancel()
        quickShapeWatch = nil
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let interval = Signposts.canvas.beginInterval("Touches moved")
        let phase = self.phase
        var sampleCount = 0
        defer {
            Signposts.canvas.endInterval("Touches moved", interval,
                                         "\(phase, privacy: .public), \(sampleCount) samples")
        }
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            let samples: [UITouch] = coalesced.isEmpty ? [touch] : coalesced
            let predicted = event?.predictedTouches(for: touch) ?? []
            sampleCount += samples.count
            var pressures: [Double] = []
            for sample in samples {
                if let value = pressure(of: sample) { pressures.append(value) }
            }
            store.session.touchMoved(
                id: id,
                samples: samples.map(location(of:)),
                predicted: predicted.map(location(of:)),
                time: touch.timestamp,
                pressures: pressures.count == samples.count ? pressures : nil
            )
        }
        setNeedsRender()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Lifting the Pencil fits and commits a stroke, or ends an edit, then refreshes.
        let interval = Signposts.canvas.beginInterval("Touches ended")
        let phase = self.phase
        defer { Signposts.canvas.endInterval("Touches ended", interval, "\(phase, privacy: .public)") }
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            store.session.touchEnded(id: id, location: location(of: touch), time: touch.timestamp)
        }
        if !store.session.isDrawing { stopWatchingForQuickShape() }
        // Gestures and taps finish here, so the controls catch up now.
        store.refresh()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        // A cancelled touch means something else took it; name the culprits when debugging.
        var takers: [String] = []
        for touch in touches {
            for recognizer in touch.gestureRecognizers ?? [] where recognizer.view !== self {
                let state = recognizer.state
                guard state == .began || state == .changed || state == .ended else { continue }
                takers.append(String(describing: type(of: recognizer)))
            }
        }
        touchLog.debug("Touches cancelled; recognizers: \(takers, privacy: .public)")
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            store.session.touchCancelled(id: id)
        }
        if !store.session.isDrawing { stopWatchingForQuickShape() }
        store.refresh()
    }
}

// MARK: Typing into text

extension MetalCanvasView: UITextViewDelegate {
    /// Puts the words being edited into the text view and gives it the keyboard, or
    /// takes the keyboard back when no text is being edited. Called after every change.
    func syncTextInput() {
        guard window != nil else { return }
        guard let edit = store.textEdit, let string = store.editedString else {
            if syncedTextEdit != nil || textInput.isFirstResponder {
                syncedTextEdit = nil
                copyingTextEdit = true
                textInput.text = ""
                copyingTextEdit = false
                if textInput.isFirstResponder { becomeFirstResponder() }
            }
            return
        }
        // Words and selection the editor changed itself (a tap placing the caret, undo,
        // a new edit) are copied in; the user's own typing is already there.
        if syncedTextEdit?.session != edit.session || syncedTextEdit?.revision != edit.revision {
            syncedTextEdit = (edit.session, edit.revision)
            copyingTextEdit = true
            if textInput.text != string { textInput.text = string }
            textInput.selectedRange = NSRange(location: edit.selection.lowerBound, length: edit.selection.count)
            copyingTextEdit = false
        }
        // The text view sits at the caret, so the system's candidates and dictation
        // appear next to the words.
        if let geometry = store.session.editor.textEditGeometry {
            let camera = store.session.camera
            let top = camera.toScreen(geometry.caret?.top ?? geometry.frame[0])
            let bottom = camera.toScreen(geometry.caret?.bottom ?? geometry.frame[3])
            let height = max(min((bottom - top).length, 400), 8)
            textInput.frame = CGRect(x: top.x, y: min(top.y, bottom.y), width: 2, height: height)
        }
        if !textInput.isFirstResponder { textInput.becomeFirstResponder() }
    }

    private func selection(of textView: UITextView) -> Range<Int> {
        let range = textView.selectedRange
        return range.location..<(range.location + range.length)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !copyingTextEdit, store.textEdit != nil else { return }
        store.setEditedText(textView.text ?? "", selection: selection(of: textView))
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !copyingTextEdit, store.textEdit != nil, let string = store.editedString,
              (textView.text ?? "") == string else { return }
        store.setTextSelection(selection(of: textView))
    }
}

/// The canvas's invisible text view (see `MetalCanvasView.textInput`). Escape ends the
/// edit.
final class TextInputView: UITextView {
    var onEscape: (() -> Void)?

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 2, height: 20), textContainer: nil)
        // Invisible: the canvas draws the words, caret and selection.
        alpha = 0.02
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        isScrollEnabled = false
        isUserInteractionEnabled = false
        textContainerInset = .zero
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.key?.keyCode == .keyboardEscape }) {
            onEscape?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

// MARK: Scribble

extension MetalCanvasView: @preconcurrency UIIndirectScribbleInteractionDelegate {
    typealias ElementIdentifier = ShapeRef

    /// The text tool's texts on screen: writing into one with the Pencil types into it.
    func indirectScribbleInteraction(_ interaction: UIInteraction, requestElementsIn rect: CGRect,
                                     completion: @escaping ([ShapeRef]) -> Void) {
        guard store.session.editor.tool == .text else { return completion([]) }
        completion(store.textFrames().filter { screenFrame($0.frame).intersects(rect) }.map(\.ref))
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, isElementFocused elementIdentifier: ShapeRef) -> Bool {
        store.textEdit?.ref == elementIdentifier && textInput.isFirstResponder
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, frameForElement elementIdentifier: ShapeRef) -> CGRect {
        store.textFrames().first { $0.ref == elementIdentifier }.map { screenFrame($0.frame) } ?? .null
    }

    func indirectScribbleInteraction(_ interaction: UIInteraction, focusElementIfNeeded elementIdentifier: ShapeRef,
                                     referencePoint focusReferencePoint: CGPoint,
                                     completion: @escaping ((UIResponder & UITextInput)?) -> Void) {
        if store.textEdit?.ref != elementIdentifier { store.beginTextEdit(elementIdentifier) }
        syncTextInput()
        completion(store.textEdit?.ref == elementIdentifier ? textInput : nil)
    }

    /// A text box (four world corners) as the screen rectangle around it.
    private func screenFrame(_ corners: [Vec2]) -> CGRect {
        let camera = store.session.camera
        let points = corners.map { camera.toScreen($0) }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: Pencil double tap and squeeze

extension MetalCanvasView: UIPencilInteractionDelegate {
    /// Double tap follows the user's setting in Settings > Apple Pencil: switch to the
    /// eraser and back, switch to the previous tool, or show the palette.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        switch UIPencilInteraction.preferredTapAction {
        case .switchEraser:
            store.toggleEraser()
        case .switchPrevious:
            store.switchToPreviousTool()
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            store.showPalette(at: tap.hoverPose?.location)
        default:
            return
        }
        setNeedsRender()
    }

    /// Squeeze (Apple Pencil Pro) opens the palette under the Pencil, unless the user
    /// set squeeze to do nothing or to run a shortcut.
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore, .runSystemShortcut:
            return
        default:
            store.showPalette(at: squeeze.hoverPose?.location)
        }
    }
}

extension DisplayOrientation {
    /// The window scene's interface orientation; nil when it is unknown.
    init?(_ orientation: UIInterfaceOrientation) {
        switch orientation {
        case .portrait: self = .portrait
        case .portraitUpsideDown: self = .portraitUpsideDown
        case .landscapeLeft: self = .landscapeLeft
        case .landscapeRight: self = .landscapeRight
        default: return nil
        }
    }
}
