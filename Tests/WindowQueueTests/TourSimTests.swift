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
    func testTheDemoHandsTheDesktopOverRatherThanLooping() {
        let model = TourModel(store: PreferencesStore())
        model.show(.basics, scheduled: false)
        XCTAssertTrue(model.demoPlaying)
        XCTAssertFalse(model.awaitingUser)
        model.run(.action(.cycleNext))
        XCTAssertTrue(model.done.isEmpty, "the demo's own doings don't tick tasks off")
        model.finishDemo()
        XCTAssertFalse(model.demoPlaying)
        XCTAssertTrue(model.awaitingUser)
        XCTAssertEqual(model.sim.selected, SimWindow.safari.id, "the desktop is back as it started")
        model.click(SimWindow.notes.id)
        XCTAssertFalse(model.awaitingUser)
        XCTAssertTrue(model.done.contains(.clicked))
    }
}
