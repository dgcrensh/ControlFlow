import XCTest
@testable import ControlFlowCore

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h))
}

/// Adds a layer holding one rectangle and returns the layer's id.
@discardableResult
private func addRect(_ d: inout Drawing, _ name: String, _ r: Rect, fill: RGBAColor? = .ink,
                     stroke: StrokeStyle? = nil) -> Int {
    let shape = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(r), fill: fill, stroke: stroke)
    let id = d.makeID()
    d.layers.append(Layer(id: id, name: name, shapes: [shape], pivot: r.center))
    return id
}

private func assertClose(_ a: Vec2?, _ b: Vec2, tolerance: Double = 1e-6, file: StaticString = #filePath, line: UInt = #line) {
    guard let a else { return XCTFail("nil is not \(b)", file: file, line: line) }
    XCTAssertTrue(a.isApproximately(b, tolerance: tolerance), "\(a) is not \(b)", file: file, line: line)
}

final class ViewportTests: XCTestCase {
    func testANewDrawingHasAWideWhiteViewportThatIsTheExportArea() {
        let d = Drawing()
        XCTAssertEqual(d.viewport.bounds, rect(0, 0, 1920, 1080))
        XCTAssertEqual(d.viewport.background, .white)
        XCTAssertEqual(d.viewport.aspect, .wide)
        XCTAssertEqual(d.exportArea(), rect(0, 0, 1920, 1080))
    }

    func testChangingTheAspectKeepsTheWidthAndTheOrigin() {
        let v = Viewport()
        XCTAssertEqual(v.withAspect(Viewport.Aspect.square.ratio).bounds, rect(0, 0, 1920, 1920))
        XCTAssertEqual(v.withAspect(Viewport.Aspect.standard.ratio).bounds, rect(0, 0, 1920, 1440))
        XCTAssertEqual(v.withAspect(Viewport.Aspect.portrait.ratio).aspect, .portrait)
        XCTAssertEqual(v.withAspect(3).aspect, nil, "a custom ratio")
        XCTAssertEqual(v.withAspect(0), v)
        XCTAssertEqual(v.withAspect(.infinity), v)
    }

    func testViewportEditsUndoAndSizesStayPositive() {
        var d = Drawing()
        addRect(&d, "Body", rect(0, 0, 100, 200))
        var e = DrawingEditor(drawing: d)
        e.setViewportAspect(Viewport.Aspect.square.ratio)
        XCTAssertEqual(e.drawing.viewport.height, 1920)
        XCTAssertEqual(e.drawing.layers[0].bounds, rect(0, 0, 100, 200), "no art moves")
        e.undo()
        XCTAssertEqual(e.drawing.viewport.height, 1080)

        e.updateViewport { $0.width = -5 }
        XCTAssertEqual(e.drawing.viewport.width, Viewport.minimumSide)
        e.undo()
        e.updateViewport(coalescingKey: "width") { $0.width = 800 }
        e.updateViewport(coalescingKey: "width") { $0.width = 640 }
        XCTAssertEqual(e.drawing.viewport.width, 640)
        e.undo()
        XCTAssertEqual(e.drawing.viewport.width, 1920, "both width edits were one step")
        XCTAssertFalse(e.canUndo)
        // No change: no undo step.
        e.updateViewport { $0.width = 1920 }
        XCTAssertFalse(e.canUndo)
    }

    func testTheVeilCoversTheViewOutsideTheViewport() {
        let v = Viewport(width: 100, height: 50)
        func area(_ triangles: [Vec2]) -> Double {
            stride(from: 0, to: triangles.count, by: 3).reduce(0) { sum, i in
                let a = triangles[i], b = triangles[i + 1], c = triangles[i + 2]
                return sum + abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) / 2
            }
        }
        // Inside the viewport: nothing to dim.
        XCTAssertEqual(v.veilTriangles(covering: rect(10, 10, 20, 20)), [])
        // Round it on every side: four bands, the view's area minus the viewport's.
        let around = v.veilTriangles(covering: rect(-50, -50, 200, 150))
        XCTAssertEqual(around.count, 4 * 6)
        XCTAssertEqual(area(around), 200 * 150 - 100 * 50, accuracy: 1e-9)
        // Overlapping one corner.
        let corner = v.veilTriangles(covering: rect(50, 25, 100, 100))
        XCTAssertEqual(area(corner), 100 * 100 - 50 * 25, accuracy: 1e-9)
        // Wholly outside: the whole view.
        XCTAssertEqual(area(v.veilTriangles(covering: rect(200, 0, 30, 30))), 900, accuracy: 1e-9)
        XCTAssertEqual(v.veilTriangles(covering: .null), [])
    }

    func testTheViewportIsSavedAndRead() throws {
        var d = Drawing()
        addRect(&d, "Body", rect(0, 0, 100, 200))
        d.viewport = Viewport(width: 1080, height: 1920, background: RGBAColor(r: 0, g: 0, b: 0))
        let json = PresentationFormat.encode(d)
        XCTAssertEqual(json["viewport"]?["width"], JSONValue.number(1080))
        var read = try PresentationFormat.decode(json).drawing.viewport
        XCTAssertGreaterThan(read.id, 0, "the viewport has an id, which keyframes use")
        read.id = 0
        XCTAssertEqual(read, d.viewport)

        // A file without one gets the default.
        let bare = try JSONValue(parsing: #"{ "formatVersion": "1.0" }"#)
        read = try PresentationFormat.decode(bare).drawing.viewport
        read.id = 0
        XCTAssertEqual(read, Viewport())
        let flat = try JSONValue(parsing: #"{ "formatVersion": "1.0", "viewport": { "width": 0, "height": 10 } }"#)
        XCTAssertThrowsError(try PresentationFormat.decode(flat))
    }
}

final class ViewOptionTests: XCTestCase {
    func testGhostingKeepsTheSelectionAndFadesTheRest() {
        var d = Drawing()
        let a = addRect(&d, "A", rect(0, 0, 10, 10))
        addRect(&d, "B", rect(20, 0, 10, 10))
        var e = DrawingEditor(drawing: d)
        e.ghostsUnselected = true
        XCTAssertNil(e.ghostFocus, "Nothing selected: nothing fades")
        e.selection = .layer(a)
        XCTAssertEqual(e.ghostFocus, [e.drawing.layers[0].shapes[0].id])

        var builder = ArtBuilder()
        let batch = builder.build(e.drawing, isolatedLayer: nil, tolerance: 0.5, ghostFocus: e.ghostFocus)
        let opacities: [Double] = batch.steps.compactMap { step in
            if case .cover(_, let paint, _, _) = step { return paint.opacity }
            return nil
        }
        XCTAssertEqual(opacities, [1, ArtBuilder.ghostOpacity])
        e.ghostsUnselected = false
        XCTAssertNil(e.ghostFocus)
    }

    func testOutlineViewDrawsAWireframeOfShownShapes() {
        var d = Drawing()
        let id = addRect(&d, "A", rect(0, 0, 10, 10))
        var e = DrawingEditor(drawing: d)
        let plain = EditorOverlay.vertices(for: e, zoom: 1)
        e.outlineView = true
        XCTAssertGreaterThan(EditorOverlay.vertices(for: e, zoom: 1).count, plain.count)
        e.setLayerHidden(id, true)
        XCTAssertEqual(EditorOverlay.vertices(for: e, zoom: 1).count, plain.count)
    }

    func testTheViewportBorderIsDrawn() {
        var e = DrawingEditor()
        let wide = EditorOverlay.vertices(for: e, zoom: 1)
        XCTAssertFalse(wide.isEmpty)
        e.setViewportAspect(1)
        XCTAssertNotEqual(EditorOverlay.vertices(for: e, zoom: 1), wide)
    }

    func testZoomToFitCentersTheRect() {
        var session = CanvasSession()
        session.zoom(toFit: rect(0, 0, 100, 50), viewSize: Vec2(1000, 600), margin: 50)
        XCTAssertEqual(session.camera.zoom, 9, accuracy: 1e-9)
        assertClose(session.camera.toScreen(Vec2(50, 25)), Vec2(500, 300))
    }
}

final class SVGExportTests: XCTestCase {
    func testWritesLayersAsNamedGroupsWithStyles() throws {
        var d = Drawing()
        d.name = "Robo & Co"
        addRect(&d, "Arm L", rect(0, 0, 10, 20), fill: RGBAColor(hex: "#FF0000")!,
                stroke: StrokeStyle(color: .black, width: 2))
        addRect(&d, "Ghost", rect(0, 0, 5, 5))
        d.layers[1].isHidden = true
        let svg = try XCTUnwrap(SVGWriter.document(for: d))
        XCTAssertTrue(svg.hasPrefix("<?xml"))
        XCTAssertTrue(svg.contains("<title>Robo &amp; Co</title>"))
        XCTAssertTrue(svg.contains("viewBox=\"0 0 1920 1080\""), svg)
        XCTAssertTrue(svg.contains("<g id=\"Arm_L\" data-name=\"Arm L\">"), svg)
        XCTAssertTrue(svg.contains("d=\"M0 0L10 0L10 20L0 20Z\" fill=\"#FF0000\" stroke=\"#000000\" stroke-width=\"2\""), svg)
        XCTAssertFalse(svg.contains("Ghost"))
        XCTAssertNotNil(SVGWriter.document(for: Drawing()), "an empty viewport still exports")
        XCTAssertNil(SVGWriter.document(for: d, area: rect(0, 0, 0, 10)))
    }

    func testNumbers() {
        XCTAssertEqual(SVGWriter.number(2), "2")
        XCTAssertEqual(SVGWriter.number(0.5), "0.5")
        XCTAssertEqual(SVGWriter.number(1.23456), "1.235")
        XCTAssertEqual(SVGWriter.number(-0.0001), "0")
        XCTAssertEqual(SVGWriter.identifier("2 Arm.L"), "_2_Arm.L")
    }

    func testGradientsClippingAlignmentAndVariableWidth() throws {
        var d = Drawing()
        addRect(&d, "Body", rect(0, 0, 100, 100), fill: .white,
                stroke: StrokeStyle(color: .black, width: 4, alignment: .inside))
        var shade = VectorShape(id: d.makeID(), path: ShapePrimitives.rectangle(rect(50, 0, 100, 100)), fill: .black)
        shade.isClipped = true
        shade.gradient = ShapeGradient(kind: .linear, start: Vec2(50, 0), end: Vec2(150, 0),
                                       stops: [GradientStop(offset: 0, color: .black), GradientStop(offset: 1, color: .white)])
        d.layers[0].shapes.append(shade)
        var line = ShapePrimitives.line(Vec2(0, 120), Vec2(100, 120))
        line.points[1].width = 2
        d.layers.append(Layer(id: d.makeID(), name: "Line", shapes: [VectorShape(id: d.makeID(), path: line,
                                                                               stroke: StrokeStyle(color: .black, width: 2))]))
        let svg = try XCTUnwrap(SVGWriter.document(for: d))
        // The inside outline is doubled and clipped to the path.
        XCTAssertTrue(svg.contains("<clipPath id=\"inside1\">"), svg)
        XCTAssertTrue(svg.contains("stroke-width=\"8\""), svg)
        XCTAssertTrue(svg.contains("clip-path=\"url(#inside1)\""), svg)
        // The clipped shape sits in a group masked by its base.
        XCTAssertTrue(svg.contains("<mask id=\"clip2\""), svg)
        XCTAssertTrue(svg.contains("<g mask=\"url(#clip2)\">"), svg)
        XCTAssertTrue(svg.contains("<linearGradient id=\"gradient3\" gradientUnits=\"userSpaceOnUse\" x1=\"50\" y1=\"0\" x2=\"150\" y2=\"0\">"), svg)
        XCTAssertTrue(svg.contains("fill=\"url(#gradient3)\""), svg)
        // A varying outline is written as filled area.
        let lineGroup = try XCTUnwrap(svg.components(separatedBy: "<g id=\"Line\">").last)
        XCTAssertFalse(lineGroup.contains("stroke"))
        XCTAssertTrue(lineGroup.contains("fill=\"#000000\"/>"))
    }

    func testExportThenImportKeepsTheArt() throws {
        var d = Drawing()
        let head = VectorShape(id: d.makeID(), path: ShapePrimitives.ellipse(rect(0, 0, 100, 80)),
                               fill: RGBAColor(hex: "#F2A65A")!, stroke: StrokeStyle(color: .ink, width: 3))
        d.layers.append(Layer(id: d.makeID(), name: "Head", shapes: [head], pivot: Vec2(50, 40)))
        addRect(&d, "Body", rect(10, 80, 80, 120), fill: RGBAColor(hex: "#5A8DEE")!)
        let svg = try XCTUnwrap(SVGWriter.document(for: d))
        let result = try SVGImporter.parse(svg, name: "robot")
        XCTAssertEqual(result.layers.map(\.name), ["Head", "Body"])
        XCTAssertEqual(result.layers.map(\.shapes.count), [1, 1])
        let shape = result.layers[0].shapes[0]
        XCTAssertTrue(shape.path.closed)
        XCTAssertEqual(shape.fill, head.fill)
        XCTAssertEqual(shape.stroke?.color, RGBAColor.ink)
        XCTAssertEqual(shape.stroke?.width, 3)
        XCTAssertEqual(shape.stroke?.cap, .round)
        XCTAssertEqual(shape.stroke?.join, .round)
        XCTAssertEqual(shape.path.points.count, 4)
        for (a, b) in zip(shape.path.points, head.path.points) {
            assertClose(a.position, b.position, tolerance: 1e-3)
            assertClose(a.inHandle, b.inHandle, tolerance: 1e-3)
            assertClose(a.outHandle, b.outHandle, tolerance: 1e-3)
            XCTAssertEqual(a.mode, .symmetric)
        }
        let body = result.layers[1].shapes[0]
        XCTAssertEqual(body.path.points.map(\.position), [Vec2(10, 80), Vec2(90, 80), Vec2(90, 200), Vec2(10, 200)])
        XCTAssertTrue(body.path.points.allSatisfy { $0.mode == .corner })
        XCTAssertNil(body.stroke)
    }
}

final class SVGParsingTests: XCTestCase {
    func testXMLReader() throws {
        let root = try XMLReader.parse("""
        <?xml version="1.0"?>
        <!DOCTYPE svg [ <!ENTITY ns "http://www.w3.org/2000/svg"> ]>
        <!-- a comment -->
        <svg xmlns="&ns;"><style><![CDATA[.a{fill:red}]]></style><svg:g id="x &amp; y &#65;"/></svg>
        """)
        XCTAssertEqual(root.name, "svg")
        XCTAssertEqual(root.attributes["xmlns"], "http://www.w3.org/2000/svg")
        XCTAssertEqual(root.children.map(\.name), ["style", "g"])
        XCTAssertEqual(root.children[0].text, ".a{fill:red}")
        XCTAssertEqual(root.children[1].attributes["id"], "x & y A")
        XCTAssertThrowsError(try XMLReader.parse("<svg width=10/>"))
        XCTAssertThrowsError(try XMLReader.parse("no markup"))
    }

    func testPathCommands() throws {
        let square = SVGPathParser.parse("M10 10 h20 v20 h-20 z")
        XCTAssertEqual(square.count, 1)
        let path = try XCTUnwrap(square[0].bezierPath)
        XCTAssertTrue(path.closed)
        XCTAssertEqual(path.points.map(\.position), [Vec2(10, 10), Vec2(30, 10), Vec2(30, 30), Vec2(10, 30)])

        // Pairs after a move are lines; numbers may run together.
        let lines = SVGPathParser.parse("M0-1.5.5 1 2,2")
        XCTAssertEqual(lines.first?.start, Vec2(0, -1.5))
        XCTAssertEqual(lines.first?.segments.map(\.p3), [Vec2(0.5, 1), Vec2(2, 2)])
        XCTAssertEqual(lines.first?.closed, false)

        // S reflects the previous control point.
        let smooth = SVGPathParser.parse("M0 0 c10 0 20 10 20 20 s10 20 20 20")
        XCTAssertEqual(smooth.first?.segments.count, 2)
        assertClose(smooth.first?.segments[1].p1, Vec2(20, 30))
        assertClose(smooth.first?.segments[1].p2, Vec2(30, 40))
        assertClose(smooth.first?.segments[1].p3, Vec2(40, 40))

        let quad = SVGPathParser.parse("M0 0 Q10 10 20 0")
        assertClose(quad.first?.segments[0].p1, Vec2(20.0 / 3, 20.0 / 3))
        assertClose(quad.first?.segments[0].p2, Vec2(40.0 / 3, 20.0 / 3))

        // A quarter circle about (0, 10).
        let arc = SVGPathParser.parse("M0 0 A10 10 0 0 1 10 10")
        let pieces = try XCTUnwrap(arc.first?.segments)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].p3, Vec2(10, 10))
        for t in [0.25, 0.5, 0.75] {
            XCTAssertEqual(pieces[0].point(at: t).distance(to: Vec2(0, 10)), 10, accuracy: 0.01)
        }

        // Drawing on after Z starts a new subpath at the closed one's start.
        let after = SVGPathParser.parse("M0 0 L10 0 L10 10 Z L20 20")
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].closed, true)
        XCTAssertEqual(after[1].start, Vec2(0, 0))
        XCTAssertEqual(after[1].segments.map(\.p3), [Vec2(20, 20)])

        // An error keeps what came before it.
        XCTAssertEqual(SVGPathParser.parse("M0 0 L10 10 L oops").first?.segments.count, 1)
    }

    func testColorsLengthsAndTransforms() {
        XCTAssertEqual(SVGImporter.color("#abc"), RGBAColor(hex: "#AABBCC"))
        XCTAssertEqual(SVGImporter.color("rgb(255, 0, 0)"), RGBAColor(r: 1, g: 0, b: 0))
        XCTAssertEqual(SVGImporter.color("rgba(0,0,255,0.5)"), RGBAColor(r: 0, g: 0, b: 1, a: 0.5))
        XCTAssertEqual(SVGImporter.color("teal"), RGBAColor(hex: "#008080"))
        XCTAssertNil(SVGImporter.color("nonsense"))
        let green = SVGImporter.color("hsl(120, 100%, 50%)")
        XCTAssertEqual(green?.r ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(green?.g ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(green?.b ?? 1, 0, accuracy: 1e-9)

        XCTAssertEqual(SVGImporter.length("12"), 12)
        XCTAssertEqual(SVGImporter.length("3px"), 3)
        XCTAssertEqual(SVGImporter.length("1in"), 96)
        XCTAssertNil(SVGImporter.length("50%"))

        let t = SVGImporter.transform("translate(10 20) rotate(90) scale(2, 3)")
        assertClose(t.apply(Vec2(1, 1)), Vec2(10 - 3, 20 + 2))
        let about = SVGImporter.transform("rotate(180 5 5)")
        assertClose(about.apply(Vec2(0, 0)), Vec2(10, 10))
        assertClose(SVGImporter.transform("matrix(1 0 0 1 4 5)").apply(.zero), Vec2(4, 5))
    }
}

final class SVGImportTests: XCTestCase {
    func testStyleRulesClassesIdsAndStyleAttributes() throws {
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
          <style>.red { fill: #FF0000 } #b { fill: blue }</style>
          <rect x="0" y="0" width="10" height="10" fill="green" class="red"/>
          <rect id="b" x="20" y="0" width="10" height="10" class="red"/>
          <rect x="40" y="0" width="10" height="10" class="red" style="fill: #00FF00; fill-opacity: 0.5"/>
          <circle cx="5" cy="30" r="5" fill="currentColor" color="#123456" opacity="0.5" stroke="black"/>
        </svg>
        """, name: "test")
        XCTAssertEqual(result.layers.map(\.name), ["test"])
        let shapes = result.layers[0].shapes
        XCTAssertEqual(shapes.map(\.fill), [RGBAColor(hex: "#FF0000"), RGBAColor(hex: "#0000FF"),
                                           RGBAColor(r: 0, g: 1, b: 0, a: 0.5), RGBAColor(hex: "#12345680")
                                               .map { RGBAColor(r: $0.r, g: $0.g, b: $0.b, a: 0.5) }])
        XCTAssertNil(shapes[0].stroke)
        XCTAssertEqual(shapes[3].stroke?.color, RGBAColor(r: 0, g: 0, b: 0, a: 0.5))
        XCTAssertEqual(shapes[3].stroke?.width, 1)
        XCTAssertEqual(shapes[3].stroke?.cap, .butt)
        XCTAssertEqual(shapes[3].stroke?.join, .miter)
        assertClose(shapes[3].path.bounds().center, Vec2(5, 30))
    }

    func testTransformsScaleOutlinesAndLinesAreNeverFilled() throws {
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <g transform="translate(10 20) scale(2)">
            <line x1="0" y1="0" x2="5" y2="0" stroke="#000" stroke-width="3" stroke-linecap="round"
                  stroke-dasharray="2 1"/>
          </g>
        </svg>
        """, name: "lines")
        // The lone group is unwrapped, so its line lands in a layer named after the file.
        XCTAssertEqual(result.layers.map(\.name), ["lines"])
        let shapes = result.layers[0].shapes
        XCTAssertEqual(shapes.count, 1)
        XCTAssertNil(shapes[0].fill)
        XCTAssertFalse(shapes[0].path.closed)
        XCTAssertEqual(shapes[0].path.points.map(\.position), [Vec2(10, 20), Vec2(20, 20)])
        XCTAssertEqual(shapes[0].stroke?.width, 6)
        XCTAssertEqual(shapes[0].stroke?.dash, [4, 2])
        XCTAssertEqual(shapes[0].stroke?.cap, .round)
    }

    func testCompoundPathsKeepTheirHoles() throws {
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <path d="M0 0H100V100H0Z M25 25H75V75H25Z" fill="#000" stroke="#F00" stroke-width="2"/>
        </svg>
        """)
        let shapes = result.layers[0].shapes
        // The fill (bridged into one ring), then each ring's outline.
        XCTAssertEqual(shapes.count, 3)
        XCTAssertNil(shapes[0].stroke)
        XCTAssertTrue(shapes[0].contains(Vec2(10, 10), tolerance: 0))
        XCTAssertFalse(shapes[0].contains(Vec2(50, 50), tolerance: 0))
        XCTAssertNil(shapes[1].fill)
        XCTAssertNil(shapes[2].fill)
        XCTAssertEqual(shapes[1].stroke?.color, RGBAColor(hex: "#FF0000"))
        XCTAssertTrue(shapes[2].path.closed)
    }

    func testGroupsBecomeLayersAndUnsupportedElementsAreCounted() throws {
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">
          <defs><circle id="dot" r="5" fill="#123456"/></defs>
          <g id="Eyes"><use xlink:href="#dot" x="10" y="10"/><use href="#dot" x="30" y="10"/></g>
          <g id="Gone" display="none"><rect width="5" height="5"/></g>
          <g data-name="Mouth Shape" id="Mouth_Shape"><text>hi</text><rect x="0" y="40" width="20" height="4"/></g>
        </svg>
        """)
        XCTAssertEqual(result.layers.map(\.name), ["Eyes", "Mouth Shape"])
        XCTAssertEqual(result.layers[0].shapes.count, 2)
        assertClose(result.layers[0].shapes[0].path.bounds().center, Vec2(10, 10))
        assertClose(result.layers[0].shapes[1].path.bounds().center, Vec2(30, 10))
        XCTAssertEqual(result.layers[0].shapes[0].fill, RGBAColor(hex: "#123456"))
        assertClose(result.layers[0].pivot, Vec2(20, 10))
        XCTAssertEqual(result.skipped["text"], 1)
        XCTAssertEqual(result.shapeCount, 3)
    }

    func testALayerGroupIsUnwrapped() throws {
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <g id="Layer_1"><g id="Head"><circle r="10"/></g><g id="Body"><rect width="10" height="10"/></g></g>
        </svg>
        """)
        XCTAssertEqual(result.layers.map(\.name), ["Head", "Body"])
    }

    func testGradientFills() throws {
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <defs>
            <linearGradient id="g"><stop offset="0" stop-color="#FF0000"/>
              <stop offset="100%" style="stop-color: #0000FF; stop-opacity: 0.5"/></linearGradient>
          </defs>
          <rect x="0" y="0" width="100" height="50" fill="url(#g)"/>
        </svg>
        """)
        let shape = result.layers[0].shapes[0]
        XCTAssertEqual(shape.fill, RGBAColor(hex: "#FF0000"))
        let gradient = try XCTUnwrap(shape.gradient)
        XCTAssertEqual(gradient.kind, .linear)
        assertClose(gradient.start, Vec2(0, 0))
        assertClose(gradient.end, Vec2(100, 0))
        XCTAssertEqual(gradient.stops.map(\.offset), [0, 1])
        XCTAssertEqual(gradient.stops[1].color, RGBAColor(r: 0, g: 0, b: 1, a: 0.5))
    }

    func testErrors() {
        XCTAssertThrowsError(try SVGImporter.parse("<html><body/></html>")) { error in
            XCTAssertEqual(error as? SVGImportError, .notSVG)
        }
        XCTAssertThrowsError(try SVGImporter.parse("<svg><text>only words</text></svg>")) { error in
            XCTAssertEqual(error as? SVGImportError, .noArt)
        }
        XCTAssertThrowsError(try SVGImporter.parse("<svg><rect")) { error in
            guard case .unreadable = error as? SVGImportError else { return XCTFail("\(error)") }
        }
    }

    func testImportedLayersArriveOnTopWithFreshIdsAndOneUndo() throws {
        var d = Drawing()
        addRect(&d, "Head", rect(0, 0, 10, 10))
        var e = DrawingEditor(drawing: d)
        let firstNew = e.drawing.nextID
        let result = try SVGImporter.parse("""
        <svg xmlns="http://www.w3.org/2000/svg">
          <g id="Head"><rect width="5" height="5"/></g>
          <g id="Arm"><rect x="10" width="5" height="5"/></g>
        </svg>
        """)
        XCTAssertTrue(e.importLayers(result.layers))
        XCTAssertEqual(e.drawing.layers.map(\.name), ["Head", "Head 2", "Arm"])
        let added = e.drawing.layers.dropFirst()
        XCTAssertTrue(added.allSatisfy { $0.id >= firstNew && $0.shapes.allSatisfy { $0.id >= firstNew } })
        XCTAssertEqual(Set(e.drawing.shapeRefs(in: e.selection).map(\.layer)), Set(added.map(\.id)))
        e.undo()
        XCTAssertEqual(e.drawing.layers.map(\.name), ["Head"])
        XCTAssertFalse(e.importLayers([]))
    }
}
