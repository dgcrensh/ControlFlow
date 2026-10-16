import ControlFlowCore
import CoreText
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The editor for one document.
struct ContentView: View {
    @Binding var document: PresentationDocument
    @State private var store: CanvasStore
    @Environment(\.scenePhase) private var scenePhase
    /// The canvas width, which bounds the context bar in the navigation bar.
    @State private var canvasWidth: CGFloat = 0
    /// The presentation being given, full-screen over the editor.
    @State private var presenting: PresentationController?
    /// The presentation this document last gave, to end on the external display.
    @State private var presented: ObjectIdentifier?

    init(document: Binding<PresentationDocument>) {
        _document = document
        _store = State(initialValue: CanvasStore(package: document.wrappedValue.package))
    }

    var body: some View {
        CanvasRepresentable(store: store)
            .ignoresSafeArea()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { canvasWidth = $0 }
            .overlay(alignment: .leading) {
                ToolBar(store: store, ui: store.ui)
                    .padding(.leading, 16)
            }
            .overlay(alignment: .trailing) {
                ModifierStrip(store: store, ui: store.ui)
                    .padding(.trailing, 16)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    TimelineBar(store: store, ui: store.ui)
                        // Clear of the tool strip and the modifier strip.
                        .padding(.horizontal, 84)
                    StyleBar(store: store, ui: store.ui)
                }
            }
            .overlay(alignment: .topTrailing) {
                RotationLockBadge(store: store, ui: store.ui)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
            }
            .overlay { ToastView(ui: store.ui) }
            .overlay { PencilPalette(store: store, ui: store.ui) }
            // Keyboard shortcuts (EditorCommands) act on the focused document's canvas,
            // and are off while presenting, where the arrows and Escape mean other things.
            .focusedSceneValue(\.canvasStore, presenting == nil ? store : nil)
            .fullScreenCover(item: $presenting, onDismiss: endPresenting) { controller in
                PresentingView(controller: controller)
            }
            .onDrop(of: [.image], isTargeted: nil) { providers in
                let store = store
                for provider in providers {
                    _ = provider.loadDataRepresentation(for: .image) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in store.importReference(data: data, name: "Dropped image") }
                    }
                }
                return !providers.isEmpty
            }
            .persistentSystemOverlays(.hidden)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            // The bar keeps its back button and title menu, but paints no band over the canvas.
            // The context bar lives in the bar itself: a view floated under the navigation bar
            // never receives touches, because the bar sits above it. It goes at the trailing
            // edge, not `.principal`: in a document's editor bar the principal slot is the
            // title, and a tap anywhere in it opens the rename menu.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Leave room for the back button and the title.
                    ContextBar(store: store, ui: store.ui, maxWidth: max(280, canvasWidth - 380))
                }
                    // The context bar draws its own capsule, like the tool and style bars.
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Present", systemImage: "play.rectangle.fill") { startPresenting() }
                }
            }
            .onAppear {
                let document = $document
                store.onDocumentChange = { document.wrappedValue.package = $0 }
                store.onPresent = { startPresenting() }
            }
            .onChange(of: document.package) { _, package in
                store.documentChanged(package)
            }
            // A held color change reaches the document before it closes or the app leaves.
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { store.flushDocument() }
            }
            .onDisappear { store.flushDocument() }
    }

    /// Present: the document as it is now, from its opening state.
    private func startPresenting() {
        guard presenting == nil else { return }
        store.stopPlaying()
        let controller = PresentationController(presentation: store.session.editor.presentation,
                                                rotationLocked: store.session.isRotationLocked,
                                                startRotation: store.session.camera.rotationDegrees)
        controller.onExit = { presenting = nil }
        PresentationHub.shared.active = controller
        presented = ObjectIdentifier(controller)
        presenting = controller
    }

    /// The external display goes back to black.
    private func endPresenting() {
        if let active = PresentationHub.shared.active, ObjectIdentifier(active) == presented {
            PresentationHub.shared.active = nil
        }
        presented = nil
    }
}

/// Tools, undo and redo, selection actions, layers and view commands, in a vertical
/// strip down the leading edge of the canvas.
private struct ToolBar: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var showingLayers = false
    @State private var showingInspector = false
    @State private var showingAppearance = false
    @State private var showingViewport = false
    @State private var importingSVG = false
    @State private var pickingPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var importingImage = false
    @State private var exporting = false
    @State private var exportFile = ExportFile()
    @State private var importError: String?

    var body: some View {
        // On a short screen (landscape) the strip scrolls rather than running off the edge.
        ViewThatFits(in: .vertical) {
            strip
            ScrollView(.vertical, showsIndicators: false) { strip }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .padding(.horizontal, 8)
        .padding(.vertical, 16)
        .background(.regularMaterial, in: Capsule())
        // On the strip as a whole, since ViewThatFits builds it twice.
        .popover(isPresented: $showingInspector) { InspectorPanel(store: store, ui: ui) }
        .popover(isPresented: $showingAppearance) { AppearancePanel(store: store, ui: ui) }
        .popover(isPresented: $showingLayers) { LayersPanel(store: store, ui: ui) }
        .popover(isPresented: $showingViewport) { ViewportPanel(store: store, ui: ui) }
        // The importer and exporter sit on separate views: SwiftUI shows only one file
        // panel modifier per view.
        .background {
            Color.clear.fileImporter(isPresented: $importingSVG, allowedContentTypes: [.svg]) { result in
                guard case .success(let url) = result else { return }
                importSVG(from: url)
            }
        }
        .background {
            Color.clear.fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { store.insertImage(data: data) }
            }
        }
        .photosPicker(isPresented: $pickingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { store.insertImage(data: data) }
                photoItem = nil
            }
        }
        .overlay {
            Color.clear
                .allowsHitTesting(false)
                .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportFile.type,
                              defaultFilename: exportFile.name) { _ in }
        }
        .alert("Couldn't Import SVG", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
        .padding(.vertical, 16)
    }

    private func importSVG(from url: URL) {
        // One import at a time.
        guard !ui.isImporting else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            importError = error.localizedDescription
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        Task {
            if let message = await store.importSVG(data, name: name) { importError = message }
        }
    }

    /// Offers the exported file to save in Files.
    private func export(_ data: Data?, type: UTType) {
        guard let data else { return }
        exportFile = ExportFile(data: data, type: type, name: exportName)
        exporting = true
    }

    /// Offers the web page's folder to save in Files.
    private func exportWebPage() {
        guard let files = store.htmlFiles() else { return }
        exportFile = ExportFile(folder: files, name: exportName)
        exporting = true
    }

    private var exportName: String { ui.presentationName.isEmpty ? "Untitled" : ui.presentationName }

    private var strip: some View {
        VStack(spacing: 12) {
            ForEach(ToolButton.all, id: \.tool) { item in
                ToolButton(store: store, ui: ui, tool: item.tool, title: item.title, systemImage: item.systemImage)
            }

            Divider().frame(width: 24)
            Button("Undo", systemImage: "arrow.uturn.backward") { store.undo() }
                .disabled(!ui.canUndo)
            Button("Redo", systemImage: "arrow.uturn.forward") { store.redo() }
                .disabled(!ui.canRedo)
            EditMenu(store: store, ui: ui)

            Divider().frame(width: 24)
            Button("Inspector", systemImage: "slider.horizontal.3") { showingInspector = true }
            Button("Appearance", systemImage: "paintpalette") { showingAppearance = true }
            Button("Layers", systemImage: "square.3.layers.3d") { showingLayers = true }
            ViewMenu(store: store, ui: ui, showingViewport: $showingViewport)
            Menu {
                Menu("Insert Image", systemImage: "photo.badge.plus") {
                    Button("From Photos", systemImage: "photo.on.rectangle") { pickingPhoto = true }
                    Button("From Files", systemImage: "folder") { importingImage = true }
                }
                Button("Import SVG", systemImage: "square.and.arrow.down") { importingSVG = true }
                    .disabled(ui.isImporting)
                Button("Export SVG", systemImage: "square.and.arrow.up") { export(store.svgData(), type: .svg) }
                Menu("Export PNG", systemImage: "photo") {
                    ForEach([1, 2, 4], id: \.self) { scale in
                        Button("\(scale)x") { export(store.pngData(scale: Double(scale)), type: .png) }
                    }
                }
                Button("Export Web Page", systemImage: "globe") { exportWebPage() }
                #if DEBUG
                Button("Time Formulas", systemImage: "stopwatch") { store.timeFormulas() }
                #endif
                Divider()
                Button("Clear Canvas", systemImage: "trash", role: .destructive) { store.clear() }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// How the canvas shows the art: the outline view, ghosting, the viewport and fitting
/// the view.
private struct ViewMenu: View {
    let store: CanvasStore
    let ui: EditorUIState
    @Binding var showingViewport: Bool

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { ui.outlineView }, set: { store.setOutlineView($0) })) {
                Label("Outline View", systemImage: "square.dashed")
            }
            Toggle(isOn: Binding(get: { ui.ghostsUnselected }, set: { store.setGhostsUnselected($0) })) {
                Label("Ghost Unselected", systemImage: "circle.lefthalf.filled")
            }
            Toggle(isOn: Binding(get: { ui.showsOnionSkin }, set: { store.setOnionSkin($0) })) {
                Label("Onion Skin", systemImage: "square.2.layers.3d")
            }
            Toggle(isOn: Binding(get: { ui.rotationLocked }, set: { store.setRotationLocked($0) })) {
                Label("Lock Rotation", systemImage: "lock.rotation")
            }
            Divider()
            Button("Viewport", systemImage: "rectangle.dashed") { showingViewport = true }
            Divider()
            Button("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right") { store.zoomToFit() }
            Button("Reset View", systemImage: "scope") { store.resetView() }
        } label: {
            Label("View", systemImage: ui.outlineView ? "eye.square.fill" : "eye.square")
        }
    }
}

/// Duplicate, the clipboard, delete, arrange, hide and lock, and isolation, for the
/// selection. The same commands have keyboard shortcuts (`EditorCommands`).
private struct EditMenu: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        Menu {
            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate() }
                .disabled(!ui.canArrange)
            Button("Cut", systemImage: "scissors") { store.cut() }
                .disabled(!ui.canArrange)
            Button("Copy", systemImage: "doc.on.doc") { store.copy() }
                .disabled(!ui.canArrange)
            Button("Duplicate Mirrored", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                store.duplicateMirrored()
            }
            .disabled(!ui.canDuplicateMirrored)
            Button("Paste", systemImage: "doc.on.clipboard") { store.paste() }
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
                .disabled(ui.selection == .none)
            Button("Convert to Outlines", systemImage: "character.textbox") { store.convertTextToOutlines() }
                .disabled(!ui.canConvertToOutlines)
            Menu("Select", systemImage: "cursorarrow.rays") {
                Button("Select Layer", systemImage: "arrow.up.square") { store.selectParent() }
                    .disabled(!ui.canSelectParent)
                Button("Select All in Layer", systemImage: "square.stack") { store.selectAllInLayer() }
                    .disabled(!ui.canSelectAllInLayer)
                Button("Invert Selection", systemImage: "circle.lefthalf.filled") { store.invertSelection() }
                    .disabled(!ui.canInvertSelection)
                Divider()
                Button("Same Fill", systemImage: "drop.fill") { store.selectSameFill() }
                    .disabled(!ui.canSelectSame)
                Button("Same Outline", systemImage: "circle") { store.selectSameOutline() }
                    .disabled(!ui.canSelectSame)
            }

            Divider()
            Menu("Arrange", systemImage: "square.3.layers.3d.top.filled") {
                Group {
                    Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") { store.arrange(.bringToFront) }
                    Button("Bring Forward", systemImage: "square.2.layers.3d.top.filled") { store.arrange(.bringForward) }
                    Button("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") { store.arrange(.sendBackward) }
                    Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") { store.arrange(.sendToBack) }
                }
                .disabled(!ui.canArrange)
                Divider()
                Menu("Align", systemImage: "align.horizontal.left") {
                    ForEach(AlignControls.edges, id: \.title) { item in
                        Button(item.title, systemImage: item.icon) { store.align(item.edge) }
                    }
                }
                .disabled(!ui.canAlign)
                Menu("Distribute", systemImage: "distribute.horizontal.center") {
                    ForEach(AlignControls.modes, id: \.title) { item in
                        Button(item.title, systemImage: item.icon) { store.distribute(item.mode) }
                    }
                }
                .disabled(!ui.canDistribute)
            }
            .disabled(!ui.canArrange && !ui.canAlign)
            Button("Group", systemImage: "square.on.square.squareshape.controlhandles") { store.groupSelection() }
                .disabled(!ui.canGroup)
            if ui.canUngroup {
                Button("Ungroup", systemImage: "square.on.square.dashed") { store.ungroupSelection() }
            }
            if !ui.groupsToAddTo.isEmpty {
                Menu("Add to Group", systemImage: "plus.rectangle.on.rectangle") {
                    ForEach(ui.groupsToAddTo) { group in
                        Button(group.name) { store.addSelection(toGroup: group.id) }
                    }
                }
            }
            if ui.canMoveShapes {
                Button("Move to New Layer", systemImage: "rectangle.badge.plus") { store.moveSelectionToNewLayer() }
                Menu("Move to Layer", systemImage: "arrow.right.square") {
                    ForEach(ui.layers.layers) { layer in
                        Button(layer.name) { store.moveSelection(toLayer: layer.id) }
                    }
                }
            }

            Divider()
            Button("Hide", systemImage: "eye.slash") { store.hideSelection() }
                .disabled(!ui.canHideOrLock)
            Button("Lock", systemImage: "lock") { store.lockSelection() }
                .disabled(!ui.canHideOrLock)
            if ui.hasHiddenArt {
                Button("Show All", systemImage: "eye") { store.showAll() }
            }
            if ui.hasLockedArt {
                Button("Unlock All", systemImage: "lock.open") { store.unlockAll() }
            }

            Divider()
            // Takes the selection's changes out of the current keyframe.
            Button("Revert to Previous", systemImage: "arrow.uturn.backward.circle") { store.revertSelectionToPrevious() }
                .disabled(ui.keyedProperties.isEmpty)

            Divider()
            if ui.isolatedLayer != nil {
                Button("Exit Isolation", systemImage: "scope") { store.exitIsolation() }
            } else {
                Button("Isolate Layer", systemImage: "scope") { store.isolateSelection() }
                    .disabled(ui.selectedLayer == nil)
            }
        } label: {
            Label("Edit", systemImage: "square.on.square.dashed")
        }
    }
}

/// One tool in the tool strip, highlighted while it is the current tool.
private struct ToolButton: View {
    let store: CanvasStore
    let ui: EditorUIState
    let tool: Tool
    let title: String
    let systemImage: String

    /// Every tool, in strip order, with its name and symbol.
    static let all: [(tool: Tool, title: String, systemImage: String)] = [
        (.pencil, "Pencil", "pencil.tip"),
        (.pen, "Pen", "pencil.and.outline"),
        (.shape, "Shapes", "square.on.circle"),
        (.text, "Text", "textformat"),
        (.select, "Select", "cursorarrow"),
        (.directSelect, "Direct Select", "point.topleft.down.to.point.bottomright.curvepath"),
        (.eraser, "Eraser", "eraser"),
        (.scissors, "Scissors", "scissors"),
    ]

    var body: some View {
        let isCurrent = ui.tool == tool
        Button { store.setTool(tool) } label: {
            Image(systemName: systemImage)
                .frame(width: 40, height: 40)
                .foregroundStyle(isCurrent ? Color.white : Color.primary)
                .background(isCurrent ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// Controls for the current tool: pen Done, the Add toggle, snapping, the point type
/// control and path commands, flips and nudging. It sits in the navigation bar.
private struct ContextBar: View {
    let store: CanvasStore
    let ui: EditorUIState
    /// The widest the bar may be, capsule included.
    let maxWidth: CGFloat

    /// A navigation bar item is offered as much width as it asks for, so the bar sizes
    /// itself: as wide as its controls up to `maxWidth`, scrolling beyond that rather
    /// than running off the edge of the screen.
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            controls.padding(.horizontal, 20)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .frame(maxWidth: max(maxWidth, 0))
        .fixedSize()
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .clipShape(Capsule())
    }

    private var controls: some View {
        HStack(spacing: 14) {
            if ui.isolatedLayer != nil {
                Button { store.stepOutOfIsolation() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                        Text("Exit \(ui.isolatedLayerName)").lineLimit(1)
                    }
                }
                .accessibilityLabel("Exit isolation")
                Divider().frame(height: 24)
            }
            if ui.isolatedLayer == nil, ui.activeLayer != nil, [Tool.pencil, .pen, .shape].contains(ui.tool) {
                // Where new art goes, chosen in the layers panel (or by auto-join).
                HStack(spacing: 6) {
                    Image(systemName: "square.3.layers.3d")
                    Text("Into \(ui.activeLayerName)").lineLimit(1)
                    if ui.activeLayerIsChosen {
                        Button("Draw New Layers", systemImage: "xmark.circle.fill") { store.clearActiveLayer() }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                Divider().frame(height: 24)
            }
            if [Tool.select, .directSelect].contains(ui.tool), ui.selectionCrumbs.contains(where: \.isCurrent) {
                breadcrumbs
                Divider().frame(height: 24)
            }
            switch ui.tool {
            case .pencil:
                Toggle(isOn: Binding(get: { ui.autoJoin }, set: { store.setAutoJoin($0) })) {
                    Label("Auto-join selected layer", systemImage: "rectangle.on.rectangle")
                }
                .toggleStyle(.button)
            case .pen:
                Text("Tap to place, drag to curve, tap the first point to close")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Done", systemImage: "checkmark.circle") { store.penDone() }
                    .disabled(!ui.penActive)
            case .select, .directSelect:
                Toggle(isOn: Binding(get: { ui.addToSelection }, set: { store.setAddToSelection($0) })) {
                    Label("Add", systemImage: "plus.square.on.square")
                }
                .toggleStyle(.button)
            case .shape:
                shapeControls
            case .eraser:
                Text("Drag across shapes to delete them")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .scissors:
                Text("Tap an outline to cut it there")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .text:
                TextStyleControls(store: store, ui: ui)
                if !ui.isEditingText {
                    Text("Tap to type, drag for a box that wraps")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if ui.tool == .select, ui.selectionHasText {
                Divider().frame(height: 24)
                TextStyleControls(store: store, ui: ui)
            }

            if [Tool.pen, .shape, .select, .directSelect].contains(ui.tool) { snapMenu }
            if [Tool.pencil, .pen, .shape].contains(ui.tool) { symmetryMenu }
            if ui.tool == .select, let group = ui.selectedGroupID, let layer = ui.selectedGroupLayer {
                Divider().frame(height: 24)
                Label("Group", systemImage: "square.on.square.squareshape.controlhandles")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                NameField(placeholder: "Group name", name: ui.selectedGroupName) {
                    store.renameGroup(group, inLayer: layer, to: $0)
                }
            }

            if ui.tool == .directSelect, ui.anchorCount > 0 { pointControls }
            if ui.tool == .directSelect, ui.anchorCount >= 2 { AlignControls(store: store, ui: ui, anchorsOnly: true) }
            if ui.canJoin, ui.tool == .select || ui.tool == .directSelect {
                Button("Join", systemImage: "link") { store.joinPaths() }
            }
            if ui.tool == .select, ui.canTransform { flipControls }
            if ui.tool == .select, ui.canAlign { AlignControls(store: store, ui: ui, anchorsOnly: false) }
            if (ui.tool == .directSelect && ui.anchorCount > 0) || (ui.tool == .select && ui.canTransform) {
                nudgeControls
            }
        }
    }

    /// Where the selection sits, such as "Hair › Bangs › Shape": tapping an outer level
    /// selects it.
    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(ui.selectionCrumbs.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.compact.right").foregroundStyle(.secondary)
                }
                if crumb.isCurrent {
                    Text(crumb.title).lineLimit(1).fontWeight(.semibold)
                } else {
                    Button(crumb.title) { store.selectCrumb(crumb.level) }
                        .lineLimit(1)
                        .accessibilityHint("Selects this level")
                }
            }
        }
        .font(.subheadline)
    }

    /// Mirror drawing about a vertical axis.
    private var symmetryMenu: some View {
        Menu {
            Toggle("Mirror Drawing", isOn: Binding(get: { ui.symmetry.isEnabled }, set: { store.setSymmetryEnabled($0) }))
            Button("Center Axis on Selection") { store.centerSymmetryAxis() }
            Button("Reset Axis") { store.resetSymmetryAxis() }
        } label: {
            Label("Symmetry", systemImage: ui.symmetry.isEnabled
                  ? "arrow.left.and.right.square.fill" : "arrow.left.and.right.square")
        }
    }

    /// The shape picker and the current shape's settings.
    @ViewBuilder
    private var shapeControls: some View {
        Picker("Shape", selection: Binding(get: { ui.shapeKind }, set: { store.setShapeKind($0) })) {
            Image(systemName: "rectangle").accessibilityLabel("Rectangle").tag(ShapeKind.rectangle)
            Image(systemName: "circle").accessibilityLabel("Ellipse").tag(ShapeKind.ellipse)
            Image(systemName: "hexagon").accessibilityLabel("Polygon").tag(ShapeKind.polygon)
            Image(systemName: "star").accessibilityLabel("Star").tag(ShapeKind.star)
            Image(systemName: "line.diagonal").accessibilityLabel("Line").tag(ShapeKind.line)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        switch ui.shapeKind {
        case .rectangle:
            Stepper("Corners \(Int(ui.shapeOptions.cornerRadius)) pt", value: shapeOption(\.cornerRadius), in: 0...200, step: 2)
                .fixedSize()
        case .polygon:
            Stepper("\(ui.shapeOptions.sides) sides", value: shapeOption(\.sides), in: 3...12)
                .fixedSize()
        case .star:
            Stepper("\(ui.shapeOptions.sides) points", value: shapeOption(\.sides), in: 3...12)
                .fixedSize()
            Slider(value: shapeOption(\.innerRatio), in: 0.2...0.9)
                .frame(width: 90)
                .accessibilityLabel("Inner radius")
        case .ellipse, .line:
            EmptyView()
        }
        Text("Shift: square, Option: from center")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private func shapeOption<T>(_ keyPath: WritableKeyPath<ShapeToolOptions, T>) -> Binding<T> {
        Binding(
            get: { ui.shapeOptions[keyPath: keyPath] },
            set: { var options = ui.shapeOptions; options[keyPath: keyPath] = $0; store.setShapeOptions(options) }
        )
    }

    private var snapMenu: some View {
        Menu {
            Toggle("Smart Guides", isOn: snapBinding(\.smartGuides))
            Toggle("Snap", isOn: snapBinding(\.isEnabled))
            Toggle("Anchors", isOn: snapBinding(\.toAnchors))
            Toggle("Grid", isOn: snapBinding(\.toGrid))
            Stepper("Grid \(Int(ui.snap.gridSize)) pt", value: Binding(
                get: { ui.snap.gridSize },
                set: { var snap = ui.snap; snap.gridSize = $0; store.setSnap(snap) }
            ), in: 1...200, step: 1)
        } label: {
            Label("Snap", systemImage: ui.snap.isEnabled ? "grid.circle.fill" : "grid.circle")
        }
    }

    private func snapBinding(_ keyPath: WritableKeyPath<SnapSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { ui.snap[keyPath: keyPath] },
            set: { var snap = ui.snap; snap[keyPath: keyPath] = $0; store.setSnap(snap) }
        )
    }

    /// An explicit control for how the selected points' handles behave, in place of
    /// the old hidden tap-to-toggle.
    @ViewBuilder
    private var pointControls: some View {
        Divider().frame(height: 24)
        Picker("Point type", selection: Binding(
            get: { ui.anchorMode },
            set: { if let mode = $0 { store.setAnchorMode(mode) } }
        )) {
            Text("Corner").tag(Optional(HandleMode.corner))
            Text("Smooth").tag(Optional(HandleMode.smooth))
            Text("Symmetric").tag(Optional(HandleMode.symmetric))
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
        Button("Break Handles", systemImage: "slash.circle") { store.breakAnchorHandles() }
        // Acts on the edges between selected anchors; a bare edge keeps its fill.
        Button(ui.edgesStroked == false ? "Show Edge Outline" : "Hide Edge Outline",
               systemImage: ui.edgesStroked == false ? "eye" : "eye.slash") {
            store.toggleEdgeOutline()
        }
        .disabled(ui.edgesStroked == nil)
        Button("Split", systemImage: "scissors") { store.splitAtAnchor() }
            .disabled(!ui.canSplit)
        Button("Delete Point", systemImage: "minus.circle") { store.deleteSelectedAnchors() }
            .disabled(!ui.canDeleteAnchor)
    }

    @ViewBuilder
    private var flipControls: some View {
        Divider().frame(height: 24)
        HStack(spacing: 14) {
            Button("Flip Horizontal", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                store.flip(horizontal: true)
            }
            Button("Flip Vertical", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") {
                store.flip(horizontal: false)
            }
            Button("Rotate Left", systemImage: "rotate.left") { store.rotateSelection(degrees: -90) }
            Button("Rotate Right", systemImage: "rotate.right") { store.rotateSelection(degrees: 90) }
            Button("Apply Transform", systemImage: "checkmark.rectangle") { store.applyTransform() }
                .disabled(!ui.canApplyTransform)
        }
        .labelStyle(.iconOnly)
    }

    @ViewBuilder
    private var nudgeControls: some View {
        Divider().frame(height: 24)
        HStack(spacing: 14) {
            Button("Nudge Left", systemImage: "arrow.left") { store.nudge(-1, 0) }
            Button("Nudge Up", systemImage: "arrow.up") { store.nudge(0, -1) }
            Button("Nudge Down", systemImage: "arrow.down") { store.nudge(0, 1) }
            Button("Nudge Right", systemImage: "arrow.right") { store.nudge(1, 0) }
        }
        .labelStyle(.iconOnly)
    }
}

/// The Arrange button and its popover: Align (with what to align to), Distribute and
/// draw order. For selected anchors in Direct Select, only Align and Distribute.
private struct AlignControls: View {
    let store: CanvasStore
    let ui: EditorUIState
    let anchorsOnly: Bool
    @State private var showing = false

    struct EdgeItem: Sendable { let title: String, icon: String, edge: AlignEdge }
    struct ModeItem: Sendable { let title: String, icon: String, mode: DistributeMode }

    static let edges: [EdgeItem] = [
        EdgeItem(title: "Align Left", icon: "align.horizontal.left", edge: .left),
        EdgeItem(title: "Align Horizontal Centers", icon: "align.horizontal.center", edge: .centerX),
        EdgeItem(title: "Align Right", icon: "align.horizontal.right", edge: .right),
        EdgeItem(title: "Align Top", icon: "align.vertical.top", edge: .top),
        EdgeItem(title: "Align Vertical Centers", icon: "align.vertical.center", edge: .centerY),
        EdgeItem(title: "Align Bottom", icon: "align.vertical.bottom", edge: .bottom),
    ]

    static let modes: [ModeItem] = [
        ModeItem(title: "Horizontal Spacing", icon: "distribute.horizontal.center", mode: .spacingX),
        ModeItem(title: "Vertical Spacing", icon: "distribute.vertical.center", mode: .spacingY),
        ModeItem(title: "Horizontal Centers", icon: "distribute.horizontal.center.fill", mode: .centersX),
        ModeItem(title: "Vertical Centers", icon: "distribute.vertical.center.fill", mode: .centersY),
    ]

    var body: some View {
        Divider().frame(height: 24)
        Button(anchorsOnly ? "Align Points" : "Arrange", systemImage: "align.horizontal.left") { showing = true }
            .labelStyle(.iconOnly)
            .popover(isPresented: $showing) { panel }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Align").font(.headline)
            HStack(spacing: 16) {
                ForEach(Self.edges, id: \.title) { item in
                    Button(item.title, systemImage: item.icon) { store.align(item.edge) }
                }
            }
            .labelStyle(.iconOnly)
            if !anchorsOnly {
                Picker("Align To", selection: Binding(
                    get: { ui.alignsToViewportOnly ? .viewport : ui.alignTarget },
                    set: { store.setAlignTarget($0) }
                )) {
                    Text("Selection").tag(AlignTarget.selection)
                    Text("Viewport").tag(AlignTarget.viewport)
                }
                .pickerStyle(.segmented)
                .disabled(ui.alignsToViewportOnly)
            }

            Divider()
            Text("Distribute").font(.headline)
            HStack(spacing: 16) {
                ForEach(Self.modes.prefix(2), id: \.title) { item in
                    Button(item.title, systemImage: item.icon) { store.distribute(item.mode) }
                }
                Menu {
                    ForEach(Self.modes.suffix(2), id: \.title) { item in
                        Button(item.title, systemImage: item.icon) { store.distribute(item.mode) }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            .labelStyle(.iconOnly)
            .disabled(!ui.canDistribute)

            if !anchorsOnly {
                Divider()
                Text("Order").font(.headline)
                HStack(spacing: 16) {
                    Button("Bring to Front", systemImage: "square.3.layers.3d.top.filled") { store.arrange(.bringToFront) }
                    Button("Bring Forward", systemImage: "square.2.layers.3d.top.filled") { store.arrange(.bringForward) }
                    Button("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") { store.arrange(.sendBackward) }
                    Button("Send to Back", systemImage: "square.3.layers.3d.bottom.filled") { store.arrange(.sendToBack) }
                }
                .labelStyle(.iconOnly)
                .disabled(!ui.canArrange)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}

/// The style of new text and of the selected text: font, size, weight and slant (for
/// the system font), alignment, and line height and tracking under More.
private struct TextStyleControls: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var choosingFont = false
    @State private var showingMore = false

    private static let weights: [(value: Int, name: String)] = [
        (100, "Thin"), (200, "Extra Light"), (300, "Light"), (400, "Regular"), (500, "Medium"),
        (600, "Semibold"), (700, "Bold"), (800, "Heavy"), (900, "Black"),
    ]

    var body: some View {
        let style = ui.textStyle
        HStack(spacing: 14) {
            Menu {
                Button("System") { store.setTextFont(TextContent.systemFont) }
                Button("Choose Font…") { choosingFont = true }
            } label: {
                Label(Self.fontName(style.font), systemImage: "textformat")
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
            }
            .popover(isPresented: $choosingFont) {
                FontPicker { name in
                    store.setTextFont(name)
                    choosingFont = false
                }
                .frame(minWidth: 320, minHeight: 480)
            }
            Stepper("\(Int(style.size.rounded())) pt", value: Binding(get: { style.size }, set: { store.setTextSize($0) }),
                    in: TextContent.sizeRange, step: 4)
                .fixedSize()
            if style.isSystemFont {
                Picker("Weight", selection: Binding(get: { style.weight }, set: { store.setTextWeight($0) })) {
                    ForEach(Self.weights, id: \.value) { Text($0.name).tag($0.value) }
                }
                .pickerStyle(.menu)
                .fixedSize()
                Toggle(isOn: Binding(get: { style.italic }, set: { store.setTextItalic($0) })) {
                    Label("Italic", systemImage: "italic")
                }
                .toggleStyle(.button)
                .labelStyle(.iconOnly)
            }
            Picker("Alignment", selection: Binding(get: { style.align }, set: { store.setTextAlignment($0) })) {
                Image(systemName: "text.alignleft").accessibilityLabel("Left").tag(ControlFlowCore.TextAlignment.left)
                Image(systemName: "text.aligncenter").accessibilityLabel("Center").tag(ControlFlowCore.TextAlignment.center)
                Image(systemName: "text.alignright").accessibilityLabel("Right").tag(ControlFlowCore.TextAlignment.right)
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
            Button("More", systemImage: "ellipsis.circle") { showingMore = true }
                .labelStyle(.iconOnly)
                .popover(isPresented: $showingMore) {
                    Form {
                        LabeledContent("Line Height") {
                            Slider(value: Binding(get: { style.lineHeight }, set: { store.setTextLineHeight(($0 * 20).rounded() / 20) }),
                                   in: 0.5...3)
                                .frame(width: 160)
                            Text("\(style.lineHeight, format: .number.precision(.fractionLength(2)))x")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                        LabeledContent("Tracking") {
                            Slider(value: Binding(get: { style.tracking }, set: { store.setTextTracking($0.rounded()) }),
                                   in: -20...100)
                                .frame(width: 160)
                            Text("\(Int(style.tracking)) pt")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    .frame(minWidth: 340, minHeight: 140)
                }
        }
    }

    /// A font's name as the picker shows it, "System" for the system font, and a note
    /// for a font this iPad doesn't have.
    static func fontName(_ name: String) -> String {
        guard name != TextContent.systemFont else { return "System" }
        guard let font = UIFont(name: name, size: 17) else { return "\(name) (missing)" }
        return CTFontCopyFullName(font as CTFont) as String
    }
}

/// The system font picker, choosing a font face by its PostScript name.
private struct FontPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = true
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIFontPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
    }

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        var onPick: (String) -> Void

        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }

        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            guard let descriptor = viewController.selectedFontDescriptor else { return }
            onPick(descriptor.postscriptName)
        }
    }
}

/// A name that is renamed when the field is submitted.
private struct NameField: View {
    let placeholder: String
    let name: String
    let rename: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 130)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onAppear { text = name }
            .onChange(of: name) { _, new in text = new }
            .onSubmit { if text != name { rename(text) } }
    }
}

/// Fill, outline, smoothing and the document's palette. Changes apply to the
/// selection (one undo step per control drag) and to new strokes.
private struct StyleBar: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { ui.style.fillEnabled }, set: { store.setFillEnabled($0) })) {
                Label("Fill", systemImage: "drop.fill")
            }
            .toggleStyle(.button)
            ColorPicker("Fill color", selection: Binding(get: { ui.style.fill.color }, set: { store.setFill($0) }),
                        supportsOpacity: true)
                .labelsHidden()

            Divider().frame(height: 24)
            Toggle(isOn: Binding(get: { ui.style.outlineEnabled }, set: { store.setOutlineEnabled($0) })) {
                Label("Outline", systemImage: "circle")
            }
            .toggleStyle(.button)
            ColorPicker("Outline color", selection: Binding(get: { ui.style.outline.color }, set: { store.setOutline($0) }),
                        supportsOpacity: true)
                .labelsHidden()
            Slider(value: Binding(get: { ui.style.outlineWidth }, set: { store.setOutlineWidth($0.rounded()) }), in: 1...40)
                .frame(width: 140)
            Text("\(Int(ui.style.outlineWidth.rounded())) pt")
                .monospacedDigit()
                .frame(width: 44, alignment: .leading)

            if ui.tool == .pencil {
                Divider().frame(height: 24)
                Image(systemName: "scribble.variable")
                    .accessibilityLabel("Smoothing")
                Slider(value: Binding(get: { ui.smoothing }, set: { store.setSmoothing($0) }), in: 0...1)
                    .frame(width: 110)
                Toggle(isOn: Binding(get: { ui.pressureWidth }, set: { store.setPressureWidth($0) })) {
                    Label("Pressure Width", systemImage: "lineweight")
                }
                .toggleStyle(.button)
            }

            Divider().frame(height: 24)
            PaletteRow(store: store, ui: ui)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 16)
    }
}

private struct PaletteRow: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        HStack(spacing: 8) {
            // Global colors: shapes filled or outlined with one follow it when it changes.
            ForEach(ui.globalColors) { global in
                RoundedRectangle(cornerRadius: 6)
                    .fill(global.color.color)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary, lineWidth: 1))
                    .frame(width: 26, height: 26)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
                    .onTapGesture { store.applyGlobalFill(global.id) }
                    .contextMenu {
                        Button("Use as Fill", systemImage: "drop.fill") { store.applyGlobalFill(global.id) }
                        Button("Use as Outline", systemImage: "circle") { store.applyGlobalOutline(global.id) }
                    }
                    .accessibilityLabel("Global color \(global.name)")
            }
            ForEach(Array(ui.palette.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(color.color)
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
                    .onTapGesture { store.applyPaletteFill(color) }
                    .contextMenu {
                        Button("Use as Fill", systemImage: "drop.fill") { store.applyPaletteFill(color) }
                        Button("Use as Outline", systemImage: "circle") { store.applyPaletteOutline(color) }
                        Button("Remove from Palette", systemImage: "trash", role: .destructive) {
                            store.removeFromPalette(at: index)
                        }
                    }
                    .accessibilityLabel("Palette color \(color.hexString)")
            }
            Menu {
                Button("Add Fill Color", systemImage: "drop.fill") { store.addFillToPalette() }
                Button("Add Outline Color", systemImage: "circle") { store.addOutlineToPalette() }
                Button("New Global Color from Fill", systemImage: "square.fill") { store.addGlobalColorFromFill() }
            } label: {
                Label("Add to Palette", systemImage: "plus.circle")
            }
        }
    }
}

/// Latching Shift and Option keys for when there is no keyboard: Shift constrains
/// (square shapes, 45-degree lines, one-axis moves, 15-degree turns) and Option draws
/// shapes from their center and makes a drag move a copy.
private struct ModifierStrip: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        VStack(spacing: 12) {
            toggle(.constrain, title: "Shift", systemImage: "shift")
            toggle(.alternate, title: "Option", systemImage: "option")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
    }

    private func toggle(_ key: EditorModifiers, title: String, systemImage: String) -> some View {
        let isOn = ui.stripModifiers.contains(key)
        return Button {
            var modifiers = ui.stripModifiers
            if isOn { modifiers.remove(key) } else { modifiers.insert(key) }
            store.setStripModifiers(modifiers)
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 36, height: 36)
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .background(isOn ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The palette the Pencil's squeeze (or double tap, if set to show the palette) opens
/// under the Pencil: the tools round the outside, undo and redo, and recent colors
/// inside. Tapping anywhere else closes it.
private struct PencilPalette: View {
    let store: CanvasStore
    let ui: EditorUIState
    private let radius: CGFloat = 96
    private let colorRadius: CGFloat = 50

    var body: some View {
        if let point = ui.palettePoint {
            GeometryReader { geometry in
                ZStack {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { store.hidePalette() }
                    ring
                        .position(clamped(point, in: geometry.size))
                }
            }
            .ignoresSafeArea()
            .transition(.opacity)
        }
    }

    private var ring: some View {
        let tools = ToolButton.all
        let actions: [(title: String, systemImage: String, run: () -> Void)] = [
            ("Undo", "arrow.uturn.backward", { store.undo() }),
            ("Redo", "arrow.uturn.forward", { store.redo() }),
        ]
        let count = tools.count + actions.count
        let colors = Array(ui.recentColors.prefix(6))
        return ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: (radius + 30) * 2, height: (radius + 30) * 2)
            ForEach(Array(tools.enumerated()), id: \.offset) { index, item in
                paletteButton(item.title, systemImage: item.systemImage, selected: ui.tool == item.tool) {
                    store.setTool(item.tool)
                }
                .offset(offset(index, of: count, radius: radius))
            }
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                paletteButton(action.title, systemImage: action.systemImage, selected: false, action: action.run)
                    .offset(offset(tools.count + index, of: count, radius: radius))
            }
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Button {
                    store.applyPaletteFill(color)
                    store.hidePalette()
                } label: {
                    Circle()
                        .fill(color.color)
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                        .frame(width: 26, height: 26)
                }
                .accessibilityLabel("Fill \(color.hexString)")
                .offset(offset(index, of: max(colors.count, 1), radius: colorRadius))
            }
            Button("Close", systemImage: "xmark") { store.hidePalette() }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
        }
    }

    private func paletteButton(_ title: String, systemImage: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button {
            action()
            store.hidePalette()
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 40, height: 40)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.accentColor : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel(title)
    }

    /// Item `index` of `count`, evenly round a circle starting at the top.
    private func offset(_ index: Int, of count: Int, radius: CGFloat) -> CGSize {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
        return CGSize(width: CGFloat(cos(angle)) * radius, height: CGFloat(sin(angle)) * radius)
    }

    /// Keeps the whole palette on screen.
    private func clamped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let margin = radius + 40
        return CGPoint(x: min(max(p.x, margin), max(size.width - margin, margin)),
                       y: min(max(p.y, margin), max(size.height - margin, margin)))
    }
}

/// A small lock in the corner of the canvas while the rotation is locked, so a pinch
/// that won't rotate isn't a mystery. Tapping it turns the lock off.
private struct RotationLockBadge: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        if ui.rotationLocked {
            Button {
                store.setRotationLocked(false)
            } label: {
                Image(systemName: "lock.rotation")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Rotation Locked")
            .accessibilityHint("Turns the rotation lock off, so two fingers rotate the canvas.")
            .transition(.opacity)
        }
    }
}

/// Briefly confirms an undo or redo made with a multi-finger tap, and shows
/// "Importing..." for as long as an SVG import reads its file.
private struct ToastView: View {
    let ui: EditorUIState
    @State private var visible = false

    var body: some View {
        Group {
            if ui.isImporting {
                label("Importing...")
            } else if visible, let toast = ui.toast {
                label(toast.text)
            }
        }
        .allowsHitTesting(false)
        .task(id: ui.toast?.count) {
            guard let toast = ui.toast else { return }
            withAnimation(.easeOut(duration: 0.15)) { visible = true }
            // Longer messages (an import summary) stay up long enough to read.
            try? await Task.sleep(for: .milliseconds(toast.text.count > 12 ? 2500 : 700))
            withAnimation(.easeIn(duration: 0.3)) { visible = false }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .transition(.opacity)
    }
}

#Preview {
    ContentView(document: .constant(PresentationDocument()))
}
