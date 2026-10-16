import XCTest
@testable import ControlFlowCore

final class DocumentHandOffTests: XCTestCase {
    func testFinishedChangesAreHandedOffAtOnce() {
        var handOff = DocumentHandOff(revision: 0)
        XCTAssertFalse(handOff.changed(revision: 0, continuous: false, now: 0), "nothing changed")
        XCTAssertTrue(handOff.changed(revision: 1, continuous: false, now: 0))
        XCTAssertFalse(handOff.changed(revision: 1, continuous: false, now: 1), "already sent")
        XCTAssertEqual(handOff.sentRevision, 1)
    }

    /// A picker drag of 60 ticks a second for two seconds is one hand-off, after it ends.
    func testAContinuousRunIsHandedOffOnceWhenItGoesQuiet() {
        var handOff = DocumentHandOff(revision: 0)
        var sent = 0
        var revision = 0
        for tick in 0..<120 {
            let now = Double(tick) / 60
            revision += 1
            if handOff.changed(revision: revision, continuous: true, now: now) { sent += 1 }
            if handOff.flush(revision: revision, now: now) { sent += 1 }
        }
        XCTAssertEqual(sent, 0)
        let last = 119.0 / 60
        XCTAssertEqual(try XCTUnwrap(handOff.due), last + DocumentHandOff.quietPeriod, accuracy: 1e-9)
        XCTAssertFalse(handOff.flush(revision: revision, now: last + 0.1))
        XCTAssertTrue(handOff.flush(revision: revision, now: last + DocumentHandOff.quietPeriod))
        XCTAssertNil(handOff.due)
        XCTAssertEqual(handOff.sentRevision, revision)
        XCTAssertFalse(handOff.flush(revision: revision, now: last + 5))
    }

    func testAnotherChangeSendsWhatWasHeld() {
        var handOff = DocumentHandOff(revision: 0)
        XCTAssertFalse(handOff.changed(revision: 1, continuous: true, now: 0))
        XCTAssertTrue(handOff.changed(revision: 2, continuous: false, now: 0.1))
        XCTAssertNil(handOff.due)
        XCTAssertFalse(handOff.flush(revision: 2, now: 1))
    }

    /// Closing the document or leaving the app sends a held change without waiting.
    func testFlushingWithoutATimeSendsAtOnce() {
        var handOff = DocumentHandOff(revision: 3)
        XCTAssertFalse(handOff.flush(revision: 3, now: nil), "nothing held")
        XCTAssertFalse(handOff.changed(revision: 4, continuous: true, now: 0))
        XCTAssertTrue(handOff.flush(revision: 4, now: nil))
        XCTAssertEqual(handOff.sentRevision, 4)
    }

    // MARK: The editor's document revision

    /// Switching keyframes shows another scene but leaves the document as it was, so it
    /// is not handed off (each hand-off is an autosave).
    func testSwitchingKeyframesLeavesTheDocumentRevision() {
        var editor = DrawingEditor()
        let first = editor.setKeyframe()
        let second = editor.setKeyframe()
        let revision = editor.documentRevision
        let drawingRevision = editor.revision
        editor.selectKeyframe(first)
        editor.selectKeyframe(nil)
        editor.selectKeyframe(second)
        XCTAssertEqual(editor.documentRevision, revision)
        XCTAssertNotEqual(editor.revision, drawingRevision, "the canvas still redraws")
    }

    /// Timeline edits that leave every scene as it was still change the document, so
    /// they are handed off like any other edit.
    func testTimelineEditsMoveTheDocumentRevision() throws {
        var editor = DrawingEditor()
        let first = editor.setKeyframe()
        let second = editor.setKeyframe()
        var revision = editor.documentRevision
        func moved(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertNotEqual(editor.documentRevision, revision, what, file: file, line: line)
            revision = editor.documentRevision
        }
        var transition = Transition.standard
        transition.duration += 1
        editor.setTransition(transition, ofKeyframe: second)
        moved("transition")
        editor.renameKeyframe(first, to: "Title")
        moved("rename")
        editor.splitSequence(at: second)
        moved("split")
        let sequence = try XCTUnwrap(editor.timeline.presentation.sequences.first?.id)
        editor.mergeSequenceWithNext(sequence)
        moved("merge")
        editor.updateViewport(coalescingKey: "width") { $0.width += 100 }
        moved("drawing edit")
        editor.undo()
        moved("undo")
        editor.renameKeyframe(first, to: "Title")
        XCTAssertEqual(editor.documentRevision, revision, "a rename to the same name changes nothing")
    }
}
