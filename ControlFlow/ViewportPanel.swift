import ControlFlowCore
import SwiftUI
import UniformTypeIdentifiers

/// The viewport: the stage's size, aspect and background. Edits of one field in a row
/// are one undo step. The viewport's top-left stays at the world origin, so changing
/// its size never moves the art.
struct ViewportPanel: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        Form {
            Section {
                Picker("Aspect", selection: Binding(get: { ui.viewport.aspect }, set: { aspect in
                    if let aspect { store.setViewportAspect(aspect) }
                })) {
                    ForEach(Viewport.Aspect.allCases, id: \.self) { aspect in
                        Text(aspect.rawValue).tag(Optional(aspect))
                    }
                    if ui.viewport.aspect == nil {
                        Text("Custom").tag(Viewport.Aspect?.none)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Aspect")
            } footer: {
                Text("Changing the aspect keeps the width.")
            }
            Section("Size") {
                numberRow("Width", ui.viewport.width) { w in store.updateViewport("width") { $0.width = w } }
                numberRow("Height", ui.viewport.height) { h in store.updateViewport("height") { $0.height = h } }
            }
            Section {
                ColorPicker("Background", selection: Binding(
                    get: { ui.viewport.background.color },
                    set: { color in store.updateViewport("background", continuous: true) { $0.background = RGBAColor(color) } }
                ), supportsOpacity: false)
            } footer: {
                Text("Art outside the viewport is dimmed. Exports cover the viewport.")
            }
        }
        .frame(minWidth: 320, minHeight: 360)
    }

    private func numberRow(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 110)
        }
    }
}

/// An exported SVG or PNG, or the web page's folder, handed to the system's file exporter.
struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = []
    static let writableContentTypes: [UTType] = [.svg, .png, .folder]

    var data = Data()
    /// A folder's files by path within it, for a folder export.
    var folder: [String: Data]?
    var type = UTType.svg
    var name = "Untitled"

    init() {}

    init(data: Data, type: UTType, name: String) {
        self.data = data
        self.type = type
        self.name = name
    }

    init(folder: [String: Data], name: String) {
        self.folder = folder
        self.type = .folder
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let folder else { return FileWrapper(regularFileWithContents: data) }
        // Paths such as `images/a.png` need real subfolders: a file wrapper's name can't
        // hold a slash, and writing one fails before the save dialog shows.
        return PresentationDocument.folder(from: folder)
    }
}
