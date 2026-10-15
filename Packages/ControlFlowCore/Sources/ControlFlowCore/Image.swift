import Foundation

/// The picture an image shape shows (see `VectorShape.image`): an encoded image (PNG,
/// JPEG or HEIC) stored in the document package at `src`.
public struct ShapeImage: Hashable, Sendable, Codable {
    /// The package-relative path of the image's file, such as `images/0f3c9a2be1d47a65.png`.
    public var src: String

    public init(src: String) {
        self.src = src
    }
}

/// Where image shapes keep their pixels: files in the package's `images/` folder, named
/// by a hash of their bytes, so a picture inserted or pasted twice is stored once and a
/// name always means the same pixels (in any document).
public enum ImageAssets {
    public static let folder = "images"

    /// The package path for an image's encoded bytes.
    public static func path(for data: Data) -> String {
        "\(folder)/\(hash(data)).\(PresentationPackage.fileExtension(for: data))"
    }

    /// True for a path a file may give as an image's `src`: a file directly in `images/`,
    /// so a file can't name anything outside the package's images.
    public static func isValidSource(_ src: String) -> Bool {
        guard src.hasPrefix(folder + "/") else { return false }
        let name = src.dropFirst(folder.count + 1)
        return !name.isEmpty && !name.contains("/") && !name.contains("\\") && name != "." && name != ".."
    }

    /// FNV-1a, 64 bits, as 16 hex digits: stable everywhere, unlike `Hasher`.
    static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            h ^= UInt64(byte)
            h = h &* 0x0000_0100_0000_01B3
        }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

extension VectorShape {
    /// An image shape showing `image` over the rectangle from `origin` to `origin + size`
    /// (top-left to bottom-right), its four corners the path's points.
    public init(id: Int, image: ShapeImage, origin: Vec2 = .zero, size: Vec2) {
        let corners = [origin, origin + Vec2(size.x, 0), origin + size, origin + Vec2(0, size.y)]
        self.init(id: id, path: BezierPath(points: corners.map { PathPoint($0, smooth: false) }, closed: true))
        self.image = image
    }

    public var isImage: Bool { image != nil }

    /// False for a text or an image, whose path isn't edited point by point: a text's
    /// is laid out from its words and an image's is the frame it is drawn in.
    public var hasEditablePath: Bool { text == nil && image == nil }

    /// For an image shape, the map from the image's own unit square (x across, y down,
    /// 0...1) to where it is drawn: its top-left, top-right and bottom-left corners are
    /// the path's first, second and fourth points. Transforms keep those corners a
    /// parallelogram, so the image stays a parallelogram too. Nil when the corners don't
    /// span an area. A path without four points (only from a hand-written file) shows
    /// the image over its bounds.
    public var imagePlacement: Affine2D? {
        guard image != nil else { return nil }
        let origin: Vec2, across: Vec2, down: Vec2
        let points = path.points
        if points.count >= 4 {
            origin = points[0].position
            across = points[1].position - origin
            down = points[3].position - origin
        } else {
            let box = path.bounds()
            guard !box.isNull else { return nil }
            origin = box.minPoint
            across = Vec2(box.width, 0)
            down = Vec2(0, box.height)
        }
        let m = Affine2D(a: across.x, b: across.y, c: down.x, d: down.y, tx: origin.x, ty: origin.y)
        guard abs(m.determinant) > 1e-12 else { return nil }
        return m
    }
}

extension Drawing {
    /// The `src` of every image shape.
    public var imageSources: Set<String> {
        var out: Set<String> = []
        for layer in layers {
            for shape in layer.shapes { if let src = shape.image?.src { out.insert(src) } }
        }
        return out
    }
}

extension Presentation {
    /// The `src` of every image the presentation shows at any keyframe: those in the
    /// opening state, and those keyframes create or set.
    public var imageSources: Set<String> {
        var out = opening.imageSources
        for sequence in sequences {
            for keyframe in sequence.keyframes {
                for change in keyframe.changes {
                    switch change {
                    case .create(.layer(let layer), _, _, _, _):
                        for shape in layer.shapes { if let src = shape.image?.src { out.insert(src) } }
                    case .create(.shape(let shape), _, _, _, _):
                        if let src = shape.image?.src { out.insert(src) }
                    case .set(_, let props):
                        for prop in props {
                            if prop.key == "image.src", case .string(let src) = prop.value { out.insert(src) }
                            if prop.key == "image", case .string(let src)? = prop.value["src"] { out.insert(src) }
                        }
                    case .create, .delete, .order:
                        break
                    }
                }
            }
        }
        return out
    }
}
