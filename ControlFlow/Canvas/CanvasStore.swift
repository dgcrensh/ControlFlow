import ControlFlowCore
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
    var presentationName = ""
    /// The layers, then reference images.
    var layers = LayerTree(drawing: Drawing())
    var selectedPart: Int?
    /// The whole layers selected (one or several), for the panel's multi-select.
    var selectedLayers: Set<Int> = []
    /// The layer new art goes into, and its name; nil when new art starts a new part.
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
    /// The isolated part's id, and the name of what isolation steps out of (the isolated
    /// group's name when editing inside a group, else the part's), while isolating.
    var isolatedPart: Int?
    var isolatedPartName = ""
    var canGroup = false
    var canUngroup = false
    /// The group the selection is, when it is one whole group.
    var selectedGroupID: Int?
    var selectedGroupPart: Int?
    var selectedGroupName = ""
    /// The selected group draws inside the shape below it, or could.
    var selectedGroupClipped = false
    var canClipSelectedGroup = false
    /// The other groups of the selected shapes' part, for Add to Group.
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
    var onDocumentChange: ((CharacterPackage) -> Void)?
    /// Encoded pixels (PNG or JPEG, as saved) for reference images, by id. Kept for
    /// the session so undo can bring a deleted reference back.
    private var referenceData: [Int: Data]
    /// Decoded pixels, filled on first use.
    private var decodedImages: [Int: CGImage] = [:]
    /// When to hand changes to the document, and the contents last handed to it.
    private var handOff: DocumentHandOff
    private var document: CharacterPackage
    /// Hands a held change (a color picker drag) to the document once it goes quiet.
    private var handOffTimer: Task<Void, Never>?
    /// Versions recently handed to the document, newest last. One of them coming back
    /// is the system undoing the document behind the editor (its three-finger swipe or
    /// shake), not an edit made elsewhere.
    private var sentDocuments: [CharacterPackage] = []
    private var seenTapCommands = 0
    /// The drawing revision `ui`'s drawing-wide values (layers, hidden and locked art,
    /// the viewport) were last read at.
    private var refreshedRevision: Int?
    private var toastCount = 0

    init(package: CharacterPackage = CharacterPackage()) {
        var options = InputOptions()
        #if targetEnvironment(simulator)
        // The Simulator has no Pencil, so a lone finger (mouse) draws there.
        options.fingerDraws = true
        #endif
        session = CanvasSession(options: options, drawing: package.drawing)
        session.editor.pressureWidth = UserDefaults.standard.bool(forKey: Self.pressureWidthKey)
        referenceData = package.referenceImages
        document = package
        handOff = DocumentHandOff(revision: session.editor.revision)
        sentDocuments = [package]
        refresh()
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
        if handOff.changed(revision: editor.revision, continuous: continuous, now: CACurrentMediaTime()) {
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
        guard !session.editor.isInGesture, handOff.flush(revision: session.editor.revision, now: now) else { return }
        handOffTimer?.cancel()
        sendDocument()
    }

    /// Each hand-off leads the system to autosave, which runs "Save" and "Thumbnail".
    private func sendDocument() {
        let interval = Signposts.canvas.beginInterval("Hand off")
        defer { Signposts.canvas.endInterval("Hand off", interval) }
        let drawing = session.editor.drawing
        let images = referenceData.filter { id, _ in drawing.referenceIndex(id) != nil }
        document = CharacterPackage(drawing: drawing, referenceImages: images)
        sentDocuments.append(document)
        if sentDocuments.count > 32 { sentDocuments.removeFirst() }
        onDocumentChange?(document)
    }

    /// Takes in a version of the document that changed outside the editor (for
    /// example, edited on another device). Undoable like any other change.
    func documentChanged(_ package: CharacterPackage) {
        let interval = Signposts.canvas.beginInterval("Document changed")
        defer { Signposts.canvas.endInterval("Document changed", interval) }
        guard package != document else { return }
        if sentDocuments.contains(package) {
            // The editor has its own undo; keep the canvas and put the document back in step.
            onDocumentChange?(document)
            return
        }
        var drawing = package.drawing
        drawing.nextID = max(drawing.nextID, session.editor.drawing.nextID)
        // Fresh reference ids, so cached pixels and textures never mix up images.
        for i in drawing.references.indices {
            let old = drawing.references[i].id
            let new = drawing.makeID()
            drawing.references[i].id = new
            referenceData[new] = package.referenceImages[old]
        }
        edit { $0.editor.replaceDrawing(drawing) }
    }

    /// Copies editor state into `ui` and redraws. The values read from the whole
    /// drawing are read again only when the drawing changed. A `continuous` change is
    /// handed to the document once the run goes quiet.
    func refresh(continuous: Bool = false) {
        let interval = Signposts.canvas.beginInterval("Refresh")
        defer { Signposts.canvas.endInterval("Refresh", interval) }
        let editor = session.editor
        if editor.revision != refreshedRevision {
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
        update(\.penActive, editor.isPenActive)
        update(\.addToSelection, editor.addToSelection)
        update(\.autoJoin, editor.autoJoinSelectedPart)
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
        update(\.isolatedPart, editor.isolatedPart)
        let isolatedName = editor.isolatedGroupInfo?.name ??
            editor.isolatedPart.flatMap { id in editor.drawing.parts.first { $0.id == id }?.name } ?? ""
        update(\.isolatedPartName, isolatedName)
        update(\.canGroup, editor.canGroupSelection)
        update(\.canUngroup, editor.canUngroupSelection)
        let group = editor.selectedGroup
        update(\.selectedGroupID, group?.group.id)
        update(\.selectedGroupPart, group?.part)
        update(\.selectedGroupName, group?.group.name ?? "")
        update(\.selectedGroupClipped, group?.group.isClipped ?? false)
        update(\.canClipSelectedGroup, group.map { editor.canClipGroup($0.group.id, inPart: $0.part) } ?? false)
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
        update(\.activeLayer, editor.activeLayer)
        update(\.activeLayerName, editor.activeLayer.flatMap { editor.drawing.part($0)?.name } ?? "")
        update(\.activeLayerIsChosen, editor.activeLayer != nil && editor.activeLayer == editor.targetLayer &&
            editor.isolatedPart == nil)
        if case .layer(let id) = editor.selection {
            update(\.selectedPart, id)
        } else if case .shape(let id, _) = editor.selection {
            update(\.selectedPart, id)
        } else if case .shapes(let refs) = editor.selection, Set(refs.map(\.part)).count == 1 {
            update(\.selectedPart, refs.first?.part)
        } else {
            update(\.selectedPart, nil)
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

    private func edit(_ change: (inout CanvasSession) -> Void) {
        Signposts.canvas.withIntervalSignpost("Edit") { change(&session) }
        refresh()
    }

    /// `edit` for a change that only restyles the selection or a global color.
    private func restyle(_ change: (inout CanvasSession) -> Void) {
        Signposts.canvas.withIntervalSignpost("Edit") { change(&session) }
        refreshStyle()
    }

    // MARK: Tools and commands

    func setTool(_ tool: Tool) { edit { $0.editor.tool = tool } }
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
    func setAutoJoin(_ on: Bool) { edit { $0.editor.autoJoinSelectedPart = on } }
    func setSnap(_ snap: SnapSettings) { edit { $0.editor.snap = snap } }
    func flip(horizontal: Bool) { edit { $0.editor.flipSelection(horizontal: horizontal) } }
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
    func hideSelection() { edit { $0.editor.hideSelection() } }
    func lockSelection() { edit { $0.editor.lockSelection() } }
    func showAll() { edit { $0.editor.showAll() } }
    func unlockAll() { edit { $0.editor.unlockAll() } }
    func setPartHidden(_ id: Int, _ hidden: Bool) { edit { $0.editor.setPartHidden(id, hidden) } }
    func setPartLocked(_ id: Int, _ locked: Bool) { edit { $0.editor.setPartLocked(id, locked) } }
    func isolate(part id: Int) { edit { $0.editor.isolate(part: id) } }
    func exitIsolation() { edit { $0.editor.exitIsolation() } }
    /// One level out: from a group to its layer, from a layer to the whole document, else deselect.
    func stepOutOfIsolation() { edit { $0.editor.stepOutOfIsolation() } }
    func groupSelection() { edit { $0.editor.groupSelection() } }
    func ungroupSelection() { edit { $0.editor.ungroupSelection() } }
    func renameGroup(_ id: Int, inPart part: Int, to name: String) {
        edit { $0.editor.renameGroup(id, inPart: part, to: name) }
    }
    func addSelection(toGroup id: Int) { edit { $0.editor.addSelection(toGroup: id) } }
    func selectParent() { edit { $0.editor.selectParent() } }
    func selectCrumb(_ level: SelectionCrumb.Level) { edit { $0.editor.selectCrumb(level) } }
    func selectAllInLayer() { edit { $0.editor.selectAllInLayer() } }
    func invertSelection() { edit { $0.editor.invertSelection() } }
    func selectSameFill() { edit { $0.editor.selectSameFill() } }
    func selectSameOutline() { edit { $0.editor.selectSameOutline() } }
    func mergePartDown(_ id: Int) { edit { $0.editor.mergePartDown(id) } }
    func moveSelectionToNewPart() { edit { $0.editor.moveSelectionToNewPart() } }
    func moveSelection(toPart id: Int) { edit { $0.editor.moveSelection(toPart: id) } }
    func setPartOrder(frontToBack ids: [Int]) { edit { $0.editor.setPartOrder(frontToBack: ids) } }
    func canMergePartDown(_ id: Int) -> Bool { session.editor.canMergePartDown(id) }

    /// Isolates the selected part (or the part of the selected shapes).
    func isolateSelection() {
        guard let id = ui.selectedPart else { return }
        isolate(part: id)
    }

    // MARK: Symmetry

    func setSymmetryEnabled(_ on: Bool) { edit { $0.editor.symmetry.isEnabled = on } }
    func centerSymmetryAxis() { edit { $0.editor.centerSymmetryAxis() } }
    func resetSymmetryAxis() { edit { $0.editor.symmetry.axis = 0 } }
    func duplicateMirrored() { edit { $0.editor.duplicateMirrored() } }

    // MARK: View options and the viewport

    func setOutlineView(_ on: Bool) { edit { $0.editor.outlineView = on } }
    func setGhostsUnselected(_ on: Bool) { edit { $0.editor.ghostsUnselected = on } }

    /// A numeric viewport edit; edits of one field in a row are one undo step.
    func updateViewport(_ field: String, _ change: (inout Viewport) -> Void) {
        edit { $0.editor.updateViewport(coalescingKey: field, change) }
    }

    /// Gives the viewport a preset aspect, keeping its width.
    func setViewportAspect(_ aspect: Viewport.Aspect) { edit { $0.editor.setViewportAspect(aspect.ratio) } }

    /// Fits the viewport in the view.
    func zoomToFit() {
        session.zoom(toFit: session.editor.drawing.viewport.bounds, viewSize: Vec2(viewSize))
        onChange?()
    }

    // MARK: Import and export

    /// Reads SVG art into new parts on top, selects them and fits them in the view.
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
        edit { _ = $0.editor.importParts(result.parts) }
        let editor = session.editor
        let bounds = editor.drawing.shapeIndices(in: editor.selection).reduce(Rect.null) {
            $0.union(editor.drawing.parts[$1.0].shapes[$1.1].bounds)
        }
        if !bounds.isNull {
            session.zoom(toFit: bounds, viewSize: Vec2(viewSize))
            onChange?()
        }
        let parts = result.parts.count == 1 ? "1 part" : "\(result.parts.count) parts"
        var message = "Imported \(parts)"
        if !result.skipped.isEmpty {
            let skipped = result.skipped.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }
            message += "; skipped " + skipped.joined(separator: ", ")
        }
        showToast(message)
        return nil
    }

    /// The art as SVG, over the viewport.
    func svgData() -> Data? {
        Signposts.canvas.withIntervalSignpost("SVG export") { session.editor.svgDocument().map { Data($0.utf8) } }
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
        guard let text = session.editor.copySelection() else { return }
        Self.putOnPasteboard(text)
    }

    func cut() {
        var text: String?
        edit { text = $0.editor.cutSelection() }
        if let text { Self.putOnPasteboard(text) }
    }

    func paste() {
        let board = UIPasteboard.general
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
    func setGradientAngle(_ degrees: Double) { edit { $0.editor.setGradientAngle(degrees) } }
    func setGradientSpan(_ fraction: Double) { edit { $0.editor.setGradientSpan(fraction) } }
    func reverseGradient() { edit { $0.editor.reverseGradient() } }
    func setAnchorWidth(_ width: Double) { edit { $0.editor.setSelectedAnchorsWidth(width) } }
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

    func selectPart(_ id: Int) { edit { $0.editor.selectPart(id) } }

    /// Selects layer `id` and makes it the one new art goes into, as tapping its name in
    /// the layers panel does.
    func activateLayer(_ id: Int) {
        edit {
            $0.editor.selectPart(id)
            $0.editor.setActiveLayer(id)
        }
    }

    /// Back to starting a new part for each new piece of art.
    func clearActiveLayer() { edit { $0.editor.setActiveLayer(nil) } }
    func selectLayers(_ ids: Set<Int>) { edit { $0.editor.selectLayers(ids) } }
    func moveTreeRow(from source: Int, to destination: Int, in rows: [LayerTree.Row]) {
        edit { $0.editor.moveTreeRow(from: source, to: destination, in: rows) }
    }
    func selectGroup(_ id: Int, inPart part: Int) { edit { $0.editor.selectGroup(id, inPart: part) } }
    func setGroupHidden(_ id: Int, inPart part: Int, _ hidden: Bool) {
        edit { $0.editor.setGroupHidden(id, inPart: part, hidden) }
    }
    func setGroupLocked(_ id: Int, inPart part: Int, _ locked: Bool) {
        edit { $0.editor.setGroupLocked(id, inPart: part, locked) }
    }
    func setGroupClipped(_ id: Int, inPart part: Int, _ clipped: Bool) {
        edit { $0.editor.setGroupClipped(id, inPart: part, clipped) }
    }
    func renamePart(_ id: Int, to name: String) { edit { $0.editor.renamePart(id, to: name) } }
    func deletePart(_ id: Int) { edit { $0.editor.deletePart(id) } }
    func renamePresentation(_ name: String) { edit { $0.editor.renamePresentation(name) } }

    // MARK: Reference images

    /// Adds a reference image under the art, fitted to the middle of the view.
    func importReference(data: Data, name: String) {
        guard let image = UIImage(data: data), let cgImage = Self.normalized(image),
              let encoded = Self.encoded(cgImage) else { return }
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

    /// Bakes orientation and caps the size at 4096 pixels on the long side.
    private static func normalized(_ image: UIImage) -> CGImage? {
        let pixelWidth = image.size.width * image.scale
        let pixelHeight = image.size.height * image.scale
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let k = min(1, 4096 / max(pixelWidth, pixelHeight))
        let size = CGSize(width: (pixelWidth * k).rounded(), height: (pixelHeight * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image.cgImage)
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.cgImage
    }

    private static func hasAlpha(_ image: CGImage?) -> Bool {
        switch image?.alphaInfo {
        case .none?, .noneSkipFirst?, .noneSkipLast?: false
        default: true
        }
    }

    /// PNG for images with transparency, otherwise JPEG to keep photos small.
    private static func encoded(_ image: CGImage) -> Data? {
        let ui = UIImage(cgImage: image)
        return hasAlpha(image) ? ui.pngData() : ui.jpegData(compressionQuality: 0.9)
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
