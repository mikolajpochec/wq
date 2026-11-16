import XCTest
@testable import WindowQueue

final class QuickMarkTests: XCTestCase {
    private func window(_ id: CGWindowID, app: String, title: String = "") -> ManagedWindow {
        ManagedWindow(id: id, element: nil, pid: 1, appName: app, bundleID: "com.example.\(app)",
                      title: title, isMinimized: false, spaceID: 1)
    }

    func testWindowMarkGoesToItsWindow() {
        let windows = [window(1, app: "A"), window(2, app: "B")]
        let mark = QuickMark(kind: .window, window: windows[1])
        XCTAssertEqual(mark.target(in: windows, recent: [], current: 1), .window(2))
    }

    func testWindowMarkFindsTheWindowAgainByTitle() {
        let old = window(7, app: "A", title: "notes.md")
        let mark = QuickMark(kind: .window, window: old)
        let windows = [window(1, app: "A", title: "other"), window(9, app: "A", title: "notes.md")]
        XCTAssertEqual(mark.target(in: windows, recent: [1], current: nil), .window(9))
    }

    func testWindowMarkFallsBackToItsAppThenLaunches() {
        let mark = QuickMark(kind: .window, window: window(7, app: "A", title: "gone"))
        XCTAssertEqual(mark.target(in: [window(1, app: "A", title: "x")], recent: [], current: nil), .window(1))
        XCTAssertEqual(mark.target(in: [window(2, app: "B")], recent: [], current: nil),
                       .launch(bundleID: "com.example.A"))
    }

    func testAppMarkPicksTheMostRecentWindowThenWalksOn() {
        let windows = [window(1, app: "A"), window(2, app: "B"), window(3, app: "A"), window(4, app: "A")]
        let mark = QuickMark(kind: .app, window: windows[0])
        XCTAssertEqual(mark.target(in: windows, recent: [2, 3, 1], current: 2), .window(3))
        XCTAssertEqual(mark.target(in: windows, recent: [], current: 3), .window(4))
        XCTAssertEqual(mark.target(in: windows, recent: [], current: 4), .window(1))
    }

    func testMarksPersist() {
        let defaults = UserDefaults(suiteName: "QuickMarkTests")!
        defaults.removePersistentDomain(forName: "QuickMarkTests")
        let store = QuickMarkStore(defaults: defaults)
        store.set(QuickMark(kind: .app, window: window(1, app: "A")), keyCode: 0)
        XCTAssertEqual(QuickMarkStore(defaults: defaults).marks[0]?.appName, "A")
        XCTAssertEqual(store.keys(for: window(5, app: "A")), [0])
        defaults.removePersistentDomain(forName: "QuickMarkTests")
    }
}
