import XCTest
@testable import WindowQueue

final class QueueContentsTests: XCTestCase {
    func testEveryChoiceReadsBackAsItself() {
        for multiMonitor in [true, false] {
            for choice in QueueContents.allCases {
                var prefs = Preferences()
                prefs.multiMonitorMode = multiMonitor
                choice.apply(to: &prefs)
                XCTAssertEqual(QueueContents(prefs: prefs), choice, "multi-monitor \(multiMonitor)")
            }
        }
    }

    func testAQueuePerMonitorTurnsMultiMonitorModeOn() {
        var prefs = Preferences()
        prefs.multiMonitorMode = false
        QueueContents.monitor.apply(to: &prefs)
        XCTAssertTrue(prefs.multiMonitorMode)
        XCTAssertEqual(prefs.effectiveScope, .monitor)
    }

    func testTheWorkspaceQueueFollowsMultiMonitorMode() {
        var prefs = Preferences()
        prefs.multiMonitorMode = true
        QueueContents.workspace.apply(to: &prefs)
        XCTAssertEqual(prefs.scope, .monitor)
        XCTAssertTrue(prefs.monitorScopeByWorkspace)

        prefs.multiMonitorMode = false
        QueueContents.workspace.apply(to: &prefs)
        XCTAssertEqual(prefs.scope, .currentSpace)
    }

    func testStoredSettingsFromBeforeTheMergeAreRead() {
        var prefs = Preferences()
        prefs.multiMonitorMode = true
        prefs.scope = .currentSpace
        XCTAssertEqual(QueueContents(prefs: prefs), .workspace)
        prefs.scope = .monitor
        prefs.monitorScopeByWorkspace = false
        XCTAssertEqual(QueueContents(prefs: prefs), .monitor)
        prefs.multiMonitorMode = false
        XCTAssertEqual(QueueContents(prefs: prefs), .everything)
    }
}
