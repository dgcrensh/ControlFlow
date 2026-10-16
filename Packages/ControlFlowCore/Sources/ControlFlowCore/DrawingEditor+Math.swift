import Foundation

/// The formula being edited (see `DrawingEditor.beginMathEdit`).
///
/// The shape keeps the last source that typeset; the source being typed lives here in
/// `draft` until it typesets too, so the document never holds a formula that doesn't.
public struct MathEditState: Hashable, Sendable {
    public var ref: ShapeRef
    /// The LaTeX in the editor's field.
    public internal(set) var draft: String
    /// Why `draft` didn't typeset, if it didn't.
    public internal(set) var error: MathError?
    /// Numbers the session: its edits are one undo step.
    public let session: Int
    /// Increments when the editor itself changes the draft (a paste starting a formula,
    /// say), so the app copies it back into its text field.
    public internal(set) var revision = 0
    /// True when the session made the formula, so it can center its pivot at the end.
    let isNew: Bool
}

extension DrawingEditor {
    // MARK: Editing sessions

    /// Starts editing formula `ref`, which becomes the selection. Ends any other edit first.
    public mutating func beginMathEdit(_ ref: ShapeRef) {
        beginMathEdit(ref, isNew: false)
    }

    private mutating func beginMathEdit(_ ref: ShapeRef, isNew: Bool) {
        guard let idx = drawing.indices(ref), let math = drawing.layers[idx.0].shapes[idx.1].math,
              drawing.layers[idx.0].isEditable(idx.1) else { return }
        if mathEdit?.ref == ref { return }
        if mathEdit != nil { endMathEdit() }
        if textEdit != nil { endTextEdit() }
        cancelGesture()
        let wanted = Selection.shape(layer: ref.layer, shape: ref.shape)
        if selection != wanted { selection = wanted }
        if tool != .math {
            textEditKeepsTool = true
            tool = .math
            textEditKeepsTool = false
        }
        textEditCount += 1
        mathEdit = MathEditState(ref: ref, draft: math.source, error: nil, session: textEditCount, revision: 1, isNew: isNew)
    }

    /// Starts a new, empty formula with its box's left middle at world point `p`, in
    /// `mathStyle` and the fill color, and edits it.
    public mutating func beginMathEdit(at p: Vec2) {
        if mathEdit != nil { endMathEdit() }
        if textEdit != nil { endTextEdit() }
        var shape = VectorShape(id: drawing.makeID(), math: mathStyle.style, fill: style.fill)
        shape.transform = Transform(position: p - Vec2(0, mathStyle.size / 2))
        let before = drawing
        let ref = insertNewShape(shape, joinNeedsOverlap: false)
        let saved = style
        selection = .shape(layer: ref.layer, shape: ref.shape)
        style = saved
        beginMathEdit(ref, isNew: true)
        guard let session = mathEdit?.session else { return }
        commit(from: before, key: mathEditKey(session))
    }

    func mathEditKey(_ session: Int) -> String { "math-\(session)" }

    /// The formula the draft would make: the edited shape's, with the draft as its
    /// source. The app typesets it (after a pause in typing) and reports back with
    /// `mathDraftTypeset`. Nil when nothing is being edited or the draft is empty.
    public var mathDraftContent: MathContent? {
        guard let edit = mathEdit, !edit.draft.isEmpty, var math = drawing.shape(edit.ref)?.math else { return nil }
        math.source = edit.draft
        return math
    }

    /// The source in the editor's field after the user typed. When the draft's layout
    /// or error is already known it applies at once; otherwise the app typesets it.
    public mutating func setMathDraft(_ draft: String) {
        guard var edit = mathEdit, edit.draft != draft else { return }
        edit.draft = draft
        edit.error = nil
        mathEdit = edit
        if let content = mathDraftContent { mathDraftTypeset(content) }
    }

    /// The typesetter finished `content` (a `mathDraftContent`). When it is still the
    /// draft, the formula takes its source if it typeset, or the edit keeps its error if
    /// it didn't. A result for a draft that has since changed is dropped.
    public mutating func mathDraftTypeset(_ content: MathContent) {
        guard var edit = mathEdit, content == mathDraftContent, let idx = drawing.indices(edit.ref) else { return }
        if MathTypesetting.layout(content) != nil {
            edit.error = nil
            mathEdit = edit
            guard drawing.layers[idx.0].shapes[idx.1].math?.source != content.source else { return }
            let before = drawing
            drawing.layers[idx.0].shapes[idx.1].math?.source = content.source
            commit(from: before, key: mathEditKey(edit.session))
        } else if let error = MathTypesetting.error(content) {
            edit.error = error
            mathEdit = edit
        }
    }

    /// Ends editing: a formula whose field was left empty (or that never typeset) is
    /// deleted, and a new one's pivot moves to the middle of its box. Part of the
    /// session's undo step.
    public mutating func endMathEdit() {
        guard let edit = mathEdit else { return }
        mathEdit = nil
        guard let idx = drawing.indices(edit.ref), let math = drawing.layers[idx.0].shapes[idx.1].math else { return }
        let before = drawing
        let empty = edit.draft.allSatisfy(\.isWhitespace) || math.source.isEmpty
        if empty {
            removeShape(edit.ref)
            if drawing.indices(edit.ref) == nil, selection == .shape(layer: edit.ref.layer, shape: edit.ref.shape) {
                selection = .none
            }
        } else if edit.isNew {
            let shape = drawing.layers[idx.0].shapes[idx.1]
            drawing.layers[idx.0].shapes[idx.1].transform = shape.transform.withPivot(shape.geometryBounds.center)
            if drawing.layers[idx.0].shapes.count == 1 {
                drawing.layers[idx.0].setWorldPivot(drawing.layers[idx.0].bounds.center)
            }
        }
        commit(from: before, key: mathEditKey(edit.session))
        // A new formula left empty leaves nothing to undo.
        if edit.isNew, empty, var last = undoStack.undoStates.last?.presentation {
            last.opening.nextID = snapshot.presentation.opening.nextID
            if last == snapshot.presentation { undoStack.dropLast() }
        }
        validateSelection()
    }

    /// The formula being edited as the canvas shows it: its box in world space (four
    /// corners), and whether the draft failed to typeset, so the overlay outlines it in red.
    public var mathEditGeometry: (frame: [Vec2], failed: Bool)? {
        guard let edit = mathEdit, let idx = drawing.indices(edit.ref), let math = drawing.layers[idx.0].shapes[idx.1].math
        else { return nil }
        let m = drawing.layers[idx.0].worldMatrix(ofShape: idx.1)
        let box = MathTypesetting.layout(math)?.bounds ?? MathLayout.placeholder(math)
        return (box.corners.map(m.apply), edit.error != nil)
    }

    /// Edits the first selected formula (the context bar's Edit), switching to the Math tool.
    public mutating func editSelectedMath() {
        guard let idx = drawing.shapeIndices(in: selection).first(where: { drawing.layers[$0.0].shapes[$0.1].math != nil })
        else { return }
        beginMathEdit(ShapeRef(layer: drawing.layers[idx.0].id, shape: drawing.layers[idx.0].shapes[idx.1].id))
    }

    // MARK: Taps

    /// Edits formula `ref`, switching to the Math tool (a select-tool double tap).
    mutating func editMath(_ ref: ShapeRef) {
        beginMathEdit(ref)
    }

    /// A Math-tool tap: edits the formula tapped, ends the edit when it lands on empty
    /// canvas, or else starts a new formula there.
    mutating func tapMath(on ref: ShapeRef?, at p: Vec2) {
        if let ref {
            beginMathEdit(ref)
        } else if mathEdit != nil {
            endMathEdit()
        } else {
            beginMathEdit(at: p)
        }
    }

    // MARK: Style

    /// The first selected shape's formula, if it is one.
    public var selectedMath: MathContent? {
        guard let first = drawing.shapeIndices(in: selection).first else { return nil }
        return drawing.layers[first.0].shapes[first.1].math
    }

    /// True when the selection holds a formula.
    public var selectionHasMath: Bool {
        drawing.shapeIndices(in: selection).contains { drawing.layers[$0.0].shapes[$0.1].math != nil }
    }

    /// Changes the size or style of new formulas and of every selected formula (one undo
    /// step per run of changes with the same `key`).
    public mutating func setMathStyle(key: String, _ change: (inout MathContent) -> Void) {
        func restyled(_ math: MathContent) -> MathContent {
            var out = math
            change(&out)
            out.source = math.source
            out.size = min(max(out.size, TextContent.sizeRange.lowerBound), TextContent.sizeRange.upperBound)
            return out
        }
        mathStyle = restyled(mathStyle).style
        guard selectionHasMath else { return }
        restyleSelection(key: "math-\(key)") { shape in
            if let math = shape.math { shape.math = restyled(math) }
        }
        // The draft is set in the new style too: its error may no longer hold.
        if var edit = mathEdit {
            edit.error = nil
            mathEdit = edit
            if let content = mathDraftContent { mathDraftTypeset(content) }
        }
    }

    public mutating func setMathSize(_ size: Double) { setMathStyle(key: "size") { $0.size = size } }
    public mutating func setMathDisplay(_ display: Bool) { setMathStyle(key: "display") { $0.display = display } }

    // MARK: Paste

    /// Starts a new formula from LaTeX `source` (plain text pasted with the Math tool),
    /// its box's left middle at world point `p`, editing it as if it were typed, so it is
    /// kept only if it typesets. False when `source` is blank.
    @discardableResult
    public mutating func pasteMath(_ source: String, at p: Vec2) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        beginMathEdit(at: p)
        guard var edit = mathEdit else { return false }
        edit.revision += 1
        mathEdit = edit
        setMathDraft(trimmed)
        return true
    }

    // MARK: Retypeset All Formulas

    /// Forgets the layouts of every formula in the presentation (kept from the file, so
    /// made by whichever MathJax saved it) and returns them, for the app to typeset anew
    /// with its own. Not an undo step: the presentation doesn't change.
    public mutating func forgetFormulaLayouts() -> [MathContent] {
        let all = presentation.mathContents
        MathTypesetting.forget(all)
        displayRevision &+= 1
        return all
    }

    /// The formulas from `forgetFormulaLayouts` are typeset: the document counts as
    /// changed, so its `math.json` is written anew.
    public mutating func formulaLayoutsChanged() {
        documentRevision &+= 1
        displayRevision &+= 1
    }

    // MARK: Convert to Outlines

    /// Formula `math` as ordinary shapes like `original`: one per glyph (its contours in
    /// place, holes bridged) and one rectangle per rule, in group `group`. Empty when its
    /// layout isn't known.
    mutating func mathOutlineShapes(_ math: MathContent, like original: VectorShape, group: Int?) -> [VectorShape] {
        guard let layout = MathTypesetting.layout(math) else { return [] }
        func shape(_ path: BezierPath) -> VectorShape {
            var shape = original
            shape.id = drawing.makeID()
            shape.math = nil
            shape.layoutFrame = nil
            shape.stroke = nil
            shape.path = path
            shape.group = group
            return shape
        }
        var out: [VectorShape] = []
        for glyph in layout.glyphs {
            let rings = (layout.outlines[glyph.key] ?? []).filter { $0.points.count >= 2 }.map { contour -> BezierPath in
                var ring = contour
                ring.closed = true
                ring.apply(glyph.place)
                return ring
            }
            if !rings.isEmpty { out.append(shape(BezierPath.bridging(rings))) }
        }
        for rule in layout.rules where rule.width > 0 && rule.height > 0 {
            out.append(shape(BezierPath(points: rule.corners.map { PathPoint($0, smooth: false) }, closed: true)))
        }
        return out
    }

    /// A group name for formula `math`: its source, up to 24 characters.
    func mathGroupName(_ math: MathContent) -> String {
        let words = math.source.split(whereSeparator: \.isNewline).joined(separator: " ")
        return words.isEmpty ? "Formula" : String(words.prefix(24))
    }
}

extension DrawingEditor.Clipboard {
    /// The LaTeX of the copied formulas, one per line, for the pasteboard's plain text
    /// (so a formula pastes into a LaTeX document or Notes). Nil when none was copied.
    public var mathSource: String? {
        let sources = drawing.layers.flatMap { $0.shapes.compactMap { $0.math?.source } }.filter { !$0.isEmpty }
        return sources.isEmpty ? nil : sources.joined(separator: "\n")
    }
}
