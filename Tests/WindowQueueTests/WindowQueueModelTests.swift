import XCTest
@testable import WindowQueue

final class WindowQueueModelTests: XCTestCase {
    private func window(_ id: CGWindowID, space: UInt64?, pid: pid_t = 1, minimized: Bool = false) -> ManagedWindow {
        ManagedWindow(id: id, element: nil, pid: pid, appName: "App\(pid)", bundleID: nil,
                      title: "w\(id)", isMinimized: minimized, spaceID: space)
    }

    /// Workspaces 1, 2, 3 with ids 10, 20, 30.
    private func makeModel(_ windows: [ManagedWindow], current: UInt64 = 10) -> WindowQueueModel {
        let model = WindowQueueModel()
        model.autoSortByWorkspace = true
        model.spaceOrder = [10, 20, 30]
        model.currentSpaceID = current
        model.reconcile(with: windows)
        return model
    }

    private func ids(_ model: WindowQueueModel) -> [CGWindowID] { model.windows.map(\.id) }

    func testSwitchingToEmptyWorkspaceShowsSlotAndBackRestoresSelection() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 30)])
        model.select(id: 2, announce: false)

        model.currentSpaceID = 20
        XCTAssertEqual(model.emptySlot?.spaceID, 20)
        XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.emptySlot?.beforeID, 3)

        model.currentSpaceID = 10
        XCTAssertNil(model.emptySlot)
        XCTAssertNotNil(model.selectedID, "arriving back on an occupied workspace should select something there")
        XCTAssertEqual(model.selectedWindow?.spaceID, 10)
    }

    func testClosingLastWindowShowsSlotAndNewWindowFillsIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 20), window(3, space: 30)], current: 20)
        model.select(id: 2, announce: false)

        model.reconcile(with: [window(1, space: 10), window(3, space: 30)])
        XCTAssertEqual(model.emptySlot, .init(spaceID: 20, beforeID: 3))
        XCTAssertNil(model.selectedID)

        model.reconcile(with: [window(1, space: 10), window(3, space: 30), window(4, space: 20)])
        XCTAssertEqual(ids(model), [1, 4, 3])
        XCTAssertEqual(model.selectedID, 4)
        XCTAssertNil(model.emptySlot)
    }

    func testClosingSelectedWindowSelectsNearestOnSameWorkspace() {
        let model = makeModel([window(1, space: 10), window(2, space: 20), window(3, space: 20), window(4, space: 20)], current: 20)
        model.select(id: 3, announce: false)
        model.reconcile(with: [window(1, space: 10), window(2, space: 20), window(4, space: 20)])
        XCTAssertTrue([2, 4].contains(model.selectedID ?? 0))
    }

    func testClosingWindowOnAnotherWorkspaceKeepsSelection() {
        let model = makeModel([window(1, space: 10), window(2, space: 20)], current: 10)
        model.select(id: 1, announce: false)
        model.reconcile(with: [window(1, space: 10)])
        XCTAssertEqual(model.selectedID, 1)
        XCTAssertNil(model.emptySlot)
    }

    func testNewWindowGoesAfterSelection() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 20)])
        model.select(id: 1, announce: false)
        model.reconcile(with: [window(1, space: 10), window(2, space: 10), window(3, space: 20), window(5, space: 10)])
        XCTAssertEqual(ids(model), [1, 5, 2, 3])
    }

    func testRelocateToEmptyWorkspaceKeepsWorkspaceOrder() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 30)])
        model.relocate([1], toSpace: 20)
        XCTAssertEqual(ids(model), [2, 1, 3])
        model.relocate([3], toSpace: 10)
        XCTAssertEqual(ids(model), [2, 3, 1])
    }

    func testRelocateAwayLastWindowShowsSlot() {
        let model = makeModel([window(1, space: 10), window(2, space: 20)])
        model.select(id: 1, announce: false)
        model.relocate([1], toSpace: 20)
        XCTAssertEqual(model.emptySlot?.spaceID, 10)
    }

    func testAimRunExtendsAndMovesAsGroup() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)])
        model.select(id: 2, announce: false)
        model.beginAiming()
        model.extendAim(by: 1)
        XCTAssertEqual(model.aimedWindows.map(\.id), [2, 3])
        model.moveAimedGroup(by: 1)
        XCTAssertEqual(ids(model), [1, 4, 2, 3])
        XCTAssertEqual(model.aimedWindows.map(\.id), [2, 3])
        model.moveAimedGroup(by: 5)
        XCTAssertEqual(ids(model), [1, 4, 2, 3])
        model.moveAimedGroup(by: -1)
        XCTAssertEqual(ids(model), [1, 2, 3, 4])
        model.extendAim(by: -3)
        XCTAssertEqual(model.aimedWindows.map(\.id), [1, 2])
    }

    func testCurrentSpaceScopeCycleStaysOnWorkspace() {
        let model = makeModel([window(1, space: 10), window(2, space: 20), window(3, space: 10)])
        model.scope = .currentSpace
        model.select(id: 1, announce: false)
        XCTAssertEqual(model.cycle(by: 1)?.id, 3)
        XCTAssertEqual(model.cycle(by: 1)?.id, 1)
    }

    func testMinimisedWindowDoesNotCountAsOccupying() {
        let model = makeModel([window(1, space: 10), window(2, space: 20, minimized: true)], current: 10)
        model.currentSpaceID = 20
        XCTAssertEqual(model.emptySlot?.spaceID, 20)
    }

    func testApplyOrderRestoresSavedOrder() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        model.applyOrder(keys: ["App1\u{1}w3", "App1\u{1}w1"])
        XCTAssertEqual(ids(model), [3, 1, 2])
    }
}

extension WindowQueueModelTests {
    func testClosingAimedWindowMovesAimToNeighbour() {
        let model = WindowQueueModel()
        model.spaceOrder = [10]
        model.currentSpaceID = 10
        let make = { (id: CGWindowID) in
            ManagedWindow(id: id, element: nil, pid: 1, appName: "A", bundleID: nil, title: "\(id)", isMinimized: false, spaceID: 10)
        }
        model.reconcile(with: [make(1), make(2), make(3)])
        model.select(id: 2, announce: false)
        model.beginAiming()
        model.reconcile(with: [make(1), make(3)])
        XCTAssertNotNil(model.aimingID)
        XCTAssertTrue([1, 3].contains(model.aimingID ?? 0))
    }
}

extension WindowQueueModelTests {
    func testCurrentSpaceScopeOnEmptyWorkspaceShowsOnlySlot() {
        let model = makeModel([window(1, space: 10), window(2, space: 30)])
        model.scope = .currentSpace
        model.currentSpaceID = 20
        XCTAssertTrue(model.visibleWindows.isEmpty)
        XCTAssertEqual(model.slotPlacement, .end)
        XCTAssertNil(model.cycle(by: 1))
    }
}

extension WindowQueueModelTests {
    func testToggleAimPicksWindowsThatAreNotAdjacent() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)])
        model.select(id: 1, announce: false)
        model.beginAiming()
        model.toggleAim(3)
        XCTAssertEqual(model.aimedWindows.map(\.id), [1, 3])
        model.extendAim(by: 1)
        XCTAssertEqual(model.aimedWindows.map(\.id), [1, 3, 4])
        model.toggleAim(1)
        XCTAssertEqual(model.aimedWindows.map(\.id), [3, 4])
        model.moveAim(by: 1)
        XCTAssertEqual(model.aimedWindows.count, 1)
    }
}

extension WindowQueueModelTests {
    func testMaximizingMovesWindowToFrontOfItsWorkspaceAndBack() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 20)])
        model.select(id: 3, announce: false)
        model.beginFocus(on: 3)
        XCTAssertEqual(ids(model), [3, 1, 2, 4])

        // Cycling stays on the maximized window while the rest of its workspace is covered.
        XCTAssertTrue(model.isCovered(model.windows[1]))
        XCTAssertFalse(model.isCovered(model.windows[3]))
        XCTAssertEqual(model.cycle(by: 1)?.id, 4)
        XCTAssertEqual(model.cycle(by: 1)?.id, 3)

        model.endFocus()
        XCTAssertEqual(ids(model), [1, 2, 3, 4])
        XCTAssertFalse(model.isCovered(model.windows[0]))
    }

    func testClosingTheMaximizedWindowEndsTheFocus() {
        let model = makeModel([window(1, space: 10), window(2, space: 10)])
        model.beginFocus(on: 2)
        model.reconcile(with: [window(1, space: 10)])
        XCTAssertNil(model.maximizedID)
        XCTAssertFalse(model.isCovered(model.windows[0]))
    }
}

extension WindowQueueModelTests {
    func testMaximizedWindowMovesWithTheWindowsItCovers() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 20), window(4, space: 20)])
        model.select(id: 1, announce: false)
        model.beginFocus(on: 1)
        XCTAssertEqual(model.maximizedGroupIDs, [1, 2])

        model.move(by: 1)
        XCTAssertEqual(ids(model), [3, 1, 2, 4])
        model.move(id: 1, toVisiblePosition: 0)
        XCTAssertEqual(ids(model), [1, 2, 3, 4])
    }
}

extension WindowQueueModelTests {
    func testTiledGroupFollowsTheQueueAndDropsClosedWindows() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        let group = model.setTiled([1, 2, 3], layout: "Main and stack")
        XCTAssertEqual(group?.id, 1)
        XCTAssertTrue(model.isTiled(model.windows[0]))

        model.select(id: 3, announce: false)
        model.move(by: -2)
        XCTAssertEqual(model.tiledWindowsInQueueOrder(group!).map(\.id), [3, 2, 1])

        model.reconcile(with: [window(3, space: 10), window(1, space: 10)])
        XCTAssertEqual(model.tiledGroups.first?.ids, [1, 3])

        model.reconcile(with: [window(3, space: 10)])
        XCTAssertTrue(model.tiledGroups.isEmpty)
    }

    func testSeveralTiledGroupsAreNumberedAndFreedOnTheirOwn() {
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 20), window(4, space: 20)])
        let first = model.setTiled([1, 2], layout: "Side by side")
        let second = model.setTiled([3, 4], layout: "Stacked")
        XCTAssertEqual([first?.id, second?.id], [1, 2])

        model.clearTiled(containing: 3)
        XCTAssertEqual(model.tiledGroups.map(\.id), [1])

        // The number the freed group had is available again.
        XCTAssertEqual(model.setTiled([3, 4], layout: "Stacked")?.id, 2)
        // A window can only be in one layout at a time; taking 2 and 3 out leaves both of their
        // old groups too small to be layouts, so both go and the numbers start again.
        XCTAssertEqual(model.setTiled([2, 3], layout: "Side by side")?.id, 1)
        XCTAssertEqual(model.tiledGroups.count, 1)
        XCTAssertEqual(model.tiledGroups.first?.ids, [2, 3])
    }
}
