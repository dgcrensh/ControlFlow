import Foundation
import XCTest
@testable import ControlFlowCore

/// What a draw reads: the state bound when it is made.
private struct DrawState: Equatable {
    enum Vertices: Equatable { case view, segment(Int) }
    enum Paint: Equatable { case none, slot(segment: Int, slot: Int), image(String, Double), veil }

    var pipeline: ArtPipeline?
    var transform: Affine2D?
    var vertices: Vertices?
    var stencil: StencilState??
    var reference: UInt8?
    var paint = Paint.none
    var range: Range<Int> = 0..<0
}

/// Plays the commands as a GPU would keep them, and records what each draw sees.
private struct RecordingEncoder: ArtEncoder {
    var ready: Set<String> = []
    var state = DrawState()
    /// The segment whose buffer fragment buffer 0 reads.
    var paintBuffer: Int?
    var draws: [DrawState] = []
    var calls = 0
    var transforms = 0
    /// Bytes copied into the command buffer: the 64-byte matrix, the view's rectangle
    /// and the image and veil paints. Paint slots are in buffers, so they copy nothing.
    var bytes = 0

    mutating func hasPicture(_ image: ArtImage) -> Bool { ready.contains(image.src) }
    mutating func setPipeline(_ pipeline: ArtPipeline) { calls += 1; state.pipeline = pipeline }
    mutating func setTransform(_ toWorld: Affine2D) { calls += 1; transforms += 1; bytes += 64; state.transform = toWorld }
    mutating func setVertices(_ segment: ArtSegment) { calls += 1; state.vertices = .segment(segment.id) }
    mutating func setViewVertices() { calls += 1; bytes += 48; state.vertices = .view }
    mutating func setStencil(_ stencil: StencilState?) { calls += 1; state.stencil = .some(stencil) }
    mutating func setStencilReference(_ reference: UInt8) { calls += 1; state.reference = reference }
    mutating func setPaint(_ segment: ArtSegment, slot: Int, rebind: Bool) {
        calls += 1
        if !rebind { XCTAssertEqual(paintBuffer, segment.id, "only the offset moves when the buffer is bound") }
        paintBuffer = segment.id
        state.paint = .slot(segment: segment.id, slot: slot)
    }
    mutating func setImagePaint(_ image: ArtImage, opacity: Double) {
        calls += 2 // the map and the picture
        bytes += 48
        paintBuffer = nil
        state.paint = .image(image.src, opacity)
    }
    mutating func setVeilPaint() { calls += 1; bytes += 208; paintBuffer = nil; state.paint = .veil }
    mutating func draw(_ vertices: Range<Int>) {
        calls += 1
        var seen = state
        seen.range = vertices
        draws.append(seen)
    }
}

/// What each draw should see, from a walk that sets everything for every step, as the
/// renderer did before `ArtEncoding`. Fields a draw doesn't read are left out: a stencil
/// draw's paint, and the veil's stencil reference.
private func expectedDraws(_ batch: ArtBatch, live: Affine2D, ready: Set<String>) -> [DrawState] {
    var draws: [DrawState] = []
    for segment in batch.segments {
        var place = Affine2D.identity
        var moving = false
        var slot = 0
        func toWorld() -> Affine2D { moving ? live * (segment.transform * place) : segment.transform * place }
        for step in batch.steps[segment.steps] {
            switch step {
            case .stencil(let range, let state, let reference):
                draws.append(DrawState(pipeline: .stencil, transform: toWorld(), vertices: .segment(segment.id),
                                       stencil: .some(state), reference: reference, range: segment.local(range)))
            case .cover(let range, let paint, let state, let reference):
                let image = paint.image.flatMap { ready.contains($0.src) ? $0 : nil }
                draws.append(DrawState(pipeline: image == nil ? .cover : .imageCover, transform: toWorld(),
                                       vertices: .segment(segment.id), stencil: .some(state), reference: reference,
                                       paint: image.map { .image($0.src, paint.opacity) } ??
                                           .slot(segment: segment.id, slot: slot),
                                       range: segment.local(range)))
                slot += 1
            case .stencilView(let state, let reference):
                draws.append(DrawState(pipeline: .stencil, transform: .identity, vertices: .view, stencil: .some(state),
                                       reference: reference, range: 0..<6))
            case .veil:
                draws.append(DrawState(pipeline: .cover, transform: .identity, vertices: .view, stencil: .some(nil),
                                       paint: .veil, range: 0..<6))
            case .moving(let on):
                moving = on
            case .place(let matrix):
                place = matrix
            }
        }
    }
    return draws
}

/// Encodes `batch` and checks every draw sees what the full walk would have set.
@discardableResult
private func assertEncodesLikeFullWalk(_ batch: ArtBatch, live: Affine2D = .identity, ready: Set<String> = [],
                                       file: StaticString = #filePath, line: UInt = #line) -> RecordingEncoder {
    var encoder = RecordingEncoder(ready: ready)
    ArtEncoding.encode(batch.steps, segments: batch.segments, liveTransform: live, into: &encoder)
    let expected = expectedDraws(batch, live: live, ready: ready)
    XCTAssertEqual(encoder.draws.count, expected.count, file: file, line: line)
    for (index, (seen, wanted)) in zip(encoder.draws, expected).enumerated() {
        var seen = seen
        if wanted.pipeline == .stencil { seen.paint = .none }
        if wanted.paint == .veil { seen.reference = nil }
        if seen != wanted {
            XCTFail("draw \(index): saw \(seen), wanted \(wanted)", file: file, line: line)
            break
        }
    }
    return encoder
}

/// The commands the renderer made before `ArtEncoding`, for each step: the pipeline, the
/// uniforms and the vertex buffer once per change of pipeline kind, then for every draw
/// its depth-stencil state, reference, paint and the draw itself. Each bind copied the
/// 176-byte uniforms, and each cover its 208-byte paint.
private func fullWalk(_ batch: ArtBatch) -> (calls: Int, bytes: Int) {
    var calls = 0
    var bytes = 0
    for segment in batch.segments {
        var bound: ArtPipeline?
        for step in batch.steps[segment.steps] {
            switch step {
            case .stencil:
                if bound != .stencil { calls += 3; bytes += 176; bound = .stencil }
                calls += 3
            case .cover:
                if bound != .cover { calls += 3; bytes += 176; bound = .cover }
                calls += 4
                bytes += 208
            case .stencilView:
                calls += 6
                bytes += 48 + 176
                bound = nil
            case .veil:
                calls += 6
                bytes += 48 + 176 + 208
                bound = nil
            case .moving, .place:
                bound = nil
            }
        }
    }
    return (calls, bytes)
}

final class ArtEncodingTests: XCTestCase {
    private static let drawing = StressDrawing.make()

    func testTheStressDrawingEncodesLikeTheFullWalkWithFewerCallsAndCopies() {
        var builder = ArtBuilder.likeRenderer()
        let batch = builder.build(Self.drawing, isolatedLayer: nil, tolerance: 0.5)
        let encoder = assertEncodesLikeFullWalk(batch)
        let before = fullWalk(batch)
        print("Art encode, \(batch.steps.count) steps: \(before.calls) calls and \(before.bytes) bytes before, " +
              "\(encoder.calls) calls and \(encoder.bytes) bytes after")
        XCTAssertLessThan(encoder.calls, before.calls)
        XCTAssertLessThan(encoder.bytes * 4, before.bytes, "copies under a quarter of the bytes")
        // One transform per segment and per change of place.
        let places = batch.steps.filter { if case .place = $0 { true } else { false } }.count
        XCTAssertLessThanOrEqual(encoder.transforms, batch.segments.count + places)
    }

    func testIsolationGhostingAndALiveDragEncodeLikeTheFullWalk() {
        let drawing = Self.drawing
        let shapes = drawing.layers.flatMap(\.shapes).map(\.id)
        let moving = Set(shapes.enumerated().filter { $0.offset % 5 == 0 }.map(\.element))
        let focus = Set(shapes.prefix(40))
        var builder = ArtBuilder.likeRenderer()
        let batch = builder.build(drawing, isolatedLayer: drawing.layers[3].id, tolerance: 0.5,
                                  ghostFocus: focus, moving: moving)
        XCTAssertTrue(batch.steps.contains(.veil))
        XCTAssertTrue(batch.steps.contains(.moving(true)))
        assertEncodesLikeFullWalk(batch, live: Affine2D(a: 1, b: 0, c: 0, d: 1, tx: 30, ty: -12))
    }

    func testImageCoversUseTheirPictureOnlyWhenItIsReady() {
        var d = Drawing()
        let a = VectorShape(id: d.makeID(), image: ShapeImage(src: "a.png"), origin: Vec2(0, 0), size: Vec2(100, 50))
        let b = VectorShape(id: d.makeID(), image: ShapeImage(src: "b.png"), origin: Vec2(50, 0), size: Vec2(100, 50))
        let c = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(Rect(minPoint: .zero, maxPoint: Vec2(40, 40))),
                            fill: RGBAColor(r: 1, g: 0, b: 0, a: 1))
        d.layers = [Layer(id: d.makeID(), name: "Photos", shapes: [a, b, c])]
        d.assignVertexIDs()
        var builder = ArtBuilder.likeRenderer()
        let batch = builder.build(d, isolatedLayer: nil, tolerance: 0.5)
        let encoder = assertEncodesLikeFullWalk(batch, ready: ["a.png"])
        XCTAssertTrue(encoder.draws.contains { $0.pipeline == .imageCover })
        XCTAssertTrue(encoder.draws.contains { $0.paint == .slot(segment: batch.segments[0].id, slot: 1) },
                      "the missing picture paints its placeholder from its slot")
    }

    func testPaintFloatsMatchTheShadersLayout() {
        var solid: [Float] = []
        ArtPaint(color: RGBAColor(r: 1, g: 0.5, b: 0.25, a: 1), opacity: 0.5).appendGPUFloats(to: &solid)
        XCTAssertEqual(solid.count, ArtPaint.gpuFloatCount)
        XCTAssertEqual(Array(solid[0..<12]), [1, 0.5, 0.25, 1, 0, 0, 0, 0, 0, 0, 0.5, 0])
        XCTAssertTrue(solid[12...].allSatisfy { $0 == 0 })

        let gradient = ShapeGradient(kind: .radial, start: Vec2(1, 2), end: Vec2(3, 4), stops: [
            GradientStop(offset: 0, color: RGBAColor(r: 1, g: 0, b: 0, a: 1)),
            GradientStop(offset: 0.75, color: RGBAColor(r: 0, g: 0, b: 1, a: 0.5)),
        ])
        var floats: [Float] = []
        ArtPaint(color: .black, gradient: gradient, opacity: 2).appendGPUFloats(to: &floats)
        XCTAssertEqual(floats.count, ArtPaint.gpuFloatCount)
        XCTAssertEqual(Array(floats[4..<12]), [1, 2, 3, 4, 2, 2, 1, 0], "points, then radial, two stops, opacity clamped")
        XCTAssertEqual(Array(floats[12..<20]), [1, 0, 0, 1, 0, 0, 1, 0.5])
        XCTAssertTrue(floats[20..<44].allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(floats[44..<52]), [0, 0.75, 1, 1, 1, 1, 1, 1])
    }

    func testEachCoverHasAnAlignedSlotAfterTheVertices() {
        var builder = ArtBuilder.likeRenderer()
        let batch = builder.build(Self.drawing, isolatedLayer: nil, tolerance: 0.5)
        for segment in batch.segments where !segment.floats.isEmpty {
            let paints = segment.paintFloats(in: batch.steps)
            let covers = batch.steps[segment.steps].compactMap { step -> ArtPaint? in
                if case .cover(_, let paint, _, _) = step { paint } else { nil }
            }
            XCTAssertEqual(segment.floats.count + paints.count,
                           segment.paintStart + covers.count * ArtSegment.paintSlotFloats)
            XCTAssertEqual(segment.paintByteOffset(slot: 0) % 256, 0)
            for (slot, paint) in covers.enumerated() {
                var wanted: [Float] = []
                paint.appendGPUFloats(to: &wanted)
                let start = segment.paintByteOffset(slot: slot) / MemoryLayout<Float>.stride - segment.floats.count
                XCTAssertEqual(Array(paints[start..<(start + ArtPaint.gpuFloatCount)]), wanted)
            }
        }
    }
}
