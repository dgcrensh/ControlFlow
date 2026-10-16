import ControlFlowCore
import ImageIO
import Observation
import QuartzCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The editor state SwiftUI controls show. Refreshed from the session after each
/// gesture and command, never per touch sample.
@MainActor
@Observable
final class EditorUIState {
    enum SelectionKind: Equatable {
        case none, layer, shape, reference
    }

    var tool: Tool = .pencil
    var canUndo = false
    var canRedo = false
    var selection: SelectionKind = .none
    var canDeleteAnchor = false
    /// How many anchors are selected in Direct Select.
    var anchorCount = 0
    /// The handle mode the selected anchors share, if they do.
    var anchorMode: HandleMode?
    /// Whether the edges between the selected anchors are outlined (nil when none is selected).
    var edgesStroked: Bool?
    var canSplit = false
    var canJoin = false
    var canTransform = false
    /// Align and Distribute apply to the selection (or the selected anchors).
    var canAlign = false
    var canDistribute = false
    /// One unit is selected, so Align lines it up with the viewport whatever `alignTarget` says.
    var alignsToViewportOnly = false
    /// What Align and Distribute line things up against. Kept for the session only.
    var alignTarget: AlignTarget = .selection
    /// The selection has a layer, group or shape transform that Apply Transform can bake.
    var canApplyTransform = false
    var penActive = false
    var addToSelection = false
    var autoJoin = false
    var snap = SnapSettings()
    /// The selection's bounds without outline width, and the selected anchors' middle,
    /// for the inspector's numeric fields.
    var selectionBounds: Rect?
    var anchorPosition: Vec2?
    var style = ShapeStyle()
    var smoothing = 0.4
    var palette: [RGBAColor] = []
    var globalColors: [GlobalColor] = []
    /// Opacity, gradient, clipping and global colors of the first selected shape.
    var appearance: ShapeAppearance?
    var canClip = false
    /// The width multiple at the selected anchors, while point-editing.
    var anchorWidth: Double?
    var pressureWidth = false
    /// Two fingers don't rotate the canvas, which keeps the viewport lined up with the screen.
    var rotationLocked = true
    var presentationName = ""
    /// The layers, then reference images.
    var layers = LayerTree(drawing: Drawing())
    var selectedLayer: Int?
    /// The whole layers selected (one or several), for the panel's multi-select.
    var selectedLayers: Set<Int> = []
    /// The layer new art goes into, and its name; nil when new art starts a new layer.
    var activeLayer: Int?
    var activeLayerName = ""
    /// True when the active layer is the one chosen in the layers panel (rather than
    /// isolation or auto-join), so it can be cleared from the canvas.
    var activeLayerIsChosen = false
    var selectedReference: Int?
    /// A short message such as "Undo" after a multi-finger tap, with a counter so
    /// repeats re-show it.
    var toast: (text: String, count: Int)?
    /// An SVG import is reading its file; the toast says "Importing..." until it ends.
    var isImporting = false
    var shapeKind: ShapeKind = .rectangle
    var shapeOptions = ShapeToolOptions()
    /// The on-screen modifier strip's latched keys.
    var stripModifiers: EditorModifiers = []
    /// The isolated layer's id, and the name of what isolation steps out of (the isolated
    /// group's name when editing inside a group, else the layer's), while isolating.
    var isolatedLayer: Int?
    var isolatedLayerName = ""
    var canGroup = false
    var canUngroup = false
    /// The group the selection is, when it is one whole group.
    var selectedGroupID: Int?
    var selectedGroupLayer: Int?
    var selectedGroupName = ""
    /// The selected group draws inside the shape below it, or could.
    var selectedGroupClipped = false
    var canClipSelectedGroup = false
    /// The other groups of the selected shapes' layer, for Add to Group.
    var groupsToAddTo: [ShapeGroup] = []
    /// The levels around the selection (layer, group, shapes), outermost first, and what
    /// the Select menu can do with it.
    var selectionCrumbs: [SelectionCrumb] = []
    var canSelectParent = false
    var canSelectAllInLayer = false
    var canInvertSelection = false
    var canSelectSame = false
    var canArrange = false
    var canHideOrLock = false
    var canMoveShapes = false
    var hasHiddenArt = false
    var hasLockedArt = false
    var recentColors: [RGBAColor] = []
    /// Where the Pencil squeeze (or double tap) palette is open, in canvas points.
    var palettePoint: CGPoint?

    var symmetry = SymmetrySettings()
    var canDuplicateMirrored = false

    // Workspace
    var outlineView = false
    var ghostsUnselected = false
    /// The stage the presentation shows.
    var viewport = Viewport()

    // Timeline
    var timeline = TimelineStrip()
    /// Chip thumbnails by keyframe id, 0 for the opening state.
    var thumbnails: [Int: UIImage] = [:]
    /// A keyframe is current, rather than the opening state.
    var isAtKeyframe = false
    var showsOnionSkin = false
    /// Play Sequence, or a transition's preview, is playing on the canvas.
    var isPlaying = false
    /// The keyframe whose transition is being scrubbed.
    var scrubbing: Int?
    /// The objects the current keyframe changes, which the layers panel marks.
    var changedObjects: Set<Int> = []
    /// What the current keyframe keys on the selection (see `DrawingEditor.keyedProperties`).
    var keyedProperties: Set<String> = []
    /// The style new text is set in, or the selected text's.
    var textStyle = TextContent()
    /// The selection holds a text, so the context bar shows its style.
    var selectionHasText = false
    /// The selection holds an image, which shows its picture in place of a fill.
    var selectionHasImage = false
    /// Text is being typed into on the canvas.
    var isEditingText = false
    var canConvertToOutlines = false
}

/// Owns the canvas session and connects SwiftUI controls to the Metal view.
/// The session itself is not observable on purpose: touches mutate it at 120 Hz and
/// SwiftUI should not re-render for each one. The view redraws through `onChange`,
/// and `ui` is refreshed when a gesture or command finishes.
@MainActor
final class CanvasStore {
    var session: CanvasSession
    /// The canvas view size in points, kept current by the view.
    var viewSize: CGSize = .zero
    /// Called whenever the canvas needs to redraw.
    var onChange: (() -> Void)?
    let ui = EditorUIState()
    /// Called with the document's new contents after each finished change, which
    /// marks the document edited so it autosaves.
    var onDocumentChange: ((PresentationPackage) -> Void)?
    /// Starts presentation mode, which the document's view owns.
    var onPresent: (() -> Void)?
    /// Encoded pixels (PNG or JPEG, as saved) for reference images, by id. Kept for
    /// the session so undo can bring a deleted reference back.
    private var referenceData: [Int: Data]
    /// Decoded pixels, filled on first use.
    private var decodedImages: [Int: CGImage] = [:]
    /// When to hand changes to the document, and the contents last handed to it.
    private var handOff: DocumentHandOff
    private var document: PresentationPackage
    /// Hands a held change (a color picker drag) to the document once it goes quiet.
    private var handOffTimer: Task<Void, Never>?
    /// Versions recently handed to the document, newest last. One of them coming back
    /// is the system undoing the document behind the editor (its three-finger swipe or
    /// shake), not an edit made elsewhere.
    private var sentDocuments: [PresentationPackage] = []
    private var seenTapCommands = 0
    /// The drawing revision `ui`'s drawing-wide values (layers, hidden and locked art,
    /// the viewport) were last read at.
    private var refreshedRevision: Int?
    private var toastCount = 0
    /// Play Sequence or a transition preview: the chain indices playing, and the time it
    /// started (from its first frame).
    private var playback: (range: ClosedRange<Int>, start: Double?)?
    /// Draws the chips' thumbnails once edits go quiet.
    private var thumbnailTask: Task<Void, Never>?
    /// The scenes the thumbnails show, by keyframe id (0 for the opening state).
    private var thumbnailScenes: [Int: Drawing] = [:]

    init(package: PresentationPackage = PresentationPackage()) {
        var options = InputOptions()
        #if targetEnvironment(simulator)
        // The Simulator has no Pencil, so a lone finger (mouse) draws there.
        options.fingerDraws = true
        #endif
        session = CanvasSession(options: options, presentation: package.presentation)
        session.editor.pressureWidth = UserDefaults.standard.bool(forKey: Self.pressureWidthKey)
        session.editor.snap.smartGuides = UserDefaults.standard.object(forKey: Self.smartGuidesKey) as? Bool ?? true
        session.setRotationLocked(Self.storedRotationLock, viewSize: .zero, animated: false)
        referenceData = package.referenceImages
        ImageLibrary.shared.add(package.images)
        document = package
        handOff = DocumentHandOff(revision: session.editor.documentRevision)
        sentDocuments = [package]
        refresh()
        noteMissingFonts(package.presentation)
    }

    /// The pixels for a reference image, decoded on first use.
    func referenceImage(_ id: Int) -> CGImage? {
        if let image = decodedImages[id] { return image }
        guard let data = referenceData[id] else { return nil }
        let decoded = Signposts.canvas.withIntervalSignpost("Reference decode") { UIImage(data: data)?.cgImage }
        guard let image = decoded else { return nil }
        decodedImages[id] = image
        return image
    }

    // MARK: Document

    /// Hands the drawing to the document once a change has finished. A `continuous`
    /// change (a color picker or slider tick) is held until the run goes quiet, since
    /// every hand-off leads to an autosave that encodes the drawing and renders its
    /// thumbnail (see `DocumentHandOff`).
    private func updateDocument(continuous: Bool = false) {
        let editor = session.editor
        guard !editor.isInGesture else { return }
        if handOff.changed(revision: editor.documentRevision, continuous: continuous, now: CACurrentMediaTime()) {
            handOffTimer?.cancel()
            sendDocument()
        } else if let due = handOff.due {
            handOffTimer?.cancel()
            handOffTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(due - CACurrentMediaTime(), 0) + 0.01))
                guard !Task.isCancelled else { return }
                self?.flushDocument(now: CACurrentMediaTime())
            }
        }
    }

    /// Hands a held change to the document: when it is due at `now`, or at once with no
    /// time, as the document closes or the app goes to the background.
    func flushDocument(now: Double? = nil) {
        guard !session.editor.isInGesture, handOff.flush(revision: session.editor.documentRevision, now: now) else { return }
        handOffTimer?.cancel()
        sendDocument()
    }

    /// Each hand-off leads the system to autosave, which runs "Save" and "Thumbnail".
    private func sendDocument() {
        let interval = Signposts.canvas.beginInterval("Hand off")
        defer { Signposts.canvas.endInterval("Hand off", interval) }
        let presentation = session.editor.presentation
        let references = referenceData.filter { id, _ in presentation.opening.referenceIndex(id) != nil }
        document = PresentationPackage(presentation: presentation, referenceImages: references,
                                       images: ImageLibrary.shared.data(for: presentation.imageSources))
        sentDocuments.append(document)
        if sentDocuments.count > 32 { sentDocuments.removeFirst() }
        onDocumentChange?(document)
    }

    /// Takes in a version of the document that changed outside the editor (for
    /// example, edited on another device). Undoable like any other change.
    func documentChanged(_ package: PresentationPackage) {
        let interval = Signposts.canvas.beginInterval("Document changed")
        defer { Signposts.canvas.endInterval("Document changed", interval) }
        guard package != document else { return }
        if sentDocuments.contains(package) {
            // The editor has its own undo; keep the canvas and put the document back in step.
            onDocumentChange?(document)
            return
        }
        ImageLibrary.shared.add(package.images)
        var presentation = package.presentation
        presentation.opening.nextID = max(presentation.opening.nextID, session.editor.drawing.nextID)
        // Fresh reference ids, so cached pixels and textures never mix up images.
        for i in presentation.opening.references.indices {
            let old = presentation.opening.references[i].id
            let new = presentation.opening.makeID()
            presentation.opening.references[i].id = new
            referenceData[new] = package.referenceImages[old]
        }
        edit { $0.editor.replacePresentation(presentation) }
        noteMissingFonts(presentation)
    }

    /// Copies editor state into `ui` and redraws. The values read from the whole
    /// drawing are read again only when the drawing changed. A `continuous` change is
    /// handed to the document once the run goes quiet.
    func refresh(continuous: Bool = false) {
        let interval = Signposts.canvas.beginInterval("Refresh")
        defer { Signposts.canvas.endInterval("Refresh", interval) }
        // A viewport turned between landscape and portrait turns the locked camera with it.
        session.keepRotationLocked(viewSize: Vec2(viewSize))
        update(\.rotationLocked, session.isRotationLocked)
        let editor = session.editor
        let revisionChanged = editor.revision != refreshedRevision
        if revisionChanged {
            refreshedRevision = editor.revision
            update(\.palette, editor.drawing.palette)
            update(\.globalColors, editor.drawing.globalColors)
            update(\.presentationName, editor.drawing.name)
            update(\.hasHiddenArt, editor.hasHiddenArt)
            update(\.hasLockedArt, editor.hasLockedArt)
            update(\.viewport, editor.drawing.viewport)
            update(\.layers, LayerTree(drawing: editor.drawing))
        }
        update(\.tool, editor.tool)
        update(\.canUndo, editor.canUndo)
        update(\.canRedo, editor.canRedo)
        let kind: EditorUIState.SelectionKind = switch editor.selection {
        case .none: .none
        case .layer, .layers: .layer
        case .shape, .shapes: .shape
        case .reference: .reference
        }
        update(\.selection, kind)
        if case .reference(let id) = editor.selection {
            update(\.selectedReference, id)
        } else {
            update(\.selectedReference, nil)
        }
        let editingPoints = editor.tool == .directSelect
        update(\.canDeleteAnchor, editingPoints && editor.canDeleteSelectedAnchor)
        update(\.anchorCount, editingPoints ? editor.selectedAnchors.count : 0)
        update(\.anchorMode, editingPoints ? editor.selectedAnchorMode : nil)
        update(\.edgesStroked, editingPoints ? editor.selectedEdgesStroked : nil)
        update(\.canSplit, editingPoints && editor.canSplitAtSelectedAnchor)
        update(\.canJoin, editor.canJoinSelection)
        update(\.canTransform, editor.canTransformSelection)
        update(\.canAlign, editor.canAlign)
        update(\.canDistribute, editor.canDistribute)
        update(\.alignsToViewportOnly, editor.alignsToViewportOnly)
        update(\.canApplyTransform, editor.canApplyTransform)
        update(\.penActive, editor.isPenActive)
        update(\.addToSelection, editor.addToSelection)
        update(\.autoJoin, editor.autoJoinSelectedLayer)
        update(\.snap, editor.snap)
        update(\.selectionBounds, editor.selectionGeometry)
        update(\.anchorPosition, editingPoints ? editor.selectedAnchorsCentroid : nil)
        update(\.style, editor.style)
        update(\.smoothing, editor.smoothing)
        update(\.appearance, editor.selectionAppearance)
        update(\.canClip, editor.canClipSelection)
        update(\.anchorWidth, editingPoints ? editor.selectedAnchorsWidth : nil)
        update(\.pressureWidth, editor.pressureWidth)
        update(\.shapeKind, editor.shapeKind)
        update(\.shapeOptions, editor.shapeOptions)
        update(\.isolatedLayer, editor.isolatedLayer)
        let isolatedName = editor.isolatedGroupInfo?.name ??
            editor.isolatedLayer.flatMap { id in editor.drawing.layers.first { $0.id == id }?.name } ?? ""
        update(\.isolatedLayerName, isolatedName)
        update(\.canGroup, editor.canGroupSelection)
        update(\.canUngroup, editor.canUngroupSelection)
        let group = editor.selectedGroup
        update(\.selectedGroupID, group?.group.id)
        update(\.selectedGroupLayer, group?.layer)
        update(\.selectedGroupName, group?.group.name ?? "")
        update(\.selectedGroupClipped, group?.group.isClipped ?? false)
        update(\.canClipSelectedGroup, group.map { editor.canClipGroup($0.group.id, inLayer: $0.layer) } ?? false)
        update(\.groupsToAddTo, editor.groupsToAddSelectionTo)
        update(\.selectionCrumbs, editor.selectionCrumbs)
        update(\.canSelectParent, editor.canSelectParent)
        update(\.canSelectAllInLayer, editor.canSelectAllInLayer)
        update(\.canInvertSelection, editor.canInvertSelection)
        update(\.canSelectSame, editor.canSelectSame)
        update(\.canArrange, editor.canArrange)
        update(\.canHideOrLock, editor.canHideOrLockSelection)
        update(\.canMoveShapes, editor.canMoveSelectedShapes)
        update(\.recentColors, editor.recentColors)
        update(\.symmetry, editor.symmetry)
        update(\.canDuplicateMirrored, editor.canDuplicateMirrored)
        update(\.outlineView, editor.outlineView)
        update(\.ghostsUnselected, editor.ghostsUnselected)
        update(\.selectedLayers, editor.selectedLayers)
        let strip = editor.timelineStrip
        let stripChanged = strip != ui.timeline
        update(\.timeline, strip)
        if revisionChanged || stripChanged {
            update(\.changedObjects, session.editor.changedObjects())
            scheduleThumbnails()
        }
        update(\.keyedProperties, session.editor.keyedProperties())
        update(\.textStyle, editor.textStyle)
        update(\.selectionHasText, editor.selectionHasText)
        update(\.selectionHasImage, editor.selectionHasImage)
        update(\.isEditingText, editor.textEdit != nil)
        update(\.canConvertToOutlines, editor.canConvertToOutlines)
        update(\.isAtKeyframe, editor.currentKeyframe != nil)
        update(\.showsOnionSkin, editor.showsOnionSkin)
        update(\.activeLayer, editor.activeLayer)
        update(\.activeLayerName, editor.activeLayer.flatMap { editor.drawing.layer($0)?.name } ?? "")
        update(\.activeLayerIsChosen, editor.activeLayer != nil && editor.activeLayer == editor.targetLayer &&
            editor.isolatedLayer == nil)
        if case .layer(let id) = editor.selection {
            update(\.selectedLayer, id)
        } else if case .shape(let id, _) = editor.selection {
            update(\.selectedLayer, id)
        } else if case .shapes(let refs) = editor.selection, Set(refs.map(\.layer)).count == 1 {
            update(\.selectedLayer, refs.first?.layer)
        } else {
            update(\.selectedLayer, nil)
        }
        if session.tapCommandCount != seenTapCommands {
            seenTapCommands = session.tapCommandCount
            showToast(session.lastTapCommand == .redo ? "Redo" : "Undo")
        }
        // An edit the editor refused says why, once.
        if let notice = editor.notice {
            session.editor.clearNotice()
            showToast(notice)
        }
        updateDocument(continuous: continuous)
        onChange?()
    }

    /// After a change to colors, opacity or outline width only, which a color picker or
    /// slider sends many of a second: copies just what such a change can alter. The
    /// drawing-wide values stay as they are (none of them depends on style), so they
    /// are not read again until something else changes the drawing.
    private func refreshStyle() {
        let interval = Signposts.canvas.beginInterval("Refresh style")
        defer { Signposts.canvas.endInterval("Refresh style", interval) }
        let editor = session.editor
        update(\.canUndo, editor.canUndo)
        update(\.canRedo, editor.canRedo)
        update(\.style, editor.style)
        update(\.appearance, editor.selectionAppearance)
        update(\.recentColors, editor.recentColors)
        update(\.palette, editor.drawing.palette)
        update(\.globalColors, editor.drawing.globalColors)
        update(\.keyedProperties, session.editor.keyedProperties())
        // The changed indicators and thumbnails follow once the run goes quiet.
        scheduleThumbnails()
        if refreshedRevision != nil { refreshedRevision = editor.revision }
        if let notice = editor.notice {
            session.editor.clearNotice()
            showToast(notice)
        }
        updateDocument(continuous: true)
        onChange?()
    }

    /// Shows a short message over the canvas.
    func showToast(_ text: String) {
        toastCount += 1
        ui.toast = (text, toastCount)
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<EditorUIState, T>, _ value: T) {
        if ui[keyPath: keyPath] != value { ui[keyPath: keyPath] = value }
    }

    /// A `continuous` edit (a keystroke or a slider tick, many a second) is handed to
    /// the document once the run goes quiet.
    private func edit(continuous: Bool = false, _ change: (inout CanvasSession) -> Void) {
        endPreview()
        Signposts.canvas.withIntervalSignpost("Edit") { change(&session) }
        refresh(continuous: continuous)
    }

    /// `edit` for a change that only restyles the selection or a global color.
    private func restyle(_ change: (inout CanvasSession) -> Void) {
        endPreview()
        Signposts.canvas.withIntervalSignpost("Edit") { change(&session) }
        refreshStyle()
    }

    // MARK: Tools and commands

    func setTool(_ tool: Tool) { edit { $0.editor.tool = tool } }

    // MARK: Text

    /// The text being typed into, for the canvas's text view.
    var textEdit: TextEditState? { session.editor.textEdit }
    var editedString: String? { session.editor.editedString }

    /// The text view's words and selection after the user typed, deleted, pasted,
    /// dictated or moved the caret.
    func setEditedText(_ string: String, selection: Range<Int>) {
        edit(continuous: true) { $0.editor.setEditedText(string, selection: selection) }
    }

    func setTextSelection(_ range: Range<Int>) { edit { $0.editor.setTextSelection(range) } }
    func endTextEdit() { edit { $0.editor.endTextEdit() } }
    /// Starts typing into text `ref` (Scribble writing into it).
    func beginTextEdit(_ ref: ShapeRef) { edit { $0.editor.beginTextEdit(ref) } }
    func setTextFont(_ name: String) { edit { $0.editor.setTextFont(name) } }
    func setTextSize(_ size: Double) { edit { $0.editor.setTextSize(size) } }
    func setTextWeight(_ weight: Int) { edit { $0.editor.setTextWeight(weight) } }
    func setTextItalic(_ italic: Bool) { edit { $0.editor.setTextItalic(italic) } }
    func setTextAlignment(_ align: ControlFlowCore.TextAlignment) { edit { $0.editor.setTextAlignment(align) } }
    func setTextLineHeight(_ lineHeight: Double) { edit { $0.editor.setTextLineHeight(lineHeight) } }
    func setTextTracking(_ tracking: Double) { edit { $0.editor.setTextTracking(tracking) } }
    func convertTextToOutlines() { edit { $0.editor.convertTextToOutlines() } }

    /// The text shapes on the canvas with their boxes in world space (four corners), for
    /// Scribble.
    func textFrames() -> [(ref: ShapeRef, frame: [Vec2])] {
        let drawing = session.editor.drawing
        var out: [(ref: ShapeRef, frame: [Vec2])] = []
        for layer in drawing.layers {
            for (s, shape) in layer.shapes.enumerated() where shape.text != nil && layer.isEditable(s) {
                guard let frame = layer.worldShape(s).textFrame else { continue }
                out.append((ShapeRef(layer: layer.id, shape: shape.id), frame))
            }
        }
        return out
    }

    /// Says once when a presentation uses fonts this iPad doesn't have.
    private func noteMissingFonts(_ presentation: Presentation) {
        var timeline = Timeline(presentation)
        var missing = Set<String>()
        for index in 0..<timeline.count {
            for layer in timeline.state(at: index).layers {
                for shape in layer.shapes {
                    if let text = shape.text, !TextShaping.hasFont(text) { missing.insert(text.font) }
                }
            }
        }
        guard !missing.isEmpty else { return }
        let names = missing.sorted().joined(separator: ", ")
        showToast("Not installed: \(names). Shown in the system font.")
    }
    func undo() { edit { $0.undo() } }
    func redo() { edit { $0.redo() } }
    func deleteSelection() { edit { $0.editor.deleteSelection() } }
    func deleteSelectedAnchors() { edit { $0.editor.deleteSelectedAnchors() } }
    func setAnchorMode(_ mode: HandleMode) { edit { $0.editor.setSelectedAnchorMode(mode) } }
    func breakAnchorHandles() { edit { $0.editor.breakSelectedAnchorHandles() } }
    func toggleEdgeOutline() { edit { $0.editor.toggleSelectedEdgesStroked() } }
    func splitAtAnchor() { edit { $0.editor.splitAtSelectedAnchor() } }
    func joinPaths() { edit { $0.editor.joinSelection() } }
    func penDone() { edit { $0.editor.penFinish() } }
    func setAddToSelection(_ on: Bool) { edit { $0.editor.addToSelection = on } }
    func setAutoJoin(_ on: Bool) { edit { $0.editor.autoJoinSelectedLayer = on } }
    /// Smart Guides are remembered on this iPad (on until turned off); the rest of Snap isn't.
    func setSnap(_ snap: SnapSettings) {
        UserDefaults.standard.set(snap.smartGuides, forKey: Self.smartGuidesKey)
        edit { $0.editor.snap = snap }
    }
    func setSmartGuides(_ on: Bool) {
        var snap = ui.snap
        snap.smartGuides = on
        setSnap(snap)
    }
    private static let smartGuidesKey = "smartGuides"
    func flip(horizontal: Bool) { edit { $0.editor.flipSelection(horizontal: horizontal) } }
    func applyTransform() { edit { $0.editor.applyTransform() } }
    func nudge(_ dx: Double, _ dy: Double) { edit { $0.editor.nudge(by: Vec2(dx, dy)) } }
    func resetPivot() { edit { $0.editor.resetPivot() } }
    func rotateSelection(degrees: Double) { edit { $0.editor.rotateSelection(byDegrees: degrees) } }
    func setSelectionX(_ x: Double) { edit { $0.editor.setSelectionOrigin(x: x) } }
    func setSelectionY(_ y: Double) { edit { $0.editor.setSelectionOrigin(y: y) } }
    func setSelectionWidth(_ width: Double) { edit { $0.editor.setSelectionSize(width: width) } }
    func setSelectionHeight(_ height: Double) { edit { $0.editor.setSelectionSize(height: height) } }
    func setAnchorX(_ x: Double) { edit { $0.editor.setSelectedAnchorsPosition(x: x) } }
    func setAnchorY(_ y: Double) { edit { $0.editor.setSelectedAnchorsPosition(y: y) } }
    func clear() { edit { $0.clear() } }
    func deselect() { edit { $0.editor.selection = .none } }
    func setShapeKind(_ kind: ShapeKind) { edit { $0.editor.shapeKind = kind } }
    func setShapeOptions(_ options: ShapeToolOptions) { edit { $0.editor.shapeOptions = options } }
    func switchToPreviousTool() { edit { $0.editor.switchToPreviousTool() } }
    func toggleEraser() { edit { $0.editor.toggleEraser() } }

    // MARK: Modifiers

    /// Keys held on a hardware keyboard, read at each touch.
    private var keyboardModifiers: EditorModifiers = []

    func setStripModifiers(_ modifiers: EditorModifiers) {
        ui.stripModifiers = modifiers
        applyModifiers()
    }

    func setKeyboardModifiers(_ flags: UIKeyModifierFlags) {
        var modifiers: EditorModifiers = []
        if flags.contains(.shift) { modifiers.insert(.constrain) }
        if flags.contains(.alternate) { modifiers.insert(.alternate) }
        keyboardModifiers = modifiers
        applyModifiers()
    }

    private func applyModifiers() {
        session.editor.modifiers = ui.stripModifiers.union(keyboardModifiers)
    }

    // MARK: Organize

    func duplicate() { edit { $0.editor.duplicateSelection() } }
    func arrange(_ move: ArrangeMove) { edit { $0.editor.arrange(move) } }
    func align(_ edge: AlignEdge) { let target = ui.alignTarget; edit { $0.editor.align(edge, to: target) } }
    func distribute(_ mode: DistributeMode) { let target = ui.alignTarget; edit { $0.editor.distribute(mode, to: target) } }
    func setAlignTarget(_ target: AlignTarget) { ui.alignTarget = target }
    func hideSelection() { edit { $0.editor.hideSelection() } }
    func lockSelection() { edit { $0.editor.lockSelection() } }
    func showAll() { edit { $0.editor.showAll() } }
    func unlockAll() { edit { $0.editor.unlockAll() } }
    func setLayerHidden(_ id: Int, _ hidden: Bool) { edit { $0.editor.setLayerHidden(id, hidden) } }
    func setLayerLocked(_ id: Int, _ locked: Bool) { edit { $0.editor.setLayerLocked(id, locked) } }
    func isolate(layer id: Int) { edit { $0.editor.isolate(layer: id) } }
    func exitIsolation() { edit { $0.editor.exitIsolation() } }
    /// One level out: from a group to its layer, from a layer to the whole document, else deselect.
    func stepOutOfIsolation() { edit { $0.editor.stepOutOfIsolation() } }
    func groupSelection() { edit { $0.editor.groupSelection() } }
    func ungroupSelection() { edit { $0.editor.ungroupSelection() } }
    func renameGroup(_ id: Int, inLayer layer: Int, to name: String) {
        edit { $0.editor.renameGroup(id, inLayer: layer, to: name) }
    }
    func addSelection(toGroup id: Int) { edit { $0.editor.addSelection(toGroup: id) } }
    func selectParent() { edit { $0.editor.selectParent() } }
    func selectCrumb(_ level: SelectionCrumb.Level) { edit { $0.editor.selectCrumb(level) } }
    func selectAllInLayer() { edit { $0.editor.selectAllInLayer() } }
    func invertSelection() { edit { $0.editor.invertSelection() } }
    func selectSameFill() { edit { $0.editor.selectSameFill() } }
    func selectSameOutline() { edit { $0.editor.selectSameOutline() } }
    func mergeLayerDown(_ id: Int) { edit { $0.editor.mergeLayerDown(id) } }
    func moveSelectionToNewLayer() { edit { $0.editor.moveSelectionToNewLayer() } }
    func moveSelection(toLayer id: Int) { edit { $0.editor.moveSelection(toLayer: id) } }
    func setLayerOrder(frontToBack ids: [Int]) { edit { $0.editor.setLayerOrder(frontToBack: ids) } }
    func canMergeLayerDown(_ id: Int) -> Bool { session.editor.canMergeLayerDown(id) }

    /// Isolates the selected layer (or the layer of the selected shapes).
    func isolateSelection() {
        guard let id = ui.selectedLayer else { return }
        isolate(layer: id)
    }

    // MARK: Symmetry

    func setSymmetryEnabled(_ on: Bool) { edit { $0.editor.symmetry.isEnabled = on } }
    func centerSymmetryAxis() { edit { $0.editor.centerSymmetryAxis() } }
    func resetSymmetryAxis() { edit { $0.editor.symmetry.axis = 0 } }
    func duplicateMirrored() { edit { $0.editor.duplicateMirrored() } }

    // MARK: View options and the viewport

    func setOutlineView(_ on: Bool) { edit { $0.editor.outlineView = on } }
    func setGhostsUnselected(_ on: Bool) { edit { $0.editor.ghostsUnselected = on } }

    /// A viewport edit; edits of one field in a row are one undo step. A `continuous`
    /// one (a color picker drag) is handed to the document once the run goes quiet.
    func updateViewport(_ field: String, continuous: Bool = false, _ change: (inout Viewport) -> Void) {
        edit(continuous: continuous) { $0.editor.updateViewport(coalescingKey: field, change) }
    }

    /// Gives the viewport a preset aspect, keeping its width.
    func setViewportAspect(_ aspect: Viewport.Aspect) { edit { $0.editor.setViewportAspect(aspect.ratio) } }

    /// Fits the viewport in the view.
    func zoomToFit() {
        session.zoom(toFit: session.editor.drawing.viewport.bounds, viewSize: Vec2(viewSize))
        onChange?()
    }

    // MARK: Timeline

    func selectKeyframe(_ id: Int?) { edit { $0.editor.selectKeyframe(id) } }
    func setKeyframe() { edit { _ = $0.editor.setKeyframe() } }
    func newSequence() { edit { _ = $0.editor.newSequence() } }
    func splitSequence(at id: Int) { edit { $0.editor.splitSequence(at: id) } }
    func mergeSequenceWithNext(_ id: Int) { edit { $0.editor.mergeSequenceWithNext(id) } }
    func deleteKeyframe(_ id: Int) { edit { $0.editor.deleteKeyframe(id) } }
    func deleteSequence(_ id: Int) { edit { $0.editor.deleteSequence(id) } }
    func revertKeyframe(_ id: Int) { edit { $0.editor.revertKeyframe(id) } }
    func duplicateKeyframe(_ id: Int) { edit { $0.editor.duplicateKeyframe(id) } }
    func renameKeyframe(_ id: Int, to name: String) { edit { $0.editor.renameKeyframe(id, to: name) } }
    func renameSequence(_ id: Int, to name: String) { edit { $0.editor.renameSequence(id, to: name) } }
    func revertSelectionToPrevious() { edit { $0.editor.revertSelectionToPrevious() } }
    func setOnionSkin(_ on: Bool) { edit { $0.editor.showsOnionSkin = on } }

    /// Moves keyframe `id` in front of keyframe `target` (into its sequence), or to the
    /// end of sequence `sequence` when there is no target.
    func moveKeyframe(_ id: Int, before target: Int?, inSequence sequence: Int) {
        guard id != target else { return }
        let position = ui.timeline.sequences.first { $0.id == sequence }.map { block in
            target.flatMap { t in block.chips.firstIndex { $0.id == t } } ?? block.chips.count
        }
        guard let position else { return }
        edit { $0.editor.moveKeyframe(id, toSequence: sequence, at: position) }
    }

    /// Sets a keyframe's transition. Changes with `continuous` in a row (a slider or a
    /// curve handle drag) are one undo step.
    func setTransition(_ transition: ControlFlowCore.Transition, ofKeyframe id: Int, continuous: Bool = false) {
        edit { $0.editor.setTransition(transition, ofKeyframe: id, continuous: continuous) }
    }

    var isPlaying: Bool { playback != nil }

    /// Play Sequence: plays sequence `id` (by default the current keyframe's) from the
    /// end of the one before it, on the canvas, then shows the current keyframe again.
    func playSequence(_ id: Int? = nil) {
        guard let range = id.map({ session.editor.chainRange(ofSequence: $0) }) ?? session.editor.currentSequenceRange
        else { return }
        startPlaying(range)
    }

    /// Plays the transition into keyframe `id` once, as the transition popover's preview.
    func previewTransition(into id: Int) {
        guard let index = session.editor.chainIndex(ofKeyframe: id) else { return }
        startPlaying(index...index)
    }

    private func startPlaying(_ range: ClosedRange<Int>) {
        endPreview()
        playback = (range, nil)
        update(\.isPlaying, true)
        session.editor.playPreview(range, at: 0)
        onChange?()
    }

    /// Shows the frame `time` (display time, in seconds) into the playback. The canvas
    /// calls this on each display refresh while `isPlaying`.
    func playbackFrame(at time: Double) {
        guard var playing = playback else { return }
        let start = playing.start ?? time
        playing.start = start
        playback = playing
        if session.editor.playPreview(playing.range, at: time - start) { stopPlaying() }
    }

    /// Present: presentation mode, from the opening state.
    func present() { onPresent?() }

    func stopPlaying() {
        guard playback != nil else { return }
        endPreview()
    }

    /// Scrubbing: shows the scene `fraction` (0...1) of the way through the transition
    /// into keyframe `id`. The canvas is view-only until `endScrub()`.
    func scrub(into id: Int, fraction: Double) {
        if playback != nil { endPreview() }
        update(\.scrubbing, id)
        session.editor.scrubPreview(into: id, fraction: fraction)
        onChange?()
    }

    /// Lifting off a transition handle returns to the current keyframe.
    func endScrub() { endPreview() }

    /// Ends playing or scrubbing and shows the current keyframe.
    private func endPreview() {
        guard playback != nil || ui.scrubbing != nil || session.editor.preview != nil else { return }
        playback = nil
        update(\.isPlaying, false)
        update(\.scrubbing, nil)
        session.editor.endPreview()
        onChange?()
    }

    /// Draws the chips' thumbnails again once edits have gone quiet, for the keyframes
    /// whose scene changed since, and updates the changed indicators.
    private func scheduleThumbnails() {
        thumbnailTask?.cancel()
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.updateThumbnails()
        }
    }

    private func updateThumbnails() async {
        guard !session.editor.isInGesture else {
            scheduleThumbnails()
            return
        }
        update(\.changedObjects, session.editor.changedObjects())
        let ids = [0] + ui.timeline.chips.map(\.id)
        let live = Set(ids)
        thumbnailScenes = thumbnailScenes.filter { live.contains($0.key) }
        if ui.thumbnails.keys.contains(where: { !live.contains($0) }) {
            ui.thumbnails = ui.thumbnails.filter { live.contains($0.key) }
        }
        var pending: [(id: Int, scene: Drawing)] = []
        for id in ids {
            let scene = session.editor.state(atKeyframe: id == 0 ? nil : id)
            if thumbnailScenes[id] != scene { pending.append((id, scene)) }
        }
        for (id, scene) in pending {
            let png = await Task.detached(priority: .utility) { Self.thumbnail(of: scene) }.value
            guard !Task.isCancelled else { return }
            thumbnailScenes[id] = scene
            ui.thumbnails[id] = png.flatMap { UIImage(data: $0) }
        }
    }

    /// A chip's picture of the viewport, 160 pixels on its long side (a chip is at most
    /// 72 points wide).
    nonisolated private static func thumbnail(of scene: Drawing) -> Data? {
        let area = scene.viewport.bounds
        return ThumbnailRenderer.exportPNG(for: scene, area: area, scale: 160 / max(area.width, area.height, 1))
    }

    // MARK: Import and export

    /// Reads SVG art into new layers on top, selects them and fits them in the view.
    /// The file is parsed off the main thread, with "Importing..." showing meanwhile;
    /// a second import while one runs is ignored. Returns an error message when nothing
    /// could be imported.
    func importSVG(_ data: Data, name: String) async -> String? {
        guard !ui.isImporting else { return nil }
        ui.isImporting = true
        defer { ui.isImporting = false }
        let interval = Signposts.canvas.beginInterval("SVG import")
        defer { Signposts.canvas.endInterval("SVG import", interval) }
        let parsed = await Task.detached(priority: .userInitiated) { () -> Result<SVGImportResult, Error> in
            Result { try SVGImporter.parse(String(decoding: data, as: UTF8.self), name: name) }
        }.value
        let result: SVGImportResult
        switch parsed {
        case .success(let value):
            result = value
        case .failure(let error):
            return (error as? SVGImportError)?.description ?? error.localizedDescription
        }
        edit { _ = $0.editor.importLayers(result.layers) }
        let editor = session.editor
        let bounds = editor.drawing.shapeIndices(in: editor.selection).reduce(Rect.null) {
            $0.union(editor.drawing.layers[$1.0].worldShape($1.1).bounds)
        }
        if !bounds.isNull {
            session.zoom(toFit: bounds, viewSize: Vec2(viewSize))
            onChange?()
        }
        let layers = result.layers.count == 1 ? "1 layer" : "\(result.layers.count) layers"
        var message = "Imported \(layers)"
        if !result.skipped.isEmpty {
            let skipped = result.skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            message += "; skipped " + skipped.joined(separator: ", ")
        }
        showToast(message)
        return nil
    }

    /// The art as SVG, over the viewport, with its pictures embedded.
    func svgData() -> Data? {
        let images = ImageLibrary.shared.data(for: session.editor.drawing.imageSources)
        return Signposts.canvas.withIntervalSignpost("SVG export") {
            session.editor.svgDocument(images: images).map { Data($0.utf8) }
        }
    }

    /// The presentation as a static web page's files (see `HTMLExport`), or nil if the
    /// player is missing from the build.
    func htmlFiles() -> [String: Data]? {
        let presentation = session.editor.presentation
        let images = ImageLibrary.shared.data(for: presentation.imageSources)
        return Signposts.canvas.withIntervalSignpost("HTML export") { try? HTMLExport.files(for: presentation, images: images) }
    }

    /// The viewport as a PNG at `scale` pixels per point: its background and the art.
    func pngData(scale: Double) -> Data? {
        let drawing = session.editor.drawing
        guard let area = drawing.exportArea() else { return nil }
        return Signposts.canvas.withIntervalSignpost("PNG export") {
            ThumbnailRenderer.exportPNG(for: drawing, area: area, scale: scale)
        }
    }

    // MARK: Clipboard

    /// Puts the selection on the pasteboard as document JSON, under the app's own type
    /// and as plain JSON, so it pastes into any document (and reads anywhere).
    func copy() {
        if session.editor.textEdit != nil {
            if let words = selectedWords { UIPasteboard.general.string = words }
            return
        }
        guard let text = session.editor.copySelection() else { return }
        Self.putOnPasteboard(text)
    }

    func cut() {
        if session.editor.textEdit != nil {
            guard let words = selectedWords else { return }
            UIPasteboard.general.string = words
            edit { $0.editor.typeText("") }
            return
        }
        var text: String?
        edit { text = $0.editor.cutSelection() }
        if let text { Self.putOnPasteboard(text) }
    }

    /// The words selected in the text being typed into, if any.
    private var selectedWords: String? {
        guard let edit = session.editor.textEdit, !edit.selection.isEmpty,
              let string = session.editor.editedString else { return nil }
        let units = Array(string.utf16)
        let range = min(edit.selection.lowerBound, units.count)..<min(edit.selection.upperBound, units.count)
        return String(decoding: units[range], as: UTF16.self)
    }

    func paste() {
        let board = UIPasteboard.general
        if session.editor.textEdit != nil {
            // Into the text being typed into, as words.
            if let words = board.string { edit { $0.editor.typeText(words) } }
            return
        }
        let data = board.data(forPasteboardType: DrawingEditor.clipboardType)
            ?? board.data(forPasteboardType: UTType.json.identifier)
        guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }) ?? board.string else { return }
        edit { _ = $0.editor.paste(text) }
    }

    private static func putOnPasteboard(_ text: String) {
        let data = Data(text.utf8)
        UIPasteboard.general.setItems([[DrawingEditor.clipboardType: data, UTType.json.identifier: data]])
    }

    // MARK: Pencil palette

    func showPalette(at point: CGPoint?) {
        let size = viewSize
        ui.palettePoint = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
    }

    func hidePalette() { ui.palettePoint = nil }

    func resetView() {
        session.resetView(viewSize: Vec2(viewSize))
        onChange?()
    }

    // MARK: Rotation lock

    private static let rotationLockKey = "rotationLocked"

    /// The rotation lock, remembered on this iPad. On until turned off.
    static var storedRotationLock: Bool {
        UserDefaults.standard.object(forKey: rotationLockKey) as? Bool ?? true
    }

    /// Turning it on snaps the canvas to the nearest allowed quarter turn, animated.
    func setRotationLocked(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.rotationLockKey)
        session.setRotationLocked(on, viewSize: Vec2(viewSize))
        update(\.rotationLocked, session.isRotationLocked)
        onChange?()
    }

    /// The canvas view changed size, turning with the iPad by `interfaceTurn` degrees.
    func viewDidResize(from old: CGSize, to new: CGSize, interfaceTurn: Double?) {
        session.viewDidResize(from: Vec2(old), to: Vec2(new), interfaceTurn: interfaceTurn)
        onChange?()
    }

    /// Moves the lock's snapping turn on to display time `time`.
    func stepTurn(at time: Double) {
        session.stepTurn(at: time)
    }

    // MARK: Style

    func setFill(_ color: Color) { restyle { $0.editor.setFill(RGBAColor(color), continuous: true) } }
    func setFillEnabled(_ on: Bool) { edit { $0.editor.setFillEnabled(on) } }
    func setOutline(_ color: Color) { restyle { $0.editor.setOutline(RGBAColor(color), continuous: true) } }
    func setOutlineWidth(_ width: Double) { restyle { $0.editor.setOutlineWidth(width) } }
    func setOutlineEnabled(_ on: Bool) { edit { $0.editor.setOutlineEnabled(on) } }
    func setSmoothing(_ amount: Double) { edit { $0.editor.smoothing = amount } }

    func addFillToPalette() { edit { $0.editor.addToPalette($0.editor.style.fill) } }
    func addOutlineToPalette() { edit { $0.editor.addToPalette($0.editor.style.outline) } }
    func removeFromPalette(at index: Int) { edit { $0.editor.removeFromPalette(at: index) } }
    func applyPaletteFill(_ color: RGBAColor) { edit { $0.editor.setFill(color) } }
    func applyPaletteOutline(_ color: RGBAColor) { edit { $0.editor.setOutline(color) } }

    // MARK: Appearance

    private static let pressureWidthKey = "pressureWidth"

    func setOutlineCap(_ cap: LineCap) { edit { $0.editor.setOutlineCap(cap) } }
    func setOutlineJoin(_ join: LineJoin) { edit { $0.editor.setOutlineJoin(join) } }
    func setMiterLimit(_ limit: Double) { edit { $0.editor.setMiterLimit(limit) } }
    func setOutlineDash(_ dash: [Double]) { edit { $0.editor.setOutlineDash(dash) } }
    func setOutlineAlignment(_ alignment: StrokeAlignment) { edit { $0.editor.setOutlineAlignment(alignment) } }
    func setOpacity(_ opacity: Double) { restyle { $0.editor.setOpacity(opacity) } }
    func setClipped(_ clipped: Bool) { edit { $0.editor.setClipped(clipped) } }
    func setGradient(_ kind: ShapeGradient.Kind?) { edit { $0.editor.setGradient(kind) } }
    func setGradientStop(_ index: Int, _ color: Color) { restyle { $0.editor.setGradientStop(index, color: RGBAColor(color)) } }
    func setGradientAngle(_ degrees: Double) { restyle { $0.editor.setGradientAngle(degrees) } }
    func setGradientSpan(_ fraction: Double) { restyle { $0.editor.setGradientSpan(fraction) } }
    func reverseGradient() { edit { $0.editor.reverseGradient() } }
    func setAnchorWidth(_ width: Double) { edit(continuous: true) { $0.editor.setSelectedAnchorsWidth(width) } }
    func resetOutlineWidths() { edit { $0.editor.resetOutlineWidths() } }

    /// Pencil pressure sets the outline width along new strokes. Remembered on this iPad.
    func setPressureWidth(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.pressureWidthKey)
        edit { $0.editor.pressureWidth = on }
    }

    // MARK: Global colors

    func addGlobalColorFromFill() { edit { _ = $0.editor.addGlobalColor($0.editor.style.fill) } }
    func renameGlobalColor(_ id: Int, to name: String) { edit { $0.editor.renameGlobalColor(id, to: name) } }
    func setGlobalColor(_ id: Int, _ color: Color) {
        restyle { $0.editor.setGlobalColor(id, to: RGBAColor(color), continuous: true) }
    }
    func removeGlobalColor(_ id: Int) { edit { $0.editor.removeGlobalColor(id) } }
    func applyGlobalFill(_ id: Int) { edit { $0.editor.applyGlobalFill(id) } }
    func applyGlobalOutline(_ id: Int) { edit { $0.editor.applyGlobalOutline(id) } }

    // MARK: Layers

    func selectLayer(_ id: Int) { edit { $0.editor.selectLayer(id) } }

    /// Selects layer `id` and makes it the one new art goes into, as tapping its name in
    /// the layers panel does.
    func activateLayer(_ id: Int) {
        edit {
            $0.editor.selectLayer(id)
            $0.editor.setActiveLayer(id)
        }
    }

    /// Back to starting a new layer for each new piece of art.
    func clearActiveLayer() { edit { $0.editor.setActiveLayer(nil) } }
    func selectLayers(_ ids: Set<Int>) { edit { $0.editor.selectLayers(ids) } }
    func moveTreeRow(from source: Int, to destination: Int, in rows: [LayerTree.Row]) {
        edit { $0.editor.moveTreeRow(from: source, to: destination, in: rows) }
    }
    func selectGroup(_ id: Int, inLayer layer: Int) { edit { $0.editor.selectGroup(id, inLayer: layer) } }
    func setGroupHidden(_ id: Int, inLayer layer: Int, _ hidden: Bool) {
        edit { $0.editor.setGroupHidden(id, inLayer: layer, hidden) }
    }
    func setGroupLocked(_ id: Int, inLayer layer: Int, _ locked: Bool) {
        edit { $0.editor.setGroupLocked(id, inLayer: layer, locked) }
    }
    func setGroupClipped(_ id: Int, inLayer layer: Int, _ clipped: Bool) {
        edit { $0.editor.setGroupClipped(id, inLayer: layer, clipped) }
    }
    func renameLayer(_ id: Int, to name: String) { edit { $0.editor.renameLayer(id, to: name) } }
    func deleteLayer(_ id: Int) { edit { $0.editor.deleteLayer(id) } }
    func renamePresentation(_ name: String) { edit { $0.editor.renamePresentation(name) } }

    // MARK: Reference images

    /// Adds a reference image under the art, fitted to the middle of the view.
    func importReference(data: Data, name: String) {
        guard let cgImage = Self.normalized(data), let encoded = Self.encoded(cgImage) else { return }
        let size = Vec2(Double(cgImage.width), Double(cgImage.height))
        let view = viewSize.width > 0 ? Vec2(viewSize) : Vec2(1024, 768)
        let camera = session.camera
        // Shrink large images to fit on screen; never enlarge small ones.
        let scale = min(view.x * 0.7 / size.x, view.y * 0.7 / size.y, 1) / camera.zoom
        let center = camera.toWorld(view / 2)
        var id = 0
        edit { id = $0.editor.addReference(name: name, size: size, center: center, scale: scale) }
        referenceData[id] = encoded
        decodedImages[id] = cgImage
        // The reference was added before its pixels were stored, so save again.
        handOff = DocumentHandOff(revision: -1)
        refresh()
    }

    func setReferenceOpacity(_ id: Int, _ opacity: Double) {
        edit { $0.editor.updateReference(id, coalescingKey: "opacity") { $0.opacity = opacity } }
    }

    func setReferenceHidden(_ id: Int, _ hidden: Bool) {
        edit { $0.editor.updateReference(id) { $0.isHidden = hidden } }
    }

    func adjustReference(_ id: Int) { edit { $0.editor.adjustReference(id) } }

    func removeReference(_ id: Int) {
        edit {
            $0.editor.selection = .reference(id)
            $0.editor.deleteSelection()
        }
    }

    // MARK: Images

    /// Adds a picture as an image shape in the middle of the view, shrunk to fit the
    /// view and the viewport if it is larger, and selects it with Select so it can be
    /// placed at once. Its opacity, place and size animate like any shape's.
    func insertImage(data: Data) {
        // Decoding, scaling and re-encoding a photo takes tens of milliseconds, so it
        // happens off the main thread and the image lands when it is ready.
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { Self.prepared(data) }.value
            guard let prepared else {
                showToast("Couldn't read that image")
                return
            }
            let src = ImageLibrary.shared.add(prepared.encoded)
            let pixels = prepared.pixels
            let view = viewSize.width > 0 ? Vec2(viewSize) : Vec2(1024, 768)
            let camera = session.camera
            let stage = session.editor.drawing.viewport
            // A pixel is a point, unless that is more than most of the view or the viewport.
            let fit = min(view.x * 0.7 / camera.zoom / pixels.x, view.y * 0.7 / camera.zoom / pixels.y,
                          stage.width * 0.8 / pixels.x, stage.height * 0.8 / pixels.y, 1)
            let center = camera.toWorld(view / 2)
            edit { $0.editor.addImage(ShapeImage(src: src), size: pixels * fit, center: center) }
        }
    }

    /// An image's bytes as the document keeps them (see `encoded`), and its size in pixels.
    private struct PreparedImage: Sendable {
        var encoded: Data
        var pixels: Vec2
    }

    /// Made with ImageIO rather than UIKit, so it is safe off the main thread.
    nonisolated private static func prepared(_ data: Data) -> PreparedImage? {
        guard let cgImage = Self.normalized(data), let bytes = Self.encoded(cgImage) else { return nil }
        return PreparedImage(encoded: bytes, pixels: Vec2(Double(cgImage.width), Double(cgImage.height)))
    }

    /// Decodes the image with its orientation baked in and its size capped at 4096
    /// pixels on the long side.
    nonisolated private static func normalized(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0
        else { return nil }
        return image
    }

    nonisolated private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// PNG for images with transparency, otherwise JPEG to keep photos small.
    nonisolated private static func encoded(_ image: CGImage) -> Data? {
        let png = hasAlpha(image)
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, type, 1, nil) else { return nil }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension Vec2 {
    init(_ p: CGPoint) { self.init(Double(p.x), Double(p.y)) }
    init(_ s: CGSize) { self.init(Double(s.width), Double(s.height)) }
}

extension RGBAColor {
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        func clamp(_ v: CGFloat) -> Double { min(max(Double(v), 0), 1) }
        self.init(r: clamp(r), g: clamp(g), b: clamp(b), a: clamp(a))
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
