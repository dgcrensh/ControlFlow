import ControlFlowCore
import SwiftUI

/// Opacity, gradients, outline options, varying width, clipping and global colors.
/// Changes apply to the selection; outline options also apply to new shapes. A slider
/// drag is one undo step.
struct AppearancePanel: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        Form {
            if let appearance = ui.appearance {
                Section("Shape") {
                    opacityRow(appearance.opacity)
                    Toggle("Clip to Shape Below", isOn: Binding(get: { appearance.isClipped }, set: { store.setClipped($0) }))
                        .disabled(!ui.canClip && !appearance.isClipped)
                    if let group = ui.selectedGroupID, let part = ui.selectedGroupPart {
                        Toggle("Clip Group to Shape Below", isOn: Binding(get: { ui.selectedGroupClipped },
                                                                          set: { store.setGroupClipped(group, inPart: part, $0) }))
                            .disabled(!ui.canClipSelectedGroup && !ui.selectedGroupClipped)
                    }
                }
                if appearance.isClosed {
                    GradientSection(store: store, ui: ui, gradient: appearance.gradient)
                }
            } else {
                Section { Text("Select shapes to change their opacity, gradient and clipping.").foregroundStyle(.secondary) }
            }

            OutlineSection(store: store, ui: ui, canAlign: ui.appearance?.isClosed ?? true)

            Section("Width Along the Outline") {
                Toggle("Pencil Pressure Sets Width", isOn: Binding(get: { ui.pressureWidth }, set: { store.setPressureWidth($0) }))
                if let width = ui.anchorWidth {
                    LabeledContent("Selected Points") {
                        Slider(value: Binding(get: { width }, set: { store.setAnchorWidth(($0 * 20).rounded() / 20) }), in: 0...3)
                            .frame(width: 150)
                        Text("\(width, format: .number.precision(.fractionLength(2)))x")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                } else if ui.appearance != nil {
                    Text("Select points with Direct Select to set the width there.").foregroundStyle(.secondary)
                }
                if ui.appearance?.hasOutline == true {
                    Button("Make Width Even") { store.resetOutlineWidths() }
                }
            }

            GlobalColorsSection(store: store, ui: ui)
        }
        .frame(width: 380, height: 560)
    }

    private func opacityRow(_ opacity: Double) -> some View {
        LabeledContent("Opacity") {
            Slider(value: Binding(get: { opacity }, set: { store.setOpacity(($0 * 100).rounded() / 100) }), in: 0...1)
                .frame(width: 150)
            Text("\(Int((opacity * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }
}

private struct GradientSection: View {
    let store: CanvasStore
    let ui: EditorUIState
    let gradient: ShapeGradient?

    private enum Choice: Hashable { case none, linear, radial }

    var body: some View {
        Section("Fill") {
            Picker("Fill", selection: Binding(get: { choice }, set: { set($0) })) {
                Text("Solid").tag(Choice.none)
                Text("Linear").tag(Choice.linear)
                Text("Radial").tag(Choice.radial)
            }
            .pickerStyle(.segmented)
            if let gradient, let first = gradient.stops.first, let last = gradient.stops.last {
                ColorPicker("Start Color", selection: Binding(get: { first.color.color }, set: { store.setGradientStop(0, $0) }),
                            supportsOpacity: true)
                ColorPicker("End Color", selection: Binding(get: { last.color.color },
                                                            set: { store.setGradientStop(gradient.stops.count - 1, $0) }),
                            supportsOpacity: true)
                if gradient.kind == .linear {
                    LabeledContent("Angle") {
                        Slider(value: Binding(get: { angle(of: gradient) }, set: { store.setGradientAngle($0.rounded()) }),
                               in: -180...180)
                            .frame(width: 150)
                        Text("\(Int(angle(of: gradient).rounded()))°")
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                }
                LabeledContent("Spread") {
                    Slider(value: Binding(get: { ui.appearance?.gradientSpan ?? 1 }, set: { store.setGradientSpan($0) }),
                           in: 0.1...2)
                        .frame(width: 150)
                }
                Button("Swap Colors") { store.reverseGradient() }
            }
        }
    }

    private var choice: Choice {
        switch gradient?.kind {
        case .linear?: .linear
        case .radial?: .radial
        case nil: .none
        }
    }

    private func set(_ choice: Choice) {
        switch choice {
        case .none: store.setGradient(nil)
        case .linear: store.setGradient(.linear)
        case .radial: store.setGradient(.radial)
        }
    }

    private func angle(of gradient: ShapeGradient) -> Double {
        let d = gradient.end - gradient.start
        return atan2(d.y, d.x) * 180 / .pi
    }
}

private struct OutlineSection: View {
    let store: CanvasStore
    let ui: EditorUIState
    let canAlign: Bool

    private enum Dash: String, CaseIterable, Identifiable {
        case solid = "Solid", dashed = "Dashed", long = "Long Dashes", dotted = "Dotted"
        var id: String { rawValue }
    }

    var body: some View {
        Section("Outline") {
            Picker("Ends", selection: Binding(get: { ui.style.outlineCap }, set: { store.setOutlineCap($0) })) {
                Text("Butt").tag(LineCap.butt)
                Text("Round").tag(LineCap.round)
                Text("Square").tag(LineCap.square)
            }
            .pickerStyle(.segmented)
            Picker("Corners", selection: Binding(get: { ui.style.outlineJoin }, set: { store.setOutlineJoin($0) })) {
                Text("Miter").tag(LineJoin.miter)
                Text("Round").tag(LineJoin.round)
                Text("Bevel").tag(LineJoin.bevel)
            }
            .pickerStyle(.segmented)
            if ui.style.outlineJoin == .miter {
                Stepper(value: Binding(get: { ui.style.miterLimit }, set: { store.setMiterLimit($0) }), in: 1...20, step: 0.5) {
                    Text("Miter Limit \(ui.style.miterLimit, format: .number.precision(.fractionLength(1)))")
                }
            }
            Picker("Dashes", selection: Binding(get: { dash }, set: { setDash($0) })) {
                ForEach(Dash.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Position", selection: Binding(get: { ui.style.outlineAlignment }, set: { store.setOutlineAlignment($0) })) {
                Text("Center").tag(StrokeAlignment.center)
                Text("Inside").tag(StrokeAlignment.inside)
                Text("Outside").tag(StrokeAlignment.outside)
            }
            .pickerStyle(.segmented)
            .disabled(!canAlign)
        }
    }

    /// Presets are in multiples of the outline width, so they look the same at any width.
    private func pattern(_ dash: Dash) -> [Double] {
        let w = max(ui.style.outlineWidth, 1)
        switch dash {
        case .solid: return []
        case .dashed: return [3 * w, 2 * w]
        case .long: return [8 * w, 3 * w]
        case .dotted: return [0, 2 * w]
        }
    }

    private var dash: Dash {
        let current = ui.style.outlineDash
        if current.isEmpty { return .solid }
        return Dash.allCases.first { pattern($0) == current } ?? .dashed
    }

    private func setDash(_ dash: Dash) {
        // Dots are zero-length dashes, which only round or square ends make visible.
        if dash == .dotted, ui.style.outlineCap == .butt { store.setOutlineCap(.round) }
        store.setOutlineDash(pattern(dash))
    }
}

private struct GlobalColorsSection: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        Section {
            ForEach(ui.globalColors) { global in
                GlobalColorRow(store: store, global: global,
                               fillFollows: ui.appearance?.fillGlobal == global.id,
                               outlineFollows: ui.appearance?.outlineGlobal == global.id)
            }
            Button("New Global Color from Fill", systemImage: "plus") { store.addGlobalColorFromFill() }
        } header: {
            Text("Global Colors")
        } footer: {
            Text("Shapes filled or outlined with a global color change with it.")
        }
    }
}

private struct GlobalColorRow: View {
    let store: CanvasStore
    let global: GlobalColor
    let fillFollows: Bool
    let outlineFollows: Bool
    @State private var name = ""

    var body: some View {
        HStack {
            ColorPicker("Color", selection: Binding(get: { global.color.color }, set: { store.setGlobalColor(global.id, $0) }),
                        supportsOpacity: true)
                .labelsHidden()
            TextField("Name", text: $name)
                .onSubmit { store.renameGlobalColor(global.id, to: name) }
            Button("Fill", systemImage: fillFollows ? "drop.fill" : "drop") { store.applyGlobalFill(global.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            Button("Outline", systemImage: outlineFollows ? "circle.inset.filled" : "circle") {
                store.applyGlobalOutline(global.id)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            Button("Delete", systemImage: "trash", role: .destructive) { store.removeGlobalColor(global.id) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .onAppear { name = global.name }
        .onChange(of: global.name) { _, new in name = new }
    }
}
