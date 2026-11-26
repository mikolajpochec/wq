import XCTest
@testable import WindowQueue

/// The pure decisions behind the monitor shortcuts.
final class MonitorPlannerTests: XCTestCase {
    private func display(_ id: CGDirectDisplayID, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> MonitorPlanner.Display {
        let frame = NSRect(x: x, y: y, width: w, height: h)
        return .init(id: id, frame: frame, area: frame)
    }

    func testMonitorsCountLeftToRightThenTopToBottom() {
        let ordered = MonitorPlanner.ordered([
            display(1, 0, 0, 1000, 800),
            display(2, 1000, 0, 800, 600),
            display(3, -1200, 0, 1200, 900),
            // Stacked above and below a display at the same x: the upper one first.
            display(4, 1800, -700, 900, 700),
            display(5, 1800, 0, 900, 700),
        ])
        XCTAssertEqual(ordered.map(\.id), [3, 1, 2, 5, 4])
    }

    func testTheNextMonitorGoesRoundAllOfThemNotJustTwo() {
        XCTAssertEqual(MonitorPlanner.target(number: nil, after: 0, count: 3), .index(1))
        XCTAssertEqual(MonitorPlanner.target(number: nil, after: 1, count: 3), .index(2))
        XCTAssertEqual(MonitorPlanner.target(number: nil, after: 2, count: 3), .index(0))
        XCTAssertEqual(MonitorPlanner.target(number: nil, after: nil, count: 4), .index(1))
        XCTAssertEqual(MonitorPlanner.target(number: nil, after: 9, count: 2), .index(0), "a stale index is kept in range")
        XCTAssertEqual(MonitorPlanner.target(number: 3, after: 0, count: 3), .index(2))
        XCTAssertEqual(MonitorPlanner.target(number: 4, after: 0, count: 3), .missing(number: 4, count: 3))
        XCTAssertEqual(MonitorPlanner.target(number: 0, after: 0, count: 3), .missing(number: 0, count: 3))
        XCTAssertEqual(MonitorPlanner.target(number: 1, after: 0, count: 1), .onlyOne)
        XCTAssertEqual(MonitorPlanner.target(number: nil, after: 0, count: 1), .onlyOne)
    }

    func testAWindowBelongsToTheScreenHoldingMostOfIt() {
        let displays = [display(1, 0, 0, 1000, 800), display(2, 1000, 0, 1000, 800)]
        XCTAssertEqual(MonitorPlanner.index(holding: NSRect(x: 900, y: 0, width: 300, height: 300), in: displays), 1)
        XCTAssertEqual(MonitorPlanner.index(holding: NSRect(x: 800, y: 0, width: 300, height: 300), in: displays), 0)
        XCTAssertNil(MonitorPlanner.index(holding: NSRect(x: 5000, y: 0, width: 300, height: 300), in: displays))
        XCTAssertNil(MonitorPlanner.index(holding: NSRect(x: 0, y: 0, width: 300, height: 300), in: []))
    }

    func testAHalfStaysAHalfOnAScreenOfAnotherSize() {
        let source = NSRect(x: 0, y: 0, width: 2000, height: 1000)
        let target = NSRect(x: 2000, y: 100, width: 1000, height: 600)
        let left = MonitorPlanner.map(NSRect(x: 0, y: 0, width: 1000, height: 1000), from: source, to: target)
        XCTAssertEqual(left, NSRect(x: 2000, y: 100, width: 500, height: 600))
        let right = MonitorPlanner.map(NSRect(x: 1000, y: 500, width: 1000, height: 500), from: source, to: target)
        XCTAssertEqual(right, NSRect(x: 2500, y: 400, width: 500, height: 300))
    }

    func testAMappedFrameIsKeptInsideItsNewRoom() {
        let source = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let target = NSRect(x: -500, y: 0, width: 500, height: 500)
        // Hanging off the right edge of its screen.
        let mapped = MonitorPlanner.map(NSRect(x: 900, y: -100, width: 400, height: 400), from: source, to: target)
        XCTAssertTrue(target.contains(mapped), "\(mapped)")
        // Bigger than the area: as big as it, no bigger.
        let huge = MonitorPlanner.map(NSRect(x: 0, y: 0, width: 5000, height: 5000), from: source, to: target)
        XCTAssertEqual(huge, target)
        // A source with no room does not divide by zero.
        let degenerate = MonitorPlanner.map(NSRect(x: 0, y: 0, width: 100, height: 100), from: .zero, to: target)
        XCTAssertTrue(target.contains(degenerate))
    }

    func testMovingThereAndBackGivesTheSameFrame() {
        let a = NSRect(x: -2560, y: 0, width: 2560, height: 1416)
        let b = NSRect(x: 3008, y: 0, width: 1512, height: 958)
        let frame = NSRect(x: -2000, y: 300, width: 900, height: 700)
        let back = MonitorPlanner.map(MonitorPlanner.map(frame, from: a, to: b), from: b, to: a)
        XCTAssertEqual(back.minX, frame.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, frame.minY, accuracy: 0.001)
        XCTAssertEqual(back.width, frame.width, accuracy: 0.001)
        XCTAssertEqual(back.height, frame.height, accuracy: 0.001)
    }

    func testAMaximizedWindowCountsAsFillingWhateverTheOuterGap() {
        let area = NSRect(x: 100, y: 50, width: 1800, height: 1000)
        for outer in [0.0, 4, 12, 20, 40] as [CGFloat] {
            let gaps = WindowTiler.Gaps(outer: outer, inner: 4)
            let filled = MonitorPlanner.filledFrame(in: area, gaps: gaps)
            XCTAssertEqual(filled, area.insetBy(dx: outer, dy: outer))
            XCTAssertTrue(MonitorPlanner.fills(filled, area, gaps: gaps), "outer gap \(outer)")
            // Apps snapping to their own grid still count.
            XCTAssertTrue(MonitorPlanner.fills(filled.insetBy(dx: 5, dy: 5), area, gaps: gaps))
            XCTAssertFalse(MonitorPlanner.fills(NSRect(x: 100, y: 50, width: 900, height: 1000), area, gaps: gaps))
        }
    }

    func testRelocatingRefillsAMaximizedWindowAndMapsAnyOther() {
        let gaps = WindowTiler.Gaps(outer: 20, inner: 4)
        let a = NSRect(x: 0, y: 0, width: 2000, height: 1200)
        let b = NSRect(x: 2000, y: 0, width: 1000, height: 700)
        let maximized = MonitorPlanner.relocate(MonitorPlanner.filledFrame(in: a, gaps: gaps), from: a, to: b, gaps: gaps)
        XCTAssertEqual(maximized, .init(frame: MonitorPlanner.filledFrame(in: b, gaps: gaps), fills: true))
        let half = MonitorPlanner.relocate(NSRect(x: 0, y: 0, width: 1000, height: 1200), from: a, to: b, gaps: gaps)
        XCTAssertEqual(half, .init(frame: NSRect(x: 2000, y: 0, width: 500, height: 700), fills: false))
    }

    func testTheFrameToGoBackToFollowsTheWindowToItsNewMonitor() {
        let displays = [display(1, -1000, 0, 1000, 800), display(2, 0, 0, 2000, 1600)]
        let onFirst = NSRect(x: -900, y: 100, width: 400, height: 400)
        XCTAssertEqual(MonitorPlanner.carried(onFirst, from: displays[0].area, to: displays[1].area),
                       NSRect(x: 200, y: 200, width: 800, height: 800))
        XCTAssertNil(MonitorPlanner.carried(nil, from: displays[0].area, to: displays[1].area))

        // Out of fullscreen on the second monitor with a frame remembered on the first.
        let filled = displays[1].area
        XCTAssertEqual(MonitorPlanner.restoreFrame(onFirst, current: filled, area: filled, displays: displays),
                       NSRect(x: 200, y: 200, width: 800, height: 800))
        // Remembered on the same monitor: exactly as it was.
        let onSecond = NSRect(x: 300, y: 300, width: 500, height: 500)
        XCTAssertEqual(MonitorPlanner.restoreFrame(onSecond, current: filled, area: filled, displays: displays), onSecond)
        // Remembered on a display since unplugged: its size, inside this screen.
        let lost = NSRect(x: 9000, y: 0, width: 300, height: 300)
        XCTAssertEqual(MonitorPlanner.restoreFrame(lost, current: filled, area: filled, displays: displays),
                       NSRect(x: 1700, y: 0, width: 300, height: 300))
    }

    func testPlanningAMove() {
        let gaps = WindowTiler.Gaps(outer: 0, inner: 0)
        let displays = [display(1, -1000, 0, 1000, 800), display(2, 0, 0, 1000, 800), display(3, 1000, 0, 500, 400)]
        let onFirst = NSRect(x: -900, y: 100, width: 400, height: 400)
        let onThird = NSRect(x: 1100, y: 0, width: 200, height: 200)

        XCTAssertEqual(MonitorPlanner.planMove([(1, onFirst)], toMonitor: nil, displays: [displays[0]], gaps: gaps), .onlyOne)
        XCTAssertEqual(MonitorPlanner.planMove([(1, onFirst)], toMonitor: 5, displays: displays, gaps: gaps),
                       .missing(number: 5, count: 3))
        XCTAssertEqual(MonitorPlanner.planMove([(1, nil)], toMonitor: 2, displays: displays, gaps: gaps), .nothing,
                       "a window that cannot be measured is not moved")
        XCTAssertEqual(MonitorPlanner.planMove([(1, NSRect(x: 9000, y: 0, width: 10, height: 10))], toMonitor: 2,
                                               displays: displays, gaps: gaps), .nothing, "nor one off every screen")
        XCTAssertEqual(MonitorPlanner.planMove([(1, onFirst)], toMonitor: 1, displays: displays, gaps: gaps),
                       .alreadyThere(target: 0))

        // Aimed windows on two monitors go to the one after the lead's; the one already there stays.
        guard case .move(let target, let lead, let moves) = MonitorPlanner.planMove(
            [(1, onFirst), (2, nil), (3, NSRect(x: 100, y: 100, width: 300, height: 300)), (4, onThird)],
            toMonitor: nil, displays: displays, gaps: gaps)
        else { return XCTFail("expected a move") }
        XCTAssertEqual(target, 1)
        XCTAssertEqual(lead, 0)
        XCTAssertEqual(moves.map(\.id), [1, 4])
        XCTAssertEqual(moves.map(\.from), [0, 2])
        XCTAssertEqual(moves[0].landing.frame, NSRect(x: 100, y: 100, width: 400, height: 400))
        XCTAssertEqual(moves[1].landing.frame, NSRect(x: 200, y: 0, width: 400, height: 400))
    }

    func testFocusLandsOnTheTopmostWindowThere() {
        XCTAssertEqual(MonitorPlanner.landing(among: [3, 4, 5], frontToBack: [9, 5, 4, 3]), 5)
        XCTAssertEqual(MonitorPlanner.landing(among: [3, 4], frontToBack: [9, 8]), 3, "none on show: the queue's first")
        XCTAssertNil(MonitorPlanner.landing(among: [], frontToBack: [9, 8]))
    }

    func testCoordinateFlipsBetweenCocoaAndTheWindowServer() {
        let primaryHeight: CGFloat = 1692
        // A display above the primary one has a negative y in WindowServer coordinates.
        let above = NSRect(x: 200, y: 1692, width: 2560, height: 1440)
        XCTAssertEqual(MonitorPlanner.flipped(above, primaryHeight: primaryHeight),
                       NSRect(x: 200, y: -1440, width: 2560, height: 1440))
        // One below has its top at the primary's bottom.
        let below = NSRect(x: 0, y: -982, width: 1512, height: 982)
        XCTAssertEqual(MonitorPlanner.flipped(below, primaryHeight: primaryHeight),
                       NSRect(x: 0, y: 1692, width: 1512, height: 982))
        for rect in [above, below, NSRect(x: -2560, y: 13, width: 7, height: 99)] {
            XCTAssertEqual(MonitorPlanner.flipped(MonitorPlanner.flipped(rect, primaryHeight: primaryHeight),
                                                  primaryHeight: primaryHeight), rect)
        }
        XCTAssertEqual(MonitorPlanner.warpPoint(for: above, primaryHeight: primaryHeight), CGPoint(x: 1480, y: -720))
    }

    func testTheStripsRoomComesOffItsSide() {
        var prefs = Preferences()
        prefs.reserveScreenSpace = true
        let area = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let gap = CGFloat(StripMetrics.reservedWidth(for: prefs))
        XCTAssertGreaterThan(gap, 0)
        prefs.stripSide = .left
        XCTAssertEqual(MonitorPlanner.stripReduced(area, prefs: prefs), NSRect(x: gap, y: 0, width: 1000 - gap, height: 800))
        prefs.stripSide = .right
        XCTAssertEqual(MonitorPlanner.stripReduced(area, prefs: prefs), NSRect(x: 0, y: 0, width: 1000 - gap, height: 800))
        prefs.stripSide = .top
        XCTAssertEqual(MonitorPlanner.stripReduced(area, prefs: prefs), NSRect(x: 0, y: 0, width: 1000, height: 800 - gap))
        prefs.stripSide = .bottom
        XCTAssertEqual(MonitorPlanner.stripReduced(area, prefs: prefs), NSRect(x: 0, y: gap, width: 1000, height: 800 - gap))
        prefs.reserveScreenSpace = false
        XCTAssertEqual(MonitorPlanner.stripReduced(area, prefs: prefs), area)
        prefs.reserveScreenSpace = true
        prefs.stripDisplay = .hidden
        XCTAssertEqual(MonitorPlanner.stripReduced(area, prefs: prefs), area)
    }
}
