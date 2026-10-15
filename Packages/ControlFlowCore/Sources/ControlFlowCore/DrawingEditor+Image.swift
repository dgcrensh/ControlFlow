import Foundation

extension DrawingEditor {
    /// Adds an image shape showing `image`, `size` points across and centered on `center`
    /// (world space), where new art goes, and selects it with the Select tool, so it can
    /// be moved, scaled, turned and faded at once. One undo step. Nil for an empty size.
    @discardableResult
    public mutating func addImage(_ image: ShapeImage, size: Vec2, center: Vec2) -> ShapeRef? {
        guard size.x > 0, size.y > 0, size.x.isFinite, size.y.isFinite else { return nil }
        endTextEdit()
        tool = .select
        let before = drawing
        let shape = VectorShape(id: drawing.makeID(), image: image, origin: center - size / 2, size: size)
        let ref = insertNewShape(shape, joinNeedsOverlap: false)
        // Selecting a shape takes up its style; an image has none to give.
        let saved = style
        selection = .shape(layer: ref.layer, shape: ref.shape)
        style = saved
        commit(from: before)
        return ref
    }
}

extension DrawingEditor {
    /// True when the selection holds an image shape, which shows its picture in place of
    /// a fill, so the Appearance panel leaves the fill's gradient out.
    public var selectionHasImage: Bool {
        drawing.shapeIndices(in: selection).contains { drawing.layers[$0.0].shapes[$0.1].image != nil }
    }
}
