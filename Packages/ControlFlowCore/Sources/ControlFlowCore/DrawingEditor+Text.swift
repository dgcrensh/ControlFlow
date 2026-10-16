import Foundation

/// A string and a selection in it, with the edits a keyboard makes. Offsets are in
/// UTF-16 code units, as `UITextView` counts them, and every edit keeps the selection
/// on character boundaries.
public struct TextEditing: Hashable, Sendable {
    public var string: String
    /// An empty range is the caret.
    public var selection: Range<Int>

    public init(string: String, selection: Range<Int>? = nil) {
        self.string = string
        let end = string.utf16.count
        self.selection = selection.map { Self.clamped($0, in: string) } ?? end..<end
    }

    public var length: Int { string.utf16.count }

    /// `range` within `string` and on character boundaries.
    static func clamped(_ range: Range<Int>, in string: String) -> Range<Int> {
        let n = string.utf16.count
        let lower = boundary(min(max(range.lowerBound, 0), n), in: string)
        let upper = boundary(min(max(range.upperBound, lower), n), in: string)
        return lower..<max(lower, upper)
    }

    /// `offset`, moved back to the start of the character it falls in.
    static func boundary(_ offset: Int, in string: String) -> Int {
        guard offset > 0, offset < string.utf16.count else { return offset }
        var start = 0
        for ch in string {
            let end = start + ch.utf16.count
            if end > offset { return start }
            start = end
        }
        return offset
    }

    /// Replaces the selection with `text`, leaving the caret after it.
    public mutating func insert(_ text: String) {
        let utf16 = Array(string.utf16)
        let new = String(decoding: utf16[..<selection.lowerBound], as: UTF16.self) + text +
            String(decoding: utf16[selection.upperBound...], as: UTF16.self)
        let caret = selection.lowerBound + text.utf16.count
        string = new
        selection = caret..<caret
    }

    /// Deletes the selection, or the character before the caret.
    public mutating func deleteBackward() {
        if selection.isEmpty {
            guard selection.lowerBound > 0 else { return }
            selection = previous(selection.lowerBound)..<selection.upperBound
        }
        insert("")
    }

    /// Deletes the selection, or the character after the caret.
    public mutating func deleteForward() {
        if selection.isEmpty {
            guard selection.upperBound < length else { return }
            selection = selection.lowerBound..<next(selection.upperBound)
        }
        insert("")
    }

    /// The caret one character left; with `extending`, the selection grows left. Without,
    /// a selection collapses to its start.
    public mutating func moveLeft(extending: Bool = false) {
        if extending {
            selection = previous(selection.lowerBound)..<selection.upperBound
        } else if !selection.isEmpty {
            selection = selection.lowerBound..<selection.lowerBound
        } else {
            let p = previous(selection.lowerBound)
            selection = p..<p
        }
    }

    /// The caret one character right; with `extending`, the selection grows right.
    /// Without, a selection collapses to its end.
    public mutating func moveRight(extending: Bool = false) {
        if extending {
            selection = selection.lowerBound..<next(selection.upperBound)
        } else if !selection.isEmpty {
            selection = selection.upperBound..<selection.upperBound
        } else {
            let n = next(selection.upperBound)
            selection = n..<n
        }
    }

    /// Selects the word around `offset` (letters and digits), or the character there
    /// when it isn't in a word.
    public mutating func selectWord(at offset: Int) {
        let characters = Array(string)
        var starts: [Int] = []
        var o = 0
        for ch in characters {
            starts.append(o)
            o += ch.utf16.count
        }
        starts.append(o)
        guard !characters.isEmpty else { return }
        // The character the offset falls in (the last one at the end).
        var i = characters.count - 1
        for k in characters.indices where starts[k + 1] > offset {
            i = k
            break
        }
        func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "_" }
        guard isWord(characters[i]) else {
            selection = starts[i]..<starts[i + 1]
            return
        }
        var a = i, b = i
        while a > 0, isWord(characters[a - 1]) { a -= 1 }
        while b + 1 < characters.count, isWord(characters[b + 1]) { b += 1 }
        selection = starts[a]..<starts[b + 1]
    }

    public mutating func selectAll() {
        selection = 0..<length
    }

    private func previous(_ offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        let index = String.Index(utf16Offset: offset, in: string)
        return string.index(before: index).utf16Offset(in: string)
    }

    private func next(_ offset: Int) -> Int {
        guard offset < length else { return length }
        let index = String.Index(utf16Offset: offset, in: string)
        return string.index(after: index).utf16Offset(in: string)
    }
}

/// The text being typed into (see `DrawingEditor.beginTextEdit`).
public struct TextEditState: Hashable, Sendable {
    public var ref: ShapeRef
    /// The selection in the text, in UTF-16 offsets; empty for the caret.
    public internal(set) var selection: Range<Int>
    /// Numbers the session: its edits are one undo step.
    public let session: Int
    /// Increments when the editor itself changes the words or the selection (a tap
    /// placing the caret, say), so the app copies them back into its text view.
    public internal(set) var revision = 0
    /// The weight chosen with nothing selected, which what is typed next takes, until the
    /// caret moves.
    public internal(set) var typingWeight: Int?
    /// True when the session made the text, so it can center its pivot at the end.
    let isNew: Bool
}

extension DrawingEditor {
    // MARK: Editing sessions

    /// The text shape being edited's words, or nil.
    public var editedString: String? {
        textEdit.flatMap { drawing.shape($0.ref)?.text?.string }
    }

    /// Starts typing into text shape `ref` with the selection `selection` (the caret at
    /// the end by default). The text becomes the selection. Ends any other edit first.
    public mutating func beginTextEdit(_ ref: ShapeRef, selection range: Range<Int>? = nil) {
        beginTextEdit(ref, selection: range, isNew: false)
    }

    private mutating func beginTextEdit(_ ref: ShapeRef, selection range: Range<Int>?, isNew: Bool) {
        guard let idx = drawing.indices(ref), let text = drawing.layers[idx.0].shapes[idx.1].text,
              drawing.layers[idx.0].isEditable(idx.1) else { return }
        if let edit = textEdit, edit.ref != ref { endTextEdit() }
        if textEdit?.ref == ref {
            if let range { setTextSelection(range, fromApp: false) }
            return
        }
        cancelGesture()
        let wanted = Selection.shape(layer: ref.layer, shape: ref.shape)
        if selection != wanted { selection = wanted }
        textEditCount += 1
        let editing = TextEditing(string: text.string, selection: range)
        textEdit = TextEditState(ref: ref, selection: editing.selection, session: textEditCount, revision: 1, isNew: isNew)
        showEditedWeight()
    }

    /// While typing, the style controls show the weight at the caret or the selection
    /// (its first character's when it mixes them).
    private mutating func showEditedWeight() {
        guard let edit = textEdit, let text = drawing.shape(edit.ref)?.text else { return }
        let w = edit.typingWeight ?? text.uniformWeight(in: edit.selection) ?? text.weight(at: edit.selection.lowerBound)
        if textStyle.weight != w { textStyle.weight = w }
    }

    /// Edits text `ref` from a tap at world point `p`: the caret goes where the tap was.
    /// With the select tool, switches to the text tool first.
    mutating func editText(_ ref: ShapeRef, at p: Vec2) {
        if tool != .text {
            textEditKeepsTool = true
            tool = .text
            textEditKeepsTool = false
        }
        let offset = textOffset(at: p, in: ref, tolerance: .infinity)
        beginTextEdit(ref, selection: offset.map { $0..<$0 })
    }

    /// Starts a new text at world point `origin` (the top-left of its first line), in
    /// `textStyle`, and edits it. With a `width` (a drag), it is a box that wraps there.
    mutating func startText(at origin: Vec2, width: Double?) {
        if textEdit != nil { endTextEdit() }
        var content = textStyle.style
        if let width { content.width = max(width, content.size) }
        var shape = VectorShape(id: drawing.makeID(), text: content, fill: style.fill)
        // Placed by its transform, which shows it where it was put in the layer it joins.
        shape.transform = Transform(position: origin)
        let before = drawing
        let ref = insertNewShape(shape, joinNeedsOverlap: false)
        let saved = style
        selection = .shape(layer: ref.layer, shape: ref.shape)
        style = saved
        beginTextEdit(ref, selection: nil, isNew: true)
        guard let session = textEdit?.session else { return }
        commit(from: before, key: textEditKey(session))
    }

    /// Ends typing: a text left empty is deleted, and a new one's pivot moves to the
    /// middle of its box. Part of the session's undo step.
    public mutating func endTextEdit() {
        guard let edit = textEdit else { return }
        textEdit = nil
        guard let idx = drawing.indices(edit.ref), let text = drawing.layers[idx.0].shapes[idx.1].text else { return }
        // The style controls show the text's own style again, not the weight at the caret.
        textStyle = text.style
        let before = drawing
        if text.string.isEmpty {
            removeShape(edit.ref)
            if drawing.indices(edit.ref) == nil, selection == .shape(layer: edit.ref.layer, shape: edit.ref.shape) {
                selection = .none
            }
        } else if edit.isNew {
            let shape = drawing.layers[idx.0].shapes[idx.1]
            drawing.layers[idx.0].shapes[idx.1].transform = shape.transform.withPivot(TextShaping.layout(text).bounds.center)
            if drawing.layers[idx.0].shapes.count == 1 {
                drawing.layers[idx.0].setWorldPivot(drawing.layers[idx.0].bounds.center)
            }
        }
        commit(from: before, key: textEditKey(edit.session))
        // A new text left empty leaves nothing to undo.
        if edit.isNew, text.string.isEmpty, var last = undoStack.undoStates.last?.presentation {
            last.opening.nextID = snapshot.presentation.opening.nextID
            if last == snapshot.presentation { undoStack.dropLast() }
        }
        validateSelection()
    }

    func textEditKey(_ session: Int) -> String { "text-\(session)" }

    /// The words and selection the app's text view has after the user typed, deleted,
    /// pasted, dictated or moved the caret. A change of words is part of the session's
    /// undo step.
    public mutating func setEditedText(_ string: String, selection range: Range<Int>) {
        guard var edit = textEdit, let idx = drawing.indices(edit.ref),
              let text = drawing.layers[idx.0].shapes[idx.1].text else { return }
        let selection = TextEditing.clamped(range, in: string)
        if text.string != string {
            let before = drawing
            drawing.layers[idx.0].shapes[idx.1].text!.replaceString(with: string, selection: edit.selection, newSelection: selection,
                                                                    typing: edit.typingWeight)
            commit(from: before, key: textEditKey(edit.session))
        }
        edit.selection = selection
        textEdit = edit
        showEditedWeight()
    }

    /// Sets the selection in the text being edited. `fromApp` is false for a change the
    /// app's text view doesn't know about yet (it then copies it in).
    public mutating func setTextSelection(_ range: Range<Int>, fromApp: Bool = true) {
        guard var edit = textEdit, let string = editedString else { return }
        let clamped = TextEditing.clamped(range, in: string)
        guard clamped != edit.selection || !fromApp else { return }
        if clamped != edit.selection { edit.typingWeight = nil }
        edit.selection = clamped
        if !fromApp { edit.revision += 1 }
        textEdit = edit
        showEditedWeight()
    }

    /// Applies a keyboard edit to the text being edited, as a hardware keyboard would.
    public mutating func applyTextEdit(_ change: (inout TextEditing) -> Void) {
        guard var edit = textEdit, let string = editedString else { return }
        var editing = TextEditing(string: string, selection: edit.selection)
        change(&editing)
        setEditedText(editing.string, selection: editing.selection)
        edit = textEdit ?? edit
        edit.revision += 1
        textEdit = edit
    }

    /// Types `text` over the selection.
    public mutating func typeText(_ text: String) { applyTextEdit { $0.insert(text) } }

    /// The UTF-16 offset in text `ref` nearest world point `p`, or nil when `p` is more
    /// than `tolerance` (world points) outside its box.
    func textOffset(at p: Vec2, in ref: ShapeRef, tolerance: Double = 0) -> Int? {
        guard let idx = drawing.indices(ref), let text = drawing.layers[idx.0].shapes[idx.1].text,
              let inverse = drawing.layers[idx.0].worldMatrix(ofShape: idx.1).inverted else { return nil }
        let layout = TextShaping.layout(text)
        let local = inverse.apply(p)
        if tolerance.isFinite {
            // The tolerance is in world points; the box is in the text's own space.
            let scale = max(inverse.uniformScale, 1e-9)
            guard layout.frame.outset(by: tolerance * scale).contains(local) else { return nil }
        }
        return layout.offset(nearest: local)
    }

    /// The text being edited as the canvas shows it, in world space: its box, the caret
    /// (when nothing is selected) and the selection's boxes, each as four corners.
    public var textEditGeometry: (frame: [Vec2], caret: (top: Vec2, bottom: Vec2)?, selection: [[Vec2]])? {
        guard let edit = textEdit, let idx = drawing.indices(edit.ref), let text = drawing.layers[idx.0].shapes[idx.1].text
        else { return nil }
        let m = drawing.layers[idx.0].worldMatrix(ofShape: idx.1)
        let layout = TextShaping.layout(text)
        let frame = layout.frame.corners.map(m.apply)
        var caret: (top: Vec2, bottom: Vec2)?
        if edit.selection.isEmpty {
            let c = layout.caret(at: edit.selection.lowerBound)
            caret = (m.apply(c.top), m.apply(c.bottom))
        }
        let boxes = layout.selectionRects(edit.selection).map { $0.corners.map(m.apply) }
        return (frame, caret, boxes)
    }

    // MARK: The select tool

    /// Drags a side of text box `ref` (from `before`) to world point `p`, changing where
    /// it wraps: the other side stays put.
    mutating func setTextWidth(of ref: ShapeRef, dragging leftSide: Bool, to p: Vec2, before: Drawing) {
        guard let idx = before.indices(ref), let text = before.layers[idx.0].shapes[idx.1].text, let width = text.width,
              let inverse = before.layers[idx.0].worldMatrix(ofShape: idx.1).inverted else { return }
        let local = inverse.apply(p)
        let least = max(text.size * 0.5, 1)
        var shape = before.layers[idx.0].shapes[idx.1]
        if leftSide {
            let left = min(local.x, width - least)
            shape.text!.width = width - left
            // The text's origin moves to the new left side, and its pivot stays at the
            // same spot on the page.
            let shift = Vec2(left, 0)
            shape.transform.position += shape.transform.matrix.applyToVector(shift)
            shape.transform = shape.transform.withPivot(shape.transform.pivot - shift)
        } else {
            shape.text!.width = max(local.x, least)
        }
        drawing = before
        drawing.layers[idx.0].shapes[idx.1] = shape
    }

    // MARK: Style

    /// The first selected shape's text, if it is one.
    public var selectedText: TextContent? {
        guard let first = drawing.shapeIndices(in: selection).first else { return nil }
        return drawing.layers[first.0].shapes[first.1].text
    }

    /// True when the selection holds a text.
    public var selectionHasText: Bool {
        drawing.shapeIndices(in: selection).contains { drawing.layers[$0.0].shapes[$0.1].text != nil }
    }

    /// Changes the style of new text and of every selected text (one undo step per run
    /// of changes with the same `key`).
    public mutating func setTextStyle(key: String, _ change: (inout TextContent) -> Void) {
        func restyled(_ text: TextContent) -> TextContent {
            var out = text
            change(&out)
            out.string = text.string
            out.held = nil
            out.size = min(max(out.size, TextContent.sizeRange.lowerBound), TextContent.sizeRange.upperBound)
            out.weight = min(max(out.weight, TextContent.weightRange.lowerBound), TextContent.weightRange.upperBound)
            out.lineHeight = min(max(out.lineHeight, TextContent.lineHeightRange.lowerBound), TextContent.lineHeightRange.upperBound)
            if let width = out.width { out.width = max(width, 1) }
            out.normalizeWeights()
            return out
        }
        textStyle = restyled(textStyle).style
        guard selectionHasText else { return }
        restyleSelection(key: "text-\(key)") { shape in
            if let text = shape.text { shape.text = restyled(text) }
        }
    }

    public mutating func setTextFont(_ name: String) { setTextStyle(key: "font") { $0.font = name.isEmpty ? TextContent.systemFont : name } }
    public mutating func setTextSize(_ size: Double) { setTextStyle(key: "size") { $0.size = size } }
    /// Sets the weight of the words selected in the text being typed into, or of what is
    /// typed next when nothing is selected. Otherwise, of new text and of every selected
    /// text, as a whole.
    public mutating func setTextWeight(_ weight: Int) {
        let weight = TextContent.clampedWeight(weight)
        guard let edit = textEdit, let idx = drawing.indices(edit.ref), drawing.layers[idx.0].shapes[idx.1].text != nil else {
            setTextStyle(key: "weight") {
                $0.weight = weight
                $0.weights = []
            }
            return
        }
        if edit.selection.isEmpty {
            textEdit?.typingWeight = weight
        } else {
            // Part of the editing session's undo step.
            let before = drawing
            drawing.layers[idx.0].shapes[idx.1].text!.setWeight(weight, in: edit.selection)
            commit(from: before, key: textEditKey(edit.session))
        }
        showEditedWeight()
    }

    /// Bold (700) or back to regular (400), as Command-B does: the words selected in the
    /// text being typed into (regular if they are all 600 or more), what is typed next
    /// when nothing is selected, or every selected text as a whole. Only the system font
    /// has weights.
    public mutating func toggleTextBold() {
        if let edit = textEdit, let text = drawing.shape(edit.ref)?.text {
            guard text.isSystemFont else { return }
            let current = edit.selection.isEmpty ? (edit.typingWeight ?? text.insertionWeight(at: edit.selection))
                : text.unitWeights[TextEditing.clamped(edit.selection, in: text.string)].min() ?? text.weight
            setTextWeight(current >= 600 ? 400 : 700)
        } else if let text = selectedText, text.isSystemFont {
            let lightest = text.unitWeights.min() ?? text.weight
            setTextWeight(lightest >= 600 ? 400 : 700)
        }
    }
    public mutating func setTextItalic(_ italic: Bool) { setTextStyle(key: "italic") { $0.italic = italic } }
    public mutating func setTextAlignment(_ align: TextAlignment) { setTextStyle(key: "align") { $0.align = align } }
    public mutating func setTextLineHeight(_ lineHeight: Double) { setTextStyle(key: "lineHeight") { $0.lineHeight = lineHeight } }
    public mutating func setTextTracking(_ tracking: Double) { setTextStyle(key: "tracking") { $0.tracking = tracking } }

    // MARK: Convert to Outlines

    /// True when the selection holds a text, or a formula that is typeset.
    public var canConvertToOutlines: Bool {
        selectionHasText || drawing.shapeIndices(in: selection).contains { idx in
            drawing.layers[idx.0].shapes[idx.1].math.flatMap(MathTypesetting.layout) != nil
        }
    }

    /// Turns each selected text and formula into ordinary shapes, one per glyph with its
    /// holes (and one per rule of a formula), grouped (or in the original's own group),
    /// looking the same. One undo step.
    public mutating func convertTextToOutlines() {
        guard canConvertToOutlines else { return }
        endTextEdit()
        endMathEdit()
        cancelGesture()
        let before = drawing
        var made: Set<ShapeRef> = []
        let targets = drawing.shapeRefs(in: selection)
        for ref in targets.reversed() {
            guard let idx = drawing.indices(ref) else { continue }
            let original = drawing.layers[idx.0].shapes[idx.1]
            let text = original.text
            let math = original.math.flatMap { MathTypesetting.layout($0) != nil ? $0 : nil }
            guard text != nil || math != nil else {
                made.insert(ref)
                continue
            }
            var group = original.group
            if group == nil {
                let id = drawing.makeID()
                let label: String
                if let text {
                    let words = text.string.split(whereSeparator: \.isNewline).joined(separator: " ")
                    label = words.isEmpty ? "Text" : String(words.prefix(24))
                } else {
                    label = mathGroupName(math!)
                }
                let name = drawing.layers[idx.0].uniqueGroupName(label)
                drawing.layers[idx.0].groups.append(ShapeGroup(id: id, name: name))
                group = id
            }
            var glyphs: [VectorShape] = []
            if let text {
                let layout = TextShaping.layout(text)
                for glyph in layout.glyphs where !glyph.contours.isEmpty {
                    let rings = glyph.contours.map { contour -> BezierPath in
                        var ring = contour
                        ring.apply(.translation(glyph.origin))
                        ring.closed = true
                        return ring
                    }
                    var shape = original
                    shape.id = drawing.makeID()
                    shape.text = nil
                    shape.layoutFrame = nil
                    shape.stroke = nil
                    shape.path = BezierPath.bridging(rings)
                    shape.group = group
                    glyphs.append(shape)
                }
            } else if let math {
                glyphs = mathOutlineShapes(math, like: original, group: group)
            }
            drawing.layers[idx.0].shapes.replaceSubrange(idx.1...idx.1, with: glyphs)
            for shape in glyphs { made.insert(ShapeRef(layer: ref.layer, shape: shape.id)) }
            if drawing.layers[idx.0].shapes.isEmpty { drawing.layers.remove(at: idx.0) }
        }
        selection = .covering(made.filter { drawing.indices($0) != nil })
        commit(from: before)
    }
}
