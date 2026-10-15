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
            if ui.isAtKeyframe, ui.selection == .layer || ui.selection == .shape {
                Section {
                    if ui.keyedProperties.isEmpty {
                        Text("The selection doesn't change in this keyframe.").foregroundStyle(.secondary)
                    } else {
                        LabeledContent("Changed") {
                            Text(TimelineStrip.propertyNames(ui.keyedProperties).joined(separator: ", "))
                        }
                        Button("Revert to Previous") { store.revertSelectionToPrevious() }
                    }
                } header: {
                    Text("This Keyframe")
                } footer: {
                    Text("Fields marked with a dot are keyed here.")
                }
            }
            if let bounds = ui.selectionBounds {
                let geometryKeyed = ui.keyedProperties.contains { $0.hasPrefix("transform") || $0 == "points" || $0 == "created" }
                Section("Selection") {
                    numberRow("X", bounds.minPoint.x, keyed: geometryKeyed) { store.setSelectionX($0) }
                    numberRow("Y", bounds.minPoint.y, keyed: geometryKeyed) { store.setSelectionY($0) }
                    if ui.canTransform {
                        numberRow("W", bounds.width, keyed: geometryKeyed) { store.setSelectionWidth($0) }
                        numberRow("H", bounds.height, keyed: geometryKeyed) { store.setSelectionHeight($0) }
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
                hexRow("Fill", text: $fillHex, keyed: ui.keyedProperties.contains { $0.hasPrefix("fill") || $0.hasPrefix("gradient") }) {
                    store.applyPaletteFill($0)
                }
                hexRow("Outline", text: $outlineHex, keyed: ui.keyedProperties.contains { $0.hasPrefix("stroke") }) {
                    store.applyPaletteOutline($0)
                }
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

    private func numberRow(_ title: String, _ value: Double, keyed: Bool = false,
                           set: @escaping (Double) -> Void) -> some View {
        LabeledContent {
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .frame(width: 110)
        } label: {
            label(title, keyed: keyed)
        }
    }

    /// A field's name, with a dot when the current keyframe keys it.
    private func label(_ title: String, keyed: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if keyed { ChangedDot() }
        }
    }

    /// A `#RRGGBB` or `#RRGGBBAA` field, applied when submitted.
    private func hexRow(_ title: String, text: Binding<String>, keyed: Bool,
                        apply: @escaping (RGBAColor) -> Void) -> some View {
        LabeledContent {
            TextField("#RRGGBB", text: text)
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.body.monospaced())
                .frame(width: 140)
                .onSubmit {
                    if let color = RGBAColor(hex: text.wrappedValue) { apply(color) } else { syncHex() }
                }
        } label: {
            label(title, keyed: keyed)
        }
    }
}
