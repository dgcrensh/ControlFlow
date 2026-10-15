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
    for path in [CharacterPackage.characterFile, "references/reference-1.png"] {
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
    e.selection = .layer(e.drawing.parts[0].id)
    e.renamePart(e.drawing.parts[0].id, to: "Head \"big\" ✨")
    e.renamePresentation("Tést")
    var d = e.drawing
    d.parts[0].shapes[0].path.points[1].isSmooth = false
    d.references.append(ReferenceImage(id: d.makeID(), name: "Ref", size: Vec2(640, 480), center: Vec2(12.5, -3),
                                       rotation: 0.3, scale: 0.25, opacity: 0.6, isHidden: true))
    return d
}

private func json(_ text: String) throws -> JSONValue { try JSONValue(parsing: text) }

final class JSONValueTests: XCTestCase {
    func testWritesReadableJSON() {
        let value = CharacterFormat.obj([
            "a": .string("q\"\\\n\u{1}é"),
            "list": .array([1, .number(0.5), .number(-0.0), .bool(true), .null]),
            "nested": CharacterFormat.obj(["p": .array([1, 2]), "deep": CharacterFormat.obj(["x": 1])]),
            "empty": .object([]),
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
        if case .number(let n) = CharacterFormat.num(1.234_567_89) { XCTAssertEqual(n, 1.2346) } else { XCTFail() }
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
        let value = CharacterFormat.encode(editorDrawing())
        XCTAssertEqual(try json(value.formatted()), value)
    }
}

final class CharacterFormatTests: XCTestCase {
    func testReadsTheExample() throws {
        let package = try CharacterPackage(files: exampleFiles("robo.charstudio"))
        let d = package.drawing
        XCTAssertEqual(d.name, "Robo")
        XCTAssertEqual(d.parts.map(\.name), ["Torso", "Head", "Antenna"])
        XCTAssertEqual(d.parts.map(\.shapes.count), [4, 4, 2])
        XCTAssertEqual(d.parts[0].pivot, Vec2(0, -40))
        XCTAssertEqual(d.palette, [RGBAColor(hex: "#FFFFFF80")!])
        XCTAssertEqual(d.globalColors.map(\.name), ["Skin", "Body", "Ink"])
        let ink = d.globalColors[2].id
        let torso = d.parts[0].shapes[0]
        XCTAssertTrue(torso.path.closed)
        XCTAssertEqual(torso.fill?.hexString, "#5A8DEEFF")
        XCTAssertEqual(torso.fillGlobal, d.globalColors[1].id)
        XCTAssertEqual(torso.gradient?.kind, .linear)
        XCTAssertEqual(torso.gradient?.stops.map(\.color.hexString), ["#5A8DEEFF", "#3655A0FF"])
        XCTAssertEqual(torso.stroke, StrokeStyle(color: RGBAColor(hex: "#222222")!, width: 3, join: .miter, global: ink))
        XCTAssertFalse(torso.path.points[0].isSmooth)
        // The neck edge is bare, so the head covers it without a seam.
        XCTAssertEqual(torso.path.points.map(\.stroked), [false, true, true, true, true])
        XCTAssertTrue(torso.path.points[2].isSmooth)
        XCTAssertEqual(torso.path.points[2].outHandle, Vec2(-8, 14))
        XCTAssertTrue(d.parts[0].shapes[1].isClipped)
        XCTAssertEqual(d.parts[0].clipBase(of: 1), 0)
        // The body and its shadow are a group.
        XCTAssertEqual(d.parts[0].groups.map(\.name), ["Shell"])
        XCTAssertEqual(d.parts[0].members(ofGroup: d.parts[0].groups[0].id), [0, 1])
        // The visor is a group clipped to the head, with a glint clipped to the visor inside it.
        let head = d.parts[1]
        XCTAssertEqual(head.groups.map(\.name), ["Visor"])
        XCTAssertTrue(head.groups[0].isClipped)
        XCTAssertEqual(head.clipBase(ofGroup: head.groups[0].id), 0)
        XCTAssertEqual(head.clipBase(of: 2), 1)
        XCTAssertNil(d.parts[0].shapes[2].stroke)
        XCTAssertEqual(d.parts[0].shapes[2].opacity, 0.8)
        let seam = d.parts[0].shapes[3].stroke
        XCTAssertEqual(seam?.cap, .butt)
        XCTAssertEqual(seam?.dash, [4, 3])
        XCTAssertEqual(d.parts[1].shapes[0].stroke?.alignment, .inside)
        let mouth = d.parts[1].shapes[3]
        XCTAssertFalse(mouth.path.closed)
        XCTAssertNil(mouth.fill)
        XCTAssertEqual(mouth.path.points.map(\.width), [0.3, 1.4, 0.3])
        // The antenna is its own layer in front of the head, and the stalk keeps its place.
        XCTAssertTrue(d.parts[2].shapes[1].path.points[0].position.isApproximately(Vec2(0, -180), tolerance: 1e-9))
        // The head's art is stored in the neck bone's space and read back into world space.
        XCTAssertTrue(d.parts[1].pivot.isApproximately(Vec2(0, -110), tolerance: 1e-9))
        XCTAssertTrue(d.parts[1].shapes[0].path.points[0].position.isApproximately(Vec2(0, -150), tolerance: 1e-9))
        XCTAssertEqual(d.references.count, 1)
        XCTAssertEqual(d.references[0].rotation, .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(d.references[0].opacity, 0.35)
        XCTAssertEqual(d.viewport, Viewport())
        XCTAssertEqual(package.referenceImages[d.references[0].id]?.count, try exampleFiles("robo.charstudio")["references/reference-1.png"]?.count)
        // Every id is distinct.
        var ids: [Int] = d.parts.map(\.id) + d.parts.flatMap { $0.shapes.map(\.id) } + d.references.map(\.id) +
            d.globalColors.map(\.id)
        ids += d.parts.flatMap { $0.groups.map(\.id) }
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertGreaterThan(d.nextID, ids.max()!)
    }

    /// Re-saving the example reproduces it byte for byte, so the committed example
    /// (which CI validates against the JSON Schema) is exactly what the app writes.
    func testRewritesTheExampleExactly() throws {
        let files = try exampleFiles("robo.charstudio")
        let package = try CharacterPackage(files: files)
        let written = package.files()
        XCTAssertEqual(Set(written.keys), Set(files.keys))
        let original = String(decoding: files[CharacterPackage.characterFile]!, as: UTF8.self)
        let rewritten = String(decoding: written[CharacterPackage.characterFile]!, as: UTF8.self)
        if rewritten != original {
            XCTFail("Re-saved example differs:\n\(rewritten)")
        }
        XCTAssertEqual(written["references/reference-1.png"], files["references/reference-1.png"])
    }

    func testEditorDrawingRoundTrips() throws {
        let drawing = editorDrawing()
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let package = CharacterPackage(drawing: drawing, referenceImages: [drawing.references[0].id: image, 999: Data([1])])
        let files = package.files(thumbnail: Data([7]))
        XCTAssertEqual(Set(files.keys), ["character.json", "thumbnail.png", "references/reference-1.jpg"])

        let reopened = try CharacterPackage(files: files)
        let d = reopened.drawing
        XCTAssertEqual(d.name, "Tést")
        XCTAssertEqual(d.parts.map(\.name), drawing.parts.map(\.name))
        XCTAssertEqual(d.palette, drawing.palette)
        XCTAssertEqual(reopened.referenceImages.values.first, image)
        XCTAssertTrue(d.references[0].isHidden)
        XCTAssertEqual(d.references[0].rotation, 0.3, accuracy: 1e-4)
        for (a, b) in zip(d.parts, drawing.parts) {
            XCTAssertTrue(a.pivot.isApproximately(b.pivot, tolerance: 1e-4))
            for (s, t) in zip(a.shapes, b.shapes) {
                XCTAssertEqual(s.fill, t.fill)
                XCTAssertEqual(s.stroke?.width ?? 0, t.stroke?.width ?? 0, accuracy: 1e-4)
                XCTAssertEqual(s.path.closed, t.path.closed)
                XCTAssertEqual(s.path.points.count, t.path.points.count)
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

    func testDrawOrderDecidesPartOrder() throws {
        let file = try json("""
        {
          "formatVersion": "0.1.0",
          "slots": [
            { "id": "a", "bone": "root", "attachment": "a" },
            { "id": "b", "bone": "root", "attachment": "b" },
            { "id": "c", "bone": "root", "attachment": "c" },
            { "id": "empty", "bone": "root" }
          ],
          "drawOrder": ["c", "a"],
          "skins": { "default": {
            "a": { "a": { "type": "vector", "shapes": [] } },
            "b": { "b": { "type": "vector", "shapes": [] } },
            "c": { "c": { "type": "vector", "shapes": [] } }
          } },
          "someFutureKey": { "ignored": true }
        }
        """)
        let d = try CharacterFormat.decode(file).drawing
        XCTAssertEqual(d.parts.map(\.name), ["c", "a", "b"])
        XCTAssertEqual(d.name, "Untitled")
    }

    func testDuplicatePartNamesBecomeUniqueSlots() {
        var d = Drawing()
        for _ in 0..<3 { d.parts.append(Part(id: d.makeID(), name: "Arm")) }
        d.parts.append(Part(id: d.makeID(), name: "  "))
        XCTAssertEqual(CharacterFormat.slotNames(for: d.parts), ["Arm", "Arm 2", "Arm 3", "Part"])
    }

    func testVersionChecks() throws {
        func open(_ version: String) throws {
            _ = try CharacterFormat.decode(json(#"{ "formatVersion": "\#(version)" }"#))
        }
        XCTAssertNoThrow(try open("0.1.0"))
        XCTAssertNoThrow(try open("0.1.7"))
        XCTAssertNoThrow(try open("0.2.0"))
        XCTAssertNoThrow(try open("0.3.0"))
        XCTAssertThrowsError(try open("0.4.0")) { XCTAssertEqual($0 as? CharacterFileError, .newerVersion("0.4.0")) }
        XCTAssertThrowsError(try open("1.0.0")) { XCTAssertEqual($0 as? CharacterFileError, .newerVersion("1.0.0")) }
        XCTAssertThrowsError(try open("0.0.9")) { XCTAssertEqual($0 as? CharacterFileError, .unsupportedVersion("0.0.9")) }
        XCTAssertThrowsError(try open("one")) {
            XCTAssertEqual($0 as? CharacterFileError, .invalid(path: "formatVersion", problem: "is not a version like \"0.1.0\""))
        }
        XCTAssertThrowsError(try CharacterFormat.decode(json("{}")))
        XCTAssertThrowsError(try CharacterFormat.decode(json("[]")))
        XCTAssertEqual(FormatVersion("2.10.3-beta"), FormatVersion(2, 10, 3))
        XCTAssertLessThan(FormatVersion(0, 9, 9), FormatVersion(0, 10, 0))
    }

    func testDamageIsReportedWithItsPath() throws {
        let file = try json("""
        { "formatVersion": "0.1.0",
          "slots": [{ "id": "Head", "bone": "root", "attachment": "Head" }],
          "skins": { "default": { "Head": { "Head": { "type": "vector",
            "shapes": [{ "closed": true, "points": [{ "p": [1, 2] }, { "in": [0, 0] }] }] } } } } }
        """)
        XCTAssertThrowsError(try CharacterFormat.decode(file)) { error in
            XCTAssertEqual(error as? CharacterFileError,
                           .invalid(path: "skins.default.Head.Head.shapes[0].points[1].p", problem: "is missing"))
        }
        let badColor = try json(##"{ "formatVersion": "0.1.0", "palette": ["#12"] }"##)
        XCTAssertThrowsError(try CharacterFormat.decode(badColor)) { error in
            XCTAssertEqual(error as? CharacterFileError, .invalid(path: "palette[0]", problem: "is not a #RRGGBBAA color"))
        }
    }

    /// Values are read without building a node when they have the right type; a wrong type must still
    /// throw the error the node would have, with its path.
    func testWrongValueTypesAreReportedWithTheirPath() throws {
        func error(part: String = "", _ shape: String) throws -> CharacterFileError? {
            let file = try json("""
            { "formatVersion": "0.2.0", "slots": [{ "id": "A", "bone": "root", "attachment": "A" }],
              "skins": { "default": { "A": { "A": { "type": "vector", \(part) "shapes": [\(shape)] } } } } }
            """)
            do {
                _ = try CharacterFormat.decode(file)
                return nil
            } catch {
                return error as? CharacterFileError
            }
        }
        func point(_ members: String) -> String { #"{ "closed": false, "points": [{ \#(members) }] }"# }
        let shape = "skins.default.A.A.shapes[0]", p = shape + ".points[0]"

        // Pairs.
        XCTAssertEqual(try error(point(#""p": "0, 0""#)), .invalid(path: p + ".p", problem: "is not an array"))
        XCTAssertEqual(try error(point(#""p": [0, 0, 0]"#)), .invalid(path: p + ".p", problem: "is not an [x, y] pair"))
        XCTAssertEqual(try error(point(#""p": [0, "1"]"#)), .invalid(path: p + ".p[1]", problem: "is not a number"))
        XCTAssertEqual(try error(point(#""p": [1e999, 0]"#)), .invalid(path: p + ".p[0]", problem: "is not a number"))
        XCTAssertEqual(try error(point(#""p": [0, 0], "in": [0]"#)), .invalid(path: p + ".in", problem: "is not an [x, y] pair"))
        XCTAssertEqual(try error(point(#""in": [0, 0]"#)), .invalid(path: p + ".p", problem: "is missing"))
        XCTAssertEqual(try error(part: #""pivot": true,"#, ""), .invalid(path: "skins.default.A.A.pivot", problem: "is not an array"))
        // Numbers, booleans, strings and colors.
        XCTAssertEqual(try error(point(#""p": [0, 0], "w": "2""#)), .invalid(path: p + ".w", problem: "is not a number"))
        XCTAssertEqual(try error(point(#""p": [0, 0], "smooth": 1"#)), .invalid(path: p + ".smooth", problem: "is not true or false"))
        XCTAssertEqual(try error(#"{ "closed": "yes", "points": [] }"#), .invalid(path: shape + ".closed", problem: "is not true or false"))
        XCTAssertEqual(try error(#"{ "points": [], "opacity": [1] }"#), .invalid(path: shape + ".opacity", problem: "is not a number"))
        XCTAssertEqual(try error(#"{ "points": [], "fill": 0 }"#), .invalid(path: shape + ".fill", problem: "is not a string"))
        XCTAssertEqual(try error(#"{ "points": [], "fill": "red" }"#), .invalid(path: shape + ".fill", problem: "is not a #RRGGBBAA color"))
        XCTAssertEqual(try error(##"{ "points": [], "fill": "#000000FF", "fillGlobal": 3 }"##),
                       .invalid(path: shape + ".fillGlobal", problem: "is not a string"))
        XCTAssertEqual(try error(#"{ "points": [], "group": 1.5 }"#), .invalid(path: shape + ".group", problem: "is not a whole number"))
        XCTAssertEqual(try error(#"{ "points": [], "group": "1" }"#), .invalid(path: shape + ".group", problem: "is not a number"))
        // Strokes.
        XCTAssertEqual(try error(##"{ "points": [], "stroke": { "color": "#000000FF" } }"##),
                       .invalid(path: shape + ".stroke.width", problem: "is missing"))
        XCTAssertEqual(try error(#"{ "points": [], "stroke": { "width": 1 } }"#),
                       .invalid(path: shape + ".stroke.color", problem: "is missing"))
        XCTAssertEqual(try error(##"{ "points": [], "stroke": { "color": "#000000FF", "width": 1, "miterLimit": 0.5 } }"##),
                       .invalid(path: shape + ".stroke.miterLimit", problem: "is less than 1"))
        XCTAssertEqual(try error(##"{ "points": [], "stroke": { "color": "#000000FF", "width": 1, "dashOffset": null, "global": [] } }"##),
                       .invalid(path: shape + ".stroke.global", problem: "is not a string"))
        // Something that isn't an object where one is expected.
        XCTAssertEqual(try error(#"{ "points": [[0, 0]] }"#), .invalid(path: p, problem: "is not an object"))
        XCTAssertEqual(try error(#"{ "points": [], "stroke": 1 }"#), .invalid(path: shape + ".stroke", problem: "is not an object"))
        // Null reads as missing.
        XCTAssertNil(try error(point(#""p": [0, 0], "in": null, "w": null, "smooth": null"#)))
    }

    func testPackageErrors() {
        XCTAssertThrowsError(try CharacterPackage(files: [:])) {
            XCTAssertEqual($0 as? CharacterFileError, .missingFile("character.json"))
        }
        XCTAssertThrowsError(try CharacterPackage(files: ["character.json": Data("{".utf8)])) {
            guard case .invalidJSON = $0 as? CharacterFileError else { return XCTFail("\($0)") }
        }
    }

    func testMissingReferencePixelsKeepTheReference() throws {
        var files = try exampleFiles("robo.charstudio")
        files["references/reference-1.png"] = nil
        let package = try CharacterPackage(files: files)
        XCTAssertEqual(package.drawing.references.count, 1)
        XCTAssertTrue(package.referenceImages.isEmpty)
    }

    func testImageExtensions() {
        XCTAssertEqual(CharacterPackage.fileExtension(for: Data([0x89, 0x50, 0x4E, 0x47, 0x0D])), "png")
        XCTAssertEqual(CharacterPackage.fileExtension(for: Data([0xFF, 0xD8, 0xFF, 0xDB])), "jpg")
        XCTAssertEqual(CharacterPackage.fileExtension(for: Data([0, 0, 0, 0x18, 0x66, 0x74, 0x79, 0x70, 0x68, 0x65, 0x69, 0x63])), "heic")
        XCTAssertEqual(CharacterPackage.fileExtension(for: Data([1, 2])), "img")
    }
}

final class LayerTests: XCTestCase {
    func testLayerTreeListsLayersFrontToBack() {
        var d = Drawing()
        d.parts = [Part(id: 1, name: "Back"), Part(id: 2, name: "Front", shapes: [VectorShape(id: 3, path: BezierPath())])]
        d.references = [ReferenceImage(id: 4, name: "Under", size: Vec2(1, 1), center: .zero),
                        ReferenceImage(id: 5, name: "Over", size: Vec2(1, 1), center: .zero)]
        let tree = LayerTree(drawing: d)
        XCTAssertEqual(tree.parts.map(\.name), ["Front", "Back"])
        XCTAssertEqual(tree.parts[0].shapeCount, 1)
        XCTAssertEqual(tree.references.map(\.name), ["Over", "Under"])
    }

    func testRenamingKeepsNamesUnique() {
        var e = DrawingEditor()
        e.addStroke(ring(center: Vec2(0, 0), radius: 30), zoom: 1)
        e.addStroke(ring(center: Vec2(300, 0), radius: 30), zoom: 1)
        let (a, b) = (e.drawing.parts[0].id, e.drawing.parts[1].id)
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Part 1", "Part 2"])
        e.renamePart(b, to: "  Part 1 ")
        XCTAssertEqual(e.drawing.parts[1].name, "Part 1 2")
        e.renamePart(a, to: "   ")
        XCTAssertEqual(e.drawing.parts[0].name, "Part 1")
        e.undo()
        XCTAssertEqual(e.drawing.parts[1].name, "Part 2")
        // A new part never reuses a taken name.
        e.renamePart(a, to: "Part 3")
        e.selection = .none
        e.addStroke(ring(center: Vec2(600, 0), radius: 30), zoom: 1)
        XCTAssertEqual(e.drawing.parts.map(\.name), ["Part 3", "Part 2", "Part 3 2"])
    }

    func testSelectDeleteAndRenamePresentation() {
        var e = DrawingEditor()
        e.addStroke(ring(center: Vec2(0, 0), radius: 30), zoom: 1)
        let id = e.drawing.parts[0].id
        e.selectPart(id)
        XCTAssertEqual(e.selection, .layer(id))
        e.renamePresentation("Robo")
        XCTAssertEqual(e.drawing.name, "Robo")
        e.deletePart(id)
        XCTAssertTrue(e.drawing.parts.isEmpty)
        XCTAssertEqual(e.selection, .none)
        e.undo()
        XCTAssertEqual(e.drawing.parts.count, 1)
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
        e.selection = .layer(original.parts[0].id)
        e.replaceDrawing(Drawing())
        XCTAssertEqual(e.selection, .none)
        e.undo()
        XCTAssertEqual(e.drawing, original)
    }
}
