import Foundation
import XCTest
@testable import ControlFlowCore

/// The repository's `Schema` folder.
private let schemaFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ControlFlowCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // ControlFlowCore
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appendingPathComponent("Schema")

/// The shared test vectors in `Schema/vectors`: documents with the scene expected at
/// chosen times while their sequences play, so another player (the planned HTML export)
/// can be checked against this one. Run with `UPDATE_VECTORS=1` to write them afresh
/// after an intended change to the rules.
final class TestVectorTests: XCTestCase {
    private static let updating = ProcessInfo.processInfo.environment["UPDATE_VECTORS"] == "1"

    func testTheDemoPlaysAsRecorded() throws {
        try check("demo.json", document: .file("../examples/demo.controlflow/presentation.json"))
    }

    func testTheMorphsPlayAsRecorded() throws {
        try check("morph.json", document: .embedded(morphDocument()))
    }

    // MARK: Checking

    private enum Document {
        /// A path relative to the vectors folder.
        case file(String)
        case embedded(Presentation)
    }

    private func check(_ name: String, document: Document) throws {
        let url = schemaFolder.appendingPathComponent("vectors").appendingPathComponent(name)
        if Self.updating {
            try write(url, document: document)
            return
        }
        let vectors = try JSONValue(parsing: Data(contentsOf: url))
        let documentJSON: JSONValue
        switch vectors["document"] {
        case .string(let path)?:
            documentJSON = try JSONValue(parsing: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(path)))
        case let value?:
            documentJSON = value
        case nil:
            return XCTFail("\(name) has no document")
        }
        var timeline = Timeline(try PresentationFormat.decode(documentJSON).presentation)
        guard case .array(let samples)? = vectors["samples"], !samples.isEmpty else { return XCTFail("\(name) has no samples") }
        for sample in samples {
            guard case .number(let sequence)? = sample["sequence"], case .number(let time)? = sample["time"],
                  let expected = sample["scene"] else { return XCTFail("\(name) has a malformed sample") }
            let scene = Self.scene(timeline.playing(sequence: Int(sequence), at: time).scene)
            if let difference = Self.difference(scene, expected, path: "") {
                XCTFail("\(name), sequence \(Int(sequence)) at \(time)s: \(difference)")
            }
        }
    }

    private func write(_ url: URL, document: Document) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let presentation: Presentation
        let documentValue: JSONValue
        switch document {
        case .file(let path):
            let json = try JSONValue(parsing: Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent(path)))
            presentation = try PresentationFormat.decode(json).presentation
            documentValue = .string(path)
        case .embedded(let p):
            // Written and read back, so the samples come from exactly what the file holds.
            let json = PresentationFormat.encode(p)
            presentation = try PresentationFormat.decode(json).presentation
            documentValue = json
        }
        var timeline = Timeline(presentation)
        var samples: [JSONValue] = []
        for s in presentation.sequences.indices {
            for time in Self.sampleTimes(presentation.sequences[s]) {
                samples.append(.object([
                    (key: "sequence", value: .number(Double(s))),
                    (key: "time", value: .number(time)),
                    (key: "scene", value: Self.scene(timeline.playing(sequence: s, at: time).scene)),
                ]))
            }
        }
        let file: JSONValue = .object([
            (key: "description", value: .string("Scenes expected while each sequence plays from the end of the one before, " +
                "\"time\" seconds in. See Schema/README.md, \"Test vectors\".")),
            (key: "document", value: documentValue),
            (key: "samples", value: .array(samples)),
        ])
        try Data(file.rounded().formatted().utf8).write(to: url)
    }

    /// The start, a quarter, half and three quarters into each transition, and the end.
    private static func sampleTimes(_ sequence: KeyframeSequence) -> [Double] {
        var times: [Double] = [0]
        var start = 0.0
        for keyframe in sequence.keyframes {
            let d = keyframe.transition.duration
            if d > 0 { times += [0.25, 0.5, 0.75].map { start + d * $0 } }
            start += d
            times.append(start)
        }
        var seen = Set<Double>()
        return times.map { ($0 * 10_000).rounded() / 10_000 }.filter { seen.insert($0).inserted }
    }

    /// A scene as the vectors write it: the viewport's background, the global colors and
    /// the layers, in the file's object JSON, rounded as files are.
    static func scene(_ d: Drawing) -> JSONValue {
        JSONValue.object([
            (key: "background", value: SceneJSON.color(d.viewport.background)),
            (key: "globalColors", value: .array(d.globalColors.map(SceneJSON.globalColor))),
            (key: "layers", value: .array(d.layers.map(SceneJSON.layer))),
        ]).rounded()
    }

    /// Where two values differ beyond 2e-4 per number (rounding to 4 decimals can differ by
    /// one in the last place between platforms), or nil.
    static func difference(_ a: JSONValue, _ b: JSONValue, path: String) -> String? {
        switch (a, b) {
        case (.number(let x), .number(let y)):
            return abs(x - y) <= 2e-4 ? nil : "\(path) is \(x), expected \(y)"
        case (.array(let x), .array(let y)):
            guard x.count == y.count else { return "\(path) has \(x.count) items, expected \(y.count)" }
            for i in x.indices { if let d = difference(x[i], y[i], path: "\(path)[\(i)]") { return d } }
            return nil
        case (.object(let x), .object(let y)):
            guard x.map(\.key) == y.map(\.key) else { return "\(path) has keys \(x.map(\.key)), expected \(y.map(\.key))" }
            for (m, n) in zip(x, y) { if let d = difference(m.value, n.value, path: "\(path).\(m.key)") { return d } }
            return nil
        default:
            return a == b ? nil : "\(path) is \(a.formatted()), expected \(b.formatted())"
        }
    }

    // MARK: The morph document

    /// Small shapes exercising each interpolation rule: points born and dying on segments
    /// and at an open path's ends, turns past 360, a flip, an overshooting color, a cut, a
    /// shape created and one deleted, a new draw order and a shape that can't be merged.
    private func morphDocument() -> Presentation {
        var d = Drawing()
        d.name = "Morph"
        let ink = GlobalColor(id: d.makeID(), name: "Ink", color: RGBAColor(hex: "#202020FF")!)
        d.globalColors = [ink]
        var layer = Layer(id: d.makeID(), name: "Shapes", pivot: Vec2(960, 540))
        func add(_ path: BezierPath, fill: RGBAColor?, _ change: (inout VectorShape) -> Void = { _ in }) -> Int {
            var shape = VectorShape(id: d.makeID(), path: path, fill: fill)
            change(&shape)
            layer.shapes.append(shape)
            return shape.id
        }
        let square = add(ShapePrimitives.rectangle(Rect(minPoint: Vec2(200, 200), maxPoint: Vec2(400, 400))),
                         fill: RGBAColor(hex: "#E0452BFF")!) { $0.transform = Transform(pivot: Vec2(300, 300)) }
        let line = add(ShapePrimitives.line(Vec2(600, 300), Vec2(800, 300)), fill: nil) {
            $0.stroke = StrokeStyle(color: ink.color, width: 8, global: ink.id)
        }
        let star = add(ShapePrimitives.star(center: Vec2(1100, 300), outerRadius: 100, innerRadius: 45, points: 5),
                       fill: RGBAColor(hex: "#2B7BE0FF")!)
        let blob = add(ShapePrimitives.ellipse(Rect(minPoint: Vec2(1400, 200), maxPoint: Vec2(1600, 400))),
                       fill: RGBAColor(hex: "#F2A65AFF")!)
        let doomed = add(ShapePrimitives.rectangle(Rect(minPoint: Vec2(200, 700), maxPoint: Vec2(300, 800))), fill: .black)
        d.layers = [layer]
        d.assignVertexIDs()
        var timeline = Timeline(Presentation(opening: d))
        func edit(_ index: Int, _ change: (inout Drawing) -> Void) {
            var s = timeline.state(at: index)
            change(&s)
            s.assignVertexIDs()
            timeline.record(s, at: index)
        }
        func shape(_ s: inout Drawing, _ id: Int) -> Int { s.layers[0].shapes.firstIndex { $0.id == id }! }

        // Sequence 0: turns, a flip, an overshooting color, points born and dying.
        timeline.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .custom(x1: 0.3, y1: 1.5, x2: 0.6, y2: 1)))
        edit(1) { s in
            let sq = shape(&s, square)
            s.layers[0].shapes[sq].transform.rotation = 720
            s.layers[0].shapes[sq].transform.scale = Vec2(-1, 1)
            s.layers[0].shapes[sq].fill = RGBAColor(hex: "#FFF000FF")!
            // Two points born on the square's top edge, pulled up.
            var path = s.layers[0].shapes[sq].path
            let a = path.insertPoint(segment: 0, t: 0.3)
            let b = path.insertPoint(segment: a, t: 0.5)
            path.points[a].position += Vec2(0, -60)
            path.points[b].position += Vec2(0, -30)
            s.layers[0].shapes[sq].path = path
            // A star point dies, healing the outline.
            let st = shape(&s, star)
            s.layers[0].shapes[st].path.removePoint(at: 3)
            // The line grows at its end.
            let ln = shape(&s, line)
            s.layers[0].shapes[ln].path.points.append(PathPoint(Vec2(800, 450)))
            s.globalColors[0].color = RGBAColor(hex: "#C02020FF")!
            s.syncGlobalColors()
        }
        // A cut.
        timeline.insertKeyframe(after: 1, transition: Transition(duration: 0, curve: .linear))
        edit(2) { s in s.viewport.background = RGBAColor(hex: "#101828FF")! }

        // Sequence 1: a shape created and one deleted, a new order, and a shape that can't merge.
        timeline.insertSequence(after: 2, transition: Transition(duration: 0.8, curve: .ease))
        edit(3) { s in
            let circle = VectorShape(id: s.makeID(), path: ShapePrimitives.ellipse(Rect(minPoint: Vec2(500, 650), maxPoint: Vec2(650, 800))),
                                     fill: RGBAColor(hex: "#2BB673FF")!)
            s.layers[0].shapes.insert(circle, at: 0)
            s.layers[0].shapes.remove(at: shape(&s, doomed))
            let bl = shape(&s, blob)
            s.layers[0].shapes[bl].path.closed = false
            s.layers[0].shapes[bl].opacity = 0.5
            let st = shape(&s, star)
            s.layers[0].shapes.swapAt(st, shape(&s, line))
            s.layers[0].transform.rotation = 10
        }
        timeline.insertKeyframe(after: 3, transition: Transition(duration: 0.6, curve: .linear))
        edit(4) { s in
            // The end of the line shrinks back into it.
            let ln = shape(&s, line)
            s.layers[0].shapes[ln].path.points.removeLast()
            s.layers[0].transform.rotation = 0
        }
        return timeline.presentation
    }
}
