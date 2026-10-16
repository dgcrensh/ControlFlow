import Foundation
import XCTest
@testable import ControlFlowCore

/// How each `Workload` grows with the drawing: every workload timed on stress drawings
/// of several sizes, printed as one table in the test log. Like `PerformanceTests` it has
/// no baselines and never fails on speed. The last column estimates the growth exponent
/// between the smallest and largest drawing (time ∝ shapes^k): about 0 is constant, 1 is
/// linear, 2 is quadratic. See "How drawings scale" in `docs/plans/performance-audit.md`.
///
/// By default the sizes stay small so the debug build on CI is quick;
/// `STRESS_DRAWING=full` runs 300 to 4,800 shapes (the audit's size is 2,400).
final class ScalingTests: XCTestCase {
    /// Layers per drawing; every size has `shapesPerLayer` shapes of 24 anchors per layer.
    static let layerCounts = StressDrawing.isFull ? [5, 10, 20, 40, 80] : [4, 8, 16]
    static let shapesPerLayer = StressDrawing.isFull ? 60 : 15
    /// Each cell is the median of this many timed calls, after one untimed warm-up call.
    static let runs = StressDrawing.isFull ? 9 : 3

    func testHowWorkloadsScaleWithDrawingSize() {
        let drawings = Self.layerCounts.map { StressDrawing.make(layers: $0, shapesPerLayer: Self.shapesPerLayer) }
        let shapes = drawings.map(\.shapeCount)
        var rows: [(name: String, seconds: [Double])] = []
        for workload in Workload.all {
            let seconds = drawings.map { Self.median(of: workload.prepare($0), runs: Self.runs) }
            rows.append((workload.name, seconds))
        }
        print(Self.table(shapes: shapes, rows: rows))
        XCTAssertEqual(rows.count, Workload.all.count)
    }

    /// What the art pass hands the GPU at each size: vertices, the bytes of a full upload
    /// (the first build, or a new zoom bucket), and what `CanvasRenderer.uploadArt` uploads
    /// after one edit (only the edited layer's segment).
    func testArtUploadSize() {
        var lines = ["Art batch per size", "", "| Shapes | Vertices | Full upload | Upload after one edit | Steps |",
                     "| ---: | ---: | ---: | ---: | ---: |"]
        func megabytes(_ floats: Int) -> String {
            String(format: "%.2f", Double(floats * MemoryLayout<Float>.size) / 1_048_576) + " MB"
        }
        for layers in Self.layerCounts {
            let drawing = StressDrawing.make(layers: layers, shapesPerLayer: Self.shapesPerLayer)
            var builder = ArtBuilder()
            let batch = builder.build(drawing, isolatedLayer: nil, tolerance: 0.5)
            var edited = drawing
            edited.layers[0].shapes[0].fill = RGBAColor(r: 1, g: 0, b: 0)
            let after = builder.build(edited, isolatedLayer: nil, tolerance: 0.5)
            let uploaded = after.segmentsToUpload(resident: batch.residentIDs).reduce(0) { $0 + $1.floats.count }
            lines.append("| \(drawing.shapeCount) | \(batch.vertexCount) | \(megabytes(batch.vertices.count)) | \(megabytes(uploaded)) | \(batch.steps.count) |")
            XCTAssertGreaterThan(batch.vertexCount, 0)
            XCTAssertEqual(uploaded, after.segments[0].floats.count)
        }
        print(lines.joined(separator: "\n"))
    }

    /// The no-vertices build that `artRebuildAfterOneEditWalkOnly` times does the same walk:
    /// the same steps as a full build, kind for kind, with nothing written.
    func testBuildWithoutVerticesWalksTheSameSteps() {
        let drawing = StressDrawing.make(layers: 4, shapesPerLayer: 15)
        var full = ArtBuilder()
        var walk = ArtBuilder()
        walk.skipsVertices = true
        let a = full.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        let b = walk.build(drawing, isolatedLayer: nil, tolerance: 0.5)
        XCTAssertTrue(b.vertices.isEmpty)
        XCTAssertEqual(a.steps.map(Self.kind), b.steps.map(Self.kind))
    }

    static func kind(_ step: ArtStep) -> String {
        switch step {
        case .stencil: "stencil"
        case .cover: "cover"
        case .stencilView: "stencilView"
        case .veil: "veil"
        case .moving(let on): "moving \(on)"
        case .place(let m): "place \(m)"
        }
    }

    /// The median time of `runs` calls of `operation`, in seconds.
    static func median(of operation: () -> Void, runs: Int) -> Double {
        operation()
        let clock = ContinuousClock()
        let times = (0..<runs).map { _ in clock.measure(operation).seconds }.sorted()
        return times[times.count / 2]
    }

    /// A Markdown table of milliseconds per call, one column per size, with the growth
    /// exponent at the end, so it can be pasted into the audit.
    static func table(shapes: [Int], rows: [(name: String, seconds: [Double])]) -> String {
        var lines = ["How workloads scale (ms per call, median of \(runs))", ""]
        lines.append("| Workload | " + shapes.map { "\($0) shapes" }.joined(separator: " | ") + " | Growth |")
        lines.append("| --- |" + String(repeating: " ---: |", count: shapes.count + 1))
        for row in rows {
            let cells = row.seconds.map { milliseconds($0) }
            lines.append("| \(row.name) | " + cells.joined(separator: " | ") + " | \(growth(shapes: shapes, seconds: row.seconds)) |")
        }
        return lines.joined(separator: "\n")
    }

    static func milliseconds(_ seconds: Double) -> String {
        let ms = seconds * 1000
        return ms >= 10 ? String(format: "%.1f", ms) : String(format: "%.3f", ms)
    }

    /// log(t_last / t_first) / log(n_last / n_first), or a dash when a time is too small
    /// to say (under 10 µs, where timer noise dominates).
    static func growth(shapes: [Int], seconds: [Double]) -> String {
        guard let t0 = seconds.first, let t1 = seconds.last, let n0 = shapes.first, let n1 = shapes.last,
              n1 > n0, t0 > 1e-5, t1 > 1e-5 else { return "–" }
        return String(format: "%.2f", log(t1 / t0) / log(Double(n1) / Double(n0)))
    }
}

extension Duration {
    var seconds: Double {
        let (s, atto) = components
        return Double(s) + Double(atto) * 1e-18
    }
}
