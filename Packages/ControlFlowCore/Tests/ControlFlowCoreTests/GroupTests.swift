import XCTest
@testable import ControlFlowCore

private func tap(_ e: inout DrawingEditor, _ p: Vec2, time: Double? = nil) {
    e.pencilBegan(at: p, zoom: 1)
    e.pencilEnded(at: p, time: time)
}

/// A 50-point square with its top-left corner at (`x`, 0).
private func square(_ x: Double) -> BezierPath {
    ShapePrimitives.rectangle(Rect(minPoint: Vec2(x, 0), maxPoint: Vec2(x + 50, 50)))
}

/// The middle of the square at `x`.
private func middle(_ x: Double) -> Vec2 { Vec2(x + 25, 25) }

/// An editor with one layer of filled squares side by side, at x = 0, 100, 200, ...
private func editor(squares count: Int) -> DrawingEditor {
    var d = Drawing()
    let shapes = (0..<count).map { i in VectorShape(id: d.makeID(), path: square(Double(i) * 100), fill: .ink) }
    d.layers.append(Layer(id: d.makeID(), name: "Face", shapes: shapes))
    var e = DrawingEditor(drawing: d)
    e.tool = .select
    return e
}

private func refs(_ e: DrawingEditor, _ indices: [Int], layer: Int = 0) -> Set<ShapeRef> {
    let p = e.drawing.layers[layer]
    return Set(indices.map { ShapeRef(layer: p.id, shape: p.shapes[$0].id) })
}

/// Each shape's x position divided by 100, bottom to top, to read the stacking order.
private func order(_ layer: Layer) -> [Int] {
    layer.shapes.map { Int(($0.path.bounds().minPoint.x / 100).rounded()) }
}

final class GroupTests: XCTestCase {
    func testGroupingGathersTheShapesBelowTheTopmostInOneUndoStep() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [0, 2]))
        XCTAssertTrue(e.canGroupSelection)
        e.groupSelection()
        let layer = e.drawing.layers[0]
        XCTAssertEqual(order(layer), [1, 0, 2, 3])
        let group = try! XCTUnwrap(layer.groups.first)
        XCTAssertEqual(group.name, "Group 1")
        XCTAssertEqual(layer.members(ofGroup: group.id), [1, 2])
        XCTAssertTrue(e.drawing.groupsAreValid)
        XCTAssertEqual(e.selectedGroup?.group, group)
        XCTAssertFalse(e.canGroupSelection, "already one group")

        e.undo()
        XCTAssertEqual(order(e.drawing.layers[0]), [0, 1, 2, 3])
        XCTAssertTrue(e.drawing.layers[0].groups.isEmpty)
        XCTAssertTrue(e.drawing.layers[0].shapes.allSatisfy { $0.group == nil })
    }

    func testGroupingDoesNotLandInsideAnotherGroup() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [1, 2, 3]))
        e.groupSelection()
        let first = e.drawing.layers[0].groups[0].id
        // Square 2 leaves the first group to join square 0. The new group would land
        // between squares 1 and 3, inside the first group, so it goes past it instead.
        e.selection = .covering(refs(e, [0, 2]))
        e.groupSelection()
        let layer = e.drawing.layers[0]
        XCTAssertTrue(e.drawing.groupsAreValid)
        XCTAssertEqual(order(layer), [1, 3, 0, 2])
        XCTAssertEqual(layer.members(ofGroup: first), [0, 1])
        XCTAssertEqual(layer.members(ofGroup: layer.groups[1].id), [2, 3])
    }

    func testShapesFromSeveralLayersCantBeGrouped() {
        var e = editor(squares: 2)
        e.drawing.layers.append(Layer(id: e.drawing.makeID(), name: "Other",
                                    shapes: [VectorShape(id: e.drawing.makeID(), path: square(300), fill: .ink)]))
        e.selection = .covering(refs(e, [0]).union(refs(e, [0], layer: 1)))
        XCTAssertTrue(e.selectionSpansLayers)
        XCTAssertFalse(e.canGroupSelection)
    }

    func testUngroupKeepsTheShapesWhereTheyAre() {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection()
        e.ungroupSelection()
        XCTAssertTrue(e.drawing.layers[0].groups.isEmpty)
        XCTAssertEqual(order(e.drawing.layers[0]), [0, 1, 2])
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [1, 2]))
    }

    func testTapsGoFromLayerToGroupAndDoubleTapGoesInside() {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection()
        e.selection = .none
        let layer = e.drawing.layers[0]
        let group = layer.groups[0].id

        tap(&e, middle(100))
        XCTAssertEqual(e.selection, .layer(layer.id))
        tap(&e, middle(100))
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [1, 2]), "the whole group")
        tap(&e, middle(0))
        XCTAssertEqual(e.selection, .shape(layer: layer.id, shape: layer.shapes[0].id), "an ungrouped shape")

        // A double tap on a grouped shape goes into its group.
        e.selection = .none
        tap(&e, middle(200), time: 1)
        tap(&e, middle(200), time: 1.1)
        XCTAssertEqual(e.isolatedLayer, layer.id)
        XCTAssertEqual(e.isolatedGroup, group)
        XCTAssertEqual(e.selection, .shape(layer: layer.id, shape: layer.shapes[2].id))
        // Only the group's shapes can be picked, one at a time.
        tap(&e, middle(0), time: 5)
        XCTAssertEqual(e.selection, Selection.none)
        tap(&e, middle(100), time: 10)
        XCTAssertEqual(e.selection, .shape(layer: layer.id, shape: layer.shapes[1].id))

        // Escape goes out one level at a time.
        e.stepOutOfIsolation()
        XCTAssertNil(e.isolatedGroup)
        XCTAssertEqual(e.isolatedLayer, layer.id)
        XCTAssertEqual(e.selectedGroup?.group.id, group)
        e.stepOutOfIsolation()
        XCTAssertNil(e.isolatedLayer)
        e.stepOutOfIsolation()
        XCTAssertEqual(e.selection, Selection.none)
    }

    func testAddModeAndMarqueesTakeWholeGroups() {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection()
        e.selection = .none
        e.addToSelection = true
        tap(&e, middle(200))
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection)), refs(e, [1, 2]))
        tap(&e, middle(100))
        XCTAssertEqual(e.selection, Selection.none, "toggled out together")

        e.addToSelection = false
        e.pencilBegan(at: Vec2(-10, -10), zoom: 1)
        e.pencilMoved(to: Vec2(60, 30))
        e.pencilMoved(to: Vec2(130, 60))
        e.pencilEnded(at: Vec2(130, 60))
        XCTAssertEqual(e.selection, .layer(e.drawing.layers[0].id), "touching the group took all three")
    }

    func testNewArtInsideAGroupJoinsIt() {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let group = e.drawing.layers[0].groups[0].id
        e.isolate(group: group, inLayer: e.drawing.layers[0].id)
        e.addPath(square(500))
        let layer = e.drawing.layers[0]
        XCTAssertEqual(e.drawing.layers.count, 1)
        XCTAssertEqual(order(layer), [0, 1, 5, 2])
        XCTAssertEqual(layer.shapes[2].group, group)
        XCTAssertTrue(e.drawing.groupsAreValid)
    }

    func testArrangeMovesAGroupAsOneUnitOrWithinIt() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        e.arrange(.bringForward)
        XCTAssertEqual(order(e.drawing.layers[0]), [2, 0, 1, 3])
        e.arrange(.bringToFront)
        XCTAssertEqual(order(e.drawing.layers[0]), [2, 3, 0, 1])
        XCTAssertTrue(e.drawing.groupsAreValid)

        // One shape of the group moves among the group's shapes only.
        e.selection = .covering(refs(e, [2]))
        e.arrange(.bringToFront)
        XCTAssertEqual(order(e.drawing.layers[0]), [2, 3, 1, 0])
        e.arrange(.sendToBack)
        XCTAssertEqual(order(e.drawing.layers[0]), [2, 3, 0, 1])

        // An ungrouped shape steps over the whole group.
        e.selection = .covering(refs(e, [1]))
        e.arrange(.bringForward)
        XCTAssertEqual(order(e.drawing.layers[0]), [2, 0, 1, 3])
    }

    func testClippingStaysInsideTheGroup() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [2, 3]))
        e.groupSelection()
        e.drawing.layers[0].shapes[1].isClipped = true
        e.drawing.layers[0].shapes[2].isClipped = true
        e.drawing.layers[0].shapes[3].isClipped = true
        let layer = e.drawing.layers[0]
        XCTAssertEqual(layer.clipBase(of: 1), 0, "ungrouped: the nearest unclipped shape")
        XCTAssertNil(layer.clipBase(of: 2), "the group's bottom shape draws unclipped")
        XCTAssertNil(layer.clipBase(of: 3), "nothing unclipped below it in the group")
        XCTAssertTrue(layer.isClipBase(0))
        XCTAssertFalse(layer.isClipBase(1))

        e.drawing.layers[0].shapes[2].isClipped = false
        XCTAssertEqual(e.drawing.layers[0].clipBase(of: 3), 2)
        XCTAssertTrue(e.drawing.layers[0].isClipBase(2))
    }

    func testClipPlanMatchesShapeByShapeLookups() {
        // Every clipped / grouped combination of five shapes, with a group in the middle.
        var e = editor(squares: 5)
        e.selection = .covering(refs(e, [1, 2, 3]))
        e.groupSelection()
        // The group clipped and not.
        for mask in 0..<64 {
            for s in 0..<5 { e.drawing.layers[0].shapes[s].isClipped = mask & (1 << s) != 0 }
            e.drawing.layers[0].groups[0].isClipped = mask & 32 != 0
            let layer = e.drawing.layers[0]
            let plan = layer.clipPlan()
            for i in 0..<5 {
                XCTAssertEqual(plan.base(of: i), layer.clipBase(of: i), "mask \(mask) shape \(i)")
                XCTAssertEqual(plan.groupBase(of: i), layer.groupClipBase(of: i), "mask \(mask) shape \(i)")
                XCTAssertEqual(plan.isBase(i), layer.isClipBase(i), "mask \(mask) shape \(i)")
            }
        }
    }

    func testDuplicatingAWholeGroupMakesANewGroup() {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let original = e.drawing.layers[0].groups[0]
        e.duplicateSelection()
        let layer = e.drawing.layers[0]
        XCTAssertTrue(e.drawing.groupsAreValid)
        XCTAssertEqual(layer.groups.count, 2)
        let copy = layer.groups[1]
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.name, original.name)
        XCTAssertEqual(layer.members(ofGroup: copy.id), [2, 3])
        XCTAssertEqual(e.selectedGroup?.group, copy)

        // Part of a group copies into the same group.
        e.selection = .covering(refs(e, [0]))
        e.duplicateSelection()
        XCTAssertEqual(e.drawing.layers[0].members(ofGroup: original.id), [0, 1, 2])
        XCTAssertTrue(e.drawing.groupsAreValid)
    }

    func testDuplicateMirroredFlipsTheGroupName() {
        var e = editor(squares: 2)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection(name: "Eye.L")
        e.duplicateMirrored()
        let layer = e.drawing.layers[0]
        XCTAssertTrue(e.drawing.groupsAreValid)
        XCTAssertEqual(layer.groupRuns.map(\.group.name), ["Eye.L", "Eye.R"])
        XCTAssertEqual(layer.groupRuns.map(\.indices), [[0, 1], [2, 3]])
    }

    func testDeletingAndMovingShapesKeepGroupsWhole() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let group = e.drawing.layers[0].groups[0].id
        e.selection = .covering(refs(e, [0, 1]))
        e.deleteSelection()
        XCTAssertTrue(e.drawing.layers[0].groups.isEmpty, "an emptied group goes")

        e.undo()
        // A whole group moved to a new layer goes with it; a partly moved one doesn't.
        e.selection = .covering(refs(e, [0, 1, 2]))
        e.moveSelectionToNewLayer()
        XCTAssertTrue(e.drawing.groupsAreValid)
        let moved = try! XCTUnwrap(e.drawing.layers.first { $0.shapes.count == 3 })
        XCTAssertEqual(moved.groups.map(\.id), [group])
        XCTAssertEqual(moved.members(ofGroup: group), [0, 1])
        XCTAssertNil(moved.shapes[2].group)
    }

    func testAddToGroupMovesShapesOnTopOfIt() {
        var e = editor(squares: 4)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let group = e.drawing.layers[0].groups[0]
        e.selection = .covering(refs(e, [3]))
        XCTAssertEqual(e.groupsToAddSelectionTo, [group])
        e.addSelection(toGroup: group.id)
        XCTAssertEqual(order(e.drawing.layers[0]), [0, 1, 3, 2])
        XCTAssertEqual(e.drawing.layers[0].members(ofGroup: group.id), [0, 1, 2])
    }

    func testRenameGroup() {
        var e = editor(squares: 2)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        let layer = e.drawing.layers[0].id
        let group = e.drawing.layers[0].groups[0].id
        e.renameGroup(group, inLayer: layer, to: "  Bangs ")
        XCTAssertEqual(e.drawing.layers[0].groups[0].name, "Bangs")
        e.renameGroup(group, inLayer: layer, to: " ")
        XCTAssertEqual(e.drawing.layers[0].groups[0].name, "Bangs")
        e.undo()
        XCTAssertEqual(e.drawing.layers[0].groups[0].name, "Group 1")
    }

    func testRepairSplitsGroupsThatCameApart() {
        var d = Drawing()
        let g = d.makeID()
        var layer = Layer(id: d.makeID(), name: "P")
        for i in 0..<4 {
            var shape = VectorShape(id: d.makeID(), path: square(Double(i) * 100), fill: .ink)
            shape.group = i == 1 ? nil : g
            layer.shapes.append(shape)
        }
        layer.shapes[3].group = 999
        layer.groups = [ShapeGroup(id: g, name: "Hair"), ShapeGroup(id: d.makeID(), name: "Empty")]
        d.layers = [layer]
        XCTAssertFalse(d.groupsAreValid)
        d.repairGroups()
        XCTAssertTrue(d.groupsAreValid)
        let repaired = d.layers[0]
        XCTAssertEqual(repaired.groups.map(\.name), ["Hair", "Hair"])
        XCTAssertEqual(repaired.shapes[0].group, g)
        XCTAssertNotNil(repaired.shapes[2].group)
        XCTAssertNotEqual(repaired.shapes[2].group, g)
        XCTAssertNil(repaired.shapes[3].group, "an unknown group")
    }

    // MARK: File

    func testGroupsRoundTripThroughTheFile() throws {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection(name: "Bangs")
        let text = CharacterFormat.encode(e.drawing).formatted()
        XCTAssertTrue(text.contains("\"groups\": ["))
        XCTAssertTrue(text.contains("{ \"id\": 1, \"name\": \"Bangs\" }"))
        XCTAssertTrue(text.contains("\"closed\": true,\n              \"group\": 1,"))
        let back = try CharacterFormat.decode(JSONValue(parsing: text)).drawing
        XCTAssertEqual(back.layers[0].groups.map(\.name), ["Bangs"])
        XCTAssertEqual(back.layers[0].members(ofGroup: back.layers[0].groups[0].id), [1, 2])
        XCTAssertEqual(CharacterFormat.encode(back).formatted(), text)

        // A layer without groups writes neither key.
        let plain = CharacterFormat.encode(editor(squares: 2).drawing).formatted()
        XCTAssertFalse(plain.contains("group"))
    }

    func testReadsSplitAndUnknownGroups() throws {
        let file = try JSONValue(parsing: """
        {
          "formatVersion": "0.2.0",
          "slots": [{ "id": "a", "bone": "root", "attachment": "a" }],
          "skins": { "default": { "a": { "a": {
            "type": "vector",
            "groups": [{ "id": 7, "name": "Eye" }, { "id": 8 }, { "id": 9, "name": "Unused" }],
            "shapes": [
              { "closed": true, "group": 7, "points": [{ "p": [0, 0] }] },
              { "closed": true, "points": [{ "p": [1, 0] }] },
              { "closed": true, "group": 7, "points": [{ "p": [2, 0] }] },
              { "closed": true, "group": 8, "points": [{ "p": [3, 0] }] },
              { "closed": true, "group": 42, "points": [{ "p": [4, 0] }] }
            ]
          } } } }
        }
        """)
        let d = try CharacterFormat.decode(file).drawing
        XCTAssertTrue(d.groupsAreValid)
        let layer = d.layers[0]
        XCTAssertEqual(layer.groupRuns.map(\.group.name), ["Eye", "Eye", "Group"])
        XCTAssertEqual(layer.groupRuns.map(\.indices), [[0], [2], [3]])
        XCTAssertNil(layer.shapes[4].group)
    }

    func testRepeatedGroupIDsAreDamage() throws {
        let file = try JSONValue(parsing: """
        {
          "formatVersion": "0.2.0",
          "slots": [{ "id": "a", "bone": "root", "attachment": "a" }],
          "skins": { "default": { "a": { "a": {
            "type": "vector", "groups": [{ "id": 1 }, { "id": 1 }], "shapes": []
          } } } }
        }
        """)
        XCTAssertThrowsError(try CharacterFormat.decode(file)) { error in
            XCTAssertEqual(error as? CharacterFileError,
                           .invalid(path: "skins.default.a.a.groups[1].id", problem: "repeats group 1"))
        }
    }

    func testCopiedGroupsPasteAsNewGroups() throws {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection(name: "Bangs")
        let original = e.drawing.layers[0].groups[0].id
        let text = try XCTUnwrap(e.copySelection())
        e.selection = .layer(e.drawing.layers[0].id)
        XCTAssertTrue(e.paste(text))
        let layer = e.drawing.layers[0]
        XCTAssertTrue(e.drawing.groupsAreValid)
        XCTAssertEqual(layer.groups.count, 2)
        XCTAssertNotEqual(layer.groups[1].id, original)
        XCTAssertEqual(layer.groups[1].name, "Bangs")
        XCTAssertEqual(layer.members(ofGroup: layer.groups[1].id), [3, 4])
    }

    // MARK: SVG

    func testSVGWritesAndReadsGroups() throws {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [1, 2]))
        e.groupSelection(name: "Bangs")
        e.drawing.layers.append(Layer(id: e.drawing.makeID(), name: "Other",
                                    shapes: [VectorShape(id: e.drawing.makeID(), path: square(400), fill: .ink)]))
        let svg = try XCTUnwrap(SVGWriter.document(for: e.drawing))
        XCTAssertTrue(svg.contains("  <g id=\"Face\">\n    <path"))
        XCTAssertTrue(svg.contains("    <g data-name=\"Bangs\">\n      <path"))
        let imported = try SVGImporter.parse(svg)
        XCTAssertEqual(imported.layers.map(\.name), ["Face", "Other"])
        let face = imported.layers[0]
        XCTAssertEqual(face.groups.map(\.name), ["Bangs"])
        XCTAssertEqual(face.members(ofGroup: face.groups[0].id), [1, 2])
        XCTAssertNil(face.shapes[0].group)
    }

    // MARK: Rendering

    func testIsolatedGroupDrawsAloneOverTheVeil() {
        var e = editor(squares: 3)
        e.selection = .covering(refs(e, [0, 1]))
        e.groupSelection()
        e.isolate(group: e.drawing.layers[0].groups[0].id, inLayer: e.drawing.layers[0].id)
        var builder = ArtBuilder()
        let batch = builder.build(e.drawing, isolatedLayer: e.isolatedLayer, isolatedGroup: e.isolatedGroup, tolerance: 0.5)
        // One stencil and one cover per filled square; the veil sits after the ungrouped one.
        let veil = try! XCTUnwrap(batch.steps.firstIndex(of: .veil))
        XCTAssertEqual(veil, 2)
        XCTAssertEqual(batch.steps.count, 7)
    }
}
