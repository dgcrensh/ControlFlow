import Foundation
import XCTest
@testable import ControlFlowCore

private let src = "images/0123456789abcdef.png"
/// The first bytes of a PNG, enough for the file's extension.
private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

/// A drawing with one layer holding one 200 x 100 image at (100, 50).
private func imageDrawing() -> (Drawing, ShapeRef) {
    var d = Drawing()
    let shape = VectorShape(id: d.makeID(), image: ShapeImage(src: src), origin: Vec2(100, 50), size: Vec2(200, 100))
    let layer = Layer(id: d.makeID(), name: "Photo", shapes: [shape])
    d.layers = [layer]
    d.assignVertexIDs()
    return (d, ShapeRef(layer: layer.id, shape: shape.id))
}

private func assertClose(_ a: Vec2, _ b: Vec2, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 1e-6, message, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 1e-6, message, file: file, line: line)
}

final class ImageShapeTests: XCTestCase {
    func testAnImageIsDrawnOverTheFrameItsCornersMake() throws {
        let (d, ref) = imageDrawing()
        let shape = try XCTUnwrap(d.shape(ref))
        XCTAssertTrue(shape.isImage)
        XCTAssertFalse(shape.hasEditablePath)
        XCTAssertTrue(shape.path.closed)
        XCTAssertNil(shape.visibleFill, "an image has no fill")
        let m = try XCTUnwrap(shape.imagePlacement)
        assertClose(m.apply(Vec2(0, 0)), Vec2(100, 50))
        assertClose(m.apply(Vec2(1, 1)), Vec2(300, 150))
        // Turned and scaled by its transform, the picture goes with the frame.
        var turned = d
        turned.apply(Affine2D.rotation(degrees: 90), to: .shape(layer: ref.layer, shape: ref.shape))
        let world = try XCTUnwrap(turned.worldShape(ref)?.imagePlacement)
        let rotation = Affine2D.rotation(degrees: 90)
        assertClose(world.apply(Vec2(0, 0)), rotation.apply(Vec2(100, 50)))
        assertClose(world.apply(Vec2(1, 0)), rotation.apply(Vec2(300, 50)))
        assertClose(world.apply(Vec2(0, 1)), rotation.apply(Vec2(100, 150)))
    }

    func testAnImageIsPickedAnywhereInItsFrame() throws {
        let (d, ref) = imageDrawing()
        let shape = try XCTUnwrap(d.shape(ref))
        XCTAssertTrue(shape.contains(Vec2(200, 100), tolerance: 1))
        XCTAssertFalse(shape.contains(Vec2(400, 100), tolerance: 1))
    }

    func testItsCornersCantBeEditedOneByOne() throws {
        var (d, ref) = imageDrawing()
        let before = d
        let idx = try XCTUnwrap(d.indices(layer: ref.layer, shape: ref.shape))
        d.setWorldPath(BezierPath(points: [PathPoint(.zero)], closed: false), at: idx)
        d.updateWorldPath(at: idx) { $0.points[0].position = Vec2(-50, -50) }
        XCTAssertEqual(d, before)

        // Direct Select shows the image as selected but grabs no corner.
        var e = DrawingEditor(drawing: before)
        e.tool = .directSelect
        e.pencilBegan(at: Vec2(100, 50), zoom: 1)
        e.pencilMoved(to: Vec2(80, 30))
        e.pencilEnded(at: Vec2(60, 10))
        XCTAssertEqual(e.drawing.shape(ref)?.path, before.shape(ref)?.path)
    }

    func testAddImageSelectsItWithSelectAsOneUndoStep() throws {
        var e = DrawingEditor()
        e.tool = .pencil
        let ref = try XCTUnwrap(e.addImage(ShapeImage(src: src), size: Vec2(40, 20), center: Vec2(500, 400)))
        XCTAssertEqual(e.tool, .select)
        XCTAssertEqual(e.selection, .shape(layer: ref.layer, shape: ref.shape))
        let shape = try XCTUnwrap(e.drawing.worldShape(ref))
        XCTAssertEqual(shape.image, ShapeImage(src: src))
        XCTAssertEqual(shape.bounds, Rect(minPoint: Vec2(480, 390), maxPoint: Vec2(520, 410)))
        XCTAssertTrue(e.drawing.vertexIDsAreValid, "its corners have ids, so it can animate")
        e.undo()
        XCTAssertEqual(e.drawing.shapeCount, 0)
        XCTAssertNil(e.addImage(ShapeImage(src: src), size: Vec2(0, 20), center: .zero))
    }

    func testOpacityPlaceAndSizeAnimateAndThePictureSwitchesAtTheStart() throws {
        let (d, ref) = imageDrawing()
        var timeline = Timeline(Presentation(opening: d))
        timeline.insertKeyframe(after: 0, transition: Transition(duration: 1, curve: .linear))
        var s = timeline.state(at: 1)
        let i = try XCTUnwrap(s.indices(layer: ref.layer, shape: ref.shape))
        s.layers[i.0].shapes[i.1].opacity = 0
        s.layers[i.0].shapes[i.1].transform = Transform(position: Vec2(100, 0), scale: Vec2(3, 3))
        s.layers[i.0].shapes[i.1].image = ShapeImage(src: "images/fedcba9876543210.jpg")
        timeline.record(s, at: 1)

        let half = timeline.playing(sequence: 0, at: 0.5).scene
        let shape = try XCTUnwrap(half.shape(ref))
        XCTAssertEqual(shape.opacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(shape.transform.position.x, 50, accuracy: 1e-9)
        XCTAssertEqual(shape.transform.scale.x, 2, accuracy: 1e-9)
        XCTAssertEqual(shape.image?.src, "images/fedcba9876543210.jpg")

        // The file says so in its keyframe.
        let json = PresentationFormat.encode(timeline.presentation).formatted()
        XCTAssertTrue(json.contains("\"image.src\": \"images/fedcba9876543210.jpg\""), json)
        XCTAssertEqual(timeline.presentation.imageSources, [src, "images/fedcba9876543210.jpg"])
    }

    func testTheFileRoundTripsAnImageAndRefusesAPathOutsideImages() throws {
        let (d, ref) = imageDrawing()
        let json = PresentationFormat.encode(d)
        guard case .array(let layers)? = json["opening"]?["layers"], case .array(let shapes)? = layers.first?["shapes"]
        else { return XCTFail("no shapes") }
        XCTAssertEqual(shapes[0]["image"], JSONValue.object([(key: "src", value: .string(src))]))
        let back = try PresentationFormat.decode(JSONValue(parsing: json.formatted())).drawing
        XCTAssertEqual(back.shape(ref), d.shape(ref))

        for bad in ["../secret.png", "images/../x.png", "images/a/b.png", "images/..", "photo.png", "images/"] {
            let text = json.formatted().replacingOccurrences(of: src, with: bad)
            XCTAssertThrowsError(try PresentationFormat.decode(JSONValue(parsing: text)), bad)
        }
    }

    func testThePackageSavesTheImagesItShows() throws {
        let (d, _) = imageDrawing()
        let package = PresentationPackage(presentation: Presentation(opening: d),
                                          images: [src: png, "images/unused.png": Data([1])])
        let files = package.files()
        XCTAssertEqual(files[src], png)
        XCTAssertNil(files["images/unused.png"], "only images the presentation shows are saved")
        let back = try PresentationPackage(files: files)
        XCTAssertEqual(back.images, [src: png])
        XCTAssertEqual(ImageAssets.path(for: png), "images/\(ImageAssets.hash(png)).png")
        XCTAssertEqual(ImageAssets.hash(png).count, 16)
        XCTAssertNotEqual(ImageAssets.hash(png), ImageAssets.hash(png + Data([0])))
    }

    func testTheArtCoversTheFrameWithThePicture() throws {
        var (d, ref) = imageDrawing()
        let i = try XCTUnwrap(d.indices(layer: ref.layer, shape: ref.shape))
        d.layers[i.0].shapes[i.1].opacity = 0.5
        var builder = ArtBuilder()
        let batch = builder.build(d, isolatedLayer: nil, tolerance: 0.25)
        let paints = batch.steps.compactMap { step -> ArtPaint? in
            if case .cover(_, let paint, _, _) = step { return paint }
            return nil
        }
        XCTAssertEqual(paints.count, 1)
        let image = try XCTUnwrap(paints.first?.image)
        XCTAssertEqual(image.src, src)
        XCTAssertEqual(paints.first?.opacity, 0.5)
        assertClose(image.worldToImage.apply(Vec2(100, 50)), Vec2(0, 0))
        assertClose(image.worldToImage.apply(Vec2(300, 150)), Vec2(1, 1))
    }

    func testExportsCarryThePicture() throws {
        let (d, _) = imageDrawing()
        let svg = try XCTUnwrap(SVGWriter.document(for: d, area: Rect(minPoint: .zero, maxPoint: Vec2(400, 200)),
                                                   images: [src: png]))
        XCTAssertTrue(svg.contains("xmlns:xlink=\"http://www.w3.org/1999/xlink\""))
        XCTAssertTrue(svg.contains("<image width=\"1\" height=\"1\" preserveAspectRatio=\"none\" " +
            "transform=\"matrix(200 0 0 100 100 50)\" xlink:href=\"data:image/png;base64,\(png.base64EncodedString())\"/>"), svg)
        let linked = try XCTUnwrap(SVGWriter.document(for: d, area: Rect(minPoint: .zero, maxPoint: Vec2(400, 200))))
        XCTAssertTrue(linked.contains("xlink:href=\"\(src)\""))

        let files = try HTMLExport.files(for: Presentation(opening: d), images: [src: png, "images/other.png": png])
        XCTAssertEqual(files[src], png)
        XCTAssertNil(files["images/other.png"])
    }
}
