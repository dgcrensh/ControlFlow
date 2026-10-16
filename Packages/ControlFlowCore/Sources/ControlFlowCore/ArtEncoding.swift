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
    /// Fragment buffer 0 reads paint `slot` of `segment`'s paint buffer, the one for its
    /// `paintID` (see `ArtSegment.paintByteOffset(slot:)`). `rebind` is false when it
    /// already reads that buffer, so only the offset moves.
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
                        encoder.setPaint(segment, slot: slot, rebind: state.paint != segment.paintID)
                        state.paint = segment.paintID
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
        /// The paint id whose buffer fragment buffer 0 reads.
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
        floats.append(contentsOf: repeatElement(0, count: Self.gpuFloatCount))
        floats.withUnsafeMutableBufferPointer { writeGPUFloats(to: $0.baseAddress! + start) }
    }

    /// Writes this paint as the cover shader reads it into the `gpuFloatCount` floats at
    /// `target`, which hold zeros.
    func writeGPUFloats(to target: UnsafeMutablePointer<Float>) {
        target[0] = Float(color.r)
        target[1] = Float(color.g)
        target[2] = Float(color.b)
        target[3] = Float(color.a)
        target[10] = Float(min(max(opacity, 0), 1))
        guard let gradient, !gradient.stops.isEmpty else { return }
        let stops = gradient.stops.prefix(ShapeGradient.maxStops)
        target[4] = Float(gradient.start.x)
        target[5] = Float(gradient.start.y)
        target[6] = Float(gradient.end.x)
        target[7] = Float(gradient.end.y)
        target[8] = gradient.kind == .linear ? 1 : 2
        target[9] = Float(stops.count)
        for slot in 0..<ShapeGradient.maxStops {
            guard slot < stops.count else {
                target[44 + slot] = 1
                continue
            }
            let stop = stops[stops.startIndex + slot]
            target[12 + slot * 4] = Float(stop.color.r)
            target[13 + slot * 4] = Float(stop.color.g)
            target[14 + slot * 4] = Float(stop.color.b)
            target[15 + slot * 4] = Float(stop.color.a)
            target[44 + slot] = Float(stop.offset)
        }
    }
}

extension ArtSegment {
    /// Floats per paint slot: 256 bytes, the strictest offset alignment Metal asks of a
    /// constant buffer, which also fits `ArtPaint.gpuFloatCount`.
    public static let paintSlotFloats = 64

    /// The byte offset of paint `slot` in the segment's paint buffer.
    public func paintByteOffset(slot: Int) -> Int {
        slot * Self.paintSlotFloats * MemoryLayout<Float>.stride
    }

    /// How many cover steps the segment has (with `steps`, its batch's).
    public func coverCount(in steps: [ArtStep]) -> Int {
        var covers = 0
        for step in steps[self.steps] {
            if case .cover = step { covers += 1 }
        }
        return covers
    }

    /// The segment's paint buffer, kept by `paintID` apart from its vertices so a change
    /// of paint alone uploads only this: one slot for each of its cover steps (with
    /// `steps`, its batch's), in order. Empty when it has no covers.
    public func paintFloats(in steps: [ArtStep]) -> [Float] {
        var result = [Float](repeating: 0, count: coverCount(in: steps) * Self.paintSlotFloats)
        result.withUnsafeMutableBufferPointer { floats in
            var slot = 0
            for step in steps[self.steps] {
                guard case .cover(_, let paint, _, _) = step else { continue }
                paint.writeGPUFloats(to: floats.baseAddress! + slot * Self.paintSlotFloats)
                slot += 1
            }
        }
        return result
    }
}
