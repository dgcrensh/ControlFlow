import ControlFlowCore
import CoreGraphics
import Foundation
import ImageIO

/// The pixels of image shapes, for every open document, by `src` (see `ImageAssets`).
/// A src is named by a hash of its bytes, so it means the same picture in any document:
/// one library serves them all, and art pasted between documents keeps its pictures.
/// Safe off the main thread, where documents are saved and thumbnails drawn.
final class ImageLibrary: @unchecked Sendable {
    static let shared = ImageLibrary()

    private let lock = NSLock()
    /// Encoded bytes (PNG or JPEG), as saved.
    private var data: [String: Data] = [:]
    /// Decoded pixels, filled on first use.
    private var decoded: [String: CGImage] = [:]
    private var revision = 0

    /// Bumped whenever pictures are added, so a renderer can look again for ones it lacked.
    var generation: Int { lock.withLock { revision } }

    /// Adds an encoded image and returns its `src`.
    @discardableResult
    func add(_ bytes: Data) -> String {
        let src = ImageAssets.path(for: bytes)
        add([src: bytes])
        return src
    }

    /// Adds encoded images by `src`, such as a package's.
    func add(_ images: [String: Data]) {
        guard !images.isEmpty else { return }
        lock.withLock {
            var added = false
            for (src, bytes) in images where data[src] == nil {
                data[src] = bytes
                added = true
            }
            if added { revision += 1 }
        }
    }

    /// The encoded bytes of each of `sources` the library has.
    func data(for sources: Set<String>) -> [String: Data] {
        lock.withLock {
            var out: [String: Data] = [:]
            for src in sources { if let bytes = data[src] { out[src] = bytes } }
            return out
        }
    }

    /// The pixels for `src`, decoded on first use, or nil when the library hasn't got them.
    func image(_ src: String) -> CGImage? {
        let bytes: Data? = lock.withLock {
            if decoded[src] != nil { return nil }
            return data[src]
        }
        if bytes == nil { return lock.withLock { decoded[src] } }
        guard let bytes, let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        lock.withLock { decoded[src] = image }
        return image
    }
}
