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

    func testReorderingDesktopsRegroupsTheQueue() {
        let model = makeModel([window(1, space: 10), window(2, space: 20), window(3, space: 30)])
        model.spaceOrder = [30, 10, 20]
        XCTAssertEqual(ids(model), [3, 1, 2])
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

    func testMaximizingAnotherWindowPutsTheFirstBackBeforeMovingTheSecond() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        model.beginFocus(on: 3)
        model.beginFocus(on: 2)
        XCTAssertEqual(ids(model), [2, 1, 3])
        model.endFocus()
        XCTAssertEqual(ids(model), [1, 2, 3])
    }

    func testMaximizingTheSameWindowTwiceStillRestoresItsPlace() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        model.beginFocus(on: 3)
        model.beginFocus(on: 3)
        model.endFocus()
        XCTAssertEqual(ids(model), [1, 2, 3])
    }

    func testRestoringAfterAWindowClosedStaysOnItsWorkspace() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10),
                               window(4, space: 20), window(5, space: 20)])
        model.beginFocus(on: 3)
        model.reconcile(with: [window(2, space: 10), window(3, space: 10), window(4, space: 20), window(5, space: 20)])
        model.endFocus()
        XCTAssertEqual(ids(model), [2, 3, 4, 5])
    }

    func testRegroupingTheOpenGroupsWindowsClosesIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        model.makeGroup([1, 2])
        model.select(id: 1, announce: false)
        XCTAssertEqual(model.openGroupID, 1)
        model.makeGroup([2, 3])
        XCTAssertNil(model.openGroupID, "the open group was broken up; the new one is not open")
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
    func testAimAllCoversTheWholeQueueAndOnlyTheGroupFromInside() {
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 10), window(4, space: 10)])
        model.makeGroup([2, 3])
        model.select(id: 1, announce: false)
        model.beginAiming()

        XCTAssertTrue(model.aimAll())
        XCTAssertEqual(model.aimedIDs, [1, 2, 3, 4], "outside a group, A takes the whole visible queue")

        XCTAssertFalse(model.aimAll(), "a second press drops back to the aimed window alone")
        XCTAssertEqual(model.aimedIDs, [1])

        model.endAiming()
        model.select(id: 2, announce: false)
        model.beginAiming()
        XCTAssertTrue(model.aimAll())
        XCTAssertEqual(model.aimedIDs, [2, 3], "started inside a group, A takes that group only")
    }

    // MARK: - Aiming inside a group

    /// Windows 1 and 3 are grouped; window 2 sits between them in the queue and is no part of it.
    private func scatteredGroupModel() -> WindowQueueModel {
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 10), window(4, space: 10)])
        model.makeGroup([1, 3])
        return model
    }

    func testAimInsideAGroupNeverReachesAWindowBetweenItsMembers() {
        let model = scatteredGroupModel()
        model.select(id: 1, announce: false)
        model.beginAiming()
        XCTAssertEqual(model.aimInsideGroupID, 1, "aiming started on a grouped window aims in the group")
        XCTAssertEqual(model.aimedIDs, [1])

        model.extendAim(by: 1)
        XCTAssertEqual(model.aimingID, 3, "the step lands on the next window of the group, not the queue")
        XCTAssertEqual(model.aimedIDs, [1, 3], "window 2 is not in the group and must not join the run")

        model.moveAim(by: 1)
        XCTAssertEqual(model.aimedIDs, [1], "moving the aim wraps within the group")
        XCTAssertEqual(model.aimingID, 1)
    }

    func testAimAllInsideAGroupTakesTheGroupAlone() {
        let model = scatteredGroupModel()
        model.select(id: 3, announce: false)
        model.beginAiming()
        XCTAssertTrue(model.aimAll())
        XCTAssertEqual(model.aimedIDs, [1, 3])
    }

    func testPickingAWindowOutsideTheGroupDoesNotJoinTheRunInside() {
        let model = scatteredGroupModel()
        model.select(id: 1, announce: false)
        model.beginAiming()
        model.toggleAim(2)
        XCTAssertFalse(model.aimedIDs.contains(2), "a window outside the open group is not on its strip")
    }

    func testAimingFromTheStripTakesAGroupWholeWithoutItsNeighbours() {
        let model = scatteredGroupModel()
        model.select(id: 4, announce: false)
        model.beginAiming()
        XCTAssertNil(model.aimInsideGroupID)
        // The strip shows [group(1, 3)] [2] [4]: two steps back from window 4 is the group.
        model.moveAim(by: -1)
        XCTAssertEqual(model.aimingID, 2)
        model.moveAim(by: -1)
        XCTAssertEqual(model.aimedGroup?.id, 1, "the aim lands on the group as one stop")
        XCTAssertEqual(model.aimedIDs, [1, 3], "the group is aimed at whole, and window 2 stays out")
    }

    func testSteppingIntoAndOutOfAGroupWhileAiming() {
        let model = scatteredGroupModel()
        model.select(id: 4, announce: false)
        model.beginAiming()
        model.moveAim(by: -2)
        XCTAssertTrue(model.enterAimedGroup())
        XCTAssertEqual(model.aimInsideGroupID, 1)
        XCTAssertEqual(model.aimedIDs, [3], "arriving backwards, the aim enters at the group's last window")

        model.leaveAimedGroup()
        XCTAssertNil(model.aimInsideGroupID)
        XCTAssertEqual(model.aimedIDs, [1, 3], "back outside, the group is one stop again")
        XCTAssertEqual(model.aimedGroup?.id, 1)
    }

    func testAGroupIsEnteredFromTheSideTheAimArrivesFrom() {
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 10), window(4, space: 10)])
        model.makeGroup([2, 3])

        // Walking down the strip: the group is entered at its first window.
        model.select(id: 1, announce: false)
        model.beginAiming()
        model.moveAim(by: 1)
        XCTAssertEqual(model.aimedGroup?.id, 1)
        model.enterAimedGroup()
        XCTAssertEqual(model.aimingID, 2)
        model.endAiming()

        // Walking up it: the same group is entered at its last window.
        model.select(id: 4, announce: false)
        model.beginAiming()
        model.moveAim(by: -1)
        XCTAssertEqual(model.aimedGroup?.id, 1)
        model.enterAimedGroup()
        XCTAssertEqual(model.aimingID, 3, "arriving backwards enters at the end of the group")
    }

    func testCyclingBackwardsStopsAtTheGroupsLastWindow() {
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 10), window(4, space: 10)])
        model.makeGroup([2, 3])
        model.select(id: 4, announce: false)

        XCTAssertEqual(model.cycle(by: -1)?.id, 3, "walking up, the queue stops at the group's last window")
        XCTAssertEqual(model.openGroupID, 1, "landing on a member steps into the group")
        XCTAssertEqual(model.cycle(by: -1)?.id, 2)
        XCTAssertEqual(model.cycle(by: -1)?.id, 1)
        XCTAssertNil(model.openGroupID, "leaving the group closes it")
    }

    func testCyclingForwardsStopsAtTheGroupsFirstWindow() {
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 10), window(4, space: 10)])
        model.makeGroup([2, 3])
        model.select(id: 1, announce: false)

        XCTAssertEqual(model.cycle(by: 1)?.id, 2)
        XCTAssertEqual(model.cycle(by: 1)?.id, 3)
        XCTAssertEqual(model.cycle(by: 1)?.id, 4)
    }

    func testAGroupIsReachableWhenOneOfItsWindowsIsOutOfTheWalk() {
        // The group's last window lives on another workspace, which the queue is not showing; the
        // group still has to be reachable walking up, at whichever of its windows is there.
        let model = makeModel([window(1, space: 10), window(2, space: 10),
                               window(3, space: 20), window(4, space: 10)])
        model.scope = .currentSpace
        model.makeGroup([2, 3])
        model.select(id: 4, announce: false)

        XCTAssertEqual(model.cycle(by: -1)?.id, 2, "the group is entered at the window that is there")
        XCTAssertEqual(model.openGroupID, 1)
    }

}
