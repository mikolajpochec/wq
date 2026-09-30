import XCTest
import Carbon.HIToolbox
@testable import WindowQueue

final class MonitorScopeTests: XCTestCase {
    private func window(_ id: CGWindowID, space: UInt64?, frame: CGRect?) -> ManagedWindow {
        ManagedWindow(id: id, element: nil, pid: 1, appName: "A", bundleID: nil,
                      title: "w\(id)", isMinimized: false, spaceID: space, frame: frame)
    }

    /// Left monitor 1 owns desktops 10 and 20, right monitor 2 owns 30; the third display shares
    /// no Spaces and is only told by frame.
    private func makeModel(_ windows: [ManagedWindow]) -> WindowQueueModel {
        let model = WindowQueueModel()
        model.spaceOrder = [10, 20, 30]
        model.currentSpaceID = 10
        model.monitors = [
            .init(id: 1, frame: CGRect(x: -1000, y: 0, width: 1000, height: 800), spaceIDs: [10, 20]),
            .init(id: 2, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), spaceIDs: [30]),
            .init(id: 3, frame: CGRect(x: 1000, y: 0, width: 1000, height: 800), spaceIDs: []),
        ]
        model.reconcile(with: windows)
        return model
    }

    func testMonitorScopeCyclesTheCurrentMonitorsWindowsOnEveryDesktop() {
        let model = makeModel([
            window(1, space: 10, frame: CGRect(x: -900, y: 0, width: 400, height: 400)),
            window(2, space: 30, frame: CGRect(x: 100, y: 0, width: 400, height: 400)),
            window(3, space: 20, frame: CGRect(x: -500, y: 0, width: 400, height: 400)),
            window(4, space: 99, frame: CGRect(x: 1600, y: 100, width: 300, height: 300)),
        ])
        model.scope = .monitor
        model.currentMonitorID = 1
        XCTAssertEqual(model.visibleWindows.map(\.id), [1, 3])
        model.currentMonitorID = 2
        XCTAssertEqual(model.visibleWindows.map(\.id), [2])
        model.currentMonitorID = 3
        XCTAssertEqual(model.visibleWindows.map(\.id), [4], "a display without its own Spaces goes by frame")
    }

    func testEveryMonitorsStripShowsItsOwnQueue() {
        let model = makeModel([
            window(1, space: 10, frame: CGRect(x: -900, y: 0, width: 400, height: 400)),
            window(2, space: 30, frame: CGRect(x: 100, y: 0, width: 400, height: 400)),
            window(3, space: 20, frame: CGRect(x: -500, y: 0, width: 400, height: 400)),
            window(4, space: nil, frame: nil),
        ])
        model.scope = .monitor
        model.queuePerMonitor = true
        model.currentMonitorID = 2
        XCTAssertEqual(model.stripWindows(onMonitor: 1).map(\.id), [1, 3])
        XCTAssertEqual(Set(model.stripWindows(onMonitor: 2).map(\.id)), [2, 4], "unknown windows go with the focused monitor")
        XCTAssertEqual(model.stripWindows(onMonitor: 3).map(\.id), [])
        XCTAssertEqual(Set(model.visibleWindows.map(\.id)), [2, 4], "the keyboard works on the focused monitor")

        // Reordering on another monitor's strip moves within that monitor's queue.
        model.onMonitor(1) { model.move(id: 3, toVisiblePosition: 0) }
        XCTAssertEqual(model.stripWindows(onMonitor: 1).map(\.id), [3, 1])

        // Without multi-monitor mode every strip shows the focused monitor's queue.
        model.queuePerMonitor = false
        XCTAssertEqual(Set(model.stripWindows(onMonitor: 1).map(\.id)), [2, 4])
    }

    func testWorkspaceScopePerMonitorShowsTheDesktopEachMonitorHasOnShow() {
        let model = makeModel([
            window(1, space: 10, frame: nil),
            window(2, space: 30, frame: nil),
            window(3, space: 20, frame: nil),
        ])
        model.monitors = [
            .init(id: 1, frame: .zero, spaceIDs: [10, 20], shownSpaceID: 20),
            .init(id: 2, frame: .zero, spaceIDs: [30], shownSpaceID: 30),
        ]
        model.scope = .currentSpace
        model.queuePerMonitor = true
        model.currentSpaceID = 30
        model.currentMonitorID = 2
        XCTAssertEqual(model.stripWindows(onMonitor: 1).map(\.id), [3])
        XCTAssertEqual(model.stripWindows(onMonitor: 2).map(\.id), [2])
        XCTAssertEqual(model.slotPlacement(onMonitor: 1), nil)
    }

    func testWindowOnTwoMonitorsBelongsToTheOneHoldingMostOfIt() {
        let model = makeModel([window(1, space: nil, frame: CGRect(x: 900, y: 0, width: 400, height: 400))])
        XCTAssertEqual(model.monitorID(of: model.windows[0]), 3)
    }

    func testUnknownMonitorStaysVisibleAndOneMonitorMeansEverything() {
        let model = makeModel([
            window(1, space: nil, frame: nil),
            window(2, space: 30, frame: CGRect(x: 100, y: 0, width: 400, height: 400)),
        ])
        model.scope = .monitor
        model.currentMonitorID = 1
        XCTAssertEqual(model.visibleWindows.map(\.id), [1])
        model.monitors = [model.monitors[0]]
        XCTAssertEqual(Set(model.visibleWindows.map(\.id)), [1, 2])
    }

    func testMonitorScopeNeedsMultiMonitorMode() {
        var prefs = Preferences()
        prefs.scope = .monitor
        XCTAssertEqual(prefs.effectiveScope, .monitor)
        prefs.multiMonitorMode = false
        XCTAssertEqual(prefs.effectiveScope, .global)
    }

    func testMonitorActions() {
        XCTAssertEqual(HotkeyAction.moveToMonitor2.moveMonitorIndex, 2)
        XCTAssertNil(HotkeyAction.moveToNextMonitor.moveMonitorIndex)
        XCTAssertEqual(HotkeyAction.monitorActions.count, 5)
        XCTAssertNil(HotkeyAction.moveToMonitor1.spaceIndex)
        let defaults = Set(HotkeyAction.allCases.map { $0.defaultCombo(superMask: UInt32(optionKey)) })
        XCTAssertEqual(defaults.count, HotkeyAction.allCases.count, "no two actions share a default key")
    }

    func testFrameMapsToTheSamePlaceOnAnotherScreen() {
        let left = NSRect(x: 0, y: 0, width: 1000, height: 500)
        let right = NSRect(x: 1000, y: 100, width: 2000, height: 1000)
        let half = NSRect(x: 500, y: 0, width: 500, height: 500)
        XCTAssertEqual(AppDelegate.map(half, from: left, to: right), NSRect(x: 2000, y: 100, width: 1000, height: 1000))
        let big = NSRect(x: -50, y: 0, width: 2000, height: 600)
        XCTAssertEqual(AppDelegate.map(big, from: left, to: left), left, "kept inside the target")
    }
}
