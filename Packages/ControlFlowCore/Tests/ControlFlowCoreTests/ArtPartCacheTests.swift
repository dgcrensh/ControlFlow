import XCTest
@testable import ControlFlowCore

/// `ArtBuilder` keeps each part's steps and vertices and reuses them while the part and
/// what it depends on are unchanged (plan step 2): a warm build must equal a cold one,
/// rebuild only the parts that changed, and give the renderer only those to upload.
final class ArtPartCacheTests: XCTestCase {
    private let base = StressDrawing.make(parts: 6, shapesPerPart: 8)

    private struct Context {
        var isolatedPart: Int?
        var isolatedGroup: Int?
        var tolerance = 0.5
        var ghostFocus: Set<Int>?
        var moving: Set<Int> = []
    }

    private func build(_ builder: inout ArtBuilder, _ d: Drawing, _ c: Context = Context()) -> ArtBatch {
        builder.build(d, isolatedPart: c.isolatedPart, isolatedGroup: c.isolatedGroup, tolerance: c.tolerance,
                      ghostFocus: c.ghostFocus, moving: c.moving)
    }

    /// Builds `before` warm, then `after`, and checks the warm build of `after` against a
    /// cold one: same vertices, steps and segment ranges (segment ids differ by builder).
    @discardableResult
    private func assertWarmEqualsCold(from before: Drawing, _ beforeContext: Context = Context(), to after: Drawing,
                                      _ afterContext: Context = Context(),
                                      file: StaticString = #filePath, line: UInt = #line) -> (rebuilt: Int, uploads: Int) {
        var warm = ArtBuilder()
        let first = build(&warm, before, beforeContext)
        let builds = warm.partBuilds
        let warmBatch = build(&warm, after, afterContext)
        var cold = ArtBuilder()
        let coldBatch = build(&cold, after, afterContext)
        XCTAssertEqual(warmBatch.vertices, coldBatch.vertices, file: file, line: line)
        XCTAssertEqual(warmBatch.steps, coldBatch.steps, file: file, line: line)
        XCTAssertEqual(warmBatch.segments.map(\.vertices), coldBatch.segments.map(\.vertices), file: file, line: line)
        XCTAssertEqual(warmBatch.segments.map(\.steps), coldBatch.segments.map(\.steps), file: file, line: line)
        Self.assertSegmentsAreConsistent(warmBatch, file: file, line: line)
        return (warm.partBuilds - builds, warmBatch.segmentsToUpload(resident: first.residentIDs).count)
    }

    /// Segments tile the steps and vertices in order, and each segment's floats are its
    /// slice of the batch's vertices.
    static func assertSegmentsAreConsistent(_ batch: ArtBatch, file: StaticString = #filePath, line: UInt = #line) {
        var step = 0, vertex = 0
        for segment in batch.segments {
            XCTAssertEqual(segment.steps.lowerBound, step, file: file, line: line)
            XCTAssertEqual(segment.vertices.lowerBound, vertex, file: file, line: line)
            XCTAssertEqual(segment.floats, Array(batch.vertices[(segment.vertices.lowerBound * 2)..<(segment.vertices.upperBound * 2)]),
                           file: file, line: line)
            for i in segment.steps {
                switch batch.steps[i] {
                case .stencil(let range, _, _), .cover(let range, _, _, _):
                    XCTAssertTrue(range.isEmpty || segment.vertices.contains(range.lowerBound) &&
                                  range.upperBound <= segment.vertices.upperBound, file: file, line: line)
                    let local = segment.local(range)
                    XCTAssertGreaterThanOrEqual(local.lowerBound, 0, file: file, line: line)
                    XCTAssertLessThanOrEqual(local.upperBound * 2, segment.floats.count, file: file, line: line)
                default:
                    break
                }
            }
            step = segment.steps.upperBound
            vertex = segment.vertices.upperBound
        }
        XCTAssertEqual(step, batch.steps.count, file: file, line: line)
        XCTAssertEqual(vertex, batch.vertexCount, file: file, line: line)
    }

    // MARK: Warm equals cold

    func testOneEditRebuildsOnePartAndUploadsOneSegment() {
        var edited = base
        edited.parts[3].shapes[2].fill = RGBAColor(r: 1, g: 0, b: 0)
        let (rebuilt, uploads) = assertWarmEqualsCold(from: base, to: edited)
        XCTAssertEqual(rebuilt, 1)
        XCTAssertEqual(uploads, 1)

        // The same drawing again rebuilds nothing.
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: base).rebuilt, 0)
    }

    func testTheUploadIsTheEditedPartsSegment() {
        var builder = ArtBuilder()
        let first = build(&builder, base)
        var edited = base
        edited.parts[3].shapes[2].path.points[0].position += Vec2(4, 1)
        let second = build(&builder, edited)
        let uploads = second.segmentsToUpload(resident: first.residentIDs)
        XCTAssertEqual(uploads.count, 1)
        // Part 3 is the fourth in the stack (the accessory of part 0 isn't split).
        XCTAssertEqual(uploads.first, second.segments[3])
        // Every other segment keeps its id, so its buffer stays.
        for i in second.segments.indices where i != 3 {
            XCTAssertEqual(second.segments[i].id, first.segments[i].id)
        }
        XCTAssertEqual(second.residentIDs.subtracting(first.residentIDs), [second.segments[3].id])
    }

    func testAPartAdded() {
        var added = base
        var part = Part(id: added.makeID(), name: "New")
        part.shapes = [VectorShape(id: added.makeID(), path: base.parts[0].shapes[0].path, fill: RGBAColor(r: 0, g: 1, b: 0))]
        added.parts.insert(part, at: 2)
        let (rebuilt, uploads) = assertWarmEqualsCold(from: base, to: added)
        XCTAssertEqual(rebuilt, 1)
        XCTAssertEqual(uploads, 1)
    }

    func testAPartReordered() {
        var reordered = base
        reordered.parts.swapAt(2, 4)
        let (rebuilt, uploads) = assertWarmEqualsCold(from: base, to: reordered)
        XCTAssertEqual(rebuilt, 0, "reordering moves the cached parts")
        XCTAssertEqual(uploads, 0)
    }

    func testAPartDeleted() {
        var deleted = base
        deleted.parts.remove(at: 4)
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: deleted).rebuilt, 0)

        var builder = ArtBuilder()
        _ = build(&builder, base)
        let all = builder.cachedShapeCount
        _ = build(&builder, deleted)
        XCTAssertEqual(builder.cachedShapeCount, all - base.parts[4].shapes.count, "the deleted shapes' tessellations go")
    }

    func testAShapeMovedToAnotherPart() {
        var moved = base
        let shape = moved.parts[2].shapes.remove(at: 1)
        moved.parts[4].shapes.append(shape)
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: moved).rebuilt, 2)
        var builder = ArtBuilder()
        _ = build(&builder, base)
        let all = builder.cachedShapeCount
        _ = build(&builder, moved)
        XCTAssertEqual(builder.cachedShapeCount, all, "the moved shape keeps its tessellation")
    }

    func testIsolationOnAndOff() {
        let isolated = Context(isolatedPart: base.parts[2].id)
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: base, isolated).rebuilt, 1, "only the isolated part changes context")
        assertWarmEqualsCold(from: base, isolated, to: base)
        let other = Context(isolatedPart: base.parts[4].id)
        XCTAssertEqual(assertWarmEqualsCold(from: base, isolated, to: base, other).rebuilt, 2)
    }

    func testAnIsolatedGroup() {
        // Part 0 has a clipped group (every fourth part does).
        let part = base.parts[0]
        let group = try! XCTUnwrap(part.groups.first).id
        let inPart = Context(isolatedPart: part.id)
        let inGroup = Context(isolatedPart: part.id, isolatedGroup: group)
        XCTAssertEqual(assertWarmEqualsCold(from: base, inPart, to: base, inGroup).rebuilt, 1)
        assertWarmEqualsCold(from: base, inGroup, to: base, inPart)
        assertWarmEqualsCold(from: base, inGroup, to: base)
    }

    func testGhostFocus() {
        let focus: Set<Int> = [base.parts[1].shapes[0].id, base.parts[1].shapes[3].id]
        let ghost = Context(ghostFocus: focus)
        assertWarmEqualsCold(from: base, to: base, ghost)
        assertWarmEqualsCold(from: base, ghost, to: base)
        // Moving the focus within part 1 rebuilds only part 1.
        let moved = Context(ghostFocus: [base.parts[1].shapes[5].id])
        XCTAssertEqual(assertWarmEqualsCold(from: base, ghost, to: base, moved).rebuilt, 1)
    }

    func testALiveTransformMovingShapesInTwoParts() {
        let moving: Set<Int> = [base.parts[1].shapes[7].id, base.parts[2].shapes[0].id, base.parts[2].shapes[1].id,
                                base.parts[4].shapes[3].id]
        let live = Context(moving: moving)
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: base, live).rebuilt, 3)
        assertWarmEqualsCold(from: base, live, to: base)

        var builder = ArtBuilder()
        let batch = build(&builder, base, live)
        let marks = batch.steps.compactMap { step -> Bool? in if case .moving(let on) = step { on } else { nil } }
        // Part 1 ends moving and part 2 starts moving: one run across both, then part 4's.
        XCTAssertEqual(marks, [true, false, true, false])
        XCTAssertEqual(marks.count, 4)
    }

    func testANewTolerance() {
        let fine = Context(tolerance: 0.1)
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: base, fine).rebuilt, base.parts.count)
    }

    /// A part built while a refine is under way holds shapes at the old tolerance. Once
    /// the refined shapes are merged it must be rebuilt, not reused, even though its key
    /// (and so the tolerance it was built for) is unchanged; after that it is reused.
    func testAPartBuiltDuringARefineIsRebuiltOnceRefined() {
        var warm = ArtBuilder()
        _ = warm.build(base, isolatedPart: nil, tolerance: 0.5)
        let tessellated = warm.tessellationCount
        _ = warm.build(base, isolatedPart: nil, tolerance: 0.25, reusingOtherTolerances: true)
        XCTAssertEqual(warm.tessellationCount, tessellated, "nothing is flattened again while the refine runs")

        let shapes = base.parts.flatMap(\.shapes)
        guard let refined = TessellationCache.tessellate(shapes, tolerance: 0.25, isCancelled: { false }) else {
            return XCTFail("not cancelled")
        }
        _ = warm.tessellations.merge(refined, for: base)
        let builds = warm.partBuilds
        let after = warm.build(base, isolatedPart: nil, tolerance: 0.25, reusingOtherTolerances: true)
        XCTAssertEqual(warm.partBuilds - builds, base.parts.count, "every mixed part is rebuilt")
        XCTAssertEqual(warm.tessellationCount, tessellated, "from the merged tessellations")

        var cold = ArtBuilder()
        let coldBatch = cold.build(base, isolatedPart: nil, tolerance: 0.25)
        XCTAssertEqual(after.vertices, coldBatch.vertices)
        XCTAssertEqual(after.steps, coldBatch.steps)

        let rebuilt = warm.partBuilds
        _ = warm.build(base, isolatedPart: nil, tolerance: 0.25)
        XCTAssertEqual(warm.partBuilds, rebuilt, "exact parts are reused")
    }

    func testHiddenPartsAndShapes() {
        var hidden = base
        hidden.parts[2].isHidden = true
        hidden.parts[3].shapes[0].isHidden = true
        XCTAssertEqual(assertWarmEqualsCold(from: base, to: hidden).rebuilt, 2)
        assertWarmEqualsCold(from: hidden, to: base)
    }

    // MARK: Segments without concatenation

    func testSegmentsCarryTheVerticesWithoutConcatenating() {
        var full = ArtBuilder()
        let expected = build(&full, base)
        var split = ArtBuilder()
        split.concatenatesVertices = false
        let batch = build(&split, base)
        XCTAssertTrue(batch.vertices.isEmpty)
        XCTAssertEqual(batch.steps, expected.steps)
        XCTAssertEqual(batch.segments.flatMap(\.floats), expected.vertices)
        XCTAssertEqual(batch.segments.map(\.vertices), expected.segments.map(\.vertices))
    }

    func testEmptyPartsHaveNothingToUpload() {
        var d = base
        d.parts[2].isHidden = true
        var builder = ArtBuilder()
        let batch = build(&builder, d)
        XCTAssertTrue(batch.segments[2].floats.isEmpty)
        XCTAssertFalse(batch.residentIDs.contains(batch.segments[2].id))
        XCTAssertFalse(batch.segmentsToUpload(resident: []).contains(batch.segments[2]))
        XCTAssertEqual(batch.segmentsToUpload(resident: []).count, batch.segments.count - 1)
    }
}
