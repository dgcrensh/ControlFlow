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
        if let math = vectors["math"] {
            guard let expected = vectors["mathOutlines"] else { return XCTFail("\(name) has formulas but no outlines") }
            if let difference = Self.difference(Self.mathOutlines(math), expected, path: "mathOutlines") { XCTFail("\(name): \(difference)") }
        }
        guard case .array(let samples)? = vectors["samples"], !samples.isEmpty else { return XCTFail("\(name) has no samples") }
        for sample in samples {
            guard case .number(let sequence)? = sample["sequence"], case .number(let time)? = sample["time"],
                  let expected = sample["scene"] else { return XCTFail("\(name) has a malformed sample") }
            let played = timeline.playing(sequence: Int(sequence), at: time).scene
            let scene = Self.scene(played)
            if let difference = Self.difference(scene, expected, path: "") {
                XCTFail("\(name), sequence \(Int(sequence)) at \(time)s: \(difference)")
            }
            if let outlines = sample["outlines"], let difference = Self.difference(Self.outlines(played), outlines, path: "outlines") {
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
            let file = url.deletingLastPathComponent().appendingPathComponent(path)
            let json = try JSONValue(parsing: Data(contentsOf: file))
            presentation = try PresentationFormat.decode(json).presentation
            documentValue = .string(path)
            // The package's formula layouts, as opening it would read them.
            let math = file.deletingLastPathComponent().appendingPathComponent(MathFile.fileName)
            if let data = try? Data(contentsOf: math) { MathTypesetting.insert(MathFile.read(try JSONValue(parsing: data))) }
        case .embedded(let p):
            // Written and read back, so the samples come from exactly what the file holds.
            let json = PresentationFormat.encode(p)
            presentation = try PresentationFormat.decode(json).presentation
            documentValue = json
        }
        var timeline = Timeline(presentation)
        var samples: [JSONValue] = []
        for s in presentation.sequences.indices {
            let times = Self.sampleTimes(presentation.sequences[s])
            for time in times {
                let scene = timeline.playing(sequence: s, at: time).scene
                var sample: [(key: String, value: JSONValue)] = [
                    (key: "sequence", value: .number(Double(s))),
                    (key: "time", value: .number(time)),
                    (key: "scene", value: Self.scene(scene)),
                ]
                // Outlines where a text's spacing is moving or a formula morphing.
                let moving = scene.layers.contains { $0.shapes.contains { $0.text?.held != nil || $0.math?.morph != nil } }
                if moving {
                    sample.append((key: "outlines", value: Self.outlines(scene)))
                }
                samples.append(.object(sample))
            }
        }
        var file: [(key: String, value: JSONValue)] = [
            (key: "description", value: .string("Scenes expected while each sequence plays from the end of the one before, " +
                "\"time\" seconds in. See Schema/README.md, \"Test vectors\".")),
            (key: "document", value: documentValue),
        ]
        // The glyphs the HTML export would write, from the stub shaper.
        if let texts = try HTMLExport.textLayouts(PresentationFormat.encode(presentation)) {
            file.append((key: "texts", value: texts))
        }
        // The formula layouts the HTML export would write (its math.json), and each
        // formula's outline drawn from them.
        if let math = MathFile.json(for: presentation.mathContents) {
            file.append((key: "math", value: math))
            file.append((key: "mathOutlines", value: Self.mathOutlines(math)))
        }
        file.append((key: "samples", value: .array(samples)))
        try Data(JSONValue.object(file).rounded().formatted().utf8).write(to: url)
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

    /// Each text shape's glyph outline, and each morphing formula's, in its own space, as
    /// `[{ "shape", "points" }]` with each point's `x, y, inX, inY, outX, outY` in one flat list.
    static func outlines(_ d: Drawing) -> JSONValue {
        var out: [JSONValue] = []
        for layer in d.layers {
            for shape in layer.shapes {
                let path: BezierPath
                if let text = shape.text {
                    path = TextShaping.outline(text)
                } else if shape.math?.morph != nil {
                    path = shape.resolvingLayout().path
                } else {
                    continue
                }
                let points = path.points.flatMap { p in
                    [p.position.x, p.position.y, p.inHandle.x, p.inHandle.y, p.outHandle.x, p.outHandle.y]
                }
                out.append(.object([(key: "shape", value: .number(Double(shape.id))),
                                    (key: "points", value: .array(points.map(JSONValue.number)))]))
            }
        }
        return JSONValue.array(out).rounded()
    }

    /// Each formula's outline in `math` (a `math.json`), in its own space, as
    /// `[{ "math", "points" }]` with each point's `x, y, inX, inY, outX, outY` in one flat list.
    static func mathOutlines(_ math: JSONValue) -> JSONValue {
        let layouts = MathFile.read(math)
        guard case .array(let formulas)? = math["formulas"] else { return .array([]) }
        var out: [JSONValue] = []
        for formula in formulas {
            guard let key = formula["math"], let content = try? SceneJSON.readMath(Node(root: key)),
                  let layout = layouts[content]?.layout else { continue }
            let points = layout.outline.points.flatMap { p in
                [p.position.x, p.position.y, p.inHandle.x, p.inHandle.y, p.outHandle.x, p.outHandle.y]
            }
            out.append(.object([(key: "math", value: key), (key: "points", value: .array(points.map(JSONValue.number)))]))
        }
        return JSONValue.array(out).rounded()
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
    /// shape created and one deleted, a new draw order, a shape that can't be merged, and
    /// a wrapping text whose spacing and words change.
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
        // Sequence 2: a text in a box, right-aligned and wrapping, whose spacing moves
        // with its lines broken as they are at the end, then whose words change.
        var title = 0
        timeline.insertSequence(after: 4, transition: Transition(duration: 0, curve: .linear))
        edit(5) { s in
            let text = TextContent(string: "Words wrap in a box", weight: 700, size: 40, align: .right, width: 300)
            title = s.makeID()
            s.layers[0].shapes.append(VectorShape(id: title, text: text, fill: s.globalColors[0].color,
                                                  transform: Transform(position: Vec2(1300, 650))))
        }
        timeline.insertKeyframe(after: 5, transition: Transition(duration: 1, curve: .easeInOut))
        edit(6) { s in
            let t = shape(&s, title)
            s.layers[0].shapes[t].text!.tracking = -6
            s.layers[0].shapes[t].text!.lineHeight = 2
        }
        timeline.insertKeyframe(after: 6, transition: Transition(duration: 0.5, curve: .linear))
        edit(7) { s in
            let t = shape(&s, title)
            s.layers[0].shapes[t].text!.string = "New words"
            s.layers[0].shapes[t].text!.lineHeight = 1
        }
        return timeline.presentation
    }
}
