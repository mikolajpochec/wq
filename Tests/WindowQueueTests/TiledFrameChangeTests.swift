import XCTest
@testable import WindowQueue

final class TiledFrameChangeTests: XCTestCase {
    let placed = NSRect(x: 100, y: 100, width: 800, height: 600)

    func testSameFrameIsUnchanged() {
        XCTAssertEqual(TiledFrameChange.between(placed, placed.offsetBy(dx: 2, dy: -3)), .unchanged)
    }

    func testDraggingAnEdgeOrCornerIsAResize() {
        // Right edge.
        XCTAssertEqual(TiledFrameChange.between(placed, NSRect(x: 100, y: 100, width: 950, height: 600)), .resized)
        // Left edge: the origin moves, the right edge stays.
        XCTAssertEqual(TiledFrameChange.between(placed, NSRect(x: 40, y: 100, width: 860, height: 600)), .resized)
        // Top-left corner.
        XCTAssertEqual(TiledFrameChange.between(placed, NSRect(x: 150, y: 50, width: 750, height: 650)), .resized)
    }

    func testMovingIsAMove() {
        XCTAssertEqual(TiledFrameChange.between(placed, placed.offsetBy(dx: 60, dy: 0)), .moved)
        // Moved and resized at once (e.g. onto another screen that the app refits to).
        XCTAssertEqual(TiledFrameChange.between(placed, NSRect(x: 400, y: 300, width: 700, height: 500)), .moved)
    }
}

final class TiledResizeTests: XCTestCase {
    // Two columns 10 pt apart.
    let left = NSRect(x: 0, y: 0, width: 500, height: 800)
    let right = NSRect(x: 510, y: 0, width: 490, height: 800)

    func testWideningOneColumnNarrowsTheOther() {
        let moves = TiledResize.follow(from: left, to: NSRect(x: 0, y: 0, width: 600, height: 800),
                                       others: [2: right], gap: 10)
        XCTAssertEqual(moves[2], NSRect(x: 610, y: 0, width: 390, height: 800))
    }

    func testNarrowingFromTheLeftEdgeWidensTheLeftNeighbour() {
        let moves = TiledResize.follow(from: right, to: NSRect(x: 410, y: 0, width: 590, height: 800),
                                       others: [1: left], gap: 10)
        XCTAssertEqual(moves[1], NSRect(x: 0, y: 0, width: 400, height: 800))
    }

    func testMainAndStackDividerMovesTheWholeStack() {
        let main = NSRect(x: 0, y: 0, width: 500, height: 800)
        let top = NSRect(x: 510, y: 405, width: 490, height: 395)
        let bottom = NSRect(x: 510, y: 0, width: 490, height: 395)
        // Resizing the top stack window by its left edge drags the shared divider.
        let moves = TiledResize.follow(from: top, to: NSRect(x: 610, y: 405, width: 390, height: 395),
                                       others: [1: main, 3: bottom], gap: 10)
        XCTAssertEqual(moves[1], NSRect(x: 0, y: 0, width: 600, height: 800))
        XCTAssertEqual(moves[3], NSRect(x: 610, y: 0, width: 390, height: 395))
    }

    func testStackDividerMovesOnlyTheStack() {
        let main = NSRect(x: 0, y: 0, width: 500, height: 800)
        let top = NSRect(x: 510, y: 405, width: 490, height: 395)
        let bottom = NSRect(x: 510, y: 0, width: 490, height: 395)
        // Dragging the bottom window's top edge up (Cocoa y grows upwards).
        let moves = TiledResize.follow(from: bottom, to: NSRect(x: 510, y: 0, width: 490, height: 495),
                                       others: [1: main, 2: top], gap: 10)
        XCTAssertNil(moves[1])
        XCTAssertEqual(moves[2], NSRect(x: 510, y: 505, width: 490, height: 295))
    }

    func testANeighbourStopsAtItsSmallestSize() {
        let moves = TiledResize.follow(from: left, to: NSRect(x: 0, y: 0, width: 950, height: 800),
                                       others: [2: right], gap: 10)
        XCTAssertEqual(moves[2], NSRect(x: 1000 - TiledResize.minimumSide, y: 0,
                                        width: TiledResize.minimumSide, height: 800))
    }
}

final class TiledResizeSnappingTests: XCTestCase {
    func testATerminalShortOfItsCellStillFollows() {
        // The top window kept to whole text rows and ended 14 pt short of the bottom one's gap.
        let top = NSRect(x: 510, y: 419, width: 490, height: 381)
        let bottom = NSRect(x: 510, y: 0, width: 490, height: 395)
        let moves = TiledResize.follow(from: bottom, to: NSRect(x: 510, y: 0, width: 490, height: 300),
                                       others: [2: top], gap: 10)
        XCTAssertEqual(moves[2], NSRect(x: 510, y: 310, width: 490, height: 490))
    }
}

final class TiledFrameChangeSnappingTests: XCTestCase {
    func testATerminalRoundingItsWidthIsStillAResize() {
        // Seen live: Ghostty's left edge dragged 20 pt in, its right edge slipped 24 pt with the rounding.
        let placed = NSRect(x: 648, y: 442, width: 1150, height: 685)
        XCTAssertEqual(TiledFrameChange.between(placed, NSRect(x: 668, y: 442, width: 1106, height: 685)), .resized)
    }

    func testJumpingToTheOtherHalfIsAMove() {
        let placed = NSRect(x: 0, y: 0, width: 900, height: 800)
        XCTAssertEqual(TiledFrameChange.between(placed, NSRect(x: 900, y: 0, width: 880, height: 800)), .moved)
    }
}
