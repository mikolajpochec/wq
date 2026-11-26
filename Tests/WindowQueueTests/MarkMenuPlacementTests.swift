import AppKit
import XCTest
@testable import WindowQueue

/// The mark menu opens off the strip, on the screen's side of it: the strip floats above menus.
final class MarkMenuPlacementTests: XCTestCase {
    private let menu = NSSize(width: 200, height: 300)

    /// The menu's rect for a top-left origin, as `NSMenu.popUp(…in: nil)` lays it out.
    private func rect(_ origin: NSPoint) -> NSRect {
        NSRect(x: origin.x, y: origin.y - menu.height, width: menu.width, height: menu.height)
    }

    func testMenuClearsTheStripOnEverySide() {
        let rows: [StripSide: NSRect] = [
            .left: NSRect(x: 0, y: 500, width: 60, height: 60),
            .right: NSRect(x: 1860, y: 500, width: 60, height: 60),
            .top: NSRect(x: 900, y: 1020, width: 60, height: 60),
            .bottom: NSRect(x: 900, y: 0, width: 60, height: 60),
        ]
        for (side, row) in rows {
            let menuRect = rect(AppDelegate.markMenuOrigin(beside: row, side: side, menuSize: menu))
            XCTAssertFalse(menuRect.intersects(row), "\(side): menu \(menuRect) covers row \(row)")
            switch side {
            case .left: XCTAssertGreaterThanOrEqual(menuRect.minX, row.maxX)
            case .right: XCTAssertLessThanOrEqual(menuRect.maxX, row.minX)
            case .top: XCTAssertLessThanOrEqual(menuRect.maxY, row.minY)
            case .bottom: XCTAssertGreaterThanOrEqual(menuRect.minY, row.maxY)
            }
        }
    }
}
