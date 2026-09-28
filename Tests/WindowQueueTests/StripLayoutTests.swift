import XCTest
@testable import WindowQueue

final class StripLayoutTests: XCTestCase {
    private func window(_ id: CGWindowID) -> ManagedWindow {
        ManagedWindow(id: id, element: nil, pid: 1, appName: "A", bundleID: nil,
                      title: "w\(id)", isMinimized: false, spaceID: 10)
    }

    private var prefs: Preferences {
        var prefs = Preferences()
        prefs.showSpaceBadge = false
        return prefs
    }

    /// A group's tile is drawn a row long, so entries after it must not be pushed further down.
    func testGroupTakesOneRow() {
        let windows = [1, 2, 3].map(window)
        let layout = StripLayout(windows: windows, prefs: prefs, groups: [1: 7, 2: 7])
        let row = StripMetrics.rowHeight(prefs: prefs)
        XCTAssertEqual(layout.topOffset(ofWindowAt: 2), StripMetrics.padding + row + StripMetrics.spacing)
    }

    /// A group whose members are not neighbours in the queue is still one entry: aiming it and the
    /// window after it is one run covering exactly the two tiles.
    func testSpansFollowEntriesNotQueuePositions() {
        let windows = [1, 2, 3, 4].map(window)
        let layout = StripLayout(windows: windows, prefs: prefs, groups: [1: 7, 3: 7])
        let row = StripMetrics.rowHeight(prefs: prefs)
        // Entries: group(1, 3), 2, 4. Aim the group and window 2.
        let spans = layout.spans(ofWindowsAt: [0, 2, 1])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].start, StripMetrics.padding)
        XCTAssertEqual(spans[0].length, row * 2 + StripMetrics.spacing)
        // The group and window 4 are not neighbours on the strip.
        XCTAssertEqual(layout.spans(ofWindowsAt: [0, 3]).count, 2)
    }

    /// The collapsed stack is as long as the cards it shows.
    func testHiddenStackLengthFollowsCards() {
        let windows = [1, 2, 3].map(window)
        let layout = StripLayout(windows: windows, prefs: prefs, collapsed: [1, 2])
        let stack = StripMetrics.rowHeight(prefs: prefs) + StripMetrics.stackStep
        XCTAssertEqual(layout.spans(ofWindowsAt: [0]).first?.length, stack)
        XCTAssertEqual(layout.topOffset(ofWindowAt: 2), StripMetrics.padding + stack + StripMetrics.spacing)
    }
}
