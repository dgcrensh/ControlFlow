import ControlFlowCore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The layers: the presentation at the root, then its layers front to back (each
/// opening to its groups), then the reference image layers.
struct LayersPanel: View {
    let store: CanvasStore
    let ui: EditorUIState
    @Environment(\.dismiss) private var dismiss
    @State private var expanded: Set<String> = []
    @State private var editMode: EditMode = .inactive
    @State private var name = ""
    @State private var renaming: LayerTree.LayerItem?
    @State private var renamingGroup: LayerTree.GroupLayer?
    @State private var newName = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var importingFile = false

    private var isEditing: Bool { editMode.isEditing }

    var body: some View {
        List(selection: Binding(get: { ui.selectedLayers }, set: { store.selectLayers($0) })) {
            Section {
                rootRow
                treeRows
                if ui.layers.layers.isEmpty {
                    Text("Draw with the pencil or pen to add a layer.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                layersHeader
            } footer: {
                Text("Tap a layer's name to select it and draw into it; tap the presentation to go back to a new layer for each stroke. Open a layer to see its groups, and drag layers to reorder.")
            }

            Section {
                HStack {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("Photos", systemImage: "photo")
                    }
                    Button { importingFile = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                }
                .buttonStyle(.bordered)
                ForEach(ui.layers.references) { reference in
                    ReferenceRow(store: store, reference: reference, isSelected: ui.selectedReference == reference.id) {
                        store.adjustReference(reference.id)
                        dismiss()
                    }
                }
            } header: {
                Text("Reference Images")
            } footer: {
                Text("Import a photo or sketch, or drag one onto the canvas. References sit locked under the art, are saved with the document, and are never exported.")
            }
        }
        .environment(\.editMode, $editMode)
        .frame(width: 400, height: 600)
        .onAppear { name = ui.presentationName }
        .onDisappear(perform: commitName)
        .alert("Rename Layer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let layer = renaming { store.renameLayer(layer.id, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Group", isPresented: Binding(get: { renamingGroup != nil }, set: { if !$0 { renamingGroup = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                if let group = renamingGroup { store.renameGroup(group.id, inLayer: group.layer, to: newName) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    store.importReference(data: data, name: "Photo")
                }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                store.importReference(data: data, name: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    // MARK: Header and root

    private var layersHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Layers")
                Spacer()
                Button(isEditing ? "Done" : "Select") {
                    withAnimation { editMode = isEditing ? .inactive : .active }
                }
                .font(.subheadline)
            }
            if isEditing { selectionBar }
        }
        .textCase(nil)
    }

    /// Commands for the layers picked in Select mode.
    private var selectionBar: some View {
        let none = ui.selectedLayers.isEmpty
        return HStack(spacing: 16) {
            Button("Hide", systemImage: "eye.slash") { store.hideSelection() }
            Button("Lock", systemImage: "lock") { store.lockSelection() }
            Button("Bring Forward", systemImage: "square.2.layers.3d.top.filled") { store.arrange(.bringForward) }
            Button("Send Backward", systemImage: "square.2.layers.3d.bottom.filled") { store.arrange(.sendBackward) }
            Spacer()
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteSelection() }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(none)
    }

    /// The presentation itself: its name, and the place new art goes when no layer is active.
    private var rootRow: some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: ui.activeLayer == nil)
            Image(systemName: "rectangle.on.rectangle")
                .foregroundStyle(.secondary)
            TextField("Presentation name", text: $name)
                .submitLabel(.done)
                .onSubmit(commitName)
            if ui.activeLayer != nil, ui.activeLayerIsChosen {
                Button("New Layers") { store.clearActiveLayer() }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    .accessibilityHint("New strokes start a new layer again")
            }
        }
    }

    // MARK: Tree

    private var treeRows: some View {
        let rows = ui.layers.treeRows(expanded: expanded)
        return ForEach(rows) { row in
            Group {
                switch row.kind {
                case .layer:
                    layerRow(row.layer, depth: row.depth, disclosure: disclosure(row)).tag(row.layer.id)
                case .group:
                    if let group = row.group { groupRow(group, depth: row.depth) }
                }
            }
            .moveDisabled(row.kind != .layer)
        }
        .onMove { from, to in
            guard let source = from.first else { return }
            store.moveTreeRow(from: source, to: to, in: rows)
        }
    }

    /// The chevron that opens a row, or room for one.
    private func disclosure(_ row: LayerTree.Row) -> some View {
        Button {
            withAnimation {
                if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
            }
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .font(.footnote.weight(.semibold))
                .frame(width: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(row.canExpand ? 1 : 0)
        .disabled(!row.canExpand)
        .accessibilityLabel(row.isExpanded ? "Close" : "Open")
    }

    private func groupRow(_ group: LayerTree.GroupLayer, depth: Int) -> some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: false)
            visibilityButtons(isHidden: group.isHidden, isLocked: group.isLocked) {
                store.setGroupHidden(group.id, inLayer: group.layer, !group.isHidden)
            } lock: {
                store.setGroupLocked(group.id, inLayer: group.layer, !group.isLocked)
            }
            .padding(.leading, CGFloat(depth) * 16 + 16)
            Button {
                store.selectGroup(group.id, inLayer: group.layer)
            } label: {
                HStack {
                    Label(group.name, systemImage: "square.on.square.squareshape.controlhandles")
                        .lineLimit(1)
                        .foregroundStyle(group.isHidden ? Color.secondary : Color.primary)
                    if group.isClipped {
                        Image(systemName: "arrow.turn.left.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clipped to the shape below")
                    }
                    Spacer()
                    Text(shapeCount(group.shapeCount))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if ui.selectedGroupID == group.id {
                        Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isEditing || group.isHidden || group.isLocked)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                newName = group.name
                renamingGroup = group
            }
            Toggle(isOn: Binding(get: { group.isClipped }, set: { store.setGroupClipped(group.id, inLayer: group.layer, $0) })) {
                Label("Clip to Shape Below", systemImage: "arrow.turn.left.down")
            }
            .disabled(!group.canClip && !group.isClipped)
        }
    }

    // MARK: Layer rows

    /// A layer: the active-layer bar, eye and lock, and its name, which selects it and
    /// makes it the layer new art goes into.
    private func layerRow(_ layer: LayerTree.LayerItem, depth: Int, disclosure: some View) -> some View {
        HStack(spacing: 10) {
            ActiveBar(isActive: ui.activeLayer == layer.id)
            disclosure
                .padding(.leading, CGFloat(depth) * 16)
            visibilityButtons(isHidden: layer.isHidden, isLocked: layer.isLocked) {
                store.setLayerHidden(layer.id, !layer.isHidden)
            } lock: {
                store.setLayerLocked(layer.id, !layer.isLocked)
            }
            if isEditing {
                layerLabel(layer)
            } else {
                Button { store.activateLayer(layer.id) } label: { layerLabel(layer) }
                    .buttonStyle(.plain)
                    .disabled(layer.isHidden || layer.isLocked)
            }
        }
        .contextMenu { layerMenu(layer) }
        .swipeActions {
            Button("Delete", systemImage: "trash", role: .destructive) { store.deleteLayer(layer.id) }
            Button("Rename", systemImage: "pencil") { startRenaming(layer) }
        }
    }

    private func layerLabel(_ layer: LayerTree.LayerItem) -> some View {
        HStack {
            Text(layer.name)
                .lineLimit(1)
                .foregroundStyle(layer.isHidden ? Color.secondary : Color.primary)
            if ui.isolatedLayer == layer.id {
                Image(systemName: "scope").foregroundStyle(Color.accentColor)
            }
            Spacer()
            if layer.hasHiddenOrLockedShapes {
                Image(systemName: "eye.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Some shapes are hidden or locked")
            }
            Text(shapeCount(layer.shapeCount))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if !isEditing, ui.selectedLayers.contains(layer.id) {
                Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    private func visibilityButtons(isHidden: Bool, isLocked: Bool, hide: @escaping () -> Void,
                                   lock: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button(isHidden ? "Show" : "Hide", systemImage: isHidden ? "eye.slash" : "eye", action: hide)
                .foregroundStyle(isHidden ? Color.secondary : Color.primary)
            Button(isLocked ? "Unlock" : "Lock", systemImage: isLocked ? "lock.fill" : "lock.open", action: lock)
                .foregroundStyle(isLocked ? Color.primary : Color.secondary)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func layerMenu(_ layer: LayerTree.LayerItem) -> some View {
        Button("Rename", systemImage: "pencil") { startRenaming(layer) }
        if ui.isolatedLayer == layer.id {
            Button("Exit Isolation", systemImage: "scope") { store.exitIsolation() }
        } else {
            Button("Isolate", systemImage: "scope") {
                store.isolate(layer: layer.id)
                dismiss()
            }
        }
        if store.canMergeLayerDown(layer.id) {
            Button("Merge Down", systemImage: "arrow.down.to.line") { store.mergeLayerDown(layer.id) }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { store.deleteLayer(layer.id) }
    }

    private func shapeCount(_ count: Int) -> String {
        count == 1 ? "1 shape" : "\(count) shapes"
    }

    private func startRenaming(_ layer: LayerTree.LayerItem) {
        newName = layer.name
        renaming = layer
    }

    private func commitName() {
        if name != ui.presentationName { store.renamePresentation(name) }
    }
}

/// The bar at a row's leading edge marking where new art goes.
private struct ActiveBar: View {
    let isActive: Bool

    var body: some View {
        Capsule()
            .fill(isActive ? Color.accentColor : Color.clear)
            .frame(width: 4, height: 26)
            .accessibilityLabel(isActive ? "New art goes here" : "")
            .accessibilityHidden(!isActive)
    }
}

private struct ReferenceRow: View {
    let store: CanvasStore
    let reference: ReferenceImage
    let isSelected: Bool
    let adjust: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(reference.isHidden ? "Show" : "Hide", systemImage: reference.isHidden ? "eye.slash" : "eye") {
                store.setReferenceHidden(reference.id, !reference.isHidden)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 4) {
                Text(reference.name).lineLimit(1)
                Slider(value: Binding(get: { reference.opacity }, set: { store.setReferenceOpacity(reference.id, $0) }),
                       in: 0.05...1)
            }

            Button("Move, Scale, Rotate", systemImage: "arrow.up.and.down.and.arrow.left.and.right", action: adjust)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            Button("Remove", systemImage: "trash", role: .destructive) { store.removeReference(reference.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}
