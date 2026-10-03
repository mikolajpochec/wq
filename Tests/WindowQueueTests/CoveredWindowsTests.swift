import CoreGraphics
import XCTest
@testable import WindowQueue

final class CoveredWindowsTests: XCTestCase {
    private func window(_ id: CGWindowID, pid: pid_t, _ rect: CGRect) -> [String: Any] {
        [kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: pid,
         kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1.0,
         kCGWindowBounds as String: rect.dictionaryRepresentation]
    }

    private let chrome: pid_t = 100, slack: pid_t = 200
    private let left = CGRect(x: 0, y: 0, width: 500, height: 800)
    private let right = CGRect(x: 500, y: 0, width: 500, height: 800)

    func testAnotherWindowOfTheSameAppInTheQueueCovers() {
        // Chrome 1 and Slack 2 are tiled; Chrome 3, not in the layout, sits over Slack.
        let list = [window(1, pid: chrome, left), window(3, pid: chrome, right), window(2, pid: slack, right)]
        let covered = WindowTiler.coveredWindowIDs(among: [1, 2], in: list, ownPIDs: [chrome, slack],
                                                   queued: [1, 2, 3], selfPID: 1)
        XCTAssertEqual(covered, [2])
    }

    func testAnAppsOwnPopoverDoesNotCover() {
        // Chrome 4 is not in the queue: a popover or dialog of the app, on top of its own window.
        let list = [window(4, pid: chrome, CGRect(x: 100, y: 100, width: 200, height: 200)), window(1, pid: chrome, left)]
        let covered = WindowTiler.coveredWindowIDs(among: [1], in: list, ownPIDs: [chrome],
                                                   queued: [1], selfPID: 1)
        XCTAssertTrue(covered.isEmpty)
    }
}
