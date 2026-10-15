import ControlFlowCore
import SwiftUI

/// Numeric position, size and rotation for the selection, the selected points'
/// position, and fill and outline colors as hex. Each edit is one undo step.
struct InspectorPanel: View {
    let store: CanvasStore
    let ui: EditorUIState
    @State private var fillHex = ""
    @State private var outlineHex = ""
    @State private var degrees = 0.0

    var body: some View {
        Form {
            if let bounds = ui.selectionBounds {
                Section("Selection") {
                    numberRow("X", bounds.minPoint.x) { store.setSelectionX($0) }
                    numberRow("Y", bounds.minPoint.y) { store.setSelectionY($0) }
                    if ui.canTransform {
                        numberRow("W", bounds.width) { store.setSelectionWidth($0) }
                        numberRow("H", bounds.height) { store.setSelectionHeight($0) }
                        LabeledContent("Rotate by") {
                            HStack {
                                TextField("Degrees", value: $degrees, format: .number.precision(.fractionLength(0...2)))
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numbersAndPunctuation)
                                    .frame(width: 70)
                                Text("deg")
                                Button("Apply") {
                                    store.rotateSelection(degrees: degrees)
                                    degrees = 0
                                }
                            }
                        }
                        Button("Reset Pivot to Center") { store.resetPivot() }
                    }
                }
            } else {
                Section { Text("Select something to edit its position and size.").foregroundStyle(.secondary) }
            }

            if let anchor = ui.anchorPosition {
                Section(ui.anchorCount == 1 ? "Selected Point" : "Selected Points (middle)") {
                    numberRow("X", anchor.x) { store.setAnchorX($0) }
                    numberRow("Y", anchor.y) { store.setAnchorY($0) }
                }
            }

            Section("Color") {
                hexRow("Fill", text: $fillHex) { store.applyPaletteFill($0) }
                hexRow("Outline", text: $outlineHex) { store.applyPaletteOutline($0) }
            }
        }
        .frame(width: 340, height: 460)
        .onAppear(perform: syncHex)
        .onChange(of: ui.style) { _, _ in syncHex() }
    }

    private func syncHex() {
        fillHex = ui.style.fill.hexString
        outlineHex = ui.style.outline.hexString
    }

    private func numberRow(_ title: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 110)
        }
    }

    /// A `#RRGGBB` or `#RRGGBBAA` field, applied when submitted.
    private func hexRow(_ title: String, text: Binding<String>, apply: @escaping (RGBAColor) -> Void) -> some View {
        LabeledContent(title) {
            TextField("#RRGGBB", text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .frame(width: 140)
                .onSubmit {
                    if let color = RGBAColor(hex: text.wrappedValue) { apply(color) } else { syncHex() }
                }
        }
    }
}
