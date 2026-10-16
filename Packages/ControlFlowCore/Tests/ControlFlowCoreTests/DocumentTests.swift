import Foundation
import XCTest
@testable import ControlFlowCore

/// The repository's `Schema/examples` folder.
private let examplesFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // ControlFlowCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // ControlFlowCore
    .deletingLastPathComponent() // Packages
    .deletingLastPathComponent() // repository root
    .appendingPathComponent("Schema/examples")

private func exampleFiles(_ name: String) throws -> [String: Data] {
    let root = examplesFolder.appendingPathComponent(name)
    var files: [String: Data] = [:]
    for path in [PresentationPackage.presentationFile, "references/reference-1.png", "images/58522a450cf10d19.png"] {
        files[path] = try Data(contentsOf: root.appendingPathComponent(path))
    }
    return files
}

private func ring(center: Vec2, radius: Double) -> [Vec2] {
    (0...48).map { i in
        let a = Double(i) / 48 * 2 * .pi
        return center + Vec2(cos(a), sin(a)) * radius
    }
}

/// A drawing made the way the editor makes them.
private func editorDrawing() -> Drawing {
    var e = DrawingEditor()
    e.addStroke(ring(center: Vec2(0, 0), radius: 60), zoom: 1)
    e.style.fillEnabled = false
    e.style.outlineWidth = 5.5
    e.addStroke((0...20).map { Vec2(Double($0) * 7.3, sin(Double($0) / 3) * 20 + 140) }, zoom: 1)
    e.addToPalette(RGBAColor(hex: "#12345680")!)
    e.selection = .layer(e.drawing.layers[0].id)
    e.renameLayer(e.drawing.layers[0].id, to: "Head \"big\" ✨")
    e.renamePresentation("Tést")
    var d = e.drawing
    d.layers[0].shapes[0].path.points[1].isSmooth = false
    d.references.append(ReferenceImage(id: d.makeID(), name: "Ref", size: Vec2(640, 480), center: Vec2(12.5, -3),
                                       rotation: 0.3, scale: 0.25, opacity: 0.6, isHidden: true))
    return d
}

private func json(_ text: String) throws -> JSONValue { try JSONValue(parsing: text) }

final class JSONValueTests: XCTestCase {
    func testWritesReadableJSON() {
        let value = JSONValue.object([
            (key: "a", value: .string("q\"\\\n\u{1}é")),
            (key: "list", value: .array([1, .number(0.5), .number(-0.0), .bool(true), .null])),
            (key: "nested", value: .object([(key: "p", value: .array([1, 2])), (key: "deep", value: .object([(key: "x", value: 1)]))])),
            (key: "empty", value: .object([])),
        ])
        XCTAssertEqual(value.formatted(), """
        {
          "a": "q\\"\\\\\\n\\u0001é",
          "list": [1, 0.5, 0, true, null],
          "nested": {
            "p": [1, 2],
            "deep": { "x": 1 }
          },
          "empty": {}
        }

        """)
    }

    func testNumberText() {
        XCTAssertEqual(JSONValue.numberText(3), "3")
        XCTAssertEqual(JSONValue.numberText(-12.25), "-12.25")
        XCTAssertEqual(JSONValue.numberText(22.0914), "22.0914")
        XCTAssertEqual(JSONValue.numberText(.nan), "0")
        XCTAssertEqual(JSONValue.number(1.234_567_89).rounded(), .number(1.2346))
        XCTAssertEqual(JSONValue.array([.number(-0.000_01)]).rounded().formatted(), "[0]\n")
    }

    func testParsesAndKeepsKeyOrder() throws {
        let value = try json(#"{ "z": 1, "a": [true, false, null, -1.5e2, "\u00e9\ud83d\ude00\/"], "m": {} }"#)
        guard case .object(let members) = value else { return XCTFail() }
        XCTAssertEqual(members.map(\.key), ["z", "a", "m"])
        XCTAssertEqual(value["a"], .array([.bool(true), .bool(false), .null, .number(-150), .string("é😀/")]))
        // Object equality ignores key order.
        XCTAssertEqual(value, try json(#"{ "m": {}, "a": [true, false, null, -150, "é😀/"], "z": 1 }"#))
    }

    func testRejectsInvalidJSON() {
        for text in ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "+1", "\"abc", "[1] x", "tru", "\"\\ud800\"", "{\"a\":1,}"] {
            XCTAssertThrowsError(try json(text), text)
        }
    }

    func testWriterOutputParsesBack() throws {
        let value = PresentationFormat.encode(editorDrawing())
        XCTAssertEqual(try json(value.formatted()), value)
    }

    /// The writer stops a one-line value as soon as it runs over the line's budget; it
    /// must still choose one line exactly where writing the whole line and counting its
    /// characters did, whatever the characters.
    func testOneLineValuesBreakWhereTheyDid() {
        let words = ["a", "é", "e\u{301}", "😀", "👩‍👩‍👧", "\u{301}x", "tab\t", "quote\"", "日本語"]
        var values: [JSONValue] = []
        for length in [0, 1, 5, 20, 40, 41, 60, 110, 117, 118, 119, 120, 121, 200] {
            for word in words {
                let text = String(repeating: word, count: max(length / max(word.count, 1), 0))
                values.append(.object([(key: "name", value: .string(text)), (key: "p", value: .array([1, 2.5]))]))
                values.append(.array([.string(text), .number(Double(length)), .null]))
                values.append(.array([.array([.number(1), .string(text)]), .array([])]))
            }
            values.append(.array((0..<length).map { .number(Double($0) / 3) }))
        }
        for indent in [0, 2, 10] {
            let nested = JSONValue.array(values.map { indent == 0 ? $0 : .object([(key: String(repeating: "k", count: indent), value: $0)]) })
            XCTAssertEqual(nested.formatted(), Self.wholeLineFormatted(nested))
        }
    }

    /// The writer as it was: each one-line candidate written out whole, then counted.
    private static func wholeLineFormatted(_ value: JSONValue) -> String {
        func scalar(_ v: JSONValue) -> String? {
            switch v {
            case .null: "null"
            case .bool(let b): b ? "true" : "false"
            case .number(let n): JSONValue.numberText(n)
            case .string(let s): JSONValue.quoted(s)
            case .array, .object: nil
            }
        }
        func isScalarArray(_ v: JSONValue) -> Bool {
            if case .array(let items) = v { return items.allSatisfy { scalar($0) != nil } }
            return false
        }
        func inline(_ v: JSONValue) -> String? {
            switch v {
            case .null, .bool, .number, .string: return scalar(v)
            case .array(let items):
                if items.allSatisfy({ scalar($0) != nil }) { return "[" + items.map { scalar($0)! }.joined(separator: ", ") + "]" }
                guard items.allSatisfy(isScalarArray) else { return nil }
                return "[" + items.map { inline($0)! }.joined(separator: ", ") + "]"
            case .object(let members):
                var parts: [String] = []
                for member in members {
                    switch member.value {
                    case .object: return nil
                    case .array(let items) where !items.allSatisfy({ scalar($0) != nil }) && !items.allSatisfy(isScalarArray):
                        return nil
                    default: parts.append(JSONValue.quoted(member.key) + ": " + inline(member.value)!)
                    }
                }
                return "{ " + parts.joined(separator: ", ") + " }"
            }
        }
        func write(_ v: JSONValue, _ out: inout String, _ indent: Int) {
            switch v {
            case .null, .bool, .number, .string:
                out.append(scalar(v)!)
            case .array(let items):
                if items.isEmpty { out.append("[]"); return }
                if let line = inline(v), line.count + indent <= 120 { out.append(line); return }
                out.append("[\n")
                for (i, item) in items.enumerated() {
                    out.append(String(repeating: " ", count: indent + 2))
                    write(item, &out, indent + 2)
                    out.append(i == items.count - 1 ? "\n" : ",\n")
                }
                out.append(String(repeating: " ", count: indent) + "]")
            case .object(let members):
                if members.isEmpty { out.append("{}"); return }
                if let line = inline(v), line.count + indent <= 120 { out.append(line); return }
                out.append("{\n")
                for (i, member) in members.enumerated() {
                    out.append(String(repeating: " ", count: indent + 2))
                    out.append(JSONValue.quoted(member.key) + ": ")
                    write(member.value, &out, indent + 2)
                    out.append(i == members.count - 1 ? "\n" : ",\n")
                }
                out.append(String(repeating: " ", count: indent) + "}")
            }
        }
        var out = ""
        write(value, &out, 0)
        return out + "\n"
    }
}

final class PresentationFormatTests: XCTestCase {
    func testReadsTheExample() throws {
        let package = try PresentationPackage(files: exampleFiles("demo.controlflow"))
        let p = package.presentation
        let d = p.opening
        XCTAssertEqual(d.name, "Demo")
        XCTAssertEqual(d.layers.map(\.name), ["Torso", "Head", "Antenna", "Title", "Photo"])
        XCTAssertEqual(d.layers.map(\.shapes.count), [4, 4, 2, 1, 1])
        XCTAssertEqual(d.layers[3].shapes[0].text, TextContent(string: "Hello", weight: 700, size: 120, align: .center))
        XCTAssertTrue(d.layers[3].shapes[0].path.points.isEmpty)
        XCTAssertTrue(d.vertexIDsAreValid)
        XCTAssertEqual(d.layers[0].transform, Transform(position: Vec2(960, 700), scale: Vec2(3, 3), pivot: Vec2(0, -40)))
        XCTAssertEqual(d.palette, [RGBAColor(hex: "#FFFFFF80")!])
        XCTAssertEqual(d.globalColors.map(\.name), ["Skin", "Body", "Ink"])
        let torso = d.layers[0].shapes[0]
        XCTAssertEqual(torso.fillGlobal, d.globalColors[1].id)
        XCTAssertEqual(torso.gradient?.stops.map(\.color.hexString), ["#5A8DEEFF", "#3655A0FF"])
        XCTAssertEqual(torso.stroke, StrokeStyle(color: RGBAColor(hex: "#222222")!, width: 3, join: .miter, global: d.globalColors[2].id))
        XCTAssertEqual(torso.path.points.map(\.stroked), [false, true, true, true, true])
        XCTAssertEqual(d.layers[0].groups.map(\.name), ["Shell"])
        XCTAssertTrue(d.layers[1].groups[0].isClipped)
        XCTAssertEqual(d.layers[1].shapes[3].path.points.map(\.width), [0.3, 1.4, 0.3])
        XCTAssertEqual(d.references.count, 1)
        XCTAssertEqual(d.references[0].rotation, .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(package.referenceImages[d.references[0].id]?.count, try exampleFiles("demo.controlflow")["references/reference-1.png"]?.count)
        let photo = d.layers[4].shapes[0]
        XCTAssertEqual(photo.image, ShapeImage(src: "images/58522a450cf10d19.png"))
        XCTAssertEqual(photo.imagePlacement, Affine2D(a: 200, b: 0, c: 0, d: 200, tx: 1560, ty: 700))
        let photoBytes = try XCTUnwrap(exampleFiles("demo.controlflow")["images/58522a450cf10d19.png"])
        XCTAssertEqual(package.images, ["images/58522a450cf10d19.png": photoBytes])
        XCTAssertEqual(ImageAssets.path(for: photoBytes), "images/58522a450cf10d19.png", "named by a hash of its bytes")

        // Three sequences of two keyframes.
        XCTAssertEqual(p.sequences.map(\.name), ["Hello", "Speak", "Point"])
        XCTAssertEqual(p.sequences.map(\.keyframes.count), [2, 2, 2])
        XCTAssertEqual(p.sequences[0].keyframes[0].name, "Tilt")
        XCTAssertEqual(p.sequences[0].keyframes[0].transition, Transition(duration: 0.6, curve: .easeOut))
        XCTAssertEqual(p.sequences[0].keyframes[1].transition.curve, .custom(x1: 0.3, y1: 1.6, x2: 0.6, y2: 1))
        var timeline = Timeline(p)
        XCTAssertEqual(timeline.state(at: 2).globalColors[1].color.hexString, "#2BB673FF")
        XCTAssertEqual(timeline.state(at: 2).layers[0].shapes[0].fill?.hexString, "#2BB673FF", "fills follow their global color")
        XCTAssertEqual(timeline.state(at: 1).layers[3].shapes[0].text?.tracking, 24)
        XCTAssertEqual(timeline.state(at: 1).layers[4].shapes[0].opacity, 0.6)
        XCTAssertEqual(timeline.state(at: 4).layers.map(\.name), ["Torso", "Head", "Antenna", "Bubble", "Title", "Photo"])
        XCTAssertEqual(timeline.state(at: 4).layers[4].shapes[0].text?.string, "Nice to meet you")
        XCTAssertEqual(timeline.state(at: 4).viewport.background.hexString, "#F4F1E8FF")
        XCTAssertEqual(timeline.state(at: 5).layers[3].shapes[0].path.points.count, 5, "a point is born on the bubble")
        XCTAssertEqual(timeline.state(at: 6).layers.count, 5)

        // Every id is distinct.
        var ids = Array(d.objectIDs) + d.references.map(\.id)
        ids += p.sequences.map(\.id) + p.keyframes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThan(d.nextID, ids.max()!)
    }

    /// Re-saving the example reproduces it byte for byte, so the committed example
    /// (which CI validates against the JSON Schema) is exactly what the app writes.
    func testRewritesTheExampleExactly() throws {
        let files = try exampleFiles("demo.controlflow")
        let package = try PresentationPackage(files: files)
        let written = package.files()
        XCTAssertEqual(Set(written.keys), Set(files.keys))
        let original = String(decoding: files[PresentationPackage.presentationFile]!, as: UTF8.self)
        let rewritten = String(decoding: written[PresentationPackage.presentationFile]!, as: UTF8.self)
        if rewritten != original {
            XCTFail("Re-saved example differs:\n\(rewritten)")
        }
        XCTAssertEqual(written["references/reference-1.png"], files["references/reference-1.png"])
    }

    func testEditorDrawingRoundTrips() throws {
        let drawing = editorDrawing()
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let package = PresentationPackage(presentation: Presentation(opening: drawing),
                                          referenceImages: [drawing.references[0].id: image, 999: Data([1])])
        let files = package.files(thumbnail: Data([7]))
        XCTAssertEqual(Set(files.keys), ["presentation.json", "thumbnail.png", "references/reference-1.jpg"])

        let reopened = try PresentationPackage(files: files)
        let d = reopened.drawing
        XCTAssertEqual(d.name, "Tést")
        XCTAssertEqual(d.layers.map(\.name), drawing.layers.map(\.name))
        XCTAssertEqual(d.layers.map(\.id), drawing.layers.map(\.id), "ids are kept")
        XCTAssertEqual(d.palette, drawing.palette)
        XCTAssertEqual(reopened.referenceImages.values.first, image)
        XCTAssertTrue(d.references[0].isHidden)
        XCTAssertEqual(d.references[0].rotation, 0.3, accuracy: 1e-4)
        for (a, b) in zip(d.layers, drawing.layers) {
            XCTAssertTrue(a.pivot.isApproximately(b.pivot, tolerance: 1e-4))
            for (s, t) in zip(a.shapes, b.shapes) {
                XCTAssertEqual(s.fill, t.fill)
                XCTAssertEqual(s.stroke?.width ?? 0, t.stroke?.width ?? 0, accuracy: 1e-4)
                XCTAssertEqual(s.path.closed, t.path.closed)
                XCTAssertEqual(s.path.points.map(\.id), t.path.points.map(\.id))
                for (p, q) in zip(s.path.points, t.path.points) {
                    XCTAssertTrue(p.position.isApproximately(q.position, tolerance: 1e-4))
                    XCTAssertTrue(p.outHandle.isApproximately(q.outHandle, tolerance: 1e-4))
                    XCTAssertEqual(p.isSmooth, q.isSmooth)
                }
            }
        }
        // A second save is identical to the first.
        XCTAssertEqual(reopened.files(thumbnail: Data([7])), files)
    }

    func testKeyframesRoundTrip() throws {
        var e = DrawingEditor(drawing: editorDrawing())
        e.setKeyframe()
        e.selection = .layer(e.drawing.layers[0].id)
        e.rotateSelection(byDegrees: 30)
        e.setTransition(Transition(duration: 1.25, curve: .custom(x1: 0.1, y1: -0.5, x2: 0.9, y2: 1.5)), ofKeyframe: e.currentKeyframe!)
        e.renameKeyframe(e.currentKeyframe!, to: "Turn")
        e.newSequence()
        e.selection = .layer(e.drawing.layers[1].id)
        e.deleteSelection()
        e.renameSequence(e.presentation.sequences[1].id, to: "Gone")
        let presentation = e.presentation
        let text = PresentationFormat.encode(presentation).formatted()
        let back = try PresentationFormat.decode(JSONValue(parsing: text)).presentation
        XCTAssertEqual(back.sequences.map(\.id), presentation.sequences.map(\.id))
        XCTAssertEqual(back.sequences.map(\.name), [nil, "Gone"])
        XCTAssertEqual(back.keyframes.map(\.id), presentation.keyframes.map(\.id))
        XCTAssertEqual(back.keyframes.map(\.name), ["Turn", nil])
        XCTAssertEqual(back.keyframes.map(\.transition), presentation.keyframes.map(\.transition))
        var a = Timeline(back), b = Timeline(presentation)
        for i in 0..<a.count {
            XCTAssertEqual(a.state(at: i).layers.map(\.id), b.state(at: i).layers.map(\.id))
            XCTAssertEqual(a.state(at: i).layers[0].transform.rotation, b.state(at: i).layers[0].transform.rotation, accuracy: 1e-4)
        }
        XCTAssertEqual(PresentationFormat.encode(back).formatted(), text)
    }

    func testDuplicateLayerNamesBecomeUniqueInSVG() {
        XCTAssertEqual(PresentationFormat.uniqueNames(["Arm", "Arm", "Arm", "  "], fallback: "Layer"), ["Arm", "Arm 2", "Arm 3", "Layer"])
    }

    func testVersionChecks() throws {
        func open(_ version: String) throws {
            _ = try PresentationFormat.decode(json(#"{ "formatVersion": "\#(version)" }"#))
        }
        XCTAssertNoThrow(try open("1.0"))
        XCTAssertNoThrow(try open("1.0.0"))
        XCTAssertNoThrow(try open("1.3"), "a newer minor version only adds what this one can skip")
        XCTAssertThrowsError(try open("2.0")) { XCTAssertEqual($0 as? PresentationFileError, .newerVersion("2.0")) }
        XCTAssertThrowsError(try open("0.3.0")) { XCTAssertEqual($0 as? PresentationFileError, .unsupportedVersion("0.3.0")) }
        XCTAssertThrowsError(try open("one")) {
            XCTAssertEqual($0 as? PresentationFileError, .invalid(path: "formatVersion", problem: "is not a version like \"1.0\""))
        }
        XCTAssertThrowsError(try PresentationFormat.decode(json("{}")))
        XCTAssertThrowsError(try PresentationFormat.decode(json("[]")))
        XCTAssertEqual(FormatVersion("2.10.3-beta"), FormatVersion(2, 10, 3))
        XCTAssertEqual(FormatVersion("1.0")?.description, "1.0")
        XCTAssertLessThan(FormatVersion(0, 9, 9), FormatVersion(0, 10, 0))
    }

    func testDamageIsReportedWithItsPath() throws {
        let file = try json("""
        { "formatVersion": "1.0", "opening": { "layers": [{ "id": 1, "name": "Head",
            "shapes": [{ "id": 2, "closed": true, "points": [{ "id": 3, "p": [1, 2] }, { "id": 4, "in": [0, 0] }] }] }] } }
        """)
        XCTAssertThrowsError(try PresentationFormat.decode(file)) { error in
            XCTAssertEqual(error as? PresentationFileError,
                           .invalid(path: "opening.layers[0].shapes[0].points[1].p", problem: "is missing"))
        }
        let badColor = try json(##"{ "formatVersion": "1.0", "palette": ["#12"] }"##)
        XCTAssertThrowsError(try PresentationFormat.decode(badColor)) { error in
            XCTAssertEqual(error as? PresentationFileError, .invalid(path: "palette[0]", problem: "is not a #RRGGBBAA color"))
        }
    }

    /// Keyframe changes must refer to objects there at their keyframe, and ids are used once.
    func testBadChangesAreReportedWithTheirPath() throws {
        func error(_ changes: String, sequences: String? = nil) throws -> PresentationFileError? {
            let file = try json("""
            { "formatVersion": "1.0",
              "viewport": { "id": 9, "width": 100, "height": 100 },
              "opening": { "layers": [{ "id": 1, "name": "A", "shapes": [
                { "id": 2, "closed": false, "points": [{ "id": 3, "p": [0, 0] }, { "id": 4, "p": [10, 0] }] }] }] },
              "sequences": \(sequences ?? #"[{ "id": 10, "keyframes": [{ "id": 11, "changes": [\#(changes)] }] }]"#) }
            """)
            do {
                _ = try PresentationFormat.decode(file)
                return nil
            } catch {
                return error as? PresentationFileError
            }
        }
        let c = "sequences[0].keyframes[0].changes"
        XCTAssertNil(try error(##"{ "set": 2, "props": { "opacity": 0.5, "fill": "#FF0000FF" } }, { "set": 9, "props": { "background": "#000000FF" } }"##))
        XCTAssertNil(try error(#"{ "create": { "id": 5, "p": [5, 5] }, "in": 2, "after": 3, "t": 0.5 }, { "delete": 3 }, { "order": [5, 4], "in": 2 }"#))
        XCTAssertNil(try error(#"{ "delete": 2 }, { "create": { "id": 2, "closed": false, "points": [] }, "in": 1 }"#),
                     "a shape can move to another place keeping its id")
        XCTAssertEqual(try error(#"{ "set": 99, "props": { "opacity": 1 } }"#), .invalid(path: c + "[0].set", problem: "is not an object there"))
        XCTAssertEqual(try error(#"{ "set": 2, "props": { "points": [] } }"#),
                       .invalid(path: c + "[0].props.points", problem: "is not a property that can be set here"))
        XCTAssertEqual(try error(#"{ "set": 9, "props": { "width": 5 } }"#),
                       .invalid(path: c + "[0].props.width", problem: "is not a property that can be set here"))
        XCTAssertEqual(try error(#"{ "delete": 2 }, { "set": 2, "props": { "opacity": 1 } }"#),
                       .invalid(path: c + "[1].set", problem: "is not an object there"))
        XCTAssertEqual(try error(#"{ "delete": 9 }"#), .invalid(path: c + "[0].delete", problem: "can't be deleted by a keyframe"))
        XCTAssertEqual(try error(#"{ "create": { "id": 3, "p": [5, 5] }, "in": 2 }"#),
                       .invalid(path: c + "[0]", problem: "doesn't apply to the state before it"))
        XCTAssertEqual(try error(#"{ "create": { "id": 11, "p": [5, 5] }, "in": 2 }"#),
                       .invalid(path: c + "[0].create.id", problem: "repeats id 11"))
        XCTAssertEqual(try error(#"{ "order": [4, 1], "in": 2 }"#),
                       .invalid(path: c + "[0].order", problem: "lists objects that aren't its children"))
        XCTAssertEqual(try error(#"{ "set": 2 }"#), .invalid(path: c + "[0].props", problem: "is missing"))
        XCTAssertEqual(try error(#"{ "set": 2, "delete": 2 }"#), .invalid(path: c + "[0]", problem: "is not one change: set, create, delete or order"))
        XCTAssertEqual(try error("", sequences: #"[{ "id": 10, "keyframes": [{ "id": 1 }] }]"#),
                       .invalid(path: "sequences[0].keyframes[0].id", problem: "repeats id 1"))
        XCTAssertEqual(try error("", sequences: #"[{ "id": 10, "keyframes": [] }]"#),
                       .invalid(path: "sequences[0].keyframes", problem: "is empty"))
        XCTAssertEqual(try error("", sequences: #"[{ "id": 10, "keyframes": [{ "id": 11, "transition": { "curve": "bouncy" } }] }]"#),
                       .invalid(path: "sequences[0].keyframes[0].transition.curve",
                                problem: #"is not one of "linear", "ease", "ease-in", "ease-out", "ease-in-out" or [x1, y1, x2, y2]"#))
        XCTAssertEqual(try error("", sequences: #"[{ "id": 10, "keyframes": [{ "id": 11, "transition": { "curve": [1.5, 0, 1, 1] } }] }]"#),
                       .invalid(path: "sequences[0].keyframes[0].transition.curve", problem: "has an x outside 0...1"))
    }

    /// Values are read without building a node when they have the right type; a wrong type must still
    /// throw the error the node would have, with its path.
    func testWrongValueTypesAreReportedWithTheirPath() throws {
        func error(layer: String = "", _ shape: String) throws -> PresentationFileError? {
            let file = try json("""
            { "formatVersion": "1.0", "opening": { "layers": [{ "id": 1, "name": "A", \(layer) "shapes": [\(shape)] }] } }
            """)
            do {
                _ = try PresentationFormat.decode(file)
                return nil
            } catch {
                return error as? PresentationFileError
            }
        }
        func point(_ members: String) -> String { #"{ "id": 2, "closed": false, "points": [{ "id": 3, \#(members) }] }"# }
        let shape = "opening.layers[0].shapes[0]", p = shape + ".points[0]"

        // Pairs.
        XCTAssertEqual(try error(point(#""p": "0, 0""#)), .invalid(path: p + ".p", problem: "is not an array"))
        XCTAssertEqual(try error(point(#""p": [0, 0, 0]"#)), .invalid(path: p + ".p", problem: "is not an [x, y] pair"))
        XCTAssertEqual(try error(point(#""p": [0, "1"]"#)), .invalid(path: p + ".p[1]", problem: "is not a number"))
        XCTAssertEqual(try error(point(#""p": [1e999, 0]"#)), .invalid(path: p + ".p[0]", problem: "is not a number"))
        XCTAssertEqual(try error(point(#""p": [0, 0], "in": [0]"#)), .invalid(path: p + ".in", problem: "is not an [x, y] pair"))
        XCTAssertEqual(try error(point(#""in": [0, 0]"#)), .invalid(path: p + ".p", problem: "is missing"))
        XCTAssertEqual(try error(layer: #""transform": { "pivot": true },"#, ""),
                       .invalid(path: "opening.layers[0].transform.pivot", problem: "is not an array"))
        // Numbers, booleans, strings and colors.
        XCTAssertEqual(try error(point(#""p": [0, 0], "w": "2""#)), .invalid(path: p + ".w", problem: "is not a number"))
        XCTAssertEqual(try error(point(#""p": [0, 0], "smooth": 1"#)), .invalid(path: p + ".smooth", problem: "is not true or false"))
        XCTAssertEqual(try error(#"{ "id": 2, "closed": "yes", "points": [] }"#), .invalid(path: shape + ".closed", problem: "is not true or false"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "opacity": [1] }"#), .invalid(path: shape + ".opacity", problem: "is not a number"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "fill": 0 }"#), .invalid(path: shape + ".fill", problem: "is not a string"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "fill": "red" }"#), .invalid(path: shape + ".fill", problem: "is not a #RRGGBBAA color"))
        XCTAssertEqual(try error(##"{ "id": 2, "points": [], "fill": "#000000FF", "fillGlobal": "Ink" }"##),
                       .invalid(path: shape + ".fillGlobal", problem: "is not a number"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "group": 1.5 }"#), .invalid(path: shape + ".group", problem: "is not a whole number"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "group": "1" }"#), .invalid(path: shape + ".group", problem: "is not a number"))
        XCTAssertEqual(try error(#"{ "id": -2, "points": [] }"#), .invalid(path: shape + ".id", problem: "is not a positive id"))
        XCTAssertEqual(try error(#"{ "points": [] }"#), .invalid(path: shape + ".id", problem: "is missing"))
        // Strokes.
        XCTAssertEqual(try error(##"{ "id": 2, "points": [], "stroke": { "color": "#000000FF" } }"##),
                       .invalid(path: shape + ".stroke.width", problem: "is missing"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "stroke": { "width": 1 } }"#),
                       .invalid(path: shape + ".stroke.color", problem: "is missing"))
        XCTAssertEqual(try error(##"{ "id": 2, "points": [], "stroke": { "color": "#000000FF", "width": 1, "miterLimit": 0.5 } }"##),
                       .invalid(path: shape + ".stroke.miterLimit", problem: "is less than 1"))
        XCTAssertEqual(try error(##"{ "id": 2, "points": [], "stroke": { "color": "#000000FF", "width": 1, "dashOffset": null, "global": [] } }"##),
                       .invalid(path: shape + ".stroke.global", problem: "is not a number"))
        // Something that isn't an object where one is expected.
        XCTAssertEqual(try error(#"{ "id": 2, "points": [[0, 0]] }"#), .invalid(path: p, problem: "is not an object"))
        XCTAssertEqual(try error(#"{ "id": 2, "points": [], "stroke": 1 }"#), .invalid(path: shape + ".stroke", problem: "is not an object"))
        // Null reads as missing.
        XCTAssertNil(try error(point(#""p": [0, 0], "in": null, "w": null, "smooth": null"#)))
    }

    func testPackageErrors() {
        XCTAssertThrowsError(try PresentationPackage(files: [:])) {
            XCTAssertEqual($0 as? PresentationFileError, .missingFile("presentation.json"))
        }
        XCTAssertThrowsError(try PresentationPackage(files: ["presentation.json": Data("{".utf8)])) {
            guard case .invalidJSON = $0 as? PresentationFileError else { return XCTFail("\($0)") }
        }
    }

    func testMissingReferencePixelsKeepTheReference() throws {
        var files = try exampleFiles("demo.controlflow")
        files["references/reference-1.png"] = nil
        let package = try PresentationPackage(files: files)
        XCTAssertEqual(package.drawing.references.count, 1)
        XCTAssertTrue(package.referenceImages.isEmpty)
    }

    func testImageExtensions() {
        XCTAssertEqual(PresentationPackage.fileExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "png")
        XCTAssertEqual(PresentationPackage.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xDB])), "jpg")
        XCTAssertEqual(PresentationPackage.fileExtension(for: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])), "heic")
        XCTAssertEqual(PresentationPackage.fileExtension(for: Data([1, 2])), "img")
    }
}

final class LayerTests: XCTestCase {
    func testLayerTreeListsLayersFrontToBack() {
        var d = Drawing()
        d.layers = [Layer(id: 1, name: "Back"), Layer(id: 2, name: "Front", shapes: [VectorShape(id: 3, path: BezierPath())])]
        d.references = [ReferenceImage(id: 4, name: "Under", size: Vec2(1, 1), center: .zero),
                        ReferenceImage(id: 5, name: "Over", size: Vec2(1, 1), center: .zero)]
        let tree = LayerTree(drawing: d)
        XCTAssertEqual(tree.layers.map(\.name), ["Front", "Back"])
        XCTAssertEqual(tree.layers[0].shapeCount, 1)
        XCTAssertEqual(tree.references.map(\.name), ["Over", "Under"])
    }

    func testRenamingKeepsNamesUnique() {
        var e = DrawingEditor()
        e.addStroke(ring(center: Vec2(0, 0), radius: 30), zoom: 1)
        e.addStroke(ring(center: Vec2(300, 0), radius: 30), zoom: 1)
        let (a, b) = (e.drawing.layers[0].id, e.drawing.layers[1].id)
        XCTAssertEqual(e.drawing.layers.map(\.name), ["Layer 1", "Layer 2"])
        e.renameLayer(b, to: "  Layer 1 ")
        XCTAssertEqual(e.drawing.layers[1].name, "Layer 1 2")
        e.renameLayer(a, to: "   ")
        XCTAssertEqual(e.drawing.layers[0].name, "Layer 1")
        e.undo()
        XCTAssertEqual(e.drawing.layers[1].name, "Layer 2")
        // A new layer never reuses a taken name.
        e.renameLayer(a, to: "Layer 3")
        e.selection = .none
        e.addStroke(ring(center: Vec2(600, 0), radius: 30), zoom: 1)
        XCTAssertEqual(e.drawing.layers.map(\.name), ["Layer 3", "Layer 2", "Layer 3 2"])
    }

    func testSelectDeleteAndRenamePresentation() {
        var e = DrawingEditor()
        e.addStroke(ring(center: Vec2(0, 0), radius: 30), zoom: 1)
        let id = e.drawing.layers[0].id
        e.selectLayer(id)
        XCTAssertEqual(e.selection, .layer(id))
        e.renamePresentation("Robo")
        XCTAssertEqual(e.drawing.name, "Robo")
        e.deleteLayer(id)
        XCTAssertTrue(e.drawing.layers.isEmpty)
        XCTAssertEqual(e.selection, .none)
        e.undo()
        XCTAssertEqual(e.drawing.layers.count, 1)
        e.undo()
        XCTAssertEqual(e.drawing.name, "Untitled")
    }

    func testIDsAreNeverReusedAfterUndo() {
        var e = DrawingEditor()
        let first = e.addReference(name: "A", size: Vec2(10, 10), center: .zero, scale: 1)
        e.undo()
        let second = e.addReference(name: "B", size: Vec2(10, 10), center: .zero, scale: 1)
        XCTAssertNotEqual(first, second)
    }

    func testReplacingTheDrawingIsUndoable() {
        var e = DrawingEditor(drawing: editorDrawing())
        XCTAssertFalse(e.canUndo)
        let original = e.drawing
        e.selection = .layer(original.layers[0].id)
        e.replaceDrawing(Drawing())
        XCTAssertEqual(e.selection, .none)
        e.undo()
        XCTAssertEqual(e.drawing, original)
    }
}
