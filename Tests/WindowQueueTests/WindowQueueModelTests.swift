import XCTest
import Carbon.HIToolbox
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

    func testNewWindowGoesAfterTheSelectedWindowsTiledGroup() {
        let all = [window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)]
        let model = makeModel(all)
        _ = model.setTiled([1, 2, 3], layout: "thirds")
        model.select(id: 1, announce: false)
        model.reconcile(with: all + [window(5, space: 10)])
        XCTAssertEqual(ids(model), [1, 2, 3, 5, 4])
    }

    func testNewWindowGoesAfterWindowSelectedWhenItWasOpened() {
        let all = [window(1, space: 10), window(2, space: 10), window(3, space: 10)]
        let model = makeModel(all)
        model.select(id: 1, announce: false)
        model.noteWindowOpening(pid: 1)
        // The app shuffles focus onto another of its windows before the new one shows up.
        model.followFocus(to: 3)
        model.reconcile(with: all + [window(5, space: 10)])
        XCTAssertEqual(ids(model), [1, 5, 2, 3])
    }

    func testAppComingForwardToOpenWindowDoesNotMoveWhereItGoes() {
        let all = [window(1, space: 10, pid: 1), window(2, space: 10, pid: 2), window(3, space: 10, pid: 2)]
        let model = makeModel(all)
        model.select(id: 1, announce: false)
        // App 2 activates on its existing window 3 first, then creates window 5.
        model.followFocus(to: 3)
        model.noteWindowOpening(pid: 2)
        model.reconcile(with: all + [window(5, space: 10, pid: 2)])
        XCTAssertEqual(ids(model), [1, 5, 2, 3])
    }

    func testPickingAWindowOverridesAnEarlierOpeningNote() {
        let all = [window(1, space: 10), window(2, space: 10), window(3, space: 10)]
        let model = makeModel(all)
        model.select(id: 1, announce: false)
        model.noteWindowOpening(pid: 1)
        model.select(id: 2, announce: false)
        model.reconcile(with: all + [window(5, space: 10)])
        XCTAssertEqual(ids(model), [1, 2, 5, 3])
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

    func testAWindowLeavingALayoutLeavesTheRestInIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        let group = model.setTiled([1, 2, 3], layout: "Columns")
        model.releaseFromTiled([2])
        XCTAssertEqual(model.tiledGroups.first?.ids, [1, 3])
        XCTAssertEqual(model.tiledGroups.first?.id, group?.id)
        model.releaseFromTiled([3])
        XCTAssertTrue(model.tiledGroups.isEmpty, "one window is no layout")
    }

    func testAWindowOpenedInsideAGroupJoinsIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        model.makeGroup([1, 2])
        model.select(id: 2, announce: false)
        XCTAssertEqual(model.openGroupID, 1)
        model.reconcile(with: [window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)])
        XCTAssertEqual(ids(model), [1, 2, 4, 3])
        XCTAssertEqual(Set(model.groups.first?.ids ?? []), [1, 2, 4])
    }

    func testAWindowOpenedOutsideAGroupStaysOutOfIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10)])
        model.makeGroup([1, 2])
        model.select(id: 3, announce: false)
        model.reconcile(with: [window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)])
        XCTAssertEqual(Set(model.groups.first?.ids ?? []), [1, 2])
    }

    func testNearestEmptyWorkspaceIsTheClosestOneWithNothingOnIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 20), window(3, space: 40, minimized: true)])
        let order: [UInt64] = [10, 20, 30, 40, 50]
        XCTAssertEqual(model.nearestEmptySpace(to: 20, among: order), 30, "the later one on a tie")
        XCTAssertEqual(model.nearestEmptySpace(to: 10, among: order), 30)
        XCTAssertEqual(model.nearestEmptySpace(to: 50, among: order), 50, "an empty workspace is its own nearest")
        XCTAssertEqual(model.nearestEmptySpace(to: 20, among: [10, 20]), nil)
        XCTAssertEqual(model.nearestEmptySpace(to: 20, among: [10, 20, 40]), 40, "a minimized window occupies nothing")
    }

    func testNearestEmptyWorkspaceForWindowsLeavingOne() {
        let model = makeModel([window(1, space: 10), window(2, space: 20)])
        let order: [UInt64] = [10, 20, 30]
        // Window 2 leaving its workspace does not make that workspace the answer.
        XCTAssertEqual(model.nearestEmptySpace(to: 20, among: order, ignoring: [2], includingOrigin: false), 30)
        // From the first workspace the nearest empty one further along is found.
        XCTAssertEqual(model.nearestEmptySpace(to: 10, among: order, ignoring: [1], includingOrigin: false), 30)
        // With 2 leaving too, 20 would be free — but only windows actually leaving are ignored.
        XCTAssertEqual(model.nearestEmptySpace(to: 10, among: [10, 20], ignoring: [1], includingOrigin: false), nil)
    }

    func testATabComingToTheFrontKeepsItsWindowsPlace() {
        func tab(_ id: CGWindowID, space: UInt64, pid: pid_t = 1) -> ManagedWindow {
            var window = window(id, space: space, pid: pid)
            window.frame = CGRect(x: 100, y: 100, width: 800, height: 600)
            return window
        }
        let model = makeModel([window(1, space: 10, pid: 2), tab(2, space: 10), window(3, space: 10, pid: 3)])
        model.makeGroup([2, 3])
        model.select(id: 2, announce: false)
        // Tab 2 goes behind, tab 4 of the same window comes to the front.
        model.reconcile(with: [window(1, space: 10, pid: 2), tab(4, space: 10), window(3, space: 10, pid: 3)])
        XCTAssertEqual(ids(model), [1, 4, 3])
        XCTAssertEqual(model.selectedID, 4)
        XCTAssertEqual(Set(model.groups.first?.ids ?? []), [3, 4])
    }

    func testANewWindowElsewhereIsNotTakenForATab() {
        var moved = window(4, space: 10)
        moved.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        var old = window(2, space: 10)
        old.frame = CGRect(x: 100, y: 100, width: 800, height: 600)
        let model = makeModel([window(1, space: 10, pid: 2), old, window(3, space: 10, pid: 3)])
        model.select(id: 3, announce: false)
        model.reconcile(with: [window(1, space: 10, pid: 2), window(3, space: 10, pid: 3), moved])
        XCTAssertEqual(ids(model), [1, 3, 4], "a different frame is a different window, inserted after the selection")
    }

    func testInsideAGroupTheWalkStaysWithItsWindowsWhateverLiesBetween() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)])
        model.makeGroup([2, 4])
        model.select(id: 2, announce: false)
        XCTAssertEqual(model.cycle(by: 1)?.id, 4, "window 3 lies between them but is not in the group")
        XCTAssertEqual(model.cycle(by: 1)?.id, 3)
    }

    func testMovingAWindowPastAGroupStepsOverAllOfIt() {
        let model = makeModel([window(1, space: 10), window(2, space: 10), window(3, space: 10), window(4, space: 10)])
        model.makeGroup([2, 3])
        model.select(id: 1, announce: false)
        model.move(by: 1)
        XCTAssertEqual(ids(model), [2, 3, 1, 4])
        model.move(by: -1)
        XCTAssertEqual(ids(model), [1, 2, 3, 4])
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

final class PreferencesMigrationTests: XCTestCase {
    func testBindingsOnTheFormerDefaultsMoveAndChosenOnesStay() {
        var prefs = Preferences()
        let option = SuperModifier.option.carbonMask
        prefs.bindings = Preferences.defaultBindings(superMask: option)
        prefs.bindings["openLauncher"] = KeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: option)
        prefs.bindings["showOverview"] = KeyCombo(keyCode: UInt32(kVK_ANSI_O), modifiers: option)
        prefs.bindings["toggleRecording"] = KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: option)

        XCTAssertTrue(prefs.moveOffFormerDefaults())
        XCTAssertEqual(prefs.combo(for: .openLauncher), KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: option))
        XCTAssertEqual(prefs.combo(for: .showOverview), KeyCombo(keyCode: UInt32(kVK_ANSI_W), modifiers: option))
        XCTAssertEqual(prefs.combo(for: .toggleRecording), KeyCombo(keyCode: UInt32(kVK_ANSI_K), modifiers: option),
                       "a key the user picked is theirs")
        XCTAssertFalse(prefs.moveOffFormerDefaults())
    }

    func testNoDefaultTakesAPolishLetter() {
        let polish: Set<Int> = [kVK_ANSI_A, kVK_ANSI_C, kVK_ANSI_E, kVK_ANSI_L, kVK_ANSI_N,
                                kVK_ANSI_O, kVK_ANSI_S, kVK_ANSI_X, kVK_ANSI_Z]
        for action in HotkeyAction.allCases {
            let combo = action.defaultCombo(superMask: SuperModifier.option.carbonMask)
            XCTAssertFalse(polish.contains(Int(combo.keyCode)), "\(action) takes a Polish letter")
        }
    }
}

final class AnimationPreferencesTests: XCTestCase {
    func testEachAnimationCanBeSwitchedOffAloneOrAllAtOnce() {
        var prefs = Preferences()
        XCTAssertTrue(AnimationKind.allCases.allSatisfy(prefs.animates))

        prefs.disabledAnimations = [.namePopup]
        XCTAssertFalse(prefs.animates(.namePopup))
        XCTAssertEqual(prefs.duration(.namePopup, 0.2), 0)
        XCTAssertTrue(prefs.animates(.stripLayout))
        XCTAssertEqual(prefs.duration(.stripLayout, 0.2), 0.2)

        prefs.animationsEnabled = false
        XCTAssertFalse(AnimationKind.allCases.contains(where: prefs.animates))
        XCTAssertNil(prefs.animation(.stripLayout, .easeOut))
    }

    func testSettingsSurviveARoundTripAndOlderBlobsKeepAnimating() throws {
        var prefs = Preferences()
        prefs.animationsEnabled = false
        prefs.disabledAnimations = [.aimCursor, .groupStrip]
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.animationsEnabled, false)
        XCTAssertEqual(decoded.disabledAnimations, [.aimCursor, .groupStrip])

        let older = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(older.animationsEnabled)
        XCTAssertTrue(older.disabledAnimations.isEmpty)
    }
}
