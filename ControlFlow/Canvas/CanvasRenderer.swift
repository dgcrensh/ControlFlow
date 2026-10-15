import ControlFlowCore
import CoreGraphics
import Metal
import QuartzCore
import simd

/// Uniforms shared by every shader. Layout must match `Uniforms` in ShaderSource.
private struct CanvasUniforms {
    var worldToClip: simd_float4x4
    var pixelToWorld: simd_float3x3
    var worldPerPixel: Float
    var gridSpacing: Float
    /// One screen point in world units, for screen-space capsules (the overlay).
    var worldPerPoint: Float
    var padding: Float = 0
    var background: SIMD4<Float>
    var gridColor: SIMD4<Float>
}

/// A solid color or gradient for the cover shader. Layout must match `Paint` in
/// ShaderSource: three float4s, then eight stop colors and eight stop offsets.
private struct PaintUniforms {
    var color: SIMD4<Float>
    var points: SIMD4<Float> = .zero
    var info: SIMD4<Float>
    var stopColors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var stopOffsets: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)

    init(_ paint: ArtPaint) {
        color = Self.vector(paint.color)
        info = SIMD4(0, 0, Float(min(max(paint.opacity, 0), 1)), 0)
        guard let gradient = paint.gradient, !gradient.stops.isEmpty else { return }
        points = SIMD4(Float(gradient.start.x), Float(gradient.start.y), Float(gradient.end.x), Float(gradient.end.y))
        let stops = Array(gradient.stops.prefix(ShapeGradient.maxStops))
        info.x = gradient.kind == .linear ? 1 : 2
        info.y = Float(stops.count)
        var colors = [SIMD4<Float>](repeating: .zero, count: 8)
        var offsets = [Float](repeating: 1, count: 8)
        for (i, stop) in stops.enumerated() {
            colors[i] = Self.vector(stop.color)
            offsets[i] = Float(stop.offset)
        }
        stopColors = (colors[0], colors[1], colors[2], colors[3], colors[4], colors[5], colors[6], colors[7])
        stopOffsets = (SIMD4(offsets[0], offsets[1], offsets[2], offsets[3]),
                       SIMD4(offsets[4], offsets[5], offsets[6], offsets[7]))
    }

    /// A solid color, given in straight alpha.
    init(solid: SIMD4<Float>) {
        color = solid
        info = SIMD4(0, 0, 1, 0)
    }

    static func vector(_ c: RGBAColor) -> SIMD4<Float> {
        SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}

/// Draws the canvas: dot grid, the viewport's background, reference images, the art,
/// the veil that dims everything outside the viewport, the live stroke, then the
/// editing overlay. Hidden shapes are skipped. In isolation the other layers are drawn
/// first under a veil of the background color, then the isolated layer on top. Ghosting
/// fades the shapes outside the selection; the outline view skips the art and the
/// overlay draws every shape as a wireframe instead.
///
/// Rendering is 4x multisampled into memoryless targets and resolved into the
/// drawable. The art is built by ControlFlowCore's `ArtBuilder` as stencil-then-cover
/// steps: fills, outlines (from the stroker, with caps, joins, dashes and varying
/// width), gradients and clipping all mark the stencil and then paint a rectangle
/// where the test passes, and multisampling anti-aliases the edges. Each shape's
/// triangles are cached and rebuilt only when that shape changes. A select-tool drag
/// keeps the art built from the drawing as it began and draws the moved shapes through
/// the drag's transform, so it re-tessellates nothing until the Pencil lifts (see
/// `LiveTransform`). Vertices are in world space and the camera is applied in the vertex shader, so navigation never re-tessellates in a
/// frame: when zoom crosses a power of two, the shapes are re-flattened in a background
/// job, visible ones first, while the current art keeps drawing (see `updateArt`). The
/// first build after opening is such a job too, so the first frame never waits for it.
@MainActor
final class CanvasRenderer {
    private static let sampleCount = 4

    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let strokePipeline: any MTLRenderPipelineState
    private let stencilPipeline: any MTLRenderPipelineState
    private let coverPipeline: any MTLRenderPipelineState
    private let imagePipeline: any MTLRenderPipelineState
    private let gridPipeline: any MTLRenderPipelineState
    private let plainState: any MTLDepthStencilState
    /// Depth-stencil states for the art's steps, made on first use.
    private var stencilStates: [StencilState: any MTLDepthStencilState] = [:]
    private let sampler: any MTLSamplerState
    private let pixelFormat = MTLPixelFormat.bgra8Unorm
    private let stencilFormat = MTLPixelFormat.stencil8
    private weak var layer: CAMetalLayer?

    private var msaaTexture: (any MTLTexture)?
    private var stencilTexture: (any MTLTexture)?

    // Art cache.
    /// Hands over each layer's vertices separately (see `uploadArt`), so it doesn't
    /// concatenate them.
    private var artBuilder: ArtBuilder = {
        var builder = ArtBuilder()
        builder.concatenatesVertices = false
        return builder
    }()
    private var artRevision = -1
    private var artTolerance = 0.0
    private var artIsolation: Int?
    private var artGroupIsolation: Int?
    private var artGhost: Set<Int>?
    /// The live transform (a drag's) the cached art was built for, and its current
    /// transform.
    private var artLive: Int?
    private var liveTransform = Affine2D.identity
    /// The live drag drawn on the last frame, whose triangles move with the shapes when it ends.
    private var lastLive: LiveTransform?
    private var artSteps: [ArtStep] = []
    /// One per layer. Each layer's vertices live in their own buffer, keyed by segment id,
    /// so an edit uploads only the layers it changed. A buffer is never written after it
    /// is made, so a frame still in flight keeps reading the one it was given (the
    /// command buffer retains it).
    private var artSegments: [ArtSegment] = []
    private var artBuffers: [Int: any MTLBuffer] = [:]
    /// The drawing the art was last built from, which a refine merges against.
    private var artDrawing = Drawing()

    // Onion skin: the keyframe before the current one, every shape at the ghost opacity.
    // Built in the frame from its own cache, at the art's tolerance.
    private var onionBuilder: ArtBuilder = {
        var builder = ArtBuilder()
        builder.concatenatesVertices = false
        return builder
    }()
    private var onionKey: (revision: Int, tolerance: Double)?
    private var onionSteps: [ArtStep] = []
    private var onionSegments: [ArtSegment] = []
    private var onionBuffers: [Int: any MTLBuffer] = [:]

    // Background refinement at a new zoom bucket.
    private var refineJob: Task<Void, Never>?
    /// The tolerance the running job flattens at.
    private var refineTolerance: Double?
    /// Bumped for every job, so a cancelled job's late result is ignored.
    private var refineGeneration = 0
    /// Some shapes are refined and the rest still at an older tolerance, because the
    /// job's visible result merged and the rest hasn't (or the job was cancelled).
    private var artMixed = false
    /// A refine merged: rebuild the art from the cache on the next frame.
    private var artRefined = false
    /// From the first frame until a refine's last result merges: the drawing is being
    /// tessellated in the background for the first time, so builds leave out the layers
    /// that aren't ready instead of flattening them in the frame.
    private var artCold = false

    /// Asks the view for a frame; a refine calls it when its result is merged.
    var onNeedsRender: (@MainActor () -> Void)?

    // Vertex buffers reused between frames, and the live strokes' committed segments.
    private let clock = FrameClock()
    private let buffers: VertexBufferPool
    private var liveTessellator = LiveStrokeTessellator()
    private var mirroredTessellator = LiveStrokeTessellator()

    // The overlay's kept layers (the outline view's wireframe and the selection's
    // outlines and anchors), in one pinned buffer uploaded when they change.
    private var overlayCache = OverlayCache()
    private var overlayGeneration = -1
    private var overlayBuffer: VertexBufferPool.Handle?
    private var overlayKept: (wireframe: Range<Int>, selection: Range<Int>) = (0..<0, 0..<0)

    private var textures: [Int: any MTLTexture] = [:]

    /// Supplies the pixels for a reference image id.
    var referenceImage: (@MainActor (Int) -> CGImage?)?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else { return nil }
        self.device = device
        self.queue = queue
        buffers = VertexBufferPool(device: device, clock: clock)

        do {
            let library = try device.makeLibrary(source: ShaderSource.metal, options: nil)

            func descriptor(_ label: String, vertex: String, fragment: String?) -> MTLRenderPipelineDescriptor {
                let d = MTLRenderPipelineDescriptor()
                d.label = label
                d.vertexFunction = library.makeFunction(name: vertex)
                d.fragmentFunction = fragment.flatMap { library.makeFunction(name: $0) }
                d.rasterSampleCount = Self.sampleCount
                d.colorAttachments[0].pixelFormat = .bgra8Unorm
                d.stencilAttachmentPixelFormat = .stencil8
                return d
            }
            func premultipliedBlending(_ d: MTLRenderPipelineDescriptor) {
                let attachment = d.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }

            let stroke = descriptor("Stroke", vertex: "stroke_vertex", fragment: "stroke_fragment")
            premultipliedBlending(stroke)
            strokePipeline = try device.makeRenderPipelineState(descriptor: stroke)

            let stencil = descriptor("Art stencil", vertex: "fill_vertex", fragment: "stencil_fragment")
            stencil.colorAttachments[0].writeMask = []
            stencilPipeline = try device.makeRenderPipelineState(descriptor: stencil)

            let cover = descriptor("Art cover", vertex: "fill_vertex", fragment: "fill_fragment")
            premultipliedBlending(cover)
            coverPipeline = try device.makeRenderPipelineState(descriptor: cover)

            let image = descriptor("Reference image", vertex: "image_vertex", fragment: "image_fragment")
            premultipliedBlending(image)
            imagePipeline = try device.makeRenderPipelineState(descriptor: image)

            let grid = descriptor("Grid", vertex: "grid_vertex", fragment: "grid_fragment")
            gridPipeline = try device.makeRenderPipelineState(descriptor: grid)
        } catch {
            assertionFailure("Canvas shaders failed to build: \(error)")
            return nil
        }

        let plain = MTLDepthStencilDescriptor()
        plain.label = "No stencil"

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        guard let plainState = device.makeDepthStencilState(descriptor: plain),
              let sampler = device.makeSamplerState(descriptor: samplerDescriptor)
        else { return nil }
        self.plainState = plainState
        self.sampler = sampler
    }

    func attach(to layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = pixelFormat
        layer.framebufferOnly = true
        // Two drawables instead of three trims a frame of latency; the scene is light.
        layer.maximumDrawableCount = 2
        layer.presentsWithTransaction = false
        self.layer = layer
    }

    /// Draws one frame. Returns false when the system had no drawable to give (it
    /// does that under load), so the caller draws again instead of leaving the last
    /// edit, such as a released anchor drag, undrawn until the next touch.
    ///
    /// When `presenting`, only the viewport's art shows, letterboxed in black: no
    /// references, onion skin or overlay.
    @discardableResult
    func render(session: CanvasSession, viewSize: CGSize, scale: CGFloat, darkMode: Bool, presenting: Bool = false) -> Bool {
        guard let layer, viewSize.width > 0, viewSize.height > 0 else { return true }
        let frameInterval = Signposts.canvas.beginInterval("Frame")
        defer { Signposts.canvas.endInterval("Frame", frameInterval) }
        // Waiting here means the GPU or the display still holds both drawables.
        let next = Signposts.canvas.withIntervalSignpost("Next drawable") { layer.nextDrawable() }
        guard let drawable = next, let commandBuffer = queue.makeCommandBuffer() else {
            Signposts.canvas.emitEvent("No drawable")
            return false
        }
        let frame = clock.beginFrame()
        let clock = clock
        commandBuffer.addCompletedHandler { buffer in
            clock.complete(frame)
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Signposts.canvas.emitEvent("GPU frame", "\(ms, format: .fixed(precision: 2)) ms")
        }

        ensureTargets(width: drawable.texture.width, height: drawable.texture.height)
        guard let msaaTexture, let stencilTexture else { return true }

        let editor = session.editor
        let w = Double(viewSize.width), h = Double(viewSize.height)
        let screen = [Vec2(0, 0), Vec2(w, 0), Vec2(w, h), Vec2(0, h)].map { session.camera.toWorld($0) }
        // The outline view draws the art as a wireframe in the overlay instead.
        if !editor.outlineView {
            updateArt(editor: editor, zoom: session.camera.zoom, navigating: session.isNavigating,
                      viewRect: Rect(points: screen))
        }
        // A preview (scrubbing or playing) shows its scene in place of the drawing.
        let shown = editor.shownDrawing
        loadMissingTextures(for: shown.references, commandBuffer: commandBuffer)

        var uniforms = makeUniforms(camera: session.camera, viewSize: viewSize, scale: scale, darkMode: darkMode)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTexture
        pass.colorAttachments[0].resolveTexture = drawable.texture
        pass.colorAttachments[0].loadAction = .dontCare // the grid covers every pixel
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.stencilAttachment.texture = stencilTexture
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let encodeInterval = Signposts.canvas.beginInterval("Encode")
        encoder.setDepthStencilState(plainState)

        encoder.setRenderPipelineState(gridPipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        let viewport = shown.viewport
        let stage = viewport.bounds.corners
        drawSolid([stage[0], stage[1], stage[2], stage[0], stage[2], stage[3]],
                  color: PaintUniforms.vector(viewport.background), encoder: encoder, uniforms: &uniforms)
        if !presenting { drawReferences(of: shown, encoder: encoder, uniforms: &uniforms) }
        if !editor.outlineView {
            if !presenting, editor.preview == nil, let onion = editor.onionSkin {
                updateOnion(onion, revision: editor.onionRevision)
                Signposts.canvas.withIntervalSignpost("Onion draw") {
                    drawArt(onionSteps, segments: onionSegments, buffers: onionBuffers, encoder: encoder, uniforms: &uniforms,
                            viewRect: Rect(points: screen))
                }
            } else if editor.onionSkin == nil, onionKey != nil {
                // Turned off; during a preview it is only hidden.
                releaseOnion()
            }
            Signposts.canvas.withIntervalSignpost("Art draw") {
                drawArt(artSteps, segments: artSegments, buffers: artBuffers, encoder: encoder, uniforms: &uniforms,
                        viewRect: Rect(points: screen))
            }
        }
        // Everything outside the viewport is dimmed toward the canvas background, or
        // black when presenting.
        let bg = uniforms.background
        drawSolid(viewport.veilTriangles(covering: Rect(points: screen)),
                  color: presenting ? SIMD4<Float>(0, 0, 0, 1) : SIMD4(bg.x, bg.y, bg.z, Self.veilOpacity),
                  encoder: encoder, uniforms: &uniforms)
        if presenting {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            Signposts.canvas.endInterval("Encode", encodeInterval)
            return true
        }

        // The live strokes keep their committed segments and add only what is new. The
        // overlay keeps its costly layers until what they show changes and builds the
        // rest every frame.
        encoder.setDepthStencilState(plainState)
        encoder.setRenderPipelineState(strokePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        if session.liveStroke != nil {
            let interval = Signposts.canvas.beginInterval("Live stroke")
            if let live = session.liveStroke {
                let tail = liveTessellator.update(for: live)
                drawCapsules(liveTessellator.committed, tail, encoder: encoder)
            }
            if let mirrored = session.mirroredLiveStroke {
                let tail = mirroredTessellator.update(for: mirrored)
                drawCapsules(mirroredTessellator.committed, tail, encoder: encoder)
            }
            Signposts.canvas.endInterval("Live stroke", interval)
        }
        let overlay = Signposts.canvas.withIntervalSignpost("Overlay build") {
            EditorOverlay.layers(for: editor, zoom: session.camera.zoom, viewRect: Rect(points: screen),
                                 darkMode: darkMode, cache: &overlayCache)
        }
        if overlayCache.generation != overlayGeneration {
            overlayGeneration = overlayCache.generation
            if let overlayBuffer { buffers.release(overlayBuffer) }
            overlayBuffer = buffers.upload([overlay.wireframe, overlay.selection], pin: true)
            let wire = overlay.wireframe.count
            overlayKept = (0..<wire, wire..<(wire + overlay.selection.count))
        }
        drawKeptOverlay(overlayKept.wireframe, encoder: encoder)
        drawCapsules(overlay.guides, encoder: encoder)
        drawKeptOverlay(overlayKept.selection, encoder: encoder)
        drawCapsules(overlay.top, encoder: encoder)

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        Signposts.canvas.endInterval("Encode", encodeInterval)
        return true
    }

    // MARK: Targets

    private func ensureTargets(width: Int, height: Int) {
        if let msaaTexture, msaaTexture.width == width, msaaTexture.height == height { return }
        Signposts.canvas.emitEvent("Render targets", "\(width) x \(height)")
        #if targetEnvironment(simulator)
        let storage = MTLStorageMode.private
        #else
        let storage = MTLStorageMode.memoryless
        #endif

        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        color.textureType = .type2DMultisample
        color.sampleCount = Self.sampleCount
        color.usage = .renderTarget
        color.storageMode = storage
        msaaTexture = device.makeTexture(descriptor: color)

        let stencil = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: stencilFormat, width: width, height: height, mipmapped: false)
        stencil.textureType = .type2DMultisample
        stencil.sampleCount = Self.sampleCount
        stencil.usage = .renderTarget
        stencil.storageMode = storage
        stencilTexture = device.makeTexture(descriptor: stencil)
    }

    // MARK: Art

    /// Rebuilds the art when the drawing, isolation or ghost focus changed, or when a
    /// background refine merged. During a drag that `LiveTransform` can draw, it builds
    /// the base drawing once and then only updates the transform.
    ///
    /// The art is flattened finely enough for the zoom, in power-of-two buckets. A new
    /// bucket never re-tessellates in the frame (see `scheduleRefine`).
    private func updateArt(editor: DrawingEditor, zoom: Double, navigating: Bool, viewRect: Rect) {
        let bucket = pow(2, ceil(log2(max(zoom, 1.0 / 64))))
        let wanted = 0.2 / bucket
        let live = editor.liveTransform.flatMap { $0.movesTessellation ? $0 : nil }
        let drawing = live?.base ?? editor.shownDrawing
        // A live drag just ended: carry the moved shapes' triangles to where they landed
        // rather than flattening them again. Enlarged ones are coarse until a refine.
        if live == nil, let ended = lastLive {
            let carry = Signposts.canvas.withIntervalSignpost("Art carry", "\(ended.shapes.count) shapes") {
                artBuilder.carry(ended, to: editor.drawing)
            }
            if carry.coarse > 0 {
                cancelRefine()
                artMixed = true
            }
        }
        lastLive = live
        // The first frame shows the references and an empty canvas at once: a refine job
        // flattens the drawing, the layers in view first, and each layer shows as it merges.
        if artTolerance == 0 {
            artTolerance = wanted
            artCold = true
            artMixed = true
        }
        scheduleRefine(to: wanted, drawing: drawing, navigating: navigating, viewRect: viewRect)

        let ghost = editor.ghostFocus
        liveTransform = live?.transform ?? .identity
        let current = live.map { artLive == $0.id } ?? (artLive == nil && editor.displayRevision == artRevision)
        guard !current || artRefined ||
            editor.isolatedLayer != artIsolation || editor.isolatedGroup != artGroupIsolation || ghost != artGhost
        else { return }
        // Why, for the signpost.
        let reason = artCold ? "open" : !current ? (live != nil ? "drag" : "edit") : artRefined ? "refine" : "focus"
        // A live build stands for no revision, so the drawing is rebuilt when the drag ends.
        artRevision = live == nil ? editor.displayRevision : -1
        artLive = live?.id
        artIsolation = editor.isolatedLayer
        artGroupIsolation = editor.isolatedGroup
        artGhost = ghost
        artRefined = false
        artDrawing = drawing
        let interval = Signposts.canvas.beginInterval("Art rebuild")
        defer { Signposts.canvas.endInterval("Art rebuild", interval, "\(reason, privacy: .public)") }
        // While a refine is under way, unchanged shapes keep whatever tessellation they
        // have; only new and edited ones are tessellated, at the art's tolerance. Until
        // the first refine is done, layers with a shape not yet tessellated wait for it.
        let batch = artBuilder.build(drawing, isolatedLayer: editor.isolatedLayer, isolatedGroup: editor.isolatedGroup,
                                     tolerance: artTolerance, ghostFocus: ghost, moving: live?.shapes ?? [],
                                     reusingOtherTolerances: refineJob != nil || artMixed, leavingOutUncached: artCold)
        uploadArt(batch)
    }

    /// Keeps the buffers of layers that didn't change and makes one for each layer that did.
    private func uploadArt(_ batch: ArtBatch) {
        artSteps = batch.steps
        artSegments = batch.segments
        artBuffers = upload(batch, keeping: artBuffers)
    }

    /// The buffers for `batch`'s layers: those in `buffers` it still uses, and a new one
    /// for each layer that changed.
    private func upload(_ batch: ArtBatch, keeping buffers: [Int: any MTLBuffer]) -> [Int: any MTLBuffer] {
        let interval = Signposts.canvas.beginInterval("Art upload")
        var floats = 0
        defer { Signposts.canvas.endInterval("Art upload", interval, "\(floats) floats") }
        var kept: [Int: any MTLBuffer] = [:]
        for id in batch.residentIDs { kept[id] = buffers[id] }
        for segment in batch.segmentsToUpload(resident: Set(kept.keys)) {
            floats += segment.floats.count
            kept[segment.id] = segment.floats.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
        }
        return kept
    }

    /// Builds the onion skin when it or the art's tolerance changed: every shape faded to
    /// the ghost opacity, as the ghost view draws shapes outside its focus.
    private func updateOnion(_ onion: Drawing, revision: Int) {
        guard onionKey?.revision != revision || onionKey?.tolerance != artTolerance, artTolerance > 0 else { return }
        onionKey = (revision, artTolerance)
        let batch = Signposts.canvas.withIntervalSignpost("Onion rebuild") {
            onionBuilder.build(onion, isolatedLayer: nil, tolerance: artTolerance, ghostFocus: [])
        }
        onionSteps = batch.steps
        onionSegments = batch.segments
        onionBuffers = upload(batch, keeping: onionBuffers)
    }

    /// Drops the onion skin's art and its cache once it is turned off.
    private func releaseOnion() {
        onionKey = nil
        onionSteps = []
        onionSegments = []
        onionBuffers = [:]
        onionBuilder = ArtBuilder()
        onionBuilder.concatenatesVertices = false
    }

    /// Moves the art toward `wanted`, the zoom bucket's tolerance, without stalling a frame.
    ///
    /// - Zooming out during a two-finger gesture changes nothing: the finer art looks the
    ///   same and only costs vertices. The coarser tolerance follows once the gesture ends.
    /// - Otherwise a detached job flattens the shapes at `wanted` from a copy of the
    ///   cache, those in view (plus a quarter-screen margin) first, and the main actor
    ///   merges each result and rebuilds from the cache. Shapes cached at `wanted` in
    ///   either tier are skipped, so returning to the last bucket costs one warm build.
    /// - A newer bucket cancels the running job.
    /// - The first job, after opening, flattens every shape. Its first result is every
    ///   layer with a shape in view, whole, and a zoom-out mid-gesture doesn't drop it.
    private func scheduleRefine(to wanted: Double, drawing: Drawing, navigating: Bool, viewRect: Rect) {
        // Where the art is headed: the running job's tolerance, or the art's own once
        // every shape is at it.
        let target = refineTolerance ?? (artMixed ? nil : artTolerance)
        guard wanted != target else { return }
        // Back at the art's own tolerance, or zooming out mid-gesture: drop the job.
        if wanted == artTolerance && !artMixed || navigating && wanted > artTolerance && !artCold {
            cancelRefine()
            return
        }
        cancelRefine()
        refineTolerance = wanted
        refineGeneration += 1
        let generation = refineGeneration
        let cache = artBuilder.tessellations
        let wholeLayers = artCold
        refineJob = Task.detached(priority: .userInitiated) { [weak self] in
            let interval = Signposts.canvas.beginInterval("Art refine")
            var made = 0
            defer { Signposts.canvas.endInterval("Art refine", interval, "\(made) shapes") }
            let plan = cache.refinePlan(for: drawing, tolerance: wanted, viewRect: viewRect, wholeLayers: wholeLayers)
            // An empty first result has nothing to show early.
            if !plan.visible.isEmpty {
                guard let visible = TessellationCache.tessellate(plan.visible, tolerance: wanted,
                                                                 isCancelled: { Task.isCancelled })
                else { return }
                made += visible.count
                await self?.mergeRefinement(visible, final: false, generation: generation)
            }
            guard let rest = TessellationCache.tessellate(plan.rest, tolerance: wanted, isCancelled: { Task.isCancelled })
            else { return }
            made += rest.count
            await self?.mergeRefinement(rest, final: true, generation: generation)
        }
    }

    private func cancelRefine() {
        refineJob?.cancel()
        refineJob = nil
        refineTolerance = nil
    }

    /// Takes a refine's result into the cache and asks for a frame, which rebuilds the
    /// art at the job's tolerance (`reason` "refine"). After the first result the art is
    /// mixed: shapes off screen keep their old tessellation until the rest arrives.
    private func mergeRefinement(_ result: TessellationCache.Refinement, final: Bool, generation: Int) {
        guard generation == refineGeneration, refineJob != nil else { return }
        _ = Signposts.canvas.withIntervalSignpost("Art merge", "\(result.count) shapes") {
            artBuilder.tessellations.merge(result, for: artDrawing)
        }
        artTolerance = result.tolerance
        artMixed = !final
        artRefined = true
        if final {
            refineJob = nil
            refineTolerance = nil
            artCold = false
        }
        onNeedsRender?()
    }

    private func drawArt(_ steps: [ArtStep], segments: [ArtSegment], buffers: [Int: any MTLBuffer],
                         encoder: any MTLRenderCommandEncoder, uniforms: inout CanvasUniforms, viewRect: Rect) {
        guard !steps.isEmpty else { return }
        var view: [Float] = []
        let corners = viewRect.corners
        for i in [0, 1, 2, 0, 2, 3] {
            view.append(Float(corners[i].x))
            view.append(Float(corners[i].y))
        }
        // Shapes a drag moves draw through its transform, applied before the camera.
        var moved = uniforms
        moved.worldToClip = uniforms.worldToClip * liveTransform.matrix4x4
        var moving = false
        enum Bound { case none, stencil, cover }
        var bound = Bound.none
        var layerBuffer: (any MTLBuffer)?
        func bind(_ pipeline: any MTLRenderPipelineState, as kind: Bound) {
            guard bound != kind else { return }
            encoder.setRenderPipelineState(pipeline)
            if moving {
                encoder.setVertexBytes(&moved, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
            } else {
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
            }
            if let layerBuffer { encoder.setVertexBuffer(layerBuffer, offset: 0, index: 0) }
            bound = kind
        }

        for segment in segments {
            // Each layer's ranges count from the start of its own buffer.
            layerBuffer = buffers[segment.id]
            bound = .none
            for step in steps[segment.steps] {
                switch step {
                case .stencil(let range, let state, let reference):
                    bind(stencilPipeline, as: .stencil)
                    encoder.setDepthStencilState(depthStencilState(state))
                    encoder.setStencilReferenceValue(UInt32(reference))
                    let local = segment.local(range)
                    encoder.drawPrimitives(type: .triangle, vertexStart: local.lowerBound, vertexCount: local.count)

                case .cover(let range, let paint, let state, let reference):
                    bind(coverPipeline, as: .cover)
                    var paintUniforms = PaintUniforms(paint)
                    encoder.setDepthStencilState(depthStencilState(state))
                    encoder.setStencilReferenceValue(UInt32(reference))
                    encoder.setFragmentBytes(&paintUniforms, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                    let local = segment.local(range)
                    encoder.drawPrimitives(type: .triangle, vertexStart: local.lowerBound, vertexCount: local.count)

                case .stencilView(let state, let reference):
                    encoder.setRenderPipelineState(stencilPipeline)
                    encoder.setVertexBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                    encoder.setDepthStencilState(depthStencilState(state))
                    encoder.setStencilReferenceValue(UInt32(reference))
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    bound = .none

                case .veil:
                    let bg = uniforms.background
                    var paint = PaintUniforms(solid: SIMD4(bg.x, bg.y, bg.z, 0.7))
                    encoder.setRenderPipelineState(coverPipeline)
                    encoder.setDepthStencilState(plainState)
                    encoder.setVertexBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 0)
                    encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
                    encoder.setFragmentBytes(&paint, length: MemoryLayout<PaintUniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    bound = .none

                case .moving(let on):
                    moving = on
                    bound = .none
                }
            }
        }
    }

    /// The Metal state for a stencil configuration from the art pass.
    private func depthStencilState(_ state: StencilState) -> any MTLDepthStencilState {
        if let cached = stencilStates[state] { return cached }
        func face(_ pass: StencilOperation) -> MTLStencilDescriptor {
            let d = MTLStencilDescriptor()
            d.stencilCompareFunction = switch state.compare {
            case .always: .always
            case .equal: .equal
            case .notEqual: .notEqual
            case .less: .less
            }
            d.stencilFailureOperation = CanvasRenderer.operation(state.fail)
            d.depthFailureOperation = .keep
            d.depthStencilPassOperation = CanvasRenderer.operation(pass)
            d.readMask = UInt32(state.readMask)
            d.writeMask = UInt32(state.writeMask)
            return d
        }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.frontFaceStencil = face(state.pass)
        descriptor.backFaceStencil = face(state.backPass)
        let made = device.makeDepthStencilState(descriptor: descriptor) ?? plainState
        stencilStates[state] = made
        return made
    }

    private static func operation(_ op: StencilOperation) -> MTLStencilOperation {
        switch op {
        case .keep: .keep
        case .zero: .zero
        case .replace: .replace
        case .incrementWrap: .incrementWrap
        case .decrementWrap: .decrementWrap
        }
    }

    /// The veil's strength over art outside the viewport.
    private static let veilOpacity: Float = 0.5

    /// Fills `triangles` (world space, three corners each) with `color` (straight alpha).
    private func drawSolid(_ triangles: [Vec2], color: SIMD4<Float>, encoder: any MTLRenderCommandEncoder,
                           uniforms: inout CanvasUniforms) {
        guard !triangles.isEmpty else { return }
        let floats = triangles.flatMap { [Float($0.x), Float($0.y)] }
        var paint = PaintUniforms(solid: color)
        encoder.setRenderPipelineState(coverPipeline)
        encoder.setDepthStencilState(plainState)
        encoder.setVertexBytes(floats, length: floats.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&paint, length: MemoryLayout<PaintUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)
    }

    /// Draws `chunks` of capsule vertices, one after another, from a pooled buffer.
    private func drawCapsules(_ chunks: [Float]..., encoder: any MTLRenderCommandEncoder) {
        let count = chunks.reduce(0) { $0 + $1.count }
        guard count > 0 else { return }
        if count * MemoryLayout<Float>.stride <= 4096 {
            // Small enough for Metal to copy into the command buffer itself.
            let floats = chunks.count == 1 ? chunks[0] : chunks.flatMap { $0 }
            encoder.setVertexBytes(floats, length: count * MemoryLayout<Float>.stride, index: 0)
        } else {
            guard let handle = buffers.upload(chunks) else { return }
            encoder.setVertexBuffer(handle.buffer, offset: 0, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: count / CapsuleTessellator.floatsPerVertex)
    }

    /// Draws `floats` of the kept overlay buffer.
    private func drawKeptOverlay(_ floats: Range<Int>, encoder: any MTLRenderCommandEncoder) {
        guard let overlayBuffer, !floats.isEmpty else { return }
        buffers.use(overlayBuffer)
        encoder.setVertexBuffer(overlayBuffer.buffer, offset: floats.lowerBound * MemoryLayout<Float>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: floats.count / CapsuleTessellator.floatsPerVertex)
    }

    // MARK: Reference images

    /// Draws the drawing's shown reference images.
    private func drawReferences(of drawing: Drawing, encoder: any MTLRenderCommandEncoder,
                                uniforms: inout CanvasUniforms) {
        let visible = drawing.references.filter { !$0.isHidden && $0.opacity > 0 && textures[$0.id] != nil }
        guard !visible.isEmpty else { return }
        encoder.setRenderPipelineState(imagePipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for ref in visible {
            guard let texture = textures[ref.id] else { continue }
            let c = ref.corners
            let uv = [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1), Vec2(0, 1)]
            var floats: [Float] = []
            for i in [0, 1, 2, 0, 2, 3] {
                floats += [Float(c[i].x), Float(c[i].y), Float(uv[i].x), Float(uv[i].y)]
            }
            var opacity = Float(ref.opacity)
            encoder.setVertexBytes(floats, length: floats.count * MemoryLayout<Float>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func loadMissingTextures(for references: [ReferenceImage], commandBuffer: any MTLCommandBuffer) {
        for ref in references where textures[ref.id] == nil {
            let interval = Signposts.canvas.beginInterval("Reference texture")
            defer { Signposts.canvas.endInterval("Reference texture", interval) }
            guard let image = referenceImage?(ref.id), let texture = makeTexture(image, commandBuffer: commandBuffer) else { continue }
            textures[ref.id] = texture
        }
    }

    /// Uploads a CGImage as premultiplied RGBA with mipmaps, so it stays smooth when zoomed out.
    private func makeTexture(_ image: CGImage, commandBuffer: any MTLCommandBuffer) -> (any MTLTexture)? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        if texture.mipmapLevelCount > 1, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
        return texture
    }

    // MARK: Uniforms

    private func makeUniforms(camera: CanvasCamera, viewSize: CGSize, scale: CGFloat, darkMode: Bool) -> CanvasUniforms {
        let w = Double(viewSize.width), h = Double(viewSize.height), s = Double(scale)

        // Screen points to clip space: x right, y up, both -1...1.
        let screenToClip = Affine2D(a: 2 / w, b: 0, c: 0, d: -2 / h, tx: -1, ty: 1)
        let worldToClip = screenToClip * camera.worldToScreen
        let pixelToWorld = camera.screenToWorld * Affine2D.scale(1 / s)

        // Pick a power-of-two grid spacing that keeps dots 24-48 points apart on screen.
        var spacing = 32.0
        let zoom = camera.zoom
        while spacing * zoom < 24 { spacing *= 2 }
        while spacing * zoom >= 48 { spacing /= 2 }

        let background: SIMD4<Float> = darkMode ? [0.11, 0.11, 0.12, 1] : [0.98, 0.98, 0.97, 1]
        let gridColor: SIMD4<Float> = darkMode ? [0.35, 0.35, 0.38, 1] : [0.78, 0.78, 0.80, 1]

        return CanvasUniforms(
            worldToClip: worldToClip.matrix4x4,
            pixelToWorld: pixelToWorld.matrix3x3,
            worldPerPixel: Float(1 / (zoom * s)),
            gridSpacing: Float(spacing),
            worldPerPoint: Float(1 / zoom),
            background: background,
            gridColor: gridColor
        )
    }
}

private extension Affine2D {
    var matrix4x4: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(Float(a), Float(b), 0, 0),
            SIMD4<Float>(Float(c), Float(d), 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(Float(tx), Float(ty), 0, 1)
        ))
    }

    var matrix3x3: simd_float3x3 {
        simd_float3x3(columns: (
            SIMD3<Float>(Float(a), Float(b), 0),
            SIMD3<Float>(Float(c), Float(d), 0),
            SIMD3<Float>(Float(tx), Float(ty), 1)
        ))
    }
}
