import Carbon.HIToolbox
import XCTest
@testable import WindowQueue

final class TourSimTests: XCTestCase {
    private var prefs: Preferences {
        var prefs = Preferences()
        prefs.superModifier = .option
        prefs.bindings = Preferences.defaultBindings(superMask: SuperModifier.option.carbonMask)
        prefs.stripSide = .left
        return prefs
    }

    private func sim(_ windows: [SimWindow]) -> TourSim {
        let sim = TourSim()
        sim.animated = false
        sim.reset(windows)
        return sim
    }

    private func press(_ sim: TourSim, _ key: Int, _ flags: NSEvent.ModifierFlags = []) {
        sim.press(keyCode: key, flags: flags, prefs: prefs)
    }

    func testShortcutsFollowTheUsersBindings() {
        let sim = sim([.safari, .notes, .terminal])
        press(sim, kVK_ANSI_RightBracket, .option)
        XCTAssertEqual(sim.selected, SimWindow.notes.id)
        XCTAssertTrue(sim.done.contains(.cycled))
        press(sim, kVK_ANSI_LeftBracket, [.option, .shift])
        XCTAssertEqual(sim.queue.first, SimWindow.notes.id)
        // A key that is not one of WindowQueue's shortcuts is left for the window.
        XCTAssertFalse(sim.press(keyCode: kVK_ANSI_W, flags: .command, prefs: prefs))
    }

    func testAimingExtendsAndConfirms() {
        let sim = sim([.safari, .notes, .terminal, .mail])
        sim.superTap(symbol: "⌥")
        XCTAssertTrue(sim.aiming)
        press(sim, kVK_DownArrow, .shift)
        press(sim, kVK_DownArrow, .shift)
        XCTAssertEqual(sim.aimedIDs, [1, 2, 3])
        XCTAssertTrue(sim.done.contains(.aimedThree))
        press(sim, kVK_Escape)
        XCTAssertFalse(sim.aiming)
        sim.superTap(symbol: "⌥")
        press(sim, kVK_DownArrow)
        sim.superTap(symbol: "⌥")
        XCTAssertEqual(sim.selected, SimWindow.notes.id)
        XCTAssertTrue(sim.done.contains(.confirmed))
    }

    func testTilingKeepsTheSimulatorsProportionsAndFollowsTheQueue() throws {
        let sim = sim([.xcode, .simulator, .safari])
        let area = CGRect(x: 0, y: 0, width: 900, height: 500)
        sim.superTap(symbol: "⌥")
        press(sim, kVK_DownArrow, .shift)
        press(sim, kVK_DownArrow, .shift)
        press(sim, kVK_RightArrow)
        XCTAssertTrue(sim.menuFocused)
        press(sim, kVK_DownArrow) // Main and stack → Columns
        press(sim, kVK_Return)
        XCTAssertEqual(sim.tiled, [5, 6, 1])
        let frames = sim.frames(in: area)
        let phone = try XCTUnwrap(frames[SimWindow.simulator.id])
        XCTAssertEqual(phone.width / phone.height, 0.48, accuracy: 0.01)
        // The others take the room the phone leaves rather than a third each.
        XCTAssertGreaterThan(try XCTUnwrap(frames[SimWindow.xcode.id]).width, area.width / 3)

        // Carrying the Simulator to the front of the queue moves it to the first column.
        sim.superTap(symbol: "⌥")
        press(sim, kVK_DownArrow)
        press(sim, kVK_UpArrow, .option)
        XCTAssertEqual(sim.queue.first, SimWindow.simulator.id)
        XCTAssertTrue(sim.done.contains(.reorderedTiles))
        let moved = sim.frames(in: area)
        XCTAssertLessThan(try XCTUnwrap(moved[SimWindow.simulator.id]).minX, try XCTUnwrap(moved[SimWindow.xcode.id]).minX)
    }

    func testAGroupLockKeepsCyclingInsideIt() {
        let sim = sim([.safari, .notes, .terminal, .mail])
        sim.superTap(symbol: "⌥")
        press(sim, kVK_DownArrow)
        press(sim, kVK_DownArrow, .shift)
        press(sim, kVK_ANSI_G) // bare in aiming mode
        XCTAssertEqual(sim.groups.first?.ids, [2, 3])
        XCTAssertEqual(sim.entries.count, 3)
        press(sim, kVK_ANSI_L, [.option, .control])
        XCTAssertNotNil(sim.lockedGroup)
        press(sim, kVK_ANSI_RightBracket, .option)
        press(sim, kVK_ANSI_RightBracket, .option)
        XCTAssertEqual(sim.selected, SimWindow.notes.id)
        XCTAssertTrue(sim.done.contains(.cycledLocked))
        press(sim, kVK_ANSI_L, [.option, .control])
        XCTAssertNil(sim.lockedGroup)
    }

    func testWorkspacesSwitchAndTakeTheWindowAlong() {
        let sim = TourSim()
        sim.animated = false
        sim.reset(SimSetup(windows: [.safari, .notes, .terminal], spaces: [3: 2], spaceCount: 3))
        let area = CGRect(x: 0, y: 0, width: 600, height: 400)
        XCTAssertEqual(Set(sim.frames(in: area).keys), [1, 2])
        press(sim, kVK_ANSI_2, .option)
        XCTAssertEqual(Set(sim.frames(in: area).keys), [3])
        XCTAssertEqual(sim.selected, SimWindow.terminal.id)
        // Cycling to a window on another workspace goes there.
        press(sim, kVK_ANSI_RightBracket, .option)
        XCTAssertEqual(sim.shownSpace, [1])
        press(sim, kVK_ANSI_2, [.option, .shift])
        XCTAssertEqual(sim.space(of: sim.selected ?? 0), 2)
        XCTAssertEqual(sim.shownSpace, [2])
        press(sim, kVK_ANSI_0, .option)
        XCTAssertEqual(sim.shownSpace, [3])
        XCTAssertTrue(sim.done.isSuperset(of: [.switchedSpace, .movedToSpace, .wentToEmptySpace]))
    }

    func testGoingToAnEmptyWorkspaceAddsOneWhenAllAreInUse() {
        let sim = TourSim()
        sim.animated = false
        sim.reset(SimSetup(windows: [.safari, .notes, .terminal], spaces: [3: 2], spaceCount: 2))
        press(sim, kVK_ANSI_0, .option)
        XCTAssertEqual(sim.spaceCount, 3)
        XCTAssertEqual(sim.shownSpace, [3])
        XCTAssertTrue(sim.done.contains(.wentToEmptySpace))
    }

    func testEachOfATipsShortcutsIsTickedOffOnItsOwn() throws {
        let model = TourModel(store: PreferencesStore())
        model.show(.tips, scheduled: false)
        let index = try XCTUnwrap(model.tips.firstIndex { $0.id == "workspaces" })
        model.showTip(index, scheduled: false)
        let tip = model.tips[index]
        let combo = model.prefs.combo(for: .goToEmptySpace)
        XCTAssertTrue(model.handleKey(keyCode: Int(combo.keyCode), flags: .option))
        XCTAssertEqual(tip.goals.map { tip.used($0, in: model.done) }, [false, false, true],
                       "going to an empty workspace isn't a numbered switch")
        XCTAssertFalse(tip.isDone(model.done))
        model.stop()
    }

    func testEachMonitorHasItsOwnQueue() {
        let sim = TourSim()
        sim.animated = false
        sim.reset(SimSetup(windows: [.safari, .notes, .terminal, .mail], monitors: [3: 1, 4: 1], monitorCount: 2))
        XCTAssertEqual(sim.queue(onMonitor: 0), [1, 2])
        press(sim, kVK_Space, [.option, .control])
        XCTAssertEqual(sim.focusedMonitor, 1)
        press(sim, kVK_Space, [.option, .control, .shift])
        XCTAssertEqual(sim.queue(onMonitor: 0).count, 3)
        XCTAssertTrue(sim.done.isSuperset(of: [.switchedMonitor, .movedToMonitor]))
    }

    func testSearchDeclutterAndDragging() throws {
        let sim = sim([.safari, .notes, .terminal, .mail])
        press(sim, kVK_Space, .option)
        XCTAssertTrue(sim.searchOpen)
        sim.press(keyCode: kVK_ANSI_M, flags: [], prefs: prefs, characters: "m")
        sim.press(keyCode: kVK_ANSI_A, flags: [], prefs: prefs, characters: "a")
        XCTAssertEqual(sim.searchMatches, [SimWindow.mail.id])
        press(sim, kVK_Return)
        XCTAssertEqual(sim.selected, SimWindow.mail.id)

        press(sim, kVK_ANSI_D, .option)
        let frames = Array(sim.frames(in: CGRect(x: 0, y: 0, width: 600, height: 400)).values)
        for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { XCTAssertFalse(a.insetBy(dx: 1, dy: 1).intersects(b)) } }

        sim.beginDrag(SimWindow.mail.id)
        sim.drag(to: -3)
        sim.endDrag()
        XCTAssertEqual(sim.queue.first, SimWindow.mail.id)
        XCTAssertTrue(sim.done.isSuperset(of: [.searched, .decluttered, .dragged]))
    }

    func testClosingTicksOffEachWay() {
        let sim = sim([.safari, .notes, .terminal, .mail])
        press(sim, kVK_ANSI_Q, .option)
        XCTAssertTrue(sim.closed.contains(SimWindow.safari.id))
        XCTAssertEqual(sim.done, [.closed])
        sim.superTap(symbol: "⌥")
        press(sim, kVK_DownArrow)
        press(sim, kVK_ANSI_Q) // bare in aiming mode
        XCTAssertEqual(sim.closed.count, 2)
        XCTAssertFalse(sim.aiming)
        XCTAssertTrue(sim.done.contains(.closedWhileAiming))
    }

    func testTheTourIsForNewUsersOnly() throws {
        XCTAssertFalse(Preferences().onboardingCompleted)
        let older = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertTrue(older.onboardingCompleted)
    }

    func testSuperKeySymbol() {
        XCTAssertEqual(SuperModifier.option.symbol, "⌥")
        XCTAssertEqual(SuperModifier.controlOption.symbol, "⌃⌥")
    }
}

final class TourModelTests: XCTestCase {
    func testOnlyTheWelcomePageHasADemoAndAnyActionStopsIt() {
        XCTAssertTrue(TourPage.allCases.filter { !$0.demo.isEmpty } == [.welcome])
        XCTAssertTrue(TourModel(store: PreferencesStore()).tips.allSatisfy { !$0.preview.isEmpty }, "every tip has a preview")
        let model = TourModel(store: PreferencesStore())
        model.show(.welcome, scheduled: false)
        XCTAssertTrue(model.demoPlaying)
        model.run(.action(.cycleNext))
        XCTAssertTrue(model.done.isEmpty, "the demo's own doings don't tick tasks off")
        model.click(SimWindow.notes.id)
        XCTAssertFalse(model.demoPlaying)
        XCTAssertTrue(model.done.contains(.clicked))

        model.show(.basics)
        XCTAssertFalse(model.demoPlaying)
        XCTAssertTrue(model.awaitingUser, "a lesson page is the user's to try at once")
        XCTAssertTrue(model.handleKey(keyCode: kVK_ANSI_RightBracket, flags: .option))
        XCTAssertFalse(model.awaitingUser)
        XCTAssertTrue(model.done.contains(.cycled))
    }

    func testDoingATipMovesOnToTheNext() throws {
        let model = TourModel(store: PreferencesStore())
        model.show(.tips, scheduled: false)
        let index = try XCTUnwrap(model.tips.firstIndex { $0.id == "declutter" })
        model.showTip(index, scheduled: false)
        XCTAssertTrue(model.handleKey(keyCode: kVK_ANSI_D, flags: .option))
        XCTAssertEqual(model.tipIndex, index, "it stays a beat, to see what happened")
        let moved = expectation(description: "next tip")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            XCTAssertEqual(model.tipIndex, index + 1)
            XCTAssertTrue(model.demoPlaying)
            model.stop()
            moved.fulfill()
        }
        wait(for: [moved], timeout: 3)
    }
}
