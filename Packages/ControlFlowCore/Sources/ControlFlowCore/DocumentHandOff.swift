import Foundation

/// Decides when the app hands a changed drawing to its document. Each hand-off marks
/// the document edited, and the autosave that follows encodes the whole drawing and
/// renders its thumbnail, so a run of continuous changes (a color picker or slider
/// drag, many a second) is held and handed off once, `quietPeriod` seconds after its
/// last change. Any other finished change is handed off at once, along with whatever
/// was held.
public struct DocumentHandOff: Sendable {
    /// How long a continuous change waits for the next one before it is handed off.
    public static let quietPeriod = 0.5

    /// The drawing revision last handed to the document.
    public private(set) var sentRevision: Int
    /// When the held change is due, in the caller's clock; nil when nothing is held.
    public private(set) var due: Double?

    public init(revision: Int) {
        sentRevision = revision
    }

    /// After a finished change that left the drawing at `revision`: returns true when
    /// it should be handed off now. A `continuous` change is held instead, until
    /// `due`, when the caller asks again with `flush`.
    public mutating func changed(revision: Int, continuous: Bool, now: Double) -> Bool {
        guard revision != sentRevision else { return false }
        if continuous {
            due = now + Self.quietPeriod
            return false
        }
        sentRevision = revision
        due = nil
        return true
    }

    /// Returns true when a held change should be handed off: at `now`, if it is due,
    /// or at any time when `now` is nil (the document is closing or going to the
    /// background).
    public mutating func flush(revision: Int, now: Double?) -> Bool {
        guard let due else { return false }
        if let now, now < due { return false }
        self.due = nil
        guard revision != sentRevision else { return false }
        sentRevision = revision
        return true
    }
}
