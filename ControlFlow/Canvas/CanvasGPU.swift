import ControlFlowCore
import CoreGraphics
import Foundation
import ImageIO
import Metal

/// The Metal objects every canvas shares: the device, the shaders (compiled from
/// `ShaderSource` once, by the first canvas made), their pipelines, and image shapes'
/// pictures as textures. The editor's canvas, the presenter view and an external display
/// each have a `CanvasRenderer`, and none of them compiles shaders or uploads a picture
/// another has already.
@MainActor
final class CanvasGPU {
    /// Nil when the device has no Metal or the shaders don't build.
    static let shared: CanvasGPU? = CanvasGPU()

    static let sampleCount = 4

    let device: any MTLDevice
    let strokePipeline: any MTLRenderPipelineState
    let stencilPipeline: any MTLRenderPipelineState
    let coverPipeline: any MTLRenderPipelineState
    let imagePipeline: any MTLRenderPipelineState
    let imageCoverPipeline: any MTLRenderPipelineState
    let gridPipeline: any MTLRenderPipelineState
    let plainState: any MTLDepthStencilState
    let sampler: any MTLSamplerState

    /// Image shapes' pictures, by `src`, from `ImageLibrary`.
    private var imageTextures: [String: any MTLTexture] = [:]
    /// Pictures being decoded and uploaded off the main thread.
    private var loadingImages: Set<String> = []
    /// Pictures the library didn't have, not looked for again until it gains some.
    private var missingImages: Set<String> = []
    private var libraryGeneration = -1
    /// Renderers to tell when a picture is ready.
    private let waiting = NSHashTable<AnyObject>.weakObjects()
    /// A queue for the uploads' mipmap blits, apart from the renderers' frames.
    private let uploadQueue: (any MTLCommandQueue)?

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        self.device = device
        uploadQueue = device.makeCommandQueue()

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

            let imageCover = descriptor("Image cover", vertex: "fill_vertex", fragment: "image_cover_fragment")
            premultipliedBlending(imageCover)
            imageCoverPipeline = try device.makeRenderPipelineState(descriptor: imageCover)

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

    // MARK: Image shapes

    /// The texture for `src` if it is ready. Otherwise starts decoding and uploading it
    /// off the main thread, unless that is under way or the library hasn't got it, and
    /// calls `renderer.imagesLoaded()` when it is done; meanwhile the art paints the
    /// picture's placeholder.
    func imageTexture(_ src: String, for renderer: CanvasRenderer) -> (any MTLTexture)? {
        if let texture = imageTextures[src] { return texture }
        let generation = ImageLibrary.shared.generation
        if generation != libraryGeneration {
            libraryGeneration = generation
            missingImages = []
        }
        waiting.add(renderer)
        guard !loadingImages.contains(src), !missingImages.contains(src) else { return nil }
        loadingImages.insert(src)
        let deviceBox = UncheckedSendable(device)
        let queueBox = uploadQueue.map { UncheckedSendable($0) }
        Task { [weak self] in
            let made = await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<any MTLTexture>? in
                let interval = Signposts.canvas.beginInterval("Image texture")
                defer { Signposts.canvas.endInterval("Image texture", interval) }
                guard let image = ImageLibrary.shared.image(src),
                      let texture = CanvasGPU.makeTexture(image, device: deviceBox.value, queue: queueBox?.value)
                else { return nil }
                return UncheckedSendable(texture)
            }.value
            self?.imageLoaded(src, texture: made?.value)
        }
        return nil
    }

    /// Decodes encoded image bytes (a reference image's PNG or JPEG) and uploads them
    /// with mipmaps, off the main thread. Nil when the bytes don't decode.
    func texture(decoding data: Data) async -> (any MTLTexture)? {
        let deviceBox = UncheckedSendable(device)
        let queueBox = uploadQueue.map { UncheckedSendable($0) }
        let made = await Task.detached(priority: .userInitiated) { () -> UncheckedSendable<any MTLTexture>? in
            let interval = Signposts.canvas.beginInterval("Reference texture")
            defer { Signposts.canvas.endInterval("Reference texture", interval) }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let texture = CanvasGPU.makeTexture(image, device: deviceBox.value, queue: queueBox?.value)
            else { return nil }
            return UncheckedSendable(texture)
        }.value
        return made?.value
    }

    private func imageLoaded(_ src: String, texture: (any MTLTexture)?) {
        loadingImages.remove(src)
        if let texture {
            imageTextures[src] = texture
        } else {
            missingImages.insert(src)
        }
        for case let renderer as CanvasRenderer in waiting.allObjects { renderer.imagesLoaded() }
        if loadingImages.isEmpty { waiting.removeAllObjects() }
    }

    /// Uploads a CGImage as premultiplied RGBA with mipmaps, so it stays smooth when
    /// zoomed out. Safe off the main thread. With no `queue`, the mipmaps are left to the
    /// caller's `commandBuffer`.
    nonisolated static func makeTexture(_ image: CGImage, device: any MTLDevice, queue: (any MTLCommandQueue)?,
                                        commandBuffer: (any MTLCommandBuffer)? = nil) -> (any MTLTexture)? {
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
        guard texture.mipmapLevelCount > 1 else { return texture }
        if let commandBuffer {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: texture)
                blit.endEncoding()
            }
        } else if let queue, let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
        }
        return texture
    }
}

/// Carries a Metal object across to another task. Metal's devices, queues and finished
/// textures are safe to use from any thread.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
