import XCTest
@testable import CharacterCore

/// True when `p` is inside one of the triangles (three points each).
private func covers(_ triangles: [Vec2], _ p: Vec2) -> Bool {
    stride(from: 0, to: triangles.count, by: 3).contains { i in
        inside(p, triangles[i], triangles[i + 1], triangles[i + 2])
    }
}

private func inside(_ p: Vec2, _ a: Vec2, _ b: Vec2, _ c: Vec2) -> Bool {
    let d1 = (b - a).cross(p - a), d2 = (c - b).cross(p - b), d3 = (a - c).cross(p - c)
    let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
    let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
    return !(hasNegative && hasPositive)
}

private func line(_ points: [Vec2], closed: Bool = false, widths: [Double]? = nil) -> BezierPath {
    var path = BezierPath(points: points.map { PathPoint($0, smooth: false) }, closed: closed)
    if let widths { for i in widths.indices { path.points[i].width = widths[i] } }
    return path
}

private func square(_ x: Double, _ y: Double, _ size: Double) -> BezierPath {
    ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + size, y + size)))
}

private let red = RGBAColor(r: 1, g: 0, b: 0)
private let blue = RGBAColor(r: 0, g: 0, b: 1)

final class StrokerTests: XCTestCase {
    func testButtLineIsARectangle() {
        let style = StrokeStyle(color: .ink, width: 4, cap: .butt)
        let tris = Stroker.triangles(for: line([Vec2(0, 0), Vec2(10, 0)]), style: style, tolerance: 0.1)
        XCTAssertEqual(tris.count, 6)
        XCTAssertTrue(covers(tris, Vec2(5, 1.9)))
        XCTAssertFalse(covers(tris, Vec2(5, 2.1)))
        XCTAssertFalse(covers(tris, Vec2(-0.1, 0)))
        XCTAssertFalse(covers(tris, Vec2(10.1, 0)))
    }

    func testCaps() {
        let path = line([Vec2(0, 0), Vec2(10, 0)])
        let square = Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 4, cap: .square), tolerance: 0.1)
        XCTAssertTrue(covers(square, Vec2(-1.9, 1.9)))
        XCTAssertFalse(covers(square, Vec2(-2.1, 0)))
        let round = Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 4, cap: .round), tolerance: 0.01)
        XCTAssertTrue(covers(round, Vec2(-1.9, 0)))
        XCTAssertTrue(covers(round, Vec2(11.9, 0)))
        XCTAssertFalse(covers(round, Vec2(-1.9, 1.9)))
        // A lone point is a dot for round caps and nothing for butt caps.
        let dot = line([Vec2(3, 3)])
        XCTAssertTrue(covers(Stroker.triangles(for: dot, style: StrokeStyle(color: .ink, width: 4), tolerance: 0.1), Vec2(4.5, 3)))
        XCTAssertTrue(Stroker.triangles(for: dot, style: StrokeStyle(color: .ink, width: 4, cap: .butt), tolerance: 0.1).isEmpty)
    }

    func testJoins() {
        // A right-angle corner at (10, 0); the outer corner of the outline is at (12, -2).
        let path = line([Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)])
        func tris(_ join: LineJoin, limit: Double = 4) -> [Vec2] {
            Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 4, cap: .butt, join: join, miterLimit: limit),
                              tolerance: 0.01)
        }
        XCTAssertTrue(covers(tris(.miter), Vec2(11.9, -1.9)))
        XCTAssertFalse(covers(tris(.bevel), Vec2(11.9, -1.9)))
        XCTAssertTrue(covers(tris(.bevel), Vec2(11, -0.9)))
        XCTAssertTrue(covers(tris(.round), Vec2(11.3, -1.3)))
        XCTAssertFalse(covers(tris(.round), Vec2(11.6, -1.6)))
        // The miter of a right angle is sqrt(2) half-widths long, so a limit of 1.2 bevels it.
        XCTAssertFalse(covers(tris(.miter, limit: 1.2), Vec2(11.9, -1.9)))
    }

    func testClosedPathsJoinAtTheStart() {
        let style = StrokeStyle(color: .ink, width: 4, join: .miter)
        let tris = Stroker.triangles(for: square(0, 0, 10).withCorners, style: style, tolerance: 0.01)
        for corner in [Vec2(-1.9, -1.9), Vec2(11.9, -1.9), Vec2(11.9, 11.9), Vec2(-1.9, 11.9)] {
            XCTAssertTrue(covers(tris, corner), "\(corner)")
        }
        XCTAssertFalse(covers(tris, Vec2(5, 5)))
    }

    func testVariableWidthBlendsAlongTheSegment() {
        let path = line([Vec2(0, 0), Vec2(10, 0)], widths: [0.5, 2])
        let tris = Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 4, cap: .butt), tolerance: 0.1)
        // Radius 1 at the start, 4 at the end, 2.5 in the middle.
        XCTAssertTrue(covers(tris, Vec2(0.1, 0.9)))
        XCTAssertFalse(covers(tris, Vec2(0.1, 1.2)))
        XCTAssertTrue(covers(tris, Vec2(5, 2.4)))
        XCTAssertFalse(covers(tris, Vec2(5, 2.6)))
        XCTAssertTrue(covers(tris, Vec2(9.9, 3.9)))
    }

    func testFlatteningCarriesWidths() {
        var path = BezierPath(points: [PathPoint(Vec2(0, 0), out: Vec2(10, 0)), PathPoint(Vec2(30, 0), in: Vec2(-10, 0))])
        path.points[0].width = 1
        path.points[1].width = 3
        path.points[0].outHandle = Vec2(10, 20)
        let flat = path.flattenedWithWidths(tolerance: 0.1)
        XCTAssertEqual(flat.points.count, flat.widths.count)
        XCTAssertEqual(flat.widths.first, 1)
        XCTAssertEqual(flat.widths.last, 3)
        XCTAssertEqual(flat.widths, flat.widths.sorted())
        XCTAssertEqual(flat.points, path.flattened(tolerance: 0.1))
    }

    func testDashes() {
        let path = line([Vec2(0, 0), Vec2(20, 0)])
        let style = StrokeStyle(color: .ink, width: 2, cap: .butt, dash: [4, 3])
        let tris = Stroker.triangles(for: path, style: style, tolerance: 0.1)
        XCTAssertTrue(covers(tris, Vec2(2, 0)))
        XCTAssertFalse(covers(tris, Vec2(5, 0)))
        XCTAssertTrue(covers(tris, Vec2(9, 0)))
        XCTAssertFalse(covers(tris, Vec2(12.5, 0)))
        XCTAssertTrue(covers(tris, Vec2(15, 0)))
        // The offset shifts the pattern along the path.
        var shifted = style
        shifted.dashOffset = 2
        let moved = Stroker.triangles(for: path, style: shifted, tolerance: 0.1)
        XCTAssertFalse(covers(moved, Vec2(3, 0)))
        XCTAssertTrue(covers(moved, Vec2(1, 0)))
        XCTAssertTrue(covers(moved, Vec2(6, 0)))
        // An odd pattern repeats twice: 2 on, 1 off, 1 on, 2 off.
        XCTAssertEqual(StrokeStyle(color: .ink, width: 1, dash: [2, 1, 1]).dashPattern, [2, 1, 1, 2, 1, 1])
        // No gaps, negative or empty: solid.
        XCTAssertNil(StrokeStyle(color: .ink, width: 1, dash: [3, 0]).dashPattern)
        XCTAssertNil(StrokeStyle(color: .ink, width: 1, dash: [3, -1]).dashPattern)
        XCTAssertFalse(StrokeStyle(color: .ink, width: 1).isDashed)
        // Dashes follow a closed path round its closing segment, and round caps on
        // zero-length dashes make dots.
        let dotted = StrokeStyle(color: .ink, width: 2, cap: .round, dash: [0, 5])
        let ring = Stroker.triangles(for: square(0, 0, 10).withCorners, style: dotted, tolerance: 0.05)
        XCTAssertTrue(covers(ring, Vec2(0, 0)))
        XCTAssertTrue(covers(ring, Vec2(0, 5)))
        XCTAssertFalse(covers(ring, Vec2(0, 7.5)))
    }

    func testTooManyDashesDrawSolid() {
        let path = line([Vec2(0, 0), Vec2(100_000, 0)])
        let tris = Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 2, cap: .butt, dash: [1, 1]),
                                     tolerance: 0.1)
        XCTAssertEqual(tris.count, 6)
    }

    func testTrianglesAreCounterClockwise() {
        var path = line([Vec2(0, 0), Vec2(10, 0), Vec2(0, 10), Vec2(10, 10)])
        path.points[1].width = 2
        for join in LineJoin.allCases {
            let tris = Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 3, join: join), tolerance: 0.1)
            for i in stride(from: 0, to: tris.count, by: 3) {
                XCTAssertGreaterThan((tris[i + 1] - tris[i]).cross(tris[i + 2] - tris[i]), 0)
            }
        }
    }

    func testAZeroWidthOutlineDrawsNothing() {
        let path = line([Vec2(0, 0), Vec2(10, 0)], widths: [0, 0])
        XCTAssertTrue(Stroker.triangles(for: path, style: StrokeStyle(color: .ink, width: 3), tolerance: 0.1).isEmpty)
    }
}

/// Plays an art batch's stencil and color steps at one sample point, as the GPU
/// would for the sample there. Colors are composited premultiplied over a white page.
struct StencilSimulator {
    var stencil: UInt8 = 0
    /// Premultiplied red, green, blue and alpha.
    var color = (r: 1.0, g: 1.0, b: 1.0, a: 1.0)

    /// `moving` is the live transform for the steps between `.moving` marks: the GPU
    /// draws their vertices through it, and gradients see the untransformed point.
    static func run(_ batch: ArtBatch, at point: Vec2, moving: Affine2D = .identity) -> StencilSimulator {
        var sim = StencilSimulator()
        let v = stride(from: 0, to: batch.vertices.count, by: 2).map {
            Vec2(Double(batch.vertices[$0]), Double(batch.vertices[$0 + 1]))
        }
        let back = moving.inverted ?? .identity
        var transformed = false
        for step in batch.steps {
            // Testing the untransformed point against untransformed triangles is the same
            // as testing the point against the transformed ones.
            let p = transformed ? back.apply(point) : point
            switch step {
            case .stencil(let range, let state, let reference):
                for i in stride(from: range.lowerBound, to: range.upperBound, by: 3) {
                    let a = v[i], b = v[i + 1], c = v[i + 2]
                    guard inside(p, a, b, c) else { continue }
                    var front = (b - a).cross(c - a) > 0
                    if transformed, moving.determinant < 0 { front.toggle() }
                    sim.apply(state, reference: reference, front: front)
                }
            case .cover(let range, let paint, let state, let reference):
                let rect = Rect(points: v[range])
                guard rect.contains(p) else { continue }
                if sim.apply(state, reference: reference, front: true) {
                    let c = paint.color(at: p)
                    sim.color = (c.r * c.a + sim.color.r * (1 - c.a), c.g * c.a + sim.color.g * (1 - c.a),
                                 c.b * c.a + sim.color.b * (1 - c.a), c.a + sim.color.a * (1 - c.a))
                }
            case .stencilView(let state, let reference):
                sim.apply(state, reference: reference, front: true)
            case .veil:
                break
            case .moving(let on):
                transformed = on
            }
        }
        return sim
    }

    /// Returns whether the test passed.
    @discardableResult
    mutating func apply(_ state: StencilState, reference: UInt8, front: Bool) -> Bool {
        let ref = reference & state.readMask, stored = stencil & state.readMask
        let passed: Bool
        switch state.compare {
        case .always: passed = true
        case .equal: passed = ref == stored
        case .notEqual: passed = ref != stored
        case .less: passed = ref < stored
        }
        let operation = passed ? (front ? state.pass : state.backPass) : state.fail
        let value: UInt8
        switch operation {
        case .keep: value = stencil
        case .zero: value = 0
        case .replace: value = reference
        case .incrementWrap: value = stencil &+ 1
        case .decrementWrap: value = stencil &- 1
        }
        stencil = (stencil & ~state.writeMask) | (value & state.writeMask)
        return passed
    }

    func isColor(_ c: RGBAColor, tolerance: Double = 0.01) -> Bool {
        abs(color.r - c.r) < tolerance && abs(color.g - c.g) < tolerance && abs(color.b - c.b) < tolerance
    }

    var isWhite: Bool { isColor(.white) }
}

final class ArtBatchTests: XCTestCase {
    private func drawing(_ shapes: [VectorShape]) -> Drawing {
        var d = Drawing()
        var shapes = shapes
        for i in shapes.indices { shapes[i].id = d.makeID() }
        d.parts.append(Part(id: d.makeID(), name: "Part", shapes: shapes))
        return d
    }

    private func render(_ d: Drawing, at p: Vec2) -> StencilSimulator {
        var builder = ArtBuilder()
        return StencilSimulator.run(builder.build(d, isolatedPart: nil, tolerance: 0.05), at: p)
    }

    func testFillsAndOutlinesPaintAndLeaveTheStencilClean() {
        let d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red, stroke: StrokeStyle(color: blue, width: 2))])
        XCTAssertTrue(render(d, at: Vec2(5, 5)).isColor(red))
        XCTAssertTrue(render(d, at: Vec2(0.5, 5)).isColor(blue))
        XCTAssertTrue(render(d, at: Vec2(-0.5, 5)).isColor(blue))
        XCTAssertTrue(render(d, at: Vec2(-1.5, 5)).isWhite)
        for p in [Vec2(5, 5), Vec2(0.5, 5), Vec2(-1.5, 5)] {
            XCTAssertEqual(render(d, at: p).stencil & 0x7F, 0)
        }
    }

    func testOverlappingOutlinePaintsOnce() {
        // A translucent outline crossing itself is as light where it crosses as elsewhere.
        let path = line([Vec2(0, 0), Vec2(10, 10), Vec2(10, 0), Vec2(0, 10)])
        let half = RGBAColor(r: 0, g: 0, b: 0, a: 0.5)
        let d = drawing([VectorShape(id: 0, path: path, stroke: StrokeStyle(color: half, width: 2))])
        let crossing = render(d, at: Vec2(5, 5)).color
        let single = render(d, at: Vec2(2, 2)).color
        XCTAssertEqual(crossing.r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(single.r, 0.5, accuracy: 1e-9)
    }

    func testClippedShapesDrawOnlyInsideTheirBase() {
        var shadow = VectorShape(id: 0, path: square(5, 5, 10), fill: blue)
        shadow.isClipped = true
        var top = VectorShape(id: 0, path: square(6, 6, 10), fill: RGBAColor(r: 0, g: 1, b: 0))
        top.isClipped = true
        let free = VectorShape(id: 0, path: square(12, 12, 10), fill: RGBAColor(r: 1, g: 1, b: 0))
        let d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red), shadow, top, free])
        XCTAssertTrue(render(d, at: Vec2(2, 2)).isColor(red))
        XCTAssertTrue(render(d, at: Vec2(5.5, 5.5)).isColor(blue))
        XCTAssertTrue(render(d, at: Vec2(8, 8)).isColor(RGBAColor(r: 0, g: 1, b: 0)))
        // Outside the base, the clipped shapes leave nothing, and the unclipped one on top draws.
        XCTAssertTrue(render(d, at: Vec2(11, 11)).isWhite)
        XCTAssertTrue(render(d, at: Vec2(13, 13)).isColor(RGBAColor(r: 1, g: 1, b: 0)))
    }

    func testTheBaseOutlineIsPartOfTheClip() {
        var shadow = VectorShape(id: 0, path: square(5, 5, 20), fill: blue)
        shadow.isClipped = true
        let base = VectorShape(id: 0, path: line([Vec2(0, 10), Vec2(30, 10)]), stroke: StrokeStyle(color: red, width: 4))
        let d = drawing([base, shadow])
        XCTAssertTrue(render(d, at: Vec2(10, 11)).isColor(blue))
        XCTAssertTrue(render(d, at: Vec2(2, 11)).isColor(red))
        XCTAssertTrue(render(d, at: Vec2(10, 15)).isWhite)
    }

    func testAClipStartsOverForEachBase() {
        var first = VectorShape(id: 0, path: square(0, 0, 30), fill: blue)
        first.isClipped = true
        var second = VectorShape(id: 0, path: square(0, 0, 30), fill: RGBAColor(r: 0, g: 1, b: 0))
        second.isClipped = true
        let d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red), first,
                         VectorShape(id: 0, path: square(20, 20, 10), fill: red), second])
        XCTAssertTrue(render(d, at: Vec2(5, 5)).isColor(blue))
        XCTAssertTrue(render(d, at: Vec2(25, 25)).isColor(RGBAColor(r: 0, g: 1, b: 0)))
        XCTAssertTrue(render(d, at: Vec2(15, 15)).isWhite)
    }

    func testAlignedOutlines() {
        for alignment in [StrokeAlignment.inside, .outside] {
            for clipBase in [false, true] {
                var shape = VectorShape(id: 0, path: square(0, 0, 10), fill: red,
                                        stroke: StrokeStyle(color: blue, width: 2, alignment: alignment))
                var shapes = [shape]
                if clipBase {
                    var clipped = VectorShape(id: 0, path: square(-5, 4, 30), fill: RGBAColor(r: 0, g: 1, b: 0, a: 0.5))
                    clipped.isClipped = true
                    shapes.append(clipped)
                }
                shape.stroke!.alignment = alignment
                let d = drawing(shapes)
                let inner = render(d, at: Vec2(1.5, 2))
                let outer = render(d, at: Vec2(-1.5, 2))
                let middle = render(d, at: Vec2(5, 3))
                XCTAssertTrue(middle.isColor(red), "\(alignment) \(clipBase)")
                if alignment == .inside {
                    XCTAssertTrue(inner.isColor(blue), "\(alignment) \(clipBase)")
                    XCTAssertTrue(outer.isWhite, "\(alignment) \(clipBase)")
                } else {
                    XCTAssertTrue(inner.isColor(red), "\(alignment) \(clipBase)")
                    XCTAssertTrue(outer.isColor(blue), "\(alignment) \(clipBase)")
                }
                for p in [Vec2(1.5, 2), Vec2(-1.5, 2), Vec2(5, 3), Vec2(5, 6), Vec2(-3, 2)] {
                    XCTAssertEqual(render(d, at: p).stencil & 0x7F, 0, "\(alignment) \(clipBase) \(p)")
                }
                if clipBase {
                    // The clipped shape shows over the base where the base draws, and nowhere else.
                    let tint = render(d, at: Vec2(5, 6)).color
                    XCTAssertEqual(tint.g, 0.5, accuracy: 0.01)
                    XCTAssertTrue(render(d, at: Vec2(-3, 6)).isWhite || alignment == .outside)
                    XCTAssertTrue(render(d, at: Vec2(-3.5, 6)).isWhite)
                }
            }
        }
    }

    func testAHiddenBaseHidesItsClippedShapes() {
        var base = VectorShape(id: 0, path: square(0, 0, 10), fill: red)
        base.isHidden = true
        var clipped = VectorShape(id: 0, path: square(0, 0, 10), fill: blue)
        clipped.isClipped = true
        XCTAssertTrue(render(drawing([base, clipped]), at: Vec2(5, 5)).isWhite)
        // With nothing below, a clipped shape draws unclipped.
        XCTAssertTrue(render(drawing([clipped]), at: Vec2(5, 5)).isColor(blue))
    }

    func testGradientsAndOpacity() {
        var shape = VectorShape(id: 0, path: square(0, 0, 10), fill: red)
        shape.gradient = ShapeGradient(kind: .linear, start: Vec2(0, 0), end: Vec2(10, 0),
                                  stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 1, color: blue)])
        let d = drawing([shape])
        let left = render(d, at: Vec2(0.5, 5)).color, right = render(d, at: Vec2(9.5, 5)).color
        XCTAssertGreaterThan(left.r, 0.9)
        XCTAssertGreaterThan(right.b, 0.9)
        let middle = render(d, at: Vec2(5, 3)).color
        XCTAssertEqual(middle.r, 0.5, accuracy: 0.01)

        shape.gradient = ShapeGradient(kind: .radial, start: Vec2(5, 5), end: Vec2(10, 5),
                                  stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 1, color: blue)])
        shape.opacity = 0.5
        let faded = render(drawing([shape]), at: Vec2(5, 5)).color
        XCTAssertEqual(faded.r, 1, accuracy: 0.01)
        XCTAssertEqual(faded.g, 0.5, accuracy: 0.01)
    }

    func testOnlyChangedShapesAreRetessellated() {
        var d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red),
                         VectorShape(id: 0, path: square(20, 0, 10), fill: blue)])
        var builder = ArtBuilder()
        let first = builder.build(d, isolatedPart: nil, tolerance: 0.1)
        XCTAssertEqual(builder.build(d, isolatedPart: nil, tolerance: 0.1), first)
        d.parts[0].shapes[1].fill = red
        let second = builder.build(d, isolatedPart: nil, tolerance: 0.1)
        XCTAssertEqual(second.vertices, first.vertices)
        XCTAssertNotEqual(second.steps, first.steps)
    }
}

final class AppearanceEditingTests: XCTestCase {
    /// An editor with one part holding a filled, outlined square and a shape above it.
    private func editor() -> DrawingEditor {
        var d = Drawing()
        let a = VectorShape(id: d.makeID(), path: square(0, 0, 100), fill: red, stroke: StrokeStyle(color: .ink, width: 2))
        let b = VectorShape(id: d.makeID(), path: square(50, 50, 100), fill: blue, stroke: StrokeStyle(color: .ink, width: 2))
        d.parts.append(Part(id: d.makeID(), name: "Arm", shapes: [a, b]))
        return DrawingEditor(drawing: d)
    }

    private func select(_ e: inout DrawingEditor, _ index: Int) {
        e.selection = .shape(part: e.drawing.parts[0].id, shape: e.drawing.parts[0].shapes[index].id)
    }

    func testOutlineOptionsApplyToTheSelectionAndNewShapes() {
        var e = editor()
        select(&e, 1)
        e.setOutlineCap(.square)
        e.setOutlineJoin(.miter)
        e.setMiterLimit(0.5)
        e.setOutlineDash([6, 2])
        e.setOutlineAlignment(.outside)
        let stroke = e.drawing.parts[0].shapes[1].stroke!
        XCTAssertEqual(stroke.cap, .square)
        XCTAssertEqual(stroke.join, .miter)
        XCTAssertEqual(stroke.miterLimit, 1)
        XCTAssertEqual(stroke.dash, [6, 2])
        XCTAssertEqual(stroke.alignment, .outside)
        XCTAssertEqual(e.drawing.parts[0].shapes[0].stroke?.cap, .round)
        // Five commands, five undo steps.
        for _ in 0..<5 { e.undo() }
        XCTAssertEqual(e.drawing.parts[0].shapes[1].stroke, StrokeStyle(color: .ink, width: 2))
        for _ in 0..<5 { e.redo() }
        // The style carries the options to new shapes, and changing the color keeps them.
        e.setOutline(red)
        XCTAssertEqual(e.drawing.parts[0].shapes[1].stroke?.dash, [6, 2])
        e.selection = .none
        e.addPath(square(300, 300, 10))
        XCTAssertEqual(e.drawing.parts.last?.shapes[0].stroke?.cap, .square)
        XCTAssertEqual(e.drawing.parts.last?.shapes[0].stroke?.alignment, .outside)
        // Selecting a shape shows its options.
        select(&e, 0)
        XCTAssertEqual(e.style.outlineCap, .round)
        XCTAssertEqual(e.style.outlineDash, [])
    }

    func testOpacityIsOneUndoStepPerDrag() {
        var e = editor()
        select(&e, 0)
        for v in [0.9, 0.7, 0.5, 0.2] { e.setOpacity(v) }
        XCTAssertEqual(e.drawing.parts[0].shapes[0].opacity, 0.2, accuracy: 1e-9)
        XCTAssertEqual(e.selectionAppearance?.opacity ?? 0, 0.2, accuracy: 1e-9)
        e.undo()
        XCTAssertEqual(e.drawing.parts[0].shapes[0].opacity, 1)
    }

    func testClipping() {
        var e = editor()
        select(&e, 0)
        XCTAssertFalse(e.canClipSelection)
        e.setClipped(true)
        XCTAssertFalse(e.drawing.parts[0].shapes[0].isClipped)
        XCTAssertFalse(e.canUndo)
        select(&e, 1)
        XCTAssertTrue(e.canClipSelection)
        e.setClipped(true)
        XCTAssertTrue(e.drawing.parts[0].shapes[1].isClipped)
        XCTAssertEqual(e.selectionAppearance?.isClipped, true)
        // The clipped square can't be tapped where it is clipped away.
        let part = e.drawing.parts[0]
        XCTAssertEqual(e.drawing.hitTest(Vec2(75, 75), tolerance: 1)?.shape, part.shapes[1].id)
        XCTAssertNil(e.drawing.hitTest(Vec2(130, 130), tolerance: 1))
        e.undo()
        XCTAssertEqual(e.drawing.hitTest(Vec2(130, 130), tolerance: 1)?.shape, part.shapes[1].id)
    }

    func testGradients() {
        var e = editor()
        select(&e, 0)
        e.setGradient(.linear)
        var gradient = e.drawing.parts[0].shapes[0].gradient!
        XCTAssertEqual(gradient.stops.first?.color, red)
        XCTAssertEqual(gradient.stops.last?.color, red.shaded(0.6))
        XCTAssertEqual(gradient.start, Vec2(50, 0))
        XCTAssertEqual(gradient.end, Vec2(50, 100))

        e.setGradientAngle(0)
        gradient = e.drawing.parts[0].shapes[0].gradient!
        XCTAssertTrue(gradient.start.isApproximately(Vec2(0, 50)))
        XCTAssertTrue(gradient.end.isApproximately(Vec2(100, 50)))
        e.setGradientSpan(0.5)
        gradient = e.drawing.parts[0].shapes[0].gradient!
        XCTAssertTrue(gradient.start.isApproximately(Vec2(25, 50)))
        XCTAssertEqual(e.selectionAppearance?.gradientSpan ?? 0, 0.5, accuracy: 1e-9)

        // The first stop is the plain fill; picking a fill color sets it.
        e.setGradientStop(1, color: .white)
        e.setFill(blue)
        gradient = e.drawing.parts[0].shapes[0].gradient!
        XCTAssertEqual(gradient.stops.map(\.color), [blue, .white])
        XCTAssertEqual(e.drawing.parts[0].shapes[0].fill, blue)
        e.reverseGradient()
        XCTAssertEqual(e.drawing.parts[0].shapes[0].gradient?.stops.map(\.color), [.white, blue])
        XCTAssertEqual(e.drawing.parts[0].shapes[0].fill, .white)

        e.setGradient(.radial)
        gradient = e.drawing.parts[0].shapes[0].gradient!
        XCTAssertEqual(gradient.kind, .radial)
        XCTAssertEqual(gradient.start, Vec2(50, 50))
        XCTAssertEqual(gradient.end, Vec2(100, 50))
        XCTAssertEqual(gradient.stops.map(\.color), [.white, blue])

        // The gradient turns with the shape.
        e.rotateSelection(byDegrees: 90)
        gradient = e.drawing.parts[0].shapes[0].gradient!
        XCTAssertTrue(gradient.end.isApproximately(Vec2(50, 100), tolerance: 1e-6), "\(gradient.end)")

        e.setGradient(nil)
        XCTAssertNil(e.drawing.parts[0].shapes[0].gradient)
        e.setGradient(.linear)
        e.setFillEnabled(false)
        XCTAssertNil(e.drawing.parts[0].shapes[0].gradient)
    }

    func testScalingScalesDashes() {
        var e = editor()
        select(&e, 0)
        e.setOutlineDash([4, 2])
        e.drawing.apply(.scale(2), to: e.selection)
        XCTAssertEqual(e.drawing.parts[0].shapes[0].stroke?.dash, [8, 4])
        XCTAssertEqual(e.drawing.parts[0].shapes[0].stroke?.width, 4)
    }

    func testGlobalColors() {
        var e = editor()
        let skin = e.addGlobalColor(RGBAColor(hex: "#F2A65A")!, name: "Skin")
        let ink = e.addGlobalColor(.black, name: "Skin")
        XCTAssertEqual(e.drawing.globalColors.map(\.name), ["Skin", "Skin 2"])
        e.renameGlobalColor(ink, to: "Ink")
        e.renameGlobalColor(ink, to: "  ")
        XCTAssertEqual(e.drawing.globalColor(ink)?.name, "Ink")

        e.selection = .layer(e.drawing.parts[0].id)
        e.applyGlobalFill(skin)
        e.undo()
        XCTAssertEqual(e.drawing.parts[0].shapes.map(\.fill), [red, blue], "applying a global color is one undo step")
        XCTAssertTrue(e.drawing.parts[0].shapes.allSatisfy { $0.fillGlobal == nil })
        e.redo()
        e.applyGlobalOutline(ink)
        XCTAssertTrue(e.drawing.parts[0].shapes.allSatisfy { $0.fillGlobal == skin && $0.stroke?.global == ink })

        // Changing the global color changes every follower; a picker drag is one step.
        for k in 1...5 { e.setGlobalColor(skin, to: RGBAColor(r: Double(k) / 5, g: 0, b: 0), continuous: true) }
        XCTAssertTrue(e.drawing.parts[0].shapes.allSatisfy { $0.fill == RGBAColor(r: 1, g: 0, b: 0) })
        XCTAssertEqual(e.style.fill, RGBAColor(r: 1, g: 0, b: 0))
        e.undo()
        XCTAssertTrue(e.drawing.parts[0].shapes.allSatisfy { $0.fill == RGBAColor(hex: "#F2A65A") })

        // A plain color unlinks; removing a global color unlinks and keeps the colors.
        select(&e, 1)
        e.setFill(blue)
        XCTAssertNil(e.drawing.parts[0].shapes[1].fillGlobal)
        XCTAssertEqual(e.drawing.parts[0].shapes[0].fillGlobal, skin)
        e.removeGlobalColor(ink)
        XCTAssertTrue(e.drawing.parts[0].shapes.allSatisfy { $0.stroke?.global == nil && $0.stroke?.color == .black })
        XCTAssertEqual(e.drawing.globalColors.map(\.id), [skin])
    }

    func testCopyAndPasteKeepGlobalColors() {
        var e = editor()
        let skin = e.addGlobalColor(red, name: "Skin")
        e.addGlobalColor(blue, name: "Unused")
        select(&e, 0)
        e.applyGlobalFill(skin)
        let text = e.copySelection()!
        XCTAssertTrue(text.contains("Skin"))
        XCTAssertFalse(text.contains("Unused"))

        // Into the same character: the copy follows the same global color.
        XCTAssertTrue(e.paste(text))
        let pasted = e.drawing.shape(e.activeShape!)!
        XCTAssertEqual(pasted.fillGlobal, skin)
        XCTAssertEqual(e.drawing.globalColors.count, 2)

        // Into another character with a "Skin" of its own: it follows that one.
        var other = DrawingEditor()
        let otherSkin = other.addGlobalColor(.white, name: "Skin")
        XCTAssertTrue(other.paste(text))
        XCTAssertEqual(other.drawing.parts[0].shapes[0].fillGlobal, otherSkin)
        XCTAssertEqual(other.drawing.parts[0].shapes[0].fill, .white)

        // Into one without it: the global color comes along.
        var fresh = DrawingEditor()
        XCTAssertTrue(fresh.paste(text))
        XCTAssertEqual(fresh.drawing.globalColors.map(\.name), ["Skin"])
        XCTAssertEqual(fresh.drawing.parts[0].shapes[0].fillGlobal, fresh.drawing.globalColors[0].id)
    }

    func testAnchorWidths() {
        var e = editor()
        e.tool = .directSelect
        select(&e, 0)
        e.selectedAnchors = [0, 2]
        for w in [1.2, 1.6, 2.0] { e.setSelectedAnchorsWidth(w) }
        XCTAssertEqual(e.drawing.parts[0].shapes[0].path.points.map(\.width), [2, 1, 2, 1])
        XCTAssertEqual(e.selectedAnchorsWidth, 2)
        e.undo()
        XCTAssertEqual(e.drawing.parts[0].shapes[0].path.points.map(\.width), [1, 1, 1, 1])
        e.redo()
        // The outline reaches further where it is wider.
        XCTAssertEqual(e.drawing.parts[0].shapes[0].bounds.minPoint.x, -2, accuracy: 1e-9)
        // Splitting a segment blends the width.
        var path = e.drawing.parts[0].shapes[0].path
        let i = path.insertPoint(segment: 0, t: 0.25)
        XCTAssertEqual(path.points[i].width, 1.75, accuracy: 1e-9)
        e.resetOutlineWidths()
        XCTAssertFalse(e.drawing.parts[0].shapes[0].path.hasVariableWidth)
    }

    func testPressureSetsWidthOnlyWhenOn() {
        let points = (0...40).map { Vec2(Double($0) * 5, 0) }
        let pressures = (0...40).map { Double($0) / 40 }
        var e = DrawingEditor()
        e.style.fillEnabled = false
        e.addStroke(points, pressures: pressures, zoom: 1)
        XCTAssertFalse(e.drawing.parts[0].shapes[0].path.hasVariableWidth)

        e.pressureWidth = true
        e.addStroke(points, pressures: pressures, zoom: 1)
        let widths = e.drawing.parts[1].shapes[0].path.points.map(\.width)
        XCTAssertEqual(widths.first ?? 0, PressureWidth.width(forPressure: 0.025), accuracy: 0.02)
        XCTAssertEqual(widths.last ?? 0, 2, accuracy: 0.01)
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(PressureWidth.width(forPressure: 1.0 / 3), 1, accuracy: 1e-9)
    }

    func testPencilPressureReachesTheStroke() {
        var s = CanvasSession()
        s.editor.pressureWidth = true
        s.editor.style.fillEnabled = false
        s.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0), pressure: 0.1)
        for k in 1...20 {
            s.touchMoved(id: 1, samples: [Vec2(Double(k) * 10, 0)], pressures: [0.1 + Double(k) * 0.04])
        }
        XCTAssertNotNil(s.liveStroke?.displayWidths)
        s.touchEnded(id: 1, location: Vec2(205, 0))
        let path = s.editor.drawing.parts[0].shapes[0].path
        XCTAssertTrue(path.hasVariableWidth)
        XCTAssertLessThan(path.points.first!.width, path.points.last!.width)

        // Without pressure (a finger in the Simulator), the outline stays uniform.
        var plain = CanvasSession()
        plain.editor.pressureWidth = true
        plain.touchBegan(id: 1, kind: .pencil, location: Vec2(0, 0))
        plain.touchMoved(id: 1, samples: [Vec2(50, 0), Vec2(100, 10)])
        XCTAssertNil(plain.liveStroke?.displayWidths)
        plain.touchEnded(id: 1, location: Vec2(150, 0))
        XCTAssertFalse(plain.editor.drawing.parts[0].shapes[0].path.hasVariableWidth)
    }
}

final class AppearanceFormatTests: XCTestCase {
    func testEveryAppearanceKeyRoundTrips() throws {
        var d = Drawing()
        let skin = GlobalColor(id: d.makeID(), name: "Skin", color: red)
        d.globalColors = [skin]
        d.palette = [blue]
        var path = square(0, 0, 10)
        path.points[1].width = 0.25
        var shape = VectorShape(id: d.makeID(), path: path, fill: red,
                                stroke: StrokeStyle(color: blue, width: 2.5, cap: .square, join: .bevel, miterLimit: 2,
                                                    dash: [3, 1.5], dashOffset: 0.5, alignment: .outside, global: skin.id))
        shape.fillGlobal = skin.id
        shape.gradient = ShapeGradient(kind: .radial, start: Vec2(5, 5), end: Vec2(9, 5),
                                  stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 0.7, color: blue)])
        shape.opacity = 0.4
        var clipped = VectorShape(id: d.makeID(), path: square(2, 2, 10), fill: blue)
        clipped.isClipped = true
        d.parts = [Part(id: d.makeID(), name: "P", shapes: [shape, clipped])]

        let text = CharacterFormat.encode(d).formatted()
        let back = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(back.palette, [blue])
        XCTAssertEqual(back.globalColors.map(\.name), ["Skin"])
        let s = back.parts[0].shapes[0]
        let newSkin = back.globalColors[0].id
        XCTAssertEqual(s.fillGlobal, newSkin)
        XCTAssertEqual(s.stroke, StrokeStyle(color: blue, width: 2.5, cap: .square, join: .bevel, miterLimit: 2,
                                             dash: [3, 1.5], dashOffset: 0.5, alignment: .outside, global: newSkin))
        XCTAssertEqual(s.gradient, shape.gradient)
        XCTAssertEqual(s.opacity, 0.4)
        XCTAssertEqual(s.path.points.map(\.width), [1, 0.25, 1, 1])
        XCTAssertTrue(back.parts[0].shapes[1].isClipped)
        // Saving again gives the same text.
        XCTAssertEqual(CharacterFormat.encode(back).formatted(), text)
    }

    func testDefaultsAreNotWritten() {
        var d = Drawing()
        let shape = VectorShape(id: d.makeID(), path: square(0, 0, 10), fill: red, stroke: StrokeStyle(color: blue, width: 2))
        d.parts = [Part(id: d.makeID(), name: "P", shapes: [shape])]
        let text = CharacterFormat.encode(d).formatted()
        for key in ["\"w\"", "cap", "join", "miterLimit", "dash", "align", "opacity", "clipped", "gradient", "global"] {
            XCTAssertFalse(text.contains(key), key)
        }
    }

    func testA01FileOpensAndSavesAsCurrent() throws {
        let old = try JSONValue(parsing: """
        { "formatVersion": "0.1.0", "name": "Old",
          "slots": [{ "id": "A", "bone": "root", "attachment": "A" }],
          "skins": { "default": { "A": { "A": { "type": "vector", "shapes": [
            { "closed": false, "stroke": { "color": "#000000FF", "width": 3 },
              "points": [{ "p": [0, 0] }, { "p": [10, 0] }] }] } } } },
          "palette": ["#FF0000FF"] }
        """)
        let migrated = try CharacterFormat.migrate(old)
        XCTAssertEqual(migrated["formatVersion"], .string(CharacterFormat.version.description))
        let d = try CharacterFormat.decode(old).drawing
        XCTAssertEqual(d.parts[0].shapes[0].stroke, StrokeStyle(color: .black, width: 3))
        XCTAssertEqual(d.palette, [red])
        XCTAssertTrue(d.globalColors.isEmpty)
        XCTAssertEqual(CharacterFormat.encode(d)["formatVersion"], .string(CharacterFormat.version.description))
    }

    func testBadAppearanceIsReportedWithItsPath() throws {
        func error(_ shape: String) throws -> CharacterFileError? {
            let file = try JSONValue(parsing: """
            { "formatVersion": "0.2.0", "slots": [{ "id": "A", "bone": "root", "attachment": "A" }],
              "skins": { "default": { "A": { "A": { "type": "vector", "shapes": [\(shape)] } } } } }
            """)
            do {
                _ = try CharacterFormat.decode(file)
                return nil
            } catch {
                return error as? CharacterFileError
            }
        }
        let prefix = "skins.default.A.A.shapes[0]"
        XCTAssertEqual(try error(##"{ "closed": false, "stroke": { "color": "#000", "width": 1 }, "points": [] }"##),
                       .invalid(path: prefix + ".stroke.color", problem: "is not a #RRGGBBAA color"))
        XCTAssertEqual(try error(##"{ "closed": false, "stroke": { "color": "#000000", "width": 1, "cap": "flat" }, "points": [] }"##),
                       .invalid(path: prefix + ".stroke.cap", problem: #"is not one of "butt", "round", "square""#))
        XCTAssertEqual(try error(##"{ "closed": false, "points": [{ "p": [0, 0], "w": -1 }] }"##),
                       .invalid(path: prefix + ".points[0].w", problem: "is negative"))
        XCTAssertEqual(try error(##"{ "closed": true, "fill": "#000000", "gradient": { "type": "linear", "start": [0, 0], "end": [1, 0], "stops": [] }, "points": [] }"##),
                       .invalid(path: prefix + ".gradient.stops", problem: "is empty"))
        // An unknown global color name keeps the plain color.
        XCTAssertNil(try error(##"{ "closed": true, "fill": "#000000", "fillGlobal": "Nope", "points": [] }"##))
    }
}

private extension BezierPath {
    /// The same path with its anchors as corners, so flattening keeps the corners exact.
    var withCorners: BezierPath {
        var copy = self
        for i in copy.points.indices { copy.points[i].mode = .corner }
        return copy
    }
}

extension ArtBatchTests {
    /// Drawing the drawing as a drag began, with the moved shapes' steps put through the
    /// live transform, paints what drawing the transformed drawing does.
    func testMovingStepsMatchTheTransformedDrawing() {
        var gradient = VectorShape(id: 0, path: square(20, 0, 10), fill: red)
        gradient.gradient = ShapeGradient(kind: .linear, start: Vec2(20, 0), end: Vec2(30, 0),
                                          stops: [GradientStop(offset: 0, color: red), GradientStop(offset: 1, color: blue)])
        var clipped = VectorShape(id: 0, path: square(4, 4, 10), fill: RGBAColor(r: 0, g: 1, b: 0))
        clipped.isClipped = true
        let outlined = VectorShape(id: 0, path: square(0, 20, 10),
                                   stroke: StrokeStyle(color: blue, width: 2, alignment: .inside))
        let still = VectorShape(id: 0, path: square(8, 8, 14), fill: RGBAColor(r: 1, g: 1, b: 0, a: 0.5))
        let d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red), clipped, gradient, outlined, still])
        let part = d.parts[0]
        // Move the clip base but not its clipped shape, and the two shapes after it.
        let moved = [0, 2, 3].map { part.shapes[$0].id }
        let selection = Selection.covering(Set(moved.map { ShapeRef(part: part.id, shape: $0) }))
        let t = Affine2D.translation(Vec2(3, -2)) * Affine2D.rotation(0.4) * Affine2D.scale(1.5)
        let after = d.applying(t, to: selection)

        var live = ArtBuilder()
        let batch = live.build(d, isolatedPart: nil, tolerance: 0.05, moving: Set(moved))
        XCTAssertEqual(batch.steps.filter { if case .moving = $0 { true } else { false } }.count, 4,
                       "on at the base, off at the clipped shape, on again, off at the last shape")
        var plain = ArtBuilder()
        let expected = plain.build(after, isolatedPart: nil, tolerance: 0.05)

        var samples = 0, differences = 0
        for x in stride(from: -10.0, through: 40, by: 0.73) {
            for y in stride(from: -15.0, through: 45, by: 0.71) {
                let p = Vec2(x, y)
                let a = StencilSimulator.run(batch, at: p, moving: t), b = StencilSimulator.run(expected, at: p)
                samples += 1
                let same = abs(a.color.r - b.color.r) < 0.02 && abs(a.color.g - b.color.g) < 0.02 &&
                    abs(a.color.b - b.color.b) < 0.02
                if !same { differences += 1 }
                XCTAssertEqual(a.stencil & 0x7F, 0)
            }
        }
        // Only samples within the flattening tolerance of an edge may differ.
        XCTAssertLessThan(Double(differences) / Double(samples), 0.005, "\(differences) of \(samples)")
    }
}

extension ArtBatchTests {
    /// The clip is cleared over the clipped shapes' covers, not the whole view, unless a
    /// live transform moves some of the shapes involved.
    func testTheClipClearIsBoundedToTheClippedShapes() {
        var first = VectorShape(id: 0, path: square(4, 4, 10), fill: blue)
        first.isClipped = true
        var second = VectorShape(id: 0, path: square(-5, 2, 8), stroke: StrokeStyle(color: blue, width: 2))
        second.isClipped = true
        let d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red), first, second,
                         VectorShape(id: 0, path: square(40, 40, 10), fill: red)])
        var builder = ArtBuilder()
        let batch = builder.build(d, isolatedPart: nil, tolerance: 0.05)
        let clears = batch.steps.compactMap { step -> Rect? in
            guard case .stencil(let range, let state, _) = step, state == ArtStencil.clearClip else { return nil }
            let v = range.map { Vec2(Double(batch.vertices[$0 * 2]), Double(batch.vertices[$0 * 2 + 1])) }
            return Rect(points: v)
        }
        XCTAssertFalse(batch.steps.contains { if case .stencilView = $0 { true } else { false } })
        XCTAssertEqual(clears.count, 1)
        let clear = try! XCTUnwrap(clears.first)
        // The fill of the first and the outline of the second, which reaches past its path.
        XCTAssertEqual(clear.minPoint.x, -6, accuracy: 0.01)
        XCTAssertEqual(clear.minPoint.y, 1, accuracy: 0.01)
        XCTAssertEqual(clear.maxPoint.x, 14, accuracy: 0.01)
        XCTAssertEqual(clear.maxPoint.y, 14, accuracy: 0.01)

        // Moving the clipped shape but not its base: the clear covers the view again.
        var live = ArtBuilder()
        let moving = live.build(d, isolatedPart: nil, tolerance: 0.05, moving: [d.parts[0].shapes[1].id])
        XCTAssertTrue(moving.steps.contains { if case .stencilView = $0 { true } else { false } })
    }

    /// A clip base whose clipped shapes are all hidden still draws, and clears nothing.
    func testABaseWithNothingClippedShownClearsNothing() {
        var hidden = VectorShape(id: 0, path: square(4, 4, 10), fill: blue)
        hidden.isClipped = true
        hidden.isHidden = true
        let d = drawing([VectorShape(id: 0, path: square(0, 0, 10), fill: red), hidden])
        var builder = ArtBuilder()
        let batch = builder.build(d, isolatedPart: nil, tolerance: 0.05)
        XCTAssertFalse(batch.steps.contains {
            switch $0 {
            case .stencilView: true
            case .stencil(_, let state, _): state == ArtStencil.clearClip
            default: false
            }
        })
        XCTAssertTrue(StencilSimulator.run(batch, at: Vec2(5, 5)).isColor(red))
    }
}

/// Clipped groups (a whole group drawn inside the shape below it) and accessory shapes
/// drawn behind their owner.
final class GroupClipAndBehindTests: XCTestCase {
    private let green = RGBAColor(r: 0, g: 1, b: 0)
    private let yellow = RGBAColor(r: 1, g: 1, b: 0)

    /// One part: a red base square (0...10), then a clipped group of a blue square and a
    /// green square clipped to the blue one inside the group, then `above`.
    private func clippedGroup(above: [VectorShape] = [], groupClipped: Bool = true) -> Drawing {
        var d = Drawing()
        let group = d.makeID()
        var shapes = [VectorShape(id: d.makeID(), path: square(0, 0, 10), fill: red),
                      VectorShape(id: d.makeID(), path: square(5, 5, 10), fill: blue),
                      VectorShape(id: d.makeID(), path: square(7, 7, 10), fill: green)]
        shapes[1].group = group
        shapes[2].group = group
        shapes[2].isClipped = true
        for var shape in above {
            shape.id = d.makeID()
            shapes.append(shape)
        }
        var part = Part(id: d.makeID(), name: "Eye", shapes: shapes)
        part.groups = [ShapeGroup(id: group, name: "Iris", isClipped: groupClipped)]
        d.parts.append(part)
        return d
    }

    private func render(_ d: Drawing, at p: Vec2, isolating part: Int? = nil, group: Int? = nil) -> StencilSimulator {
        var builder = ArtBuilder()
        return StencilSimulator.run(builder.build(d, isolatedPart: part, isolatedGroup: group, tolerance: 0.05), at: p)
    }

    func testAClippedGroupDrawsOnlyInsideTheShapeBelowIt() {
        let d = clippedGroup()
        XCTAssertTrue(render(d, at: Vec2(2, 2)).isColor(red))
        XCTAssertTrue(render(d, at: Vec2(6, 6)).isColor(blue))
        // Clipping inside the group still works, within the group's base.
        XCTAssertTrue(render(d, at: Vec2(8, 8)).isColor(green))
        for p in [Vec2(12, 12), Vec2(16, 16), Vec2(6, 12)] {
            XCTAssertTrue(render(d, at: p).isWhite, "\(p)")
        }
        for p in [Vec2(2, 2), Vec2(6, 6), Vec2(8, 8), Vec2(12, 12), Vec2(30, 30)] {
            XCTAssertEqual(render(d, at: p).stencil & 0x7F, 0, "\(p)")
        }
        // Not clipped, the group draws whole.
        let whole = clippedGroup(groupClipped: false)
        XCTAssertTrue(render(whole, at: Vec2(12, 12)).isColor(green))
        XCTAssertTrue(render(whole, at: Vec2(6, 12)).isColor(blue))
    }

    func testClippedShapesAboveAClippedGroupShareItsBase() {
        var shadow = VectorShape(id: 0, path: square(-5, -5, 40), fill: yellow)
        shadow.isClipped = true
        let d = clippedGroup(above: [shadow])
        XCTAssertEqual(d.parts[0].clipBase(of: 3), 0)
        // The shadow draws over the base, including where the group's inner clip was.
        XCTAssertTrue(render(d, at: Vec2(2, 2)).isColor(yellow))
        XCTAssertTrue(render(d, at: Vec2(8, 8)).isColor(yellow))
        XCTAssertTrue(render(d, at: Vec2(12, 12)).isWhite)
        XCTAssertTrue(render(d, at: Vec2(-2, -2)).isWhite)
    }

    func testAClippedGroupWithAlignedOutlines() {
        for alignment in [StrokeAlignment.center, .inside, .outside] {
            var d = clippedGroup()
            for s in d.parts[0].shapes.indices {
                d.parts[0].shapes[s].stroke = StrokeStyle(color: .ink, width: 2, alignment: alignment)
            }
            for p in [Vec2(1.5, 2), Vec2(-1.5, 2), Vec2(6, 6), Vec2(8, 8), Vec2(9.5, 9.5), Vec2(10.5, 10.5),
                      Vec2(12, 12), Vec2(20, 20)] {
                XCTAssertEqual(render(d, at: p).stencil & 0x7F, 0, "\(alignment) \(p)")
            }
            XCTAssertTrue(render(d, at: Vec2(9.5, 9.5)).isColor(green), "\(alignment)")
            XCTAssertTrue(render(d, at: Vec2(14, 14)).isWhite, "\(alignment)")
        }
    }

    func testAHiddenBaseHidesTheGroupAndNothingBelowDrawsItWhole() {
        var d = clippedGroup()
        d.parts[0].shapes[0].isHidden = true
        XCTAssertTrue(render(d, at: Vec2(6, 6)).isWhite)
        XCTAssertNil(d.hitTest(Vec2(6, 6), tolerance: 0))
        d.parts[0].shapes.removeFirst()
        XCTAssertNil(d.parts[0].clipBase(ofGroup: d.parts[0].groups[0].id))
        XCTAssertTrue(render(d, at: Vec2(12, 12)).isColor(green))
    }

    func testHitTestingFollowsTheGroupClip() {
        let d = clippedGroup()
        let part = d.parts[0]
        XCTAssertEqual(d.hitTest(Vec2(6, 6), tolerance: 0)?.shape, part.shapes[1].id)
        XCTAssertNil(d.hitTest(Vec2(12, 12), tolerance: 0))
    }

    /// The bounded clip clear before a group's base covers the whole group, so a clip
    /// left over from an earlier part doesn't show through the group mask.
    func testAClippedGroupIgnoresAClipLeftByAnEarlierPart() {
        var d = clippedGroup()
        var big = VectorShape(id: d.makeID(), path: square(0, 0, 40), fill: red)
        big.stroke = nil
        var cover = VectorShape(id: d.makeID(), path: square(0, 0, 40), fill: yellow)
        cover.isClipped = true
        d.parts.insert(Part(id: d.makeID(), name: "Back", shapes: [big, cover]), at: 0)
        XCTAssertTrue(render(d, at: Vec2(12, 12)).isColor(yellow))
        XCTAssertTrue(render(d, at: Vec2(6, 6)).isColor(blue))
        XCTAssertTrue(render(d, at: Vec2(8, 8)).isColor(green))
    }

    func testAnIsolatedClippedGroupDrawsWhole() {
        let d = clippedGroup()
        let render = render(d, at: Vec2(12, 12), isolating: d.parts[0].id, group: d.parts[0].groups[0].id)
        XCTAssertTrue(render.isColor(green))
    }

    func testGroupClippingIsOneUndoStepAndNeedsAShapeBelow() {
        var d = clippedGroup(groupClipped: false)
        let part = d.parts[0].id, group = d.parts[0].groups[0].id
        var e = DrawingEditor(drawing: d)
        XCTAssertTrue(e.canClipGroup(group, inPart: part))
        e.setGroupClipped(group, inPart: part, true)
        XCTAssertTrue(e.drawing.parts[0].groups[0].isClipped)
        e.undo()
        XCTAssertFalse(e.drawing.parts[0].groups[0].isClipped)
        d.parts[0].shapes.removeFirst()
        e = DrawingEditor(drawing: d)
        XCTAssertFalse(e.canClipGroup(group, inPart: part))
        e.setGroupClipped(group, inPart: part, true)
        XCTAssertFalse(e.drawing.parts[0].groups[0].isClipped)
    }

    func testTheFileKeepsClippedGroups() throws {
        let d = clippedGroup()
        let text = CharacterFormat.encode(d).formatted()
        let back = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(back.parts[0].groups.first?.isClipped, true)
        XCTAssertEqual(CharacterFormat.encode(back).formatted(), text)
        // Off, the group's key isn't written; the clipped shape's still is.
        let plain = CharacterFormat.encode(clippedGroup(groupClipped: false)).formatted()
        XCTAssertEqual(plain.components(separatedBy: "\"clipped\"").count, 2)
    }

    func testSVGMasksClippedGroups() throws {
        let clipped = try XCTUnwrap(SVGWriter.document(for: clippedGroup()))
        XCTAssertTrue(clipped.contains("<g data-name=\"Iris\" mask=\"url(#"))
    }
}
