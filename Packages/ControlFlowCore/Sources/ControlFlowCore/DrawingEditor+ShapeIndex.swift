import Foundation

extension Tool {
    /// The tools whose hover or touch looks for shapes near the Pencil.
    var usesShapeIndex: Bool {
        switch self {
        case .select, .directSelect, .eraser, .scissors, .text: true
        case .pencil, .pen, .shape: false
        }
    }
}

/// Shape lookups near a point, from `shapeIndex` when it is fresh and from a scan of the
/// drawing otherwise. Both give the same answer; the index only makes it cheaper. The
/// mutating entry points (hover, touch down, erasing, the marquee) rebuild a stale index;
/// the getters never do, and a stale index is never read, so it can't return a shape
/// from an older drawing.
extension DrawingEditor {
    /// `shapeIndex` when it was built (or patched) for the current drawing.
    var freshShapeIndex: ShapeIndex? {
        guard let index = shapeIndex, index.revision == revision else { return nil }
        return index
    }

    /// Rebuilds `shapeIndex` unless it is fresh (and, with `forHitTest`, can hit-test),
    /// keeping the entries of the layers the stale one indexed as they are now.
    mutating func refreshShapeIndex(forHitTest: Bool = true) {
        if let index = freshShapeIndex, index.supportsHitTest || !forHitTest { return }
        shapeIndex = ShapeIndex(drawing, revision: revision, reusing: shapeIndex)
    }

    /// The topmost editable shape under `p`, within isolation: `Drawing.hitTest`.
    func hitShape(at p: Vec2, tolerance: Double) -> ShapeRef? {
        if let index = freshShapeIndex, index.supportsHitTest {
            return index.hitTest(p, tolerance: tolerance, within: isolatedLayer, group: isolatedGroup)
        }
        return drawing.hitTest(p, tolerance: tolerance, within: isolatedLayer, group: isolatedGroup)
            .map { ShapeRef(layer: $0.layer, shape: $0.shape) }
    }

    /// The editable shapes (within isolation) whose bounds may meet `rect` and that pass
    /// `test`, in `layers` order.
    func shapes(meeting rect: Rect, where test: (VectorShape) -> Bool) -> [ShapeRef] {
        var out: [ShapeRef] = []
        if let index = freshShapeIndex {
            for i in index.candidates(meeting: rect, within: isolatedLayer, group: isolatedGroup) {
                let entry = index.entries[i]
                if test(entry.shape) { out.append(entry.ref) }
            }
            return out
        }
        forEachEditableShape { ref, shape in
            if test(shape) { out.append(ref) }
        }
        return out
    }

    /// Every editable shape within isolation (in world space), in `layers` order, as
    /// `Drawing.editableShapeRefs` lists them, without looking each one up by id.
    func forEachEditableShape(_ body: (ShapeRef, VectorShape) -> Void) {
        for layer in drawing.layers where isolatedLayer == nil || layer.id == isolatedLayer {
            for i in layer.shapes.indices where (isolatedGroup == nil || layer.shapes[i].group == isolatedGroup) &&
                layer.isEditable(i) {
                body(ShapeRef(layer: layer.id, shape: layer.shapes[i].id), layer.worldShape(i))
            }
        }
    }

    /// The outline nearest `p` that the scissors can cut, within reach: the first,
    /// in `layers` order, of the shapes at the least distance.
    func cutTarget(at p: Vec2, zoom: Double) -> (ref: ShapeRef, segment: Int, t: Double, path: BezierPath)? {
        var best: (ref: ShapeRef, segment: Int, t: Double, distance: Double, path: BezierPath)?
        let hit = EditorMetrics.curveHit / zoom
        func consider(_ ref: ShapeRef, _ shape: VectorShape, _ control: Rect) {
            // A text's glyphs are laid out, and an image's frame isn't cut.
            guard shape.hasEditablePath else { return }
            let reach = hit + (shape.stroke?.width ?? 0) / 2
            let limit = min(reach, best?.distance ?? .infinity)
            guard control.outset(by: reach).contains(p),
                  let near = shape.path.nearestSegment(to: p, within: limit), near.distance <= reach,
                  near.distance < (best?.distance ?? .infinity) else { return }
            best = (ref, near.segment, near.t, near.distance, shape.path)
        }
        if let index = freshShapeIndex {
            let query = Rect(from: p, to: p).outset(by: max(hit, 0))
            for i in index.candidates(meeting: query, within: isolatedLayer, group: isolatedGroup) {
                let entry = index.entries[i]
                consider(entry.ref, entry.shape, entry.controlBounds)
            }
        } else {
            forEachEditableShape { ref, shape in consider(ref, shape, shape.path.controlBounds) }
        }
        return best.map { (ref: $0.ref, segment: $0.segment, t: $0.t, path: $0.path) }
    }
}
