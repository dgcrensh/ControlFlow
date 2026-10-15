import Foundation
import XCTest
@testable import ControlFlowCore

/// `ShapeIndex` must give exactly the answers of the scans it replaces: the topmost hit,
/// the scissors' target, the eraser's and the marquee's hit sets, with isolation, an
/// isolated group, hidden and locked shapes and clipping. And a stale index is never read.
final class ShapeIndexTests: XCTestCase {
    /// The stress drawing with every case the filters and the draw order care about.
    static let drawing: Drawing = {
        var d = StressDrawing.make(parts: 12, shapesPerPart: 15)
        for p in d.parts.indices {
            for s in d.parts[p].shapes.indices {
                let n = p * 15 + s
                if n % 7 == 3 { d.parts[p].shapes[s].isHidden = true }
                if n % 11 == 5 { d.parts[p].shapes[s].isLocked = true }
                // Variable-width outlines, so the outline reach differs from half the width.
                if n % 5 == 1 { d.parts[p].shapes[s].path.points[0].width = 0.4 }
                if n % 9 == 2 { d.parts[p].shapes[s].stroke?.alignment = .outside }
            }
        }
        d.parts[2].isLocked = true
        d.parts[3].isHidden = true
        // Part 4's group clips to the shape below it; part 8's group clips to a hidden shape.
        d.parts[4].groups[0].isClipped = true
        d.parts[8].groups[0].isClipped = true
        d.parts[8].shapes[d.parts[8].shapes.count - 4].isHidden = true
        // An open, unfilled path and an exact copy of a shape in another part (a tie).
        var open = d.parts[5].shapes[0]
        open.id = d.makeID()
        open.path.closed = false
        open.fill = nil
        d.parts[5].shapes.append(open)
        var twin = d.parts[6].shapes[1]
        twin.id = d.makeID()
        twin.isHidden = false
        twin.isLocked = false
        d.parts[7].shapes.append(twin)
        return d
    }()

    /// Random points over the drawing, half of them on or near an outline.
    static func points(count: Int, seed: UInt64) -> [Vec2] {
        var random = SeededRandom(seed: seed)
        let d = drawing
        let bounds = d.parts.reduce(Rect.null) { $0.union($1.bounds) }.outset(by: 30)
        let shapes = d.parts.flatMap(\.shapes)
        return (0..<count).map { i in
            if i % 2 == 0 {
                return Vec2(bounds.minPoint.x + random.next() * bounds.width, bounds.minPoint.y + random.next() * bounds.height)
            }
            let path = shapes[Int(random.next() * Double(shapes.count))].path
            let segment = path.segment(Int(random.next() * Double(path.segmentCount)))
            return segment.point(at: random.next()) + Vec2(random.next() - 0.5, random.next() - 0.5) * 30
        }
    }

    /// The isolations to try: none, two parts, and groups.
    static var isolations: [(part: Int?, group: Int?)] {
        let d = drawing
        return [(nil, nil), (d.parts[5].id, nil), (d.parts[1].id, nil), (d.parts[4].id, d.parts[4].groups[0].id),
                (d.parts[8].id, d.parts[8].groups[0].id)]
    }

    func testDrawingCoversTheCases() {
        let d = Self.drawing
        XCTAssertTrue(d.groupsAreValid)
    }

    func testHitTestMatchesTheScan() {
        let d = Self.drawing
        let index = ShapeIndex(d, revision: 0)
        var hits = 0
        for iso in Self.isolations {
            for (i, p) in Self.points(count: 600, seed: 1).enumerated() {
                let tolerance = [0, 1, 4, 16][i % 4]
                let scan = d.hitTest(p, tolerance: Double(tolerance), within: iso.part, group: iso.group)
                    .map { ShapeRef(part: $0.part, shape: $0.shape) }
                XCTAssertEqual(index.hitTest(p, tolerance: Double(tolerance), within: iso.part, group: iso.group), scan,
                               "at \(p), tolerance \(tolerance), isolation \(iso)")
                if scan != nil { hits += 1 }
            }
        }
        XCTAssertGreaterThan(hits, 300)
    }

    /// The scissors' search as it was before the index and the segment skip.
    static func scanCutTarget(_ e: DrawingEditor, at p: Vec2, zoom: Double) -> (ref: ShapeRef, segment: Int, t: Double)? {
        var best: (ref: ShapeRef, segment: Int, t: Double, distance: Double)?
        for ref in e.drawing.editableShapeRefs(within: e.isolatedPart, group: e.isolatedGroup) {
            guard let shape = e.drawing.shape(ref) else { continue }
            let reach = EditorMetrics.curveHit / zoom + (shape.stroke?.width ?? 0) / 2
            guard shape.path.controlBounds.outset(by: reach).contains(p),
                  let near = shape.path.nearestSegment(to: p), near.distance <= reach,
                  near.distance < (best?.distance ?? .infinity) else { continue }
            best = (ref, near.segment, near.t, near.distance)
        }
        return best.map { (ref: $0.ref, segment: $0.segment, t: $0.t) }
    }

    static func editor(isolation iso: (part: Int?, group: Int?)) -> DrawingEditor {
        var e = DrawingEditor(drawing: drawing)
        if let group = iso.group, let part = iso.part {
            e.isolate(group: group, inPart: part)
        } else if let part = iso.part {
            e.isolate(part: part)
        }
        return e
    }

    func testCutTargetMatchesTheScan() {
        var cuts = 0
        for iso in Self.isolations {
            var indexed = Self.editor(isolation: iso)
            indexed.refreshShapeIndex()
            XCTAssertNotNil(indexed.freshShapeIndex)
            var scanned = Self.editor(isolation: iso)
            scanned.shapeIndex = nil
            for (i, p) in Self.points(count: 300, seed: 2).enumerated() {
                let zoom = [0.5, 1, 4][i % 3]
                let expected = Self.scanCutTarget(scanned, at: p, zoom: zoom)
                for e in [indexed, scanned] {
                    let cut = e.cutTarget(at: p, zoom: zoom)
                    XCTAssertEqual(cut?.ref, expected?.ref, "at \(p), zoom \(zoom), isolation \(iso)")
                    XCTAssertEqual(cut?.segment, expected?.segment)
                    XCTAssertEqual(cut?.t, expected?.t)
                }
                if expected != nil { cuts += 1 }
            }
        }
        XCTAssertGreaterThan(cuts, 150)
    }

    /// The twin shape in part 7 ties with its original in part 6: the first in `parts` order wins.
    func testCutTargetTiesGoToTheFirstShape() {
        let d = Self.drawing
        var e = DrawingEditor(drawing: d)
        e.refreshShapeIndex()
        let p = d.parts[6].shapes[1].path.segment(3).point(at: 0.5)
        XCTAssertEqual(e.cutTarget(at: p, zoom: 1)?.ref, ShapeRef(part: d.parts[6].id, shape: d.parts[6].shapes[1].id))
    }

    func testSegmentSkipKeepsTheNearestSegment() {
        let shapes = Self.drawing.parts.flatMap(\.shapes)
        for (i, p) in Self.points(count: 400, seed: 3).enumerated() {
            let path = shapes[i % shapes.count].path
            let full = path.nearestSegment(to: p)
            let skipped = path.nearestSegment(to: p, within: .infinity)
            XCTAssertEqual(full?.segment, skipped?.segment)
            XCTAssertEqual(full?.t, skipped?.t)
            XCTAssertEqual(full?.distance, skipped?.distance)
            guard let full else { continue }
            for limit in [full.distance, full.distance * 2, full.distance / 2] {
                let r = path.nearestSegment(to: p, within: limit)
                if full.distance <= limit {
                    XCTAssertEqual(r?.segment, full.segment)
                    XCTAssertEqual(r?.t, full.t)
                } else if let r {
                    XCTAssertGreaterThan(r.distance, limit)
                }
            }
        }
    }

    /// The shapes a sweep of the eraser, or a marquee, would test, as the scans found them.
    static func scanRefs(_ e: DrawingEditor, _ test: (VectorShape) -> Bool) -> [ShapeRef] {
        e.drawing.editableShapeRefs(within: e.isolatedPart, group: e.isolatedGroup).filter { test(e.drawing.shape($0)!) }
    }

    func testEraserAndMarqueeHitSetsMatchTheScan() {
        let points = Self.points(count: 400, seed: 4)
        var found = 0
        for iso in Self.isolations {
            var e = Self.editor(isolation: iso)
            e.refreshShapeIndex()
            for i in stride(from: 0, to: points.count - 1, by: 2) {
                let a = points[i], b = points[i + 1] * 0.1 + a * 0.9
                let radius = EditorMetrics.eraserRadius / [0.5, 1, 4][i % 3]
                let samples = [a, Vec2.lerp(a, b, 0.5), b]
                let swept = Rect(points: [a, b]).outset(by: radius)
                let erases: (VectorShape) -> Bool = {
                    $0.hitBounds.intersects(swept) && $0.containsAny(of: samples, tolerance: radius)
                }
                let expected = Self.scanRefs(e, erases)
                XCTAssertEqual(e.shapes(meeting: swept, where: erases), expected)
                found += expected.count

                let rect = Rect(from: a, to: b + Vec2(40, 25))
                XCTAssertEqual(Set(e.shapes(meeting: rect) { DrawingEditor.marqueeTouches($0, rect) }),
                               Set(Self.scanRefs(e) { DrawingEditor.marqueeTouches($0, rect) }))
            }
        }
        XCTAssertGreaterThan(found, 100)
    }

    /// A whole eraser stroke with the index (patched as shapes go) erases what erasing
    /// sample by sample with the scan erases.
    func testEraserStrokeMatchesTheScan() {
        for iso in Self.isolations {
            var e = Self.editor(isolation: iso)
            e.tool = .eraser
            var reference = Self.editor(isolation: iso)
            let center = iso.part.flatMap { Self.drawing.part($0)?.pivot } ?? Self.drawing.parts[5].pivot
            let start = center + Vec2(-200, -30)
            let stroke = (0...40).map { start + Vec2(Double($0) * 12, sin(Double($0) / 3) * 40) }
            e.pencilBegan(at: stroke[0], zoom: 1)
            var last = stroke[0]
            for (i, p) in stroke.enumerated() {
                if i > 0 { e.pencilMoved(to: p) }
                let radius = EditorMetrics.eraserRadius
                let steps = max(1, Int((last.distance(to: p) / (radius / 2)).rounded(.up)))
                let samples = (0...steps).map { Vec2.lerp(last, p, Double($0) / Double(steps)) }
                let swept = Rect(points: [last, p]).outset(by: radius)
                for ref in Self.scanRefs(reference, {
                    $0.hitBounds.intersects(swept) && $0.containsAny(of: samples, tolerance: radius)
                }) { reference.removeShape(ref) }
                last = p
                XCTAssertEqual(e.drawing, reference.drawing, "after sample \(i), isolation \(iso)")
            }
            XCTAssertLessThan(e.drawing.shapeCount, Self.drawing.shapeCount)
            e.pencilEnded(at: last)
        }
    }

    /// After an edit or an undo the index is stale: the getters answer from the drawing,
    /// never from the old index, until the next hover rebuilds it.
    func testStaleIndexFallsBackUntilTheNextHover() {
        let d = Self.drawing
        var e = DrawingEditor(drawing: d)
        e.tool = .select
        // A point on the topmost shape of part 0.
        let top = d.parts[0].shapes.indices.last { d.parts[0].isEditable($0) }!
        let p = d.parts[0].shapes[top].path.segment(0).point(at: 0.5)
        e.pencilHovered(at: p, zoom: 1)
        XCTAssertNotNil(e.freshShapeIndex)
        let before = e.hoverTarget
        XCTAssertNotNil(before)
        let expectedBefore = d.hitTest(p, tolerance: EditorMetrics.shapeHit).map { ShapeRef(part: $0.part, shape: $0.shape) }
        XCTAssertEqual(before, expectedBefore)

        // Delete the hovered shape: a stale index would still return it.
        e.selection = .shape(part: before!.part, shape: before!.shape)
        e.deleteSelection()
        XCTAssertNil(e.freshShapeIndex)
        let afterDelete = e.drawing.hitTest(p, tolerance: EditorMetrics.shapeHit).map { ShapeRef(part: $0.part, shape: $0.shape) }
        XCTAssertNotEqual(afterDelete, before)
        XCTAssertEqual(e.hoverTarget, afterDelete)
        e.pencilHovered(at: p, zoom: 1)
        XCTAssertNotNil(e.freshShapeIndex)
        XCTAssertEqual(e.hoverTarget, afterDelete)

        e.undo()
        XCTAssertNil(e.freshShapeIndex)
        XCTAssertEqual(e.hoverTarget, before)
        e.pencilHovered(at: p, zoom: 1)
        XCTAssertNotNil(e.freshShapeIndex)
        XCTAssertEqual(e.hoverTarget, before)

        // The scissors the same way.
        e.tool = .scissors
        e.pencilHovered(at: p, zoom: 1)
        let cutBefore = e.hoverCut?.ref
        XCTAssertEqual(cutBefore, Self.scanCutTarget(e, at: p, zoom: 1)?.ref)
        e.redo()
        XCTAssertNil(e.freshShapeIndex)
        XCTAssertEqual(e.hoverCut?.ref, Self.scanCutTarget(e, at: p, zoom: 1)?.ref)
        XCTAssertNotEqual(e.hoverCut?.ref, cutBefore)
    }

    /// An erase leaves an index that answers geometry queries but rebuilds for a hit test.
    func testErasingKeepsTheIndexForGeometryOnly() {
        var e = DrawingEditor(drawing: Self.drawing)
        e.tool = .eraser
        let p = Self.drawing.parts[5].pivot
        e.pencilBegan(at: p, zoom: 1)
        XCTAssertLessThan(e.drawing.shapeCount, Self.drawing.shapeCount)
        XCTAssertEqual(e.freshShapeIndex?.supportsHitTest, false)
        XCTAssertEqual(e.hitShape(at: p + Vec2(30, 0), tolerance: 4),
                       e.drawing.hitTest(p + Vec2(30, 0), tolerance: 4).map { ShapeRef(part: $0.part, shape: $0.shape) })
        e.pencilEnded(at: p)
        e.pencilHovered(at: p, zoom: 1)
        XCTAssertEqual(e.freshShapeIndex?.supportsHitTest, true)
    }
}
