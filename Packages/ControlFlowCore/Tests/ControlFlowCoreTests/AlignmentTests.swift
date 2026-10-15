import XCTest
@testable import ControlFlowCore

private func box(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> Rect {
    Rect(minPoint: Vec2(x, y), maxPoint: Vec2(x + w, y + h))
}

private func moved(_ boxes: [Rect], _ offsets: [Vec2]) -> [Rect] {
    zip(boxes, offsets).map { Rect(minPoint: $0.minPoint + $1, maxPoint: $0.maxPoint + $1) }
}

final class AlignmentTests: XCTestCase {
    let boxes = [box(10, 50, 20, 10), box(40, 0, 40, 40), box(100, 20, 10, 60)]
    var union: Rect { boxes.reduce(Rect.null) { $0.union($1) } }

    func testEachEdgeLinesUpWithTheReference() {
        let expected: [(AlignEdge, (Rect) -> Double, Double)] = [
            (.left, { $0.minPoint.x }, 10), (.centerX, { $0.center.x }, 60), (.right, { $0.maxPoint.x }, 110),
            (.top, { $0.minPoint.y }, 0), (.centerY, { $0.center.y }, 40), (.bottom, { $0.maxPoint.y }, 80),
        ]
        for (edge, line, value) in expected {
            let offsets = Aligner.offsets(boxes: boxes, edge: edge, reference: union)
            for (b, d) in zip(moved(boxes, offsets), offsets) {
                XCTAssertEqual(line(b), value, accuracy: 1e-9, "\(edge)")
                XCTAssertEqual(edge.isHorizontal ? d.y : d.x, 0, "\(edge) moves along one axis")
            }
        }
    }

    func testTheReferenceBoxDoesNotMove() {
        let offsets = Aligner.offsets(boxes: boxes, edge: .top, reference: boxes[1])
        XCTAssertEqual(offsets[1], .zero)
        XCTAssertEqual(offsets[0], Vec2(0, -50))
    }

    func testPointsAlignToTheirOwnExtent() {
        let points = [Vec2(0, 10), Vec2(5, 30), Vec2(20, 20)]
        XCTAssertEqual(Aligner.offsets(points: points, edge: .centerY), [Vec2(0, 10), Vec2(0, -10), .zero])
        XCTAssertEqual(Aligner.offsets(points: points, edge: .right), [Vec2(20, 0), Vec2(15, 0), .zero])
        XCTAssertEqual(Aligner.offsets(points: [], edge: .left), [])
    }

    func testSpacingMakesEqualGapsWithTheOuterBoxesStill() {
        // Unequal widths: total span 0...100, widths 10 + 30 + 20 = 60, so gaps of 20.
        let row = [box(0, 0, 10, 10), box(80, 0, 20, 10), box(15, 0, 30, 10)]
        let offsets = Distributor.offsets(boxes: row, mode: .spacingX, within: nil)
        XCTAssertEqual(offsets[0], .zero)
        XCTAssertEqual(offsets[1], .zero)
        let out = moved(row, offsets)
        XCTAssertEqual(out[2].minPoint.x, 30, accuracy: 1e-9)
        XCTAssertEqual(out[2].maxPoint.x, 60, accuracy: 1e-9)
    }

    func testSpacingWithEqualBoxesAndFour() {
        let column = [box(0, 0, 10, 10), box(0, 13, 10, 10), box(0, 50, 10, 10), box(0, 90, 10, 10)]
        let out = moved(column, Distributor.offsets(boxes: column, mode: .spacingY, within: nil))
        XCTAssertEqual(out.map(\.minPoint.y), [0, 30, 60, 90])
    }

    func testOverlappingBoxesGetEqualNegativeGaps() {
        let row = [box(0, 0, 50, 10), box(10, 0, 50, 10), box(40, 0, 50, 10)]
        let out = moved(row, Distributor.offsets(boxes: row, mode: .spacingX, within: nil))
        // Span 90, widths 150: each gap is -30.
        XCTAssertEqual(out.map(\.minPoint.x), [0, 20, 40])
    }

    func testCentersMakeEqualSteps() {
        let row = [box(0, 0, 10, 10), box(30, 0, 40, 10), box(90, 0, 20, 10)]
        let out = moved(row, Distributor.offsets(boxes: row, mode: .centersX, within: nil))
        XCTAssertEqual(out.map(\.center.x), [5, 52.5, 100])
    }

    func testTiesInCenterOrderKeepInputOrder() {
        // Boxes 1 and 2 share a center: 1 comes first, so it takes the earlier slot.
        let row = [box(0, 0, 10, 10), box(40, 0, 10, 10), box(40, 0, 10, 10), box(90, 0, 10, 10)]
        let out = moved(row, Distributor.offsets(boxes: row, mode: .spacingX, within: nil))
        XCTAssertEqual(out.map(\.minPoint.x), [0, 30, 60, 90])
    }

    func testWithinTheViewportTheOuterBoxesTouchItsEdges() {
        let viewport = box(0, 0, 200, 100)
        let row = [box(20, 0, 10, 10), box(50, 0, 20, 10), box(100, 0, 10, 10)]
        let out = moved(row, Distributor.offsets(boxes: row, mode: .spacingX, within: viewport))
        XCTAssertEqual(out.map(\.minPoint.x), [0, 90, 190])
        let centers = moved(row, Distributor.offsets(boxes: row, mode: .centersX, within: viewport))
        XCTAssertEqual(centers.map(\.center.x), [5, 100, 195])
    }

    func testFewerThanThreeDoNotMove() {
        let pair = [box(0, 0, 10, 10), box(50, 0, 10, 10)]
        XCTAssertEqual(Distributor.offsets(boxes: pair, mode: .spacingX, within: box(0, 0, 500, 500)), [.zero, .zero])
        XCTAssertEqual(Distributor.offsets(points: [.zero, Vec2(3, 3)], mode: .centersY), [.zero, .zero])
    }

    func testPointsDistributeEvenly() {
        let points = [Vec2(0, 0), Vec2(9, 0), Vec2(3, 0), Vec2(5, 4)]
        let offsets = Distributor.offsets(points: points, mode: .spacingX)
        XCTAssertEqual(zip(points, offsets).map { $0.x + $1.x }, [0, 9, 3, 6])
        XCTAssertTrue(offsets.allSatisfy { $0.y == 0 })
    }
}
