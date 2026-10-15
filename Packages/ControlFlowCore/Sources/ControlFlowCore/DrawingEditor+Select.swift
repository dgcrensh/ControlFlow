import Foundation

/// One level of the breadcrumbs shown for the selection (layer, group, shapes), outermost
/// first. Tapping a crumb that isn't the current level selects that level.
public struct SelectionCrumb: Hashable, Sendable {
    public enum Level: Hashable, Sendable {
        /// A whole layer.
        case layer(Int)
        /// A whole group of a layer.
        case group(Int, inLayer: Int)
        /// Some shapes, less than a whole group or layer.
        case shapes
    }

    public var level: Level
    public var title: String
    /// True for the level the selection is now; tapping it does nothing.
    public var isCurrent: Bool

    public init(level: Level, title: String, isCurrent: Bool) {
        self.level = level
        self.title = title
        self.isCurrent = isCurrent
    }
}

/// The Select menu: select parent and the breadcrumbs it walks, Select All in Layer,
/// Select Same Fill and Outline, and Invert Selection. None of these is an undo step.
extension DrawingEditor {
    // MARK: Breadcrumbs and select parent

    /// The levels around the selection, outermost first: the layer, the group when the selected shapes are all in one, then the shapes
    /// themselves when they are less than that. With nothing selected inside an isolated
    /// layer or group, the levels of the isolation, none of them current. Empty when
    /// nothing is selected and nothing isolated, or for several layers, shapes in several
    /// layers or a reference image.
    public var selectionCrumbs: [SelectionCrumb] {
        let layer: Int
        var group: Int?
        var current: SelectionCrumb.Level?
        var shapeCount = 0
        switch selection {
        case .layer(let id):
            layer = id
            current = .layer(id)
        case .shape, .shapes:
            let refs = drawing.shapeRefs(in: selection)
            guard let first = refs.first, refs.allSatisfy({ $0.layer == first.layer }) else { return [] }
            layer = first.layer
            shapeCount = refs.count
            let groups = Set(refs.map { drawing.shape($0)?.group })
            if groups.count == 1, let g = groups.first ?? nil { group = g }
            if let whole = drawing.selectedGroup(selection) {
                group = whole.group.id
                current = .group(whole.group.id, inLayer: layer)
            } else {
                current = .shapes
            }
        case .none:
            guard let isolated = isolatedLayer else { return [] }
            layer = isolated
            group = isolatedGroup
        case .layers, .reference:
            return []
        }
        guard let found = drawing.layer(layer) else { return [] }
        var crumbs: [SelectionCrumb] = []
        crumbs.append(SelectionCrumb(level: .layer(layer), title: found.name, isCurrent: current == .layer(layer)))
        if let group, let info = found.group(group) {
            let level = SelectionCrumb.Level.group(group, inLayer: layer)
            crumbs.append(SelectionCrumb(level: level, title: info.name, isCurrent: current == level))
        }
        if current == .shapes {
            let title = shapeCount == 1 ? "Shape" : "\(shapeCount) Shapes"
            crumbs.append(SelectionCrumb(level: .shapes, title: title, isCurrent: true))
        }
        return crumbs
    }

    /// Selects the level `level` of the breadcrumbs: a whole layer (leaving isolation
    /// unless that layer is the isolated one) or a whole group (leaving the group if it
    /// was being edited on its own). `.shapes` does nothing.
    public mutating func selectCrumb(_ level: SelectionCrumb.Level) {
        switch level {
        case .layer(let id):
            selectLayer(id)
        case .group(let id, let layer):
            selectGroup(id, inLayer: layer)
            if isolatedGroup == id, selection != .none { isolatedGroup = nil }
        case .shapes:
            break
        }
    }

    /// The level select parent goes to: the crumb just outside the current one, or with
    /// nothing selected the innermost level of the isolation.
    private var parentCrumb: SelectionCrumb.Level? {
        let crumbs = selectionCrumbs
        if let current = crumbs.firstIndex(where: \.isCurrent) {
            return current > 0 ? crumbs[current - 1].level : nil
        }
        return crumbs.last?.level
    }

    /// True when select parent has somewhere to go.
    public var canSelectParent: Bool { parentCrumb != nil }

    /// Selects the level around the selection (Cmd-Up): from shapes to their group or
    /// layer, and from a group to its layer.
    public mutating func selectParent() {
        guard let level = parentCrumb else { return }
        selectCrumb(level)
    }

    // MARK: Select all, same and invert

    /// The layer Select All in Layer and Invert Selection work in: the isolated layer, else
    /// the one layer the selection is in, else the active layer chosen in the panel.
    public var selectionScopeLayer: Int? {
        if let isolatedLayer { return isolatedLayer }
        let refs = drawing.shapeRefs(in: selection)
        if let first = refs.first, refs.allSatisfy({ $0.layer == first.layer }) { return first.layer }
        if case .layer(let id) = selection { return id }
        return usableTargetLayer
    }

    /// The editable shapes of the scope layer, or of the isolated group inside it.
    private var scopeShapeRefs: [ShapeRef]? {
        guard let layer = selectionScopeLayer else { return nil }
        return drawing.editableShapeRefs(within: layer, group: isolatedLayer == layer ? isolatedGroup : nil)
    }

    /// True when Select All in Layer has shapes to select.
    public var canSelectAllInLayer: Bool { !(scopeShapeRefs ?? []).isEmpty }

    /// Selects every editable shape of the scope layer (only the group's, inside an
    /// isolated group), as shapes rather than the whole layer.
    public mutating func selectAllInLayer() {
        guard let refs = scopeShapeRefs, !refs.isEmpty else { return }
        cancelGesture()
        selection = .covering(Set(refs))
    }

    /// True when there is a scope layer to invert the selection within.
    public var canInvertSelection: Bool { selectionScopeLayer != nil }

    /// Selects the editable shapes of the scope layer (or isolated group) that aren't
    /// selected, and deselects the ones that are.
    public mutating func invertSelection() {
        guard let refs = scopeShapeRefs else { return }
        cancelGesture()
        let selected = Set(drawing.shapeRefs(in: selection))
        selection = .covering(Set(refs).subtracting(selected))
    }

    /// True when shapes are selected, so Select Same Fill and Outline have something to match.
    public var canSelectSame: Bool { !drawing.shapeRefs(in: selection).isEmpty }

    /// Selects every editable shape (inside the isolated layer or group, if any) whose
    /// fill matches a selected shape's: the same global color, else the same gradient,
    /// else the same color. Shapes with no fill match each other.
    public mutating func selectSameFill() {
        selectSame { shape in
            guard shape.path.closed, let fill = shape.fill else { return .none }
            if let global = shape.fillGlobal { return .global(global) }
            if let gradient = shape.gradient { return .gradient(gradient) }
            return .color(fill)
        }
    }

    /// Selects every editable shape (inside the isolated layer or group, if any) whose
    /// outline matches a selected shape's: the same width and the same global color,
    /// else the same color. Shapes with no outline match each other.
    public mutating func selectSameOutline() {
        selectSame { shape in
            guard let stroke = shape.stroke else { return .none }
            return .outline(width: stroke.width, color: stroke.global.map(PaintKey.Color.global) ?? .rgba(stroke.color))
        }
    }

    private mutating func selectSame(by key: (VectorShape) -> PaintKey) {
        let wanted = Set(drawing.shapeRefs(in: selection).compactMap { drawing.shape($0).map(key) })
        guard !wanted.isEmpty else { return }
        cancelGesture()
        let refs = drawing.editableShapeRefs(within: isolatedLayer, group: isolatedGroup).filter { ref in
            drawing.shape(ref).map { wanted.contains(key($0)) } ?? false
        }
        selection = .covering(Set(refs))
    }
}

/// What Select Same compares: a fill or an outline reduced to what makes two look alike.
private enum PaintKey: Hashable {
    enum Color: Hashable {
        case global(Int)
        case rgba(RGBAColor)
    }

    case none
    case global(Int)
    case gradient(ShapeGradient)
    case color(RGBAColor)
    case outline(width: Double, color: Color)
}
