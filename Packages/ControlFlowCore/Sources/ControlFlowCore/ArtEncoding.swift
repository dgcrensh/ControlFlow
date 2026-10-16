import Foundation

/// The pipeline an art draw uses: stencil-only triangles, a cover painted with an
/// `ArtPaint` (or the veil's color), or a cover painted with an image shape's picture.
public enum ArtPipeline: Hashable, Sendable {
    case stencil, cover, imageCover
}

/// Takes the art pass's GPU commands from `ArtEncoding.encode`: the renderer's side of
/// the art, one Metal call per method. Bindings stay until they are set again, as
/// Metal's do, including across pipeline changes.
public protocol ArtEncoder {
    /// Whether `image`'s picture is ready to sample. When it isn't, its cover paints the
    /// placeholder in its slot of the segment's paint (see `ArtSegment.paintFloats`).
    mutating func hasPicture(_ image: ArtImage) -> Bool
    mutating func setPipeline(_ pipeline: ArtPipeline)
    /// The vertex shader's matrix: `toWorld`, from the vertices' space to the world, then
    /// the camera.
    mutating func setTransform(_ toWorld: Affine2D)
    /// Vertex buffer 0 reads `segment`'s buffer.
    mutating func setVertices(_ segment: ArtSegment)
    /// Vertex buffer 0 reads the view's rectangle (two triangles, in the world).
    mutating func setViewVertices()
    /// The depth-stencil state; nil is no stencil test or writes.
    mutating func setStencil(_ state: StencilState?)
    mutating func setStencilReference(_ reference: UInt8)
    /// Fragment buffer 0 reads paint `slot` of `segment`'s buffer (see
    /// `ArtSegment.paintByteOffset(slot:)`). `rebind` is false when it already reads that
    /// buffer, so only the offset moves.
    mutating func setPaint(_ segment: ArtSegment, slot: Int, rebind: Bool)
    /// Fragment buffer 0 holds `image`'s map and `opacity`, and texture 0 its picture.
    mutating func setImagePaint(_ image: ArtImage, opacity: Double)
    /// Fragment buffer 0 holds the veil's color.
    mutating func setVeilPaint()
    /// Draws `vertices` (counted from the start of the bound vertex buffer) as triangles.
    mutating func draw(_ vertices: Range<Int>)
}

/// Turns an `ArtBatch`'s steps into encoder commands, leaving out each one that would
/// set what is already set: the pipeline, the transform, the vertex buffer, the
/// depth-stencil state, the stencil reference and the paint buffer each change only
/// when a step needs a different one. Stencil and cover steps alternate, so a walk that
/// set everything per step spends most of its calls repeating itself.
public enum ArtEncoding {
    /// Encodes `segments` (with `steps`, their batch's) into `encoder`. Shapes the
    /// `moving` steps mark are drawn through `liveTransform` (see `LiveTransform`).
    /// Assumes nothing about what is bound before, and leaves whatever it last set.
    public static func encode<Encoder: ArtEncoder>(_ steps: [ArtStep], segments: [ArtSegment],
                                                   liveTransform: Affine2D, into encoder: inout Encoder) {
        var state = State()
        for segment in segments {
            var place = Affine2D.identity
            var moving = false
            var slot = 0
            for step in steps[segment.steps] {
                switch step {
                case .stencil(let range, let stencil, let reference):
                    state.pipeline(.stencil, &encoder)
                    state.place(segment, place, moving: moving, live: liveTransform, &encoder)
                    state.stencil(stencil, reference, &encoder)
                    encoder.draw(segment.local(range))

                case .cover(let range, let paint, let stencil, let reference):
                    if let image = paint.image, encoder.hasPicture(image) {
                        state.pipeline(.imageCover, &encoder)
                        encoder.setImagePaint(image, opacity: paint.opacity)
                        state.paint = nil
                    } else {
                        state.pipeline(.cover, &encoder)
                        encoder.setPaint(segment, slot: slot, rebind: state.paint != segment.id)
                        state.paint = segment.id
                    }
                    slot += 1
                    state.place(segment, place, moving: moving, live: liveTransform, &encoder)
                    state.stencil(stencil, reference, &encoder)
                    encoder.draw(segment.local(range))

                case .stencilView(let stencil, let reference):
                    state.pipeline(.stencil, &encoder)
                    state.view(&encoder)
                    state.stencil(stencil, reference, &encoder)
                    encoder.draw(0..<6)

                case .veil:
                    state.pipeline(.cover, &encoder)
                    state.view(&encoder)
                    state.stencil(nil, nil, &encoder)
                    encoder.setVeilPaint()
                    state.paint = nil
                    encoder.draw(0..<6)

                case .moving(let on):
                    moving = on

                case .place(let matrix):
                    place = matrix
                }
            }
        }
    }

    /// What is bound, as far as the walk knows. Nil is unknown or something else.
    private struct State {
        enum Vertices: Equatable {
            case view
            case segment(Int)
        }

        var pipeline: ArtPipeline?
        var transform: Affine2D?
        var vertices: Vertices?
        /// `.some(nil)` is no stencil.
        var stencil: StencilState??
        var reference: UInt8?
        /// The segment whose buffer fragment buffer 0 reads.
        var paint: Int?

        mutating func pipeline<E: ArtEncoder>(_ wanted: ArtPipeline, _ encoder: inout E) {
            guard pipeline != wanted else { return }
            encoder.setPipeline(wanted)
            pipeline = wanted
        }

        /// Binds the segment's vertices through its transform, the place and, while
        /// moving, the live transform.
        mutating func place<E: ArtEncoder>(_ segment: ArtSegment, _ place: Affine2D, moving: Bool, live: Affine2D,
                                           _ encoder: inout E) {
            var toWorld = segment.transform * place
            if moving { toWorld = live * toWorld }
            transform(toWorld, &encoder)
            if vertices != .segment(segment.id) {
                encoder.setVertices(segment)
                vertices = .segment(segment.id)
            }
        }

        mutating func view<E: ArtEncoder>(_ encoder: inout E) {
            transform(.identity, &encoder)
            if vertices != .view {
                encoder.setViewVertices()
                vertices = .view
            }
        }

        mutating func transform<E: ArtEncoder>(_ toWorld: Affine2D, _ encoder: inout E) {
            guard transform != toWorld else { return }
            encoder.setTransform(toWorld)
            transform = toWorld
        }

        /// A nil `reference` leaves the reference as it is (no stencil ignores it).
        mutating func stencil<E: ArtEncoder>(_ wanted: StencilState?, _ wantedReference: UInt8?, _ encoder: inout E) {
            if stencil != .some(wanted) {
                encoder.setStencil(wanted)
                stencil = .some(wanted)
            }
            if let wantedReference, reference != wantedReference {
                encoder.setStencilReference(wantedReference)
                reference = wantedReference
            }
        }
    }
}

extension ArtPaint {
    /// Floats in the cover shader's `Paint` (ShaderSource): color, gradient points
    /// (start x, y, end x, y), info (kind: 0 solid, 1 linear, 2 radial; stop count;
    /// opacity), eight stop colors and eight stop offsets.
    public static let gpuFloatCount = 52

    /// Appends this paint as the cover shader reads it (`gpuFloatCount` floats). An image
    /// shape's paint is its placeholder: `color`.
    public func appendGPUFloats(to floats: inout [Float]) {
        let start = floats.count
        floats.append(contentsOf: [Float(color.r), Float(color.g), Float(color.b), Float(color.a)])
        guard let gradient, !gradient.stops.isEmpty else {
            floats.append(contentsOf: [0, 0, 0, 0, 0, 0, Float(min(max(opacity, 0), 1)), 0])
            floats.append(contentsOf: repeatElement(0, count: start + Self.gpuFloatCount - floats.count))
            return
        }
        let stops = gradient.stops.prefix(ShapeGradient.maxStops)
        floats.append(contentsOf: [Float(gradient.start.x), Float(gradient.start.y),
                                   Float(gradient.end.x), Float(gradient.end.y)])
        floats.append(contentsOf: [gradient.kind == .linear ? 1 : 2, Float(stops.count),
                                   Float(min(max(opacity, 0), 1)), 0])
        for stop in stops {
            floats.append(contentsOf: [Float(stop.color.r), Float(stop.color.g), Float(stop.color.b), Float(stop.color.a)])
        }
        floats.append(contentsOf: repeatElement(0, count: (ShapeGradient.maxStops - stops.count) * 4))
        floats.append(contentsOf: stops.map { Float($0.offset) })
        floats.append(contentsOf: repeatElement(1, count: ShapeGradient.maxStops - stops.count))
    }
}

extension ArtSegment {
    /// Floats per paint slot: 256 bytes, the strictest offset alignment Metal asks of a
    /// constant buffer, which also fits `ArtPaint.gpuFloatCount`.
    public static let paintSlotFloats = 64

    /// Where the paint slots start in the segment's buffer, in floats: after `floats`,
    /// rounded up to a slot.
    public var paintStart: Int {
        (floats.count + Self.paintSlotFloats - 1) / Self.paintSlotFloats * Self.paintSlotFloats
    }

    /// The byte offset of paint `slot` in the segment's buffer.
    public func paintByteOffset(slot: Int) -> Int {
        (paintStart + slot * Self.paintSlotFloats) * MemoryLayout<Float>.stride
    }

    /// What follows `floats` in the segment's buffer: padding up to `paintStart`, then one
    /// slot for each of its cover steps (with `steps`, its batch's), in order. Empty when
    /// it has no covers. A segment with the same id has the same steps, so its paint
    /// stays valid as long as its vertices do.
    public func paintFloats(in steps: [ArtStep]) -> [Float] {
        var covers = 0
        for step in steps[self.steps] {
            if case .cover = step { covers += 1 }
        }
        guard covers > 0 else { return [] }
        var result: [Float] = []
        result.reserveCapacity(paintStart - floats.count + covers * Self.paintSlotFloats)
        result.append(contentsOf: repeatElement(0, count: paintStart - floats.count))
        for step in steps[self.steps] {
            guard case .cover(_, let paint, _, _) = step else { continue }
            let start = result.count
            paint.appendGPUFloats(to: &result)
            result.append(contentsOf: repeatElement(0, count: start + Self.paintSlotFloats - result.count))
        }
        return result
    }
}
