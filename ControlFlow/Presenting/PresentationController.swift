import ControlFlowCore
import Observation
import UIKit

/// The presentation being given, if any, and whether an external display is there to
/// show it. The external display's scene and the document presenting share it.
@MainActor @Observable
final class PresentationHub {
    static let shared = PresentationHub()

    /// The presentation being given.
    var active: PresentationController?
    /// External display scenes connected (cable, AirPlay or Sidecar).
    private(set) var externalDisplays = 0

    var hasExternalDisplay: Bool { externalDisplays > 0 }

    func externalDisplayConnected() { externalDisplays += 1 }
    func externalDisplayDisconnected() { externalDisplays = max(externalDisplays - 1, 0) }
}

/// One presentation being given: the core's `Presenter`, the inputs that drive it, and
/// the scene each display draws. The presentation is the document as it was when
/// presenting started.
@MainActor @Observable
final class PresentationController: Identifiable {
    @ObservationIgnored private var presenter: Presenter
    /// The presenter view's labels, refreshed when the scene jumps rather than each frame.
    private(set) var counter: String
    private(set) var nextTitle: String?
    /// The end of the next sequence, drawn off the main thread.
    private(set) var nextImage: UIImage? = nil
    let viewport: Viewport
    /// Called for Exit (Escape or a pinch-in).
    @ObservationIgnored var onExit: (() -> Void)?

    /// The canvases drawing the presentation, told to draw when the scene jumps.
    private let displays = NSHashTable<PresentationCanvasView>.weakObjects()
    /// The last frame asked for: displays drawing the same refresh share it.
    @ObservationIgnored private var lastFrame: (time: Double, revision: Int, scene: Drawing)?
    @ObservationIgnored private var nextImageTask: Task<Void, Never>?
    /// The sequence `nextTitle` and `nextImage` show.
    @ObservationIgnored private var nextSequence: Int?

    init(presentation: Presentation) {
        let presenter = Presenter(presentation: presentation)
        self.presenter = presenter
        counter = presenter.counter
        nextTitle = presenter.nextSequenceTitle
        viewport = presenter.viewport
        nextSequence = presenter.nextSequence
        drawNextImage()
    }

    /// True while a sequence plays, when the displays draw every refresh.
    var isPlaying: Bool { presenter.isPlaying }

    func perform(_ action: PresentationAction) {
        guard action != .exit else {
            onExit?()
            return
        }
        let revision = presenter.revision
        presenter.perform(action)
        if presenter.revision != revision { sceneJumped() }
    }

    /// The scene at display time `time`, moving playback on.
    func scene(at time: Double) -> Drawing {
        if let lastFrame, lastFrame.time == time, lastFrame.revision == presenter.revision { return lastFrame.scene }
        let revision = presenter.revision
        let scene = presenter.scene(at: time)
        lastFrame = (time, presenter.revision, scene)
        if presenter.revision != revision { sceneJumped() }
        return scene
    }

    func addDisplay(_ view: PresentationCanvasView) { displays.add(view) }

    private func sceneJumped() {
        lastFrame = nil
        if counter != presenter.counter { counter = presenter.counter }
        if nextSequence != presenter.nextSequence {
            nextSequence = presenter.nextSequence
            nextTitle = presenter.nextSequenceTitle
            drawNextImage()
        }
        for display in displays.allObjects { display.setNeedsRender() }
    }

    /// Draws the next sequence's end state for the presenter view.
    private func drawNextImage() {
        nextImageTask?.cancel()
        guard let scene = presenter.nextEndState() else {
            nextImage = nil
            return
        }
        nextImageTask = Task { [weak self] in
            let png = await Task.detached(priority: .userInitiated) { Self.image(of: scene) }.value
            guard !Task.isCancelled, let self else { return }
            self.nextImage = png.flatMap { UIImage(data: $0) }
        }
    }

    /// The viewport's picture, 960 pixels on its long side.
    nonisolated private static func image(of scene: Drawing) -> Data? {
        let area = scene.viewport.bounds
        return ThumbnailRenderer.exportPNG(for: scene, area: area, scale: 960 / max(area.width, area.height, 1))
    }
}
