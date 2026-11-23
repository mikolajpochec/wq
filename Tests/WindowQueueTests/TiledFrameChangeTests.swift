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
