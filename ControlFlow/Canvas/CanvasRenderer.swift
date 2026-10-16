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

/// A solid color for the cover shader, for the draws outside the art (the stage, the
/// veils). Layout must match `Paint` in ShaderSource: three float4s, then eight stop
/// colors and eight stop offsets. The art's paints are written into each layer's buffer
/// instead (`ArtSegment.paintFloats`).
private struct PaintUniforms {
    var color: SIMD4<Float>
    var points: SIMD4<Float> = .zero
    var info: SIMD4<Float>
    var stopColors: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                     SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero, .zero, .zero, .zero, .zero)
    var stopOffsets: (SIMD4<Float>, SIMD4<Float>) = (.zero, .zero)

    /// A solid color, given in straight alpha.
    init(solid: SIMD4<Float>) {
        color = solid
        info = SIMD4(0, 0, 1, 0)
    }

    static func vector(_ c: RGBAColor) -> SIMD4<Float> {
        SIMD4(Float(c.r), Float(c.g), Float(c.b), Float(c.a))
    }
}

/// Where a cover step samples an image shape's picture. Layout must match `ImagePaint`
/// in ShaderSource: the world-to-image map's two rows, then the opacity.
private struct ImagePaintUniforms {
    var u: SIMD4<Float>
    var v: SIMD4<Float>
    var info: SIMD4<Float>

    init(_ image: ArtImage, opacity: Double) {
        let m = image.worldToImage
        // u = a x + c y + tx, v = b x + d y + ty.
        u = SIMD4(Float(m.a), Float(m.c), Float(m.tx), 0)
        v = SIMD4(Float(m.b), Float(m.d), Float(m.ty), 0)
        info = SIMD4(Float(min(max(opacity, 0), 1)), 0, 0, 0)
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
/// triangles are made in its own space, cached, and rebuilt only when its path or outline
/// changes: the vertex shader draws them through the shape's group and shape transforms
/// (`ArtStep.place`) and its layer's (`ArtSegment.transform`), so moving, turning or
/// scaling anything, in an edit or a transition, flattens nothing. A select-tool drag
/// keeps the art built from the drawing as it began and draws the moved shapes through
/// the drag's transform too, so it rebuilds nothing until the Pencil lifts (see
/// `LiveTransform`). The camera is applied in the vertex shader, so navigation never
/// re-tessellates in a frame: when zoom crosses a power of two, the shapes are re-flattened in a background
/// job, visible ones first, while the current art keeps drawing (see `updateArt`). The
/// first build after opening is such a job too, so the first frame never waits for it.
@MainActor
final class CanvasRenderer {
    private static let sampleCount = CanvasGPU.sampleCount

    /// The shaders, pipelines and pictures every canvas shares.
    private let gpu: CanvasGPU
    private let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let strokePipeline: any MTLRenderPipelineState
    private let stencilPipeline: any MTLRenderPipelineState
    private let coverPipeline: any MTLRenderPipelineState
    private let imagePipeline: any MTLRenderPipelineState
    private let imageCoverPipeline: any MTLRenderPipelineState
    private let gridPipeline: any MTLRenderPipelineState
    private let plainState: any MTLDepthStencilState
    /// Depth-stencil states for the art's steps, made on first use.
    private let stencilStates: StencilStates
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
    /// One per layer. Each layer's vertices, then its cover steps' paints, live in their own
    /// buffer, keyed by segment id, so an edit uploads only the layers it changed. A buffer
    /// is never written after it is made, so a frame still in flight keeps reading the one
    /// it was given (the command buffer retains it).
    private var artSegments: [ArtSegment] = []
    private var artBuffers: [Int: any MTLBuffer] = [:]
    /// Presenting, where the art is each played frame's scene: its layers' buffers from
    /// the pool, as the editor's preview's are (`previewHandles`).
    private var artHandles: [Int: VertexBufferPool.Handle] = [:]
    /// The drawing the art was last built from, which a refine merges against.
    private var artDrawing = Drawing()

    // Preview art, in the editor: a scrubbed or playing scene. Built by a copy of the art
    // builder taken when the preview starts, so its first frame flattens only what the
    // transition changes, while the art builder keeps the keyframe's own art and cache.
    // When the preview ends, the keyframe shows again without a rebuild. Presenting has
    // no drawing of its own, so there the scenes are the art.
    private var previewBuilder: ArtBuilder?
    private var previewKey: (revision: Int, merges: Int, isolation: Int?, groupIsolation: Int?, ghost: Set<Int>?)?
    private var previewSteps: [ArtStep] = []
    private var previewSegments: [ArtSegment] = []
    private var previewBuffers: [Int: any MTLBuffer] = [:]
    /// The preview's own layers' buffers, from the pool rather than made every frame,
    /// pinned while the preview draws them. The rest of `previewBuffers` are the art's.
    private var previewHandles: [Int: VertexBufferPool.Handle] = [:]

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
    /// Counts the refine results merged, so a preview takes them too.
    private var refineMerges = 0
    /// From the first frame until a refine's last result merges: the drawing is being
    /// tessellated in the background for the first time, so builds leave out the layers
    /// that aren't ready instead of flattening them in the frame.
    private var artCold = false

    /// Asks the view for a frame; a refine calls it when its result is merged, and
    /// `CanvasGPU` when a picture has loaded.
    var onNeedsRender: (@MainActor () -> Void)?
    /// Presenting: the first build flattens everything in the frame (see `init`), and the
    /// art, which is each played frame, takes its buffers from the pool.
    private let isPresenting: Bool

    // Vertex buffers reused between frames, and the live strokes' committed segments.
    private let clock = FrameClock()
    private let buffers: VertexBufferPool
    private var liveTessellator = LiveStrokeTessellator()
    private var mirroredTessellator = LiveStrokeTessellator()

    // The overlay's kept layers (the outline view's wireframe and the selection's
    // outlines and anchors), in one pinned buffer uploaded when they change.
    private var overlayCache = OverlayCache()
    /// The ghost view's focus, kept between frames.
    private var ghostCache = GhostFocusCache()
    private var overlayGeneration = -1
    private var overlayBuffer: VertexBufferPool.Handle?
    private var overlayKept: (wireframe: Range<Int>, selection: Range<Int>) = (0..<0, 0..<0)

    /// Reference images' textures by id (ids are never reused in a session), the ones
    /// being decoded, and the ones whose bytes didn't decode.
    private var textures: [Int: any MTLTexture] = [:]
    private var loadingReferences: Set<Int> = []
    private var failedReferences: Set<Int> = []

    /// Supplies the encoded bytes (PNG or JPEG) of a reference image id.
    var referenceData: (@MainActor (Int) -> Data?)?

    /// Nil when the device has no Metal. The shaders are compiled once, for the first
    /// canvas (`CanvasGPU`), so a second one, such as presenting's, starts at once.
    ///
    /// When `presenting`, the first frame flattens the whole scene before it shows,
    /// rather than filling the layers in over the next frames as the editor's canvas
    /// does after opening, so the first slide appears whole.
    init?(presenting: Bool = false) {
        guard let gpu = CanvasGPU.shared, let queue = gpu.device.makeCommandQueue() else { return nil }
        self.gpu = gpu
        device = gpu.device
        self.queue = queue
        buffers = VertexBufferPool(device: gpu.device, clock: clock)
        strokePipeline = gpu.strokePipeline
        stencilPipeline = gpu.stencilPipeline
        coverPipeline = gpu.coverPipeline
        imagePipeline = gpu.imagePipeline
        imageCoverPipeline = gpu.imageCoverPipeline
        gridPipeline = gpu.gridPipeline
        plainState = gpu.plainState
        stencilStates = StencilStates(device: gpu.device, fallback: gpu.plainState)
        sampler = gpu.sampler
        isPresenting = presenting
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
        guard let commandBuffer = queue.makeCommandBuffer() else { return false }
        let frame = clock.beginFrame()
        let clock = clock
        commandBuffer.addCompletedHandler { buffer in
            clock.complete(frame)
            let ms = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
            Signposts.canvas.emitEvent("GPU frame", "\(ms, format: .fixed(precision: 2)) ms")
        }

        // The CPU work comes first, and the drawable is taken only once there is something
        // to encode, so a slow GPU frame doesn't hold the main thread (and touches) while
        // the art, the onion skin and the overlay are built.
        let editor = session.editor
        let w = Double(viewSize.width), h = Double(viewSize.height)
        let screen = [Vec2(0, 0), Vec2(w, 0), Vec2(w, h), Vec2(0, h)].map { session.camera.toWorld($0) }
        // The outline view draws the art as a wireframe in the overlay instead.
        if !editor.outlineView {
            updateArt(editor: editor, zoom: session.camera.zoom, navigating: session.isNavigating,
                      viewRect: Rect(points: screen), presenting: presenting)
        }
        // A preview (scrubbing or playing) shows its scene in place of the drawing.
        let shown = editor.shownDrawing
        if !presenting { loadMissingTextures(for: shown.references) }
        let showsOnion = !editor.outlineView && !presenting && editor.preview == nil && editor.onionSkin != nil
        if showsOnion, let onion = editor.onionSkin {
            updateOnion(onion, revision: editor.onionRevision)
        } else if editor.onionSkin == nil, onionKey != nil {
            // Turned off; during a preview it is only hidden.
            releaseOnion()
        }
        let overlay: OverlayLayers? = presenting ? nil : Signposts.canvas.withIntervalSignpost("Overlay build") {
            EditorOverlay.layers(for: editor, zoom: session.camera.zoom, viewRect: Rect(points: screen),
                                 darkMode: darkMode, cache: &overlayCache)
        }
        if let overlay, overlayCache.generation != overlayGeneration {
            overlayGeneration = overlayCache.generation
            if let overlayBuffer { buffers.release(overlayBuffer) }
            overlayBuffer = buffers.upload([overlay.wireframe, overlay.selection], pin: true)
            let wire = overlay.wireframe.count
            overlayKept = (0..<wire, wire..<(wire + overlay.selection.count))
        }

        // Waiting here means the GPU or the display still holds both drawables.
        let next = Signposts.canvas.withIntervalSignpost("Next drawable") { layer.nextDrawable() }
        guard let drawable = next else {
            Signposts.canvas.emitEvent("No drawable")
            // Any texture uploads still go to the GPU, and the frame completes.
            commandBuffer.commit()
            return false
        }
        ensureTargets(width: drawable.texture.width, height: drawable.texture.height)
        guard let msaaTexture, let stencilTexture else {
            commandBuffer.commit()
            return true
        }

        var uniforms = makeUniforms(camera: session.camera, viewSize: viewSize, scale: scale, darkMode: darkMode)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaaTexture
        pass.colorAttachments[0].resolveTexture = drawable.texture
        // The grid covers every pixel; presenting, which draws no grid, starts from black.
        pass.colorAttachments[0].loadAction = presenting ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.stencilAttachment.texture = stencilTexture
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.clearStencil = 0
        pass.stencilAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        let encodeInterval = Signposts.canvas.beginInterval("Encode")
        encoder.setDepthStencilState(plainState)

        // Presenting covers the canvas with the stage and the black around it, so the grid
        // would never show.
        if !presenting {
            encoder.setRenderPipelineState(gridPipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        let viewport = shown.viewport
        let stage = viewport.bounds.corners
        drawSolid([stage[0], stage[1], stage[2], stage[0], stage[2], stage[3]],
                  color: PaintUniforms.vector(viewport.background), encoder: encoder, uniforms: &uniforms)
        if !presenting { drawReferences(of: shown, encoder: encoder, uniforms: &uniforms) }
        if !editor.outlineView {
            if showsOnion {
                Signposts.canvas.withIntervalSignpost("Onion draw") {
                    drawArt(onionSteps, segments: onionSegments, buffers: onionBuffers, encoder: encoder, uniforms: uniforms,
                            viewRect: Rect(points: screen))
                }
            }
            Signposts.canvas.withIntervalSignpost("Art draw") {
                if editor.preview != nil, previewBuilder != nil {
                    for handle in previewHandles.values { buffers.use(handle) }
                    drawArt(previewSteps, segments: previewSegments, buffers: previewBuffers, encoder: encoder,
                            uniforms: uniforms, viewRect: Rect(points: screen))
                } else {
                    for handle in artHandles.values { buffers.use(handle) }
                    drawArt(artSteps, segments: artSegments, buffers: artBuffers, encoder: encoder, uniforms: uniforms,
                            viewRect: Rect(points: screen))
                }
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
        drawKeptOverlay(overlayKept.wireframe, encoder: encoder)
        drawCapsules(overlay?.guides ?? [], encoder: encoder)
        drawKeptOverlay(overlayKept.selection, encoder: encoder)
        drawCapsules(overlay?.top ?? [], encoder: encoder)

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
    ///
    /// In the editor, a preview (a scrub or playback) is built apart, by `updatePreviewArt`,
    /// and the art stays the drawing's. Presenting shows its scenes as the art.
    private func updateArt(editor: DrawingEditor, zoom: Double, navigating: Bool, viewRect: Rect, presenting: Bool) {
        let bucket = pow(2, ceil(log2(max(zoom, 1.0 / 64))))
        let wanted = 0.2 / bucket
        let live = editor.liveTransform.flatMap { $0.movesTessellation ? $0 : nil }
        let previewsApart = !presenting
        let drawing = live?.base ?? (previewsApart ? editor.drawing : editor.shownDrawing)
        let revision = previewsApart ? editor.revision : editor.displayRevision
        // A live drag just ended: keep the moved shapes' triangles where they landed
        // rather than flattening them again. Enlarged ones are coarse until a refine.
        if live == nil, let ended = lastLive {
            let carry = Signposts.canvas.withIntervalSignpost("Art carry", "\(ended.shapes.count) shapes") {
                artBuilder.carry(ended, to: editor.drawing, tolerance: artTolerance)
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
            // Presenting builds its first scene whole, in this frame (see `init`).
            artCold = !isPresenting
            artMixed = !isPresenting
        }
        scheduleRefine(to: wanted, drawing: drawing, navigating: navigating, viewRect: viewRect)

        let ghost = ghostCache.focus(of: editor)
        if previewsApart, live == nil, let preview = editor.preview {
            updatePreviewArt(preview, editor: editor, ghost: ghost)
            return
        }
        if previewBuilder != nil { releasePreview() }
        liveTransform = live?.transform ?? .identity
        let current = live.map { artLive == $0.id } ?? (artLive == nil && revision == artRevision)
        guard !current || artRefined ||
            editor.isolatedLayer != artIsolation || editor.isolatedGroup != artGroupIsolation || ghost != artGhost
        else { return }
        // Why, for the signpost.
        let reason = artCold ? "open" : !current ? (live != nil ? "drag" : "edit") : artRefined ? "refine" : "focus"
        // A live build stands for no revision, so the drawing is rebuilt when the drag ends.
        artRevision = live == nil ? revision : -1
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

    /// Builds a preview frame's art with `previewBuilder`, starting it from a copy of the
    /// art builder (and the art's buffers, which its cached layers use) on the
    /// preview's first frame. The copies share storage until the preview's builds write.
    private func updatePreviewArt(_ preview: Drawing, editor: DrawingEditor, ghost: Set<Int>?) {
        if previewBuilder == nil {
            previewBuilder = artBuilder
            previewBuffers = artBuffers
            previewKey = nil
        } else if let key = previewKey, key.merges != refineMerges {
            // A refine merged into the art's cache (at a new tolerance, or the first
            // flattening after opening): take its shapes too.
            previewBuilder?.tessellations = artBuilder.tessellations
        }
        if let key = previewKey, key.revision == editor.displayRevision, key.merges == refineMerges,
           key.isolation == editor.isolatedLayer, key.groupIsolation == editor.isolatedGroup, key.ghost == ghost {
            return
        }
        previewKey = (editor.displayRevision, refineMerges, editor.isolatedLayer, editor.isolatedGroup, ghost)
        let interval = Signposts.canvas.beginInterval("Art rebuild")
        defer { Signposts.canvas.endInterval("Art rebuild", interval, "preview") }
        guard let batch = previewBuilder?.build(preview, isolatedLayer: editor.isolatedLayer,
                                                isolatedGroup: editor.isolatedGroup, tolerance: artTolerance,
                                                ghostFocus: ghost,
                                                reusingOtherTolerances: refineJob != nil || artMixed,
                                                leavingOutUncached: artCold)
        else { return }
        previewSteps = batch.steps
        previewSegments = batch.segments
        uploadPooled(batch, keeping: &previewBuffers, handles: &previewHandles)
    }

    /// Like `upload(_:keeping:)`, but each changed layer goes in a pooled buffer, since
    /// playback changes the moving layers on every frame. A pooled buffer stays pinned
    /// while it is drawn, and goes back to the pool when a later frame replaces it or the
    /// preview ends. `kept` may also hold the art's own buffers, which aren't pooled.
    private func uploadPooled(_ batch: ArtBatch, keeping kept: inout [Int: any MTLBuffer],
                              handles: inout [Int: VertexBufferPool.Handle]) {
        let interval = Signposts.canvas.beginInterval("Art upload")
        var floats = 0
        defer { Signposts.canvas.endInterval("Art upload", interval, "\(floats) floats, pooled") }
        var nextBuffers: [Int: any MTLBuffer] = [:]
        var nextHandles: [Int: VertexBufferPool.Handle] = [:]
        for id in batch.residentIDs {
            nextBuffers[id] = kept[id]
            nextHandles[id] = handles[id]
        }
        for segment in batch.segmentsToUpload(resident: Set(nextBuffers.keys)) {
            let paint = segment.paintFloats(in: batch.steps)
            floats += segment.floats.count + paint.count
            guard let handle = buffers.upload([segment.floats, paint], pin: true) else { continue }
            nextBuffers[segment.id] = handle.buffer
            nextHandles[segment.id] = handle
        }
        for (id, handle) in handles where nextHandles[id] == nil { buffers.release(handle) }
        kept = nextBuffers
        handles = nextHandles
    }

    /// Drops the preview's art, its buffers and its builder's copies of the caches.
    private func releasePreview() {
        previewBuilder = nil
        previewKey = nil
        previewSteps = []
        previewSegments = []
        previewBuffers = [:]
        for handle in previewHandles.values { buffers.release(handle) }
        previewHandles = [:]
    }

    /// Keeps the buffers of layers that didn't change and makes one for each layer that
    /// did. Presenting, whose art changes every frame while a sequence plays, takes them
    /// from the pool.
    private func uploadArt(_ batch: ArtBatch) {
        artSteps = batch.steps
        artSegments = batch.segments
        if isPresenting {
            uploadPooled(batch, keeping: &artBuffers, handles: &artHandles)
        } else {
            artBuffers = upload(batch, keeping: artBuffers)
        }
    }

    /// The buffers for `batch`'s layers: those in `buffers` it still uses, and a new one
    /// for each layer that changed, holding its vertices and then its paints.
    private func upload(_ batch: ArtBatch, keeping buffers: [Int: any MTLBuffer]) -> [Int: any MTLBuffer] {
        let interval = Signposts.canvas.beginInterval("Art upload")
        var floats = 0
        defer { Signposts.canvas.endInterval("Art upload", interval, "\(floats) floats") }
        var kept: [Int: any MTLBuffer] = [:]
        for id in batch.residentIDs { kept[id] = buffers[id] }
        for segment in batch.segmentsToUpload(resident: Set(kept.keys)) {
            let paint = segment.paintFloats(in: batch.steps)
            floats += segment.floats.count + paint.count
            kept[segment.id] = makeBuffer([segment.floats, paint])
        }
        return kept
    }

    /// A new shared buffer holding `chunks`, one after another.
    private func makeBuffer(_ chunks: [[Float]]) -> (any MTLBuffer)? {
        let length = chunks.reduce(0) { $0 + $1.count } * MemoryLayout<Float>.stride
        guard length > 0, let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        var offset = 0
        for chunk in chunks {
            chunk.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                buffer.contents().advanced(by: offset).copyMemory(from: base, byteCount: bytes.count)
                offset += bytes.count
            }
        }
        return buffer
    }

    /// Builds the onion skin when it or the art's tolerance changed: every shape faded to
    /// the ghost opacity, as the ghost view draws shapes outside its focus.
    private func updateOnion(_ onion: Drawing, revision: Int) {
        guard onionKey?.revision != revision || onionKey?.tolerance != artTolerance, artTolerance > 0 else { return }
        onionKey = (revision, artTolerance)
        // The keyframe before mostly shares its shapes' geometry with this one, so the
        // onion starts from the art's tessellations rather than flattening every shape.
        onionBuilder.tessellations = artBuilder.tessellations
        let batch = Signposts.canvas.withIntervalSignpost("Onion rebuild") {
            onionBuilder.build(onion, isolatedLayer: nil, tolerance: artTolerance, ghostFocus: [],
                               reusingOtherTolerances: true)
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
        refineMerges += 1
        if final {
            refineJob = nil
            refineTolerance = nil
            artCold = false
        }
        onNeedsRender?()
    }

    /// Draws the art's steps with `ArtEncoding`, which sets only what changes from one
    /// step to the next. Each layer's vertices are in its own space, and each shape's in
    /// the space its `place` step names: the vertex shader takes them through the place,
    /// the layer's transform and, for shapes a drag moves, the drag's transform, before
    /// the camera. Gradients and pictures are in the vertices' own space, so they move
    /// with them. Each cover's paint is read from its slot in the layer's buffer.
    private func drawArt(_ steps: [ArtStep], segments: [ArtSegment], buffers: [Int: any MTLBuffer],
                         encoder: any MTLRenderCommandEncoder, uniforms: CanvasUniforms, viewRect: Rect) {
        guard !steps.isEmpty else { return }
        var view: [Float] = []
        let corners = viewRect.corners
        for i in [0, 1, 2, 0, 2, 3] {
            view.append(Float(corners[i].x))
            view.append(Float(corners[i].y))
        }
        let bg = uniforms.background
        var art = MetalArtEncoder(encoder: encoder, buffers: buffers, worldToClip: uniforms.worldToClip, view: view,
                                  veil: PaintUniforms(solid: SIMD4(bg.x, bg.y, bg.z, 0.7)),
                                  stencilPipeline: stencilPipeline, coverPipeline: coverPipeline,
                                  imageCoverPipeline: imageCoverPipeline, plainState: plainState,
                                  stencilStates: stencilStates, sampler: sampler, pictures: gpu.readyImages)
        ArtEncoding.encode(steps, segments: segments, liveTransform: liveTransform, into: &art)
        // A picture not loaded yet painted its placeholder, which clears the stencil as
        // any cover does; this starts loading it, and `imagesLoaded` asks for a frame.
        for src in art.missingPictures { _ = gpu.imageTexture(src, for: self) }
    }

    /// The veil's strength over art outside the viewport.
    private static let veilOpacity: Float = 0.5

    /// Fills `triangles` (world space, three corners each) with `color` (straight alpha).
    private func drawSolid(_ triangles: [Vec2], color: SIMD4<Float>, encoder: any MTLRenderCommandEncoder,
                           uniforms: inout CanvasUniforms) {
        guard !triangles.isEmpty else { return }
        let floats = triangles.flatMap { [Float($0.x), Float($0.y)] }
        var paint = PaintUniforms(solid: color)
        var worldToClip = uniforms.worldToClip
        encoder.setRenderPipelineState(coverPipeline)
        encoder.setDepthStencilState(plainState)
        encoder.setVertexBytes(floats, length: floats.count * MemoryLayout<Float>.stride, index: 0)
        encoder.setVertexBytes(&worldToClip, length: MemoryLayout<simd_float4x4>.stride, index: 1)
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

    // MARK: Image shapes

    /// A picture the art drew without has loaded (see `CanvasGPU.imageTexture`).
    func imagesLoaded() {
        onNeedsRender?()
    }

    /// Starts decoding and uploading each reference image that has no texture yet, off
    /// the main thread (see `CanvasGPU.texture(decoding:)`); it shows from the frame after
    /// it is ready. Bytes that don't decode are not tried again.
    private func loadMissingTextures(for references: [ReferenceImage]) {
        for ref in references where textures[ref.id] == nil && !loadingReferences.contains(ref.id) &&
            !failedReferences.contains(ref.id) {
            guard let data = referenceData?(ref.id) else { continue }
            loadingReferences.insert(ref.id)
            let id = ref.id, gpu = gpu
            Task { [weak self] in
                let texture = await gpu.texture(decoding: data)
                guard let self else { return }
                loadingReferences.remove(id)
                if let texture { textures[id] = texture } else { failedReferences.insert(id) }
                onNeedsRender?()
            }
        }
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

/// Sends `ArtEncoding`'s commands to a Metal encoder. The art's vertex shader takes
/// the 64-byte matrix alone, so a new place copies only that.
private struct MetalArtEncoder: ArtEncoder {
    let encoder: any MTLRenderCommandEncoder
    let buffers: [Int: any MTLBuffer]
    let worldToClip: simd_float4x4
    /// The view's rectangle, two triangles in the world.
    let view: [Float]
    let veil: PaintUniforms
    let stencilPipeline: any MTLRenderPipelineState
    let coverPipeline: any MTLRenderPipelineState
    let imageCoverPipeline: any MTLRenderPipelineState
    let plainState: any MTLDepthStencilState
    let stencilStates: StencilStates
    let sampler: any MTLSamplerState
    /// Image shapes' pictures that are ready, by `src`.
    let pictures: [String: any MTLTexture]
    /// Pictures the art wanted and didn't have.
    private(set) var missingPictures: Set<String> = []
    /// The picture `hasPicture` found, for `setImagePaint`.
    private var picture: (any MTLTexture)?

    init(encoder: any MTLRenderCommandEncoder, buffers: [Int: any MTLBuffer], worldToClip: simd_float4x4,
         view: [Float], veil: PaintUniforms, stencilPipeline: any MTLRenderPipelineState,
         coverPipeline: any MTLRenderPipelineState, imageCoverPipeline: any MTLRenderPipelineState,
         plainState: any MTLDepthStencilState, stencilStates: StencilStates, sampler: any MTLSamplerState,
         pictures: [String: any MTLTexture]) {
        self.encoder = encoder
        self.buffers = buffers
        self.worldToClip = worldToClip
        self.view = view
        self.veil = veil
        self.stencilPipeline = stencilPipeline
        self.coverPipeline = coverPipeline
        self.imageCoverPipeline = imageCoverPipeline
        self.plainState = plainState
        self.stencilStates = stencilStates
        self.sampler = sampler
        self.pictures = pictures
    }

    mutating func hasPicture(_ image: ArtImage) -> Bool {
        picture = pictures[image.src]
        if picture == nil { missingPictures.insert(image.src) }
        return picture != nil
    }

    func setPipeline(_ pipeline: ArtPipeline) {
        switch pipeline {
        case .stencil: encoder.setRenderPipelineState(stencilPipeline)
        case .cover: encoder.setRenderPipelineState(coverPipeline)
        case .imageCover: encoder.setRenderPipelineState(imageCoverPipeline)
        }
    }

    func setTransform(_ toWorld: Affine2D) {
        var matrix = toWorld == .identity ? worldToClip : worldToClip * toWorld.matrix4x4
        encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
    }

    func setVertices(_ segment: ArtSegment) {
        // A layer with no vertices has no buffer, and nothing to draw.
        guard let buffer = buffers[segment.id] else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
    }

    func setViewVertices() {
        encoder.setVertexBytes(view, length: view.count * MemoryLayout<Float>.stride, index: 0)
    }

    func setStencil(_ state: StencilState?) {
        encoder.setDepthStencilState(state.map { stencilStates.state($0) } ?? plainState)
    }

    func setStencilReference(_ reference: UInt8) {
        encoder.setStencilReferenceValue(UInt32(reference))
    }

    func setPaint(_ segment: ArtSegment, slot: Int, rebind: Bool) {
        let offset = segment.paintByteOffset(slot: slot)
        if rebind {
            guard let buffer = buffers[segment.id] else { return }
            encoder.setFragmentBuffer(buffer, offset: offset, index: 0)
        } else {
            encoder.setFragmentBufferOffset(offset, index: 0)
        }
    }

    func setImagePaint(_ image: ArtImage, opacity: Double) {
        var uniforms = ImagePaintUniforms(image, opacity: opacity)
        encoder.setFragmentTexture(picture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ImagePaintUniforms>.stride, index: 0)
    }

    func setVeilPaint() {
        var paint = veil
        encoder.setFragmentBytes(&paint, length: MemoryLayout<PaintUniforms>.stride, index: 0)
    }

    func draw(_ vertices: Range<Int>) {
        guard !vertices.isEmpty else { return }
        encoder.drawPrimitives(type: .triangle, vertexStart: vertices.lowerBound, vertexCount: vertices.count)
    }
}

/// The Metal depth-stencil state for each of the art's stencil configurations, made on
/// first use.
private final class StencilStates {
    private let device: any MTLDevice
    /// Used if Metal can't make a state.
    private let fallback: any MTLDepthStencilState
    private var states: [StencilState: any MTLDepthStencilState] = [:]

    init(device: any MTLDevice, fallback: any MTLDepthStencilState) {
        self.device = device
        self.fallback = fallback
    }

    func state(_ state: StencilState) -> any MTLDepthStencilState {
        if let cached = states[state] { return cached }
        func face(_ pass: StencilOperation) -> MTLStencilDescriptor {
            let d = MTLStencilDescriptor()
            d.stencilCompareFunction = switch state.compare {
            case .always: .always
            case .equal: .equal
            case .notEqual: .notEqual
            case .less: .less
            }
            d.stencilFailureOperation = Self.operation(state.fail)
            d.depthFailureOperation = .keep
            d.depthStencilPassOperation = Self.operation(pass)
            d.readMask = UInt32(state.readMask)
            d.writeMask = UInt32(state.writeMask)
            return d
        }
        let descriptor = MTLDepthStencilDescriptor()
        descriptor.frontFaceStencil = face(state.pass)
        descriptor.backFaceStencil = face(state.backPass)
        let made = device.makeDepthStencilState(descriptor: descriptor) ?? fallback
        states[state] = made
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
