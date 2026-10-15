import ControlFlowCore
import SwiftUI

/// The timeline strip above the style bar: the Opening chip, then each sequence as a
/// block of keyframe chips, with a transition handle before each keyframe. Tap a chip to
/// edit its keyframe, tap a handle for its transition, or drag along a handle to scrub
/// through it. Onion skin, Play Sequence, Set Keyframe and New Sequence sit at the end.
struct TimelineBar: View {
    let store: CanvasStore
    let ui: EditorUIState
    /// The keyframe whose transition popover is open.
    @State private var editingTransition: Int?
    @State private var renaming: Renaming?
    @State private var newName = ""

    /// A keyframe or sequence being renamed.
    private enum Renaming: Equatable {
        case keyframe(Int)
        case sequence(Int)
    }

    /// The opening chip's id in `ui.thumbnails` and for scrolling.
    private static let openingID = 0

    var body: some View {
        HStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 8) {
                        openingChip
                        ForEach(ui.timeline.sequences) { block in
                            sequenceBlock(block)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: ui.timeline.currentChip?.id) { _, id in
                    withAnimation { proxy.scrollTo(id ?? Self.openingID, anchor: .center) }
                }
            }
            Divider().frame(height: 44)
            controls
                .padding(.trailing, 16)
        }
        .labelStyle(.iconOnly)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
        .alert(renamingTitle, isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { target in
            TextField("Name", text: $newName)
            Button("Rename") {
                switch target {
                case .keyframe(let id): store.renameKeyframe(id, to: newName)
                case .sequence(let id): store.renameSequence(id, to: newName)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Leave it empty to show the number.")
        }
    }

    private var renamingTitle: String {
        if case .sequence = renaming { return "Rename Sequence" }
        return "Rename Keyframe"
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            Toggle(isOn: Binding(get: { ui.showsOnionSkin }, set: { store.setOnionSkin($0) })) {
                Label("Onion Skin", systemImage: "square.2.layers.3d")
            }
            .toggleStyle(.button)
            if ui.isPlaying {
                Button("Stop", systemImage: "stop.fill") { store.stopPlaying() }
            } else {
                Button("Play Sequence", systemImage: "play.fill") { store.playSequence() }
                    .disabled(ui.timeline.sequences.isEmpty)
            }
            Button("Set Keyframe", systemImage: "plus.rectangle.on.rectangle") { store.setKeyframe() }
            Button("New Sequence", systemImage: "rectangle.stack.badge.plus") { store.newSequence() }
        }
        .font(.title3)
    }

    // MARK: Chips

    private var openingChip: some View {
        chipFace(id: Self.openingID, title: "Opening", isCurrent: ui.timeline.openingIsCurrent)
            .id(Self.openingID)
            .onTapGesture { store.selectKeyframe(nil) }
            .accessibilityLabel("Opening state")
            .accessibilityAddTraits(.isButton)
            .padding(.bottom, 6)
    }

    private func sequenceBlock(_ block: TimelineStrip.Block) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(block.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(ControlFlowCore.Transition.seconds(block.duration) + "s")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    sequenceMenu(block)
                } label: {
                    Label("Sequence Actions", systemImage: "ellipsis.circle")
                        .font(.footnote)
                }
            }
            .padding(.leading, 4)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(block.chips) { chip in
                    transitionHandle(chip)
                    keyframeChip(chip, in: block)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(block.isCurrent ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06)))
        // Dropping a chip on the block's empty space moves it to the end of the block.
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap({ Int($0) }) else { return false }
            store.moveKeyframe(id, before: nil, inSequence: block.id)
            return true
        }
    }

    @ViewBuilder
    private func sequenceMenu(_ block: TimelineStrip.Block) -> some View {
        Button("Play Sequence", systemImage: "play.fill") { store.playSequence(block.id) }
        Button("Rename", systemImage: "pencil") {
            newName = block.name ?? ""
            renaming = .sequence(block.id)
        }
        if let current = block.chips.first(where: \.isCurrent), current.id != block.chips.first?.id {
            Button("Split at Current Keyframe", systemImage: "scissors") { store.splitSequence(at: current.id) }
        }
        if block.canMergeWithNext {
            Button("Merge with Next", systemImage: "arrow.right.to.line") { store.mergeSequenceWithNext(block.id) }
        }
        Divider()
        Button("Delete Sequence", systemImage: "trash", role: .destructive) { store.deleteSequence(block.id) }
    }

    private func keyframeChip(_ chip: TimelineStrip.Chip, in block: TimelineStrip.Block) -> some View {
        chipFace(id: chip.id, title: chip.title, isCurrent: chip.isCurrent)
            .id(chip.id)
            .onTapGesture { store.selectKeyframe(chip.id) }
            .accessibilityLabel("Keyframe \(chip.title)")
            .accessibilityAddTraits(chip.isCurrent ? [.isButton, .isSelected] : .isButton)
            .contextMenu {
                Button("Rename", systemImage: "pencil") {
                    newName = chip.name ?? ""
                    renaming = .keyframe(chip.id)
                }
                Button("Duplicate Keyframe", systemImage: "plus.square.on.square") { store.duplicateKeyframe(chip.id) }
                Button("Revert Keyframe", systemImage: "arrow.uturn.backward") { store.revertKeyframe(chip.id) }
                    .disabled(chip.changeCount == 0)
                if chip.id != block.chips.first?.id {
                    Button("Split Sequence Here", systemImage: "scissors") { store.splitSequence(at: chip.id) }
                }
                Divider()
                Button("Delete Keyframe", systemImage: "trash", role: .destructive) { store.deleteKeyframe(chip.id) }
            }
            // Dragging a chip onto another moves it in front of that one.
            .draggable(String(chip.id))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap({ Int($0) }) else { return false }
                store.moveKeyframe(id, before: chip.id, inSequence: block.id)
                return true
            }
    }

    /// A chip: the scene's thumbnail over its name or number, outlined when current.
    private func chipFace(id: Int, title: String, isCurrent: Bool) -> some View {
        let height: CGFloat = 36
        let aspect = ui.viewport.height > 0 ? ui.viewport.width / ui.viewport.height : 16.0 / 9
        let width = min(max(height * CGFloat(aspect), 24), 72)
        return VStack(spacing: 3) {
            Group {
                if let image = ui.thumbnails[id] {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                } else {
                    Rectangle().fill(ui.viewport.background.color)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isCurrent ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: isCurrent ? 2.5 : 1)
            }
            Text(title)
                .font(.caption2.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: max(width, 44))
        }
        .contentShape(Rectangle())
    }

    // MARK: Transitions

    /// The handle before a keyframe's chip: its duration and curve. Tap it for the
    /// transition popover; drag along it to scrub through the transition on the canvas.
    private func transitionHandle(_ chip: TimelineStrip.Chip) -> some View {
        let width: CGFloat = 46
        let isScrubbing = ui.scrubbing == chip.id
        return VStack(spacing: 2) {
            CurveGlyph(curve: chip.transition.curve)
                .stroke(isScrubbing ? Color.accentColor : Color.secondary, lineWidth: 1.5)
                .frame(width: 22, height: 14)
            Text(chip.transition.durationLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, height: 44)
        .background(isScrubbing ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { editingTransition = chip.id }
        .highPriorityGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag in store.scrub(into: chip.id, fraction: Double(drag.location.x / width)) }
                .onEnded { _ in store.endScrub() }
        )
        .popover(isPresented: Binding(get: { editingTransition == chip.id },
                                      set: { if !$0 { editingTransition = nil } })) {
            TransitionPopover(store: store, ui: ui, keyframe: chip.id)
        }
        .accessibilityLabel("Transition into \(chip.title), \(chip.transition.durationLabel), \(chip.transition.curve.displayName)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A transition's duration, timing curve presets and the curve editor. Each change
/// previews the transition on the canvas.
struct TransitionPopover: View {
    let store: CanvasStore
    let ui: EditorUIState
    let keyframe: Int

    private var chip: TimelineStrip.Chip? { ui.timeline.chips.first { $0.id == keyframe } }

    var body: some View {
        if let chip {
            content(chip)
        } else {
            Text("This keyframe is gone.")
                .padding()
        }
    }

    private func content(_ chip: TimelineStrip.Chip) -> some View {
        let transition = chip.transition
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Into \(chip.title)").font(.headline)
                Spacer()
                Button("Preview", systemImage: "play.fill") { store.previewTransition(into: keyframe) }
                    .disabled(transition.duration == 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Duration")
                    Spacer()
                    Text(transition.durationLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("Duration", value: Binding(get: { transition.duration }, set: { set(duration: $0) }),
                            in: 0...ControlFlowCore.Transition.maxDuration, step: 0.1)
                        .labelsHidden()
                }
                Slider(value: Binding(get: { min(transition.duration, 3) },
                                      set: { set(duration: ($0 * 20).rounded() / 20, continuous: true) }),
                       in: 0...3,
                       onEditingChanged: { editing in
                           if !editing { store.previewTransition(into: keyframe) }
                       })
                .accessibilityLabel("Duration")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Curve")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TimingCurve.presets, id: \.self) { preset in
                            Button(preset.displayName) { set(curve: preset) }
                                .buttonStyle(.bordered)
                                .tint(preset == transition.curve ? Color.accentColor : Color.secondary)
                                .font(.footnote)
                        }
                    }
                }
                CurveEditor(curve: transition.curve) { curve, ended in
                    set(curve: curve, continuous: !ended)
                }
                .frame(width: 260, height: 220)
                Text(curveCaption(transition.curve))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .frame(width: 300)
    }

    private func curveCaption(_ curve: TimingCurve) -> String {
        let c = curve.controlPoints
        func f(_ v: Double) -> String { String(format: "%.2f", v) }
        return "\(curve.displayName): cubic-bezier(\(f(c.x1)), \(f(c.y1)), \(f(c.x2)), \(f(c.y2)))"
    }

    private func set(duration: Double, continuous: Bool = false) {
        guard let chip else { return }
        store.setTransition(ControlFlowCore.Transition(duration: min(max(duration, 0), ControlFlowCore.Transition.maxDuration), curve: chip.transition.curve),
                            ofKeyframe: keyframe, continuous: continuous)
        if !continuous { store.previewTransition(into: keyframe) }
    }

    private func set(curve: TimingCurve, continuous: Bool = false) {
        guard let chip else { return }
        store.setTransition(ControlFlowCore.Transition(duration: chip.transition.duration, curve: curve), ofKeyframe: keyframe,
                            continuous: continuous)
        if !continuous { store.previewTransition(into: keyframe) }
    }
}

/// A timing curve's shape in its frame: time across, progress up.
struct CurveGlyph: Shape {
    let curve: TimingCurve
    /// The progress at the frame's top and bottom edges.
    var range: ClosedRange<Double> = 0...1

    nonisolated func path(in rect: CGRect) -> Path {
        Path { path in
            for (i, p) in curve.samples(count: 32).enumerated() {
                let point = CurveGeometry.position(of: p, in: rect, range: range)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }
}

/// The timing curve with its two control points to drag. Progress runs from -0.5 at the
/// bottom to 1.5 at the top, so overshoot shows. `change` gets the new curve, and true
/// when the drag ended.
struct CurveEditor: View {
    let curve: TimingCurve
    let change: (TimingCurve, Bool) -> Void

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let c = curve.controlPoints
            let p0 = CurveGeometry.position(of: Vec2(0, 0), in: rect, range: CurveGeometry.range)
            let p3 = CurveGeometry.position(of: Vec2(1, 1), in: rect, range: CurveGeometry.range)
            let p1 = CurveGeometry.position(of: Vec2(c.x1, c.y1), in: rect, range: CurveGeometry.range)
            let p2 = CurveGeometry.position(of: Vec2(c.x2, c.y2), in: rect, range: CurveGeometry.range)
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                // The unit square: where progress runs from 0 to 1.
                Path { path in
                    path.addRect(CGRect(x: p0.x, y: p3.y, width: p3.x - p0.x, height: p0.y - p3.y))
                }
                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                Path { path in
                    path.move(to: p0)
                    path.addLine(to: p1)
                    path.move(to: p3)
                    path.addLine(to: p2)
                }
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
                CurveGlyph(curve: curve, range: CurveGeometry.range)
                    .stroke(Color.primary, lineWidth: 2)
                handle(at: p1, first: true, in: rect)
                handle(at: p2, first: false, in: rect)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timing curve, \(curve.displayName)")
    }

    private func handle(at point: CGPoint, first: Bool, in rect: CGRect) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
            .frame(width: 22, height: 22)
            .contentShape(Circle().inset(by: -10))
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        change(curve.moving(controlPoint: first, to: CurveGeometry.value(at: drag.location, in: rect)), false)
                    }
                    .onEnded { drag in
                        change(curve.moving(controlPoint: first, to: CurveGeometry.value(at: drag.location, in: rect)), true)
                    }
            )
    }
}

/// Maps a timing curve's time and progress to points in a frame and back.
enum CurveGeometry {
    /// The progress the curve editor shows, bottom to top, so overshoot shows.
    static let range = -0.5...1.5

    /// Where time and progress `p` sit in `rect`, with progress `range` from bottom to top.
    static func position(of p: Vec2, in rect: CGRect, range: ClosedRange<Double>) -> CGPoint {
        let span = max(range.upperBound - range.lowerBound, 1e-9)
        return CGPoint(x: rect.minX + rect.width * CGFloat(p.x),
                       y: rect.maxY - rect.height * CGFloat((p.y - range.lowerBound) / span))
    }

    /// The time and progress at `point` in `rect`.
    static func value(at point: CGPoint, in rect: CGRect) -> Vec2 {
        let span = Self.range.upperBound - Self.range.lowerBound
        return Vec2(Double((point.x - rect.minX) / max(rect.width, 1)),
                    Self.range.lowerBound + Double((rect.maxY - point.y) / max(rect.height, 1)) * span)
    }
}
