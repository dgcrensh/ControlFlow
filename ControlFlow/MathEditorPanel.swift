import ControlFlowCore
import SwiftUI
import UIKit

/// The source panel for the formula being edited, docked above the keyboard: a row of
/// insert buttons, the LaTeX in a monospaced field, and the error when it doesn't
/// typeset. The canvas shows the formula as it typesets.
struct MathEditorPanel: View {
    let store: CanvasStore
    let edit: MathEditState
    @State private var field = MathSourceField.Controller()

    /// LaTeX the insert buttons put in, with the caret in the first empty `{}`.
    private static let structures: [(title: String, symbol: String, latex: String)] = [
        ("Fraction", "a/b", "\\frac{}{}"),
        ("Root", "√", "\\sqrt{}"),
        ("Superscript", "x²", "^{}"),
        ("Subscript", "x₂", "_{}"),
        ("Sum", "∑", "\\sum_{}^{}"),
        ("Integral", "∫", "\\int_{}^{}"),
        ("Matrix", "( )", "\\begin{pmatrix} {} & {} \\\\ {} & {} \\end{pmatrix}"),
    ]
    private static let relations: [(symbol: String, latex: String)] = [
        ("≤", "\\le "), ("≥", "\\ge "), ("≠", "\\ne "), ("→", "\\to "), ("∈", "\\in "),
    ]
    private static let greek: [(symbol: String, latex: String)] = [
        ("α", "\\alpha "), ("β", "\\beta "), ("γ", "\\gamma "), ("δ", "\\delta "), ("ε", "\\epsilon "),
        ("θ", "\\theta "), ("λ", "\\lambda "), ("μ", "\\mu "), ("π", "\\pi "), ("σ", "\\sigma "),
        ("φ", "\\phi "), ("ω", "\\omega "), ("Γ", "\\Gamma "), ("Δ", "\\Delta "), ("Θ", "\\Theta "),
        ("Λ", "\\Lambda "), ("Π", "\\Pi "), ("Σ", "\\Sigma "), ("Φ", "\\Phi "), ("Ω", "\\Omega "),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Self.structures, id: \.title) { item in
                            insertButton(item.symbol, item.latex).accessibilityLabel(item.title)
                        }
                        Menu {
                            ForEach(Self.greek, id: \.symbol) { item in
                                Button(item.symbol) { field.insert(item.latex) }
                            }
                        } label: {
                            Text("αβ").frame(minWidth: 36, minHeight: 32)
                        }
                        .accessibilityLabel("Greek letters")
                        Divider().frame(height: 24)
                        ForEach(Self.relations, id: \.symbol) { item in insertButton(item.symbol, item.latex) }
                    }
                }
                Button("Done") { store.endMathEdit() }
                    .bold()
            }
            MathSourceField(store: store, edit: edit, controller: field)
                .frame(height: 76)
                .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
            if let error = edit.error {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text("The formula on the canvas updates as you type. \\color is ignored; color it with its fill.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: 760)
    }

    private func insertButton(_ symbol: String, _ latex: String) -> some View {
        Button { field.insert(latex) } label: {
            Text(symbol).frame(minWidth: 36, minHeight: 32)
        }
        .buttonStyle(.bordered)
    }
}

/// A monospaced `UITextView` for LaTeX, so the hardware keyboard and Scribble work, with
/// smart quotes, dashes and autocorrect off. It copies the draft from the editor when a
/// session starts or the editor changes it, and reports every change back.
struct MathSourceField: UIViewRepresentable {
    let store: CanvasStore
    let edit: MathEditState
    let controller: Controller

    /// Lets the panel's insert buttons reach the text view.
    @MainActor
    final class Controller {
        weak var textView: UITextView?
        var onChange: ((String) -> Void)?

        /// Puts `latex` in place of the selection, with the caret in its first empty `{}`
        /// (holding the selection, if there was one) or after it.
        func insert(_ latex: String) {
            guard let textView, let range = textView.selectedTextRange else { return }
            let selected = textView.text(in: range) ?? ""
            var text = latex
            var caret = latex.utf16.count
            if let slot = latex.range(of: "{}") {
                let offset = latex.utf16.distance(from: latex.startIndex, to: slot.lowerBound) + 1
                text = latex.replacingCharacters(in: slot, with: "{\(selected)}")
                caret = offset + selected.utf16.count
            } else if !selected.isEmpty {
                text = latex + selected
                caret = text.utf16.count
            }
            let start = textView.offset(from: textView.beginningOfDocument, to: range.start)
            textView.replace(range, withText: text)
            if let position = textView.position(from: textView.beginningOfDocument, offset: start + caret) {
                textView.selectedTextRange = textView.textRange(from: position, to: position)
            }
            onChange?(textView.text ?? "")
        }
    }

    final class FieldView: UITextView {
        var onEscape: (() -> Void)?

        override var keyCommands: [UIKeyCommand]? {
            [UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))]
        }

        @objc private func escape() { onEscape?() }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var store: CanvasStore
        /// The session and revision whose draft the field shows.
        var synced: (session: Int, revision: Int)?
        var copying = false

        init(store: CanvasStore) { self.store = store }

        func textViewDidChange(_ textView: UITextView) {
            guard !copying else { return }
            store.setMathDraft(textView.text ?? "")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeUIView(context: Context) -> FieldView {
        let view = FieldView()
        view.font = .monospacedSystemFont(ofSize: 17, weight: .regular)
        view.backgroundColor = .clear
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.inlinePredictionType = .no
        view.keyboardType = .asciiCapable
        view.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        view.delegate = context.coordinator
        view.onEscape = { [weak store] in store?.endMathEdit() }
        controller.textView = view
        controller.onChange = { [weak store] in store?.setMathDraft($0) }
        return view
    }

    func updateUIView(_ view: FieldView, context: Context) {
        let coordinator = context.coordinator
        coordinator.store = store
        controller.textView = view
        guard coordinator.synced?.session != edit.session || coordinator.synced?.revision != edit.revision else { return }
        let isNewSession = coordinator.synced?.session != edit.session
        coordinator.synced = (edit.session, edit.revision)
        coordinator.copying = true
        if view.text != edit.draft { view.text = edit.draft }
        coordinator.copying = false
        if isNewSession {
            let end = view.endOfDocument
            view.selectedTextRange = view.textRange(from: end, to: end)
            // Up comes the keyboard, once the panel is on screen.
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }
}

/// The size and style of new formulas and of the selected formulas, and Edit.
struct MathStyleControls: View {
    let store: CanvasStore
    let ui: EditorUIState

    var body: some View {
        let style = ui.mathStyle
        HStack(spacing: 14) {
            Stepper("\(Int(style.size.rounded())) pt", value: Binding(get: { style.size }, set: { store.setMathSize($0) }),
                    in: TextContent.sizeRange, step: 4)
                .fixedSize()
            Picker("Style", selection: Binding(get: { style.display }, set: { store.setMathDisplay($0) })) {
                Text("Display").tag(true)
                Text("Inline").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 150)
            if ui.selectionHasMath, !ui.isEditingMath {
                Button("Edit", systemImage: "pencil.line") { store.editSelectedMath() }
            }
        }
    }
}
