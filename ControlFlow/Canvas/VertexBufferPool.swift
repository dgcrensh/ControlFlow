import Metal
import Synchronization

/// Counts the frames the renderer commits and the last one the GPU has finished, so
/// a buffer is only written again once no frame in flight still reads it.
final class FrameClock: Sendable {
    private let state = Mutex<(current: UInt64, completed: UInt64)>((0, 0))

    /// The frame being encoded.
    var current: UInt64 { state.withLock { $0.current } }
    /// The newest frame the GPU has finished. Command buffers on one queue complete in order.
    var completed: UInt64 { state.withLock { $0.completed } }

    /// Starts a frame and returns its number.
    func beginFrame() -> UInt64 {
        state.withLock {
            $0.current += 1
            return $0.current
        }
    }

    /// Called from the command buffer's completion handler, on any thread.
    func complete(_ frame: UInt64) {
        state.withLock { $0.completed = max($0.completed, frame) }
    }
}

/// Shared-storage vertex buffers reused across frames instead of a new `MTLBuffer` per
/// draw. A buffer is written only when every frame that used it has finished on the
/// GPU; when none is free (the GPU is far behind) the pool falls back to a new one.
@MainActor
final class VertexBufferPool {
    struct Handle {
        let buffer: any MTLBuffer
        fileprivate let slot: Int?
    }

    private struct Slot {
        var buffer: any MTLBuffer
        var lastUse: UInt64
        /// Held across frames (the overlay's kept layers), so never handed out again until released.
        var isPinned = false
    }

    /// Enough for the overlay's kept layers (pinned), and the live and
    /// mirrored strokes and the overlay's two per-frame layers with three frames in flight.
    private static let maxSlots = 20
    private static let minimumLength = 64 * 1024

    private let device: any MTLDevice
    private let clock: FrameClock
    private var slots: [Slot] = []

    init(device: any MTLDevice, clock: FrameClock) {
        self.device = device
        self.clock = clock
    }

    /// Copies `chunks`, one after another, into a free buffer used by the current frame.
    /// A pinned buffer stays reserved, for drawing in later frames, until `release`.
    func upload(_ chunks: [[Float]], pin: Bool = false) -> Handle? {
        let count = chunks.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        let length = count * MemoryLayout<Float>.stride
        let completed = clock.completed
        let free = slots.indices.filter { !slots[$0].isPinned && slots[$0].lastUse <= completed }

        var slot = free.first { slots[$0].buffer.length >= length }
        if slot == nil, let grow = free.first ?? (slots.count < Self.maxSlots ? slots.count : nil) {
            var size = Self.minimumLength
            while size < length { size *= 2 }
            guard let buffer = device.makeBuffer(length: size, options: .storageModeShared) else { return nil }
            if grow == slots.count {
                slots.append(Slot(buffer: buffer, lastUse: 0))
            } else {
                slots[grow].buffer = buffer
            }
            slot = grow
        }

        let buffer: any MTLBuffer
        if let slot {
            buffer = slots[slot].buffer
            slots[slot].lastUse = clock.current
            slots[slot].isPinned = pin
        } else {
            // Every slot is busy: a one-off buffer, released when the GPU is done with it.
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
            buffer = made
        }
        var offset = 0
        for chunk in chunks {
            chunk.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                buffer.contents().advanced(by: offset).copyMemory(from: base, byteCount: bytes.count)
                offset += bytes.count
            }
        }
        return Handle(buffer: buffer, slot: slot)
    }

    /// Marks a pinned buffer as read by the current frame.
    func use(_ handle: Handle) {
        guard let slot = handle.slot else { return }
        slots[slot].lastUse = clock.current
    }

    /// Unpins a buffer; it becomes free once the frames that read it have finished.
    func release(_ handle: Handle) {
        guard let slot = handle.slot else { return }
        slots[slot].isPinned = false
    }
}
