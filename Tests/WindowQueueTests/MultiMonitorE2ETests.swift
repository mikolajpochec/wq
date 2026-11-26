import XCTest
@testable import WindowQueue

/// The monitor shortcuts end to end on a simulated desk (`MultiMonitorSim`): what lands where, which
/// strip shows it, where focus and the pointer go, through maximizing, launching, unplugging.
final class MultiMonitorE2ETests: XCTestCase {
    private typealias Sim = MultiMonitorSim

    private func assertFrame(_ actual: NSRect?, _ expected: NSRect, accuracy: CGFloat = 1,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else { return XCTFail("no frame \(message)", file: file, line: line) }
        let close = abs(actual.minX - expected.minX) <= accuracy && abs(actual.minY - expected.minY) <= accuracy
            && abs(actual.width - expected.width) <= accuracy && abs(actual.height - expected.height) <= accuracy
        XCTAssertTrue(close, "\(actual) is not \(expected) \(message)", file: file, line: line)
    }

    // MARK: - The user's desk

    func testTheUsersMonitorsAreNumberedDellMainBuiltIn() {
        let sim = Sim.usersDesk()
        XCTAssertEqual(sim.displays.map(\.id), [1, 2, 3])
        XCTAssertEqual(sim.model.monitors.map(\.id), [1, 2, 3])
        // The Dell is left of the primary: negative x in both coordinate systems, same top.
        XCTAssertEqual(sim.model.monitors[0].frame, CGRect(x: -2560, y: 252, width: 2560, height: 1440))
        sim.checkInvariants()
    }

    func testMovingToTheNextMonitorGoesRoundAllThreeAndComesBackUnchanged() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1, fraction: 0.4)
        sim.open(2, "Mail", on: 2)
        sim.open(3, "Safari", on: 3)
        sim.focus(1)
        let start = sim.windows[1]!.frame
        var visited: [Int?] = []
        for step in 0..<3 {
            sim.moveToMonitor(nil)
            visited.append(sim.stripNumber(of: 1))
            sim.checkInvariants("step \(step)")
            XCTAssertEqual(sim.model.selectedID, 1, "focus follows the window")
            XCTAssertEqual(sim.model.currentMonitorID, sim.display(of: 1), "its monitor is the one worked on")
        }
        XCTAssertEqual(visited, [2, 3, 1])
        XCTAssertEqual(sim.flashes, [2, 3, 1], "the monitor frame lights up wherever it lands")
        assertFrame(sim.windows[1]!.frame, start, "after going all the way round")
        XCTAssertEqual(sim.toasts, ["Moved to monitor 2", "Moved to monitor 3", "Moved to monitor 1"])
    }

    func testMovingToANumberedMonitor() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 2)
        sim.moveToMonitor(3)
        XCTAssertEqual(sim.stripNumber(of: 1), 3)
        let there = sim.windows[1]!.frame
        sim.moveToMonitor(3)
        XCTAssertEqual(sim.toasts.last, "Already on monitor 3")
        XCTAssertEqual(sim.windows[1]!.frame, there)
        sim.moveToMonitor(4)
        XCTAssertEqual(sim.toasts.last, "No monitor 4")
        XCTAssertEqual(sim.windows[1]!.frame, there)
        sim.moveToMonitor(1)
        XCTAssertEqual(sim.stripNumber(of: 1), 1)
        sim.checkInvariants()
    }

    func testAHalfOnOneMonitorIsAHalfOnTheNext() {
        let sim = Sim.usersDesk()
        let dell = sim.area(of: 1)
        sim.open(1, "Terminal", NSRect(x: dell.minX, y: dell.minY, width: dell.width / 2, height: dell.height))
        sim.open(2, "Xcode", NSRect(x: dell.midX, y: dell.minY, width: dell.width / 2, height: dell.height))
        sim.focus(1)
        sim.moveToMonitor(2)
        let main = sim.area(of: 2)
        assertFrame(sim.windows[1]!.frame, NSRect(x: main.minX, y: main.minY, width: main.width / 2, height: main.height))
        sim.focus(2)
        sim.moveToMonitor(2)
        assertFrame(sim.windows[2]!.frame, NSRect(x: main.midX, y: main.minY, width: main.width / 2, height: main.height))
        XCTAssertEqual(Set(sim.strip(2)), [1, 2])
        XCTAssertTrue(sim.strip(1).isEmpty)
        sim.checkInvariants()
    }

    func testAMaximizedWindowFillsEveryMonitorItVisits() {
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 2)
        sim.maximize()
        assertFrame(sim.windows[1]!.frame, sim.area(of: 2), accuracy: 0)
        for target in [3, 1, 2] as [CGDirectDisplayID] {
            sim.moveToMonitor(nil)
            assertFrame(sim.windows[1]!.frame, sim.area(of: target), accuracy: 0, "on \(target)")
            sim.checkInvariants()
        }
    }

    func testAMaximizedWindowRefillsTheNextMonitorWithAnOuterGap() {
        var prefs = Sim.defaultPrefs
        prefs.tileOuterGap = 24
        let sim = Sim.usersDesk(prefs: prefs)
        sim.open(1, "Spotify", on: 1)
        sim.maximize()
        let gaps = WindowTiler.Gaps(prefs: prefs)
        assertFrame(sim.windows[1]!.frame, MonitorPlanner.filledFrame(in: sim.area(of: 1), gaps: gaps), accuracy: 0)
        sim.moveToMonitor(3)
        assertFrame(sim.windows[1]!.frame, MonitorPlanner.filledFrame(in: sim.area(of: 3), gaps: gaps), accuracy: 0,
                    "fills the smaller screen, gap and all, rather than being scaled down to a near miss")
        // The fullscreen toggle recognises it as filling there.
        sim.toggleFullscreen()
        sim.toggleFullscreen()
        XCTAssertEqual(sim.display(of: 1), 3)
    }

    func testAWindowTooBigForTheSmallMonitorStaysOnIt() {
        let sim = Sim.usersDesk()
        // An app that will not go below 1600 × 1000 (the built-in screen's room is smaller).
        sim.open(1, "Logic", on: 2, fraction: 0.6, minSize: NSSize(width: 1600, height: 1000))
        sim.moveToMonitor(3)
        XCTAssertEqual(sim.display(of: 1), 3, "it sticks out, but it is on the monitor it was sent to")
        XCTAssertEqual(sim.stripNumber(of: 1), 3)
        let area = sim.area(of: 3)
        let frame = sim.windows[1]!.frame
        XCTAssertLessThanOrEqual(frame.maxY, area.maxY, "its title bar is not under the menu bar")
        XCTAssertGreaterThanOrEqual(frame.minX, area.minX, "nor behind the strip")
        XCTAssertGreaterThan(frame.maxY, area.minY + 28, "and on screen to be grabbed")
        sim.checkInvariants()
    }

    // MARK: - Maximize and fullscreen after a move

    func testFullscreenAfterMovingComesBackOnTheNewMonitor() {
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 1, fraction: 0.5)
        sim.moveToMonitor(2)
        let placed = sim.windows[1]!.frame
        sim.toggleFullscreen()
        assertFrame(sim.windows[1]!.frame, sim.area(of: 2), accuracy: 0)
        sim.toggleFullscreen()
        assertFrame(sim.windows[1]!.frame, placed, "back where the move put it")
        XCTAssertEqual(sim.stripNumber(of: 1), 2)
    }

    func testMaximizingAfterAMoveStaysOnTheNewMonitor() {
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 1, fraction: 0.5)
        sim.moveToMonitor(2)
        sim.maximize()
        XCTAssertEqual(sim.display(of: 1), 2)
        assertFrame(sim.windows[1]!.frame, sim.area(of: 2), accuracy: 0)
        sim.toggleFullscreen()
        XCTAssertEqual(sim.display(of: 1), 2, "out of fullscreen it is still on the monitor it was sent to")
        sim.checkInvariants()
    }

    func testAFullscreenWindowMovedOnComesOutOfItOnTheNewMonitor() {
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 1, fraction: 0.5)
        sim.toggleFullscreen()
        sim.moveToMonitor(2)
        assertFrame(sim.windows[1]!.frame, sim.area(of: 2), accuracy: 0, "fills the new monitor")
        sim.toggleFullscreen()
        XCTAssertEqual(sim.display(of: 1), 2, "and leaves fullscreen there, never back on the old one")
        sim.checkInvariants()
    }

    func testAWindowOnceMaximizedThenMovedDoesNotGoBackWhenItLeavesFullscreen() {
        // ⌥M on the Dell remembers the Dell frame; the window is then made smaller by hand, sent to
        // the main monitor, maximized and toggled out of fullscreen there.
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 1, fraction: 0.5)
        sim.maximize()
        let dell = sim.area(of: 1)
        sim.setFrame(1, NSRect(x: dell.minX + 100, y: dell.minY + 100, width: 900, height: 700))
        sim.refresh()
        sim.moveToMonitor(2)
        XCTAssertEqual(sim.display(of: 1), 2)
        sim.maximize()
        XCTAssertEqual(sim.display(of: 1), 2)
        sim.toggleFullscreen()
        XCTAssertEqual(sim.display(of: 1), 2, "the frame remembered on the Dell is not where it goes back to")
        XCTAssertEqual(sim.stripNumber(of: 1), 2)
        sim.checkInvariants()
    }

    func testAWindowDraggedToAnotherMonitorByHandLeavesFullscreenThere() {
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 1, fraction: 0.5)
        sim.toggleFullscreen()
        // Dragged by its title bar to the built-in screen: no shortcut involved.
        sim.setFrame(1, NSRect(x: 3100, y: 100, width: 1000, height: 700))
        sim.refresh()
        sim.toggleFullscreen()
        assertFrame(sim.windows[1]!.frame, sim.area(of: 3), accuracy: 0)
        sim.toggleFullscreen()
        XCTAssertEqual(sim.display(of: 1), 3)
    }

    // MARK: - Aimed windows

    func testAimedWindowsGoTogetherAndTheOnesAlreadyThereStay() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.open(2, "Mail", on: 2)
        sim.open(3, "Safari", on: 3)
        sim.focus(1)
        sim.moveToMonitor(2, aimed: [1, 2, 3])
        XCTAssertEqual(Set(sim.strip(2)), [1, 2, 3])
        XCTAssertEqual(sim.model.selectedID, 1, "the first one moved is focused")
        XCTAssertEqual(sim.flashes, [2])
        sim.checkInvariants()

        // Next monitor goes by the lead's monitor; all of them follow it.
        sim.moveToMonitor(nil, aimed: [2, 3])
        XCTAssertEqual(Set(sim.strip(3)), [2, 3])
        XCTAssertEqual(sim.strip(2), [1])
        sim.checkInvariants()
    }

    func testAnUnmeasurableWindowIsLeftAlone() {
        let sim = Sim.usersDesk()
        sim.open(1, "Hung", on: 1)
        sim.windows[1]!.measurable = false
        let before = sim.windows[1]!.frame
        sim.moveToMonitor(2)
        XCTAssertEqual(sim.windows[1]!.frame, before)
        XCTAssertTrue(sim.toasts.isEmpty)
        // Aimed with a measurable one, only that one goes.
        sim.open(2, "Mail", on: 1)
        sim.moveToMonitor(3, aimed: [1, 2])
        XCTAssertEqual(sim.display(of: 1), 1)
        XCTAssertEqual(sim.display(of: 2), 3)
        sim.checkInvariants()
    }

    // MARK: - Focusing a monitor

    func testFocusingAMonitorLandsOnItsTopmostWindow() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.open(2, "Mail", on: 1)
        sim.open(3, "Safari", on: 2)
        sim.open(4, "Xcode", on: 3)
        sim.focus(1)
        sim.focus(3)
        sim.focusMonitor(1)
        XCTAssertEqual(sim.model.selectedID, 1, "Notes was on top on the Dell")
        XCTAssertEqual(sim.model.currentMonitorID, 1)
        XCTAssertEqual(Set(sim.model.visibleWindows.map(\.id)), [1, 2], "the keyboard now cycles the Dell's queue")
        sim.focusMonitor(nil)
        XCTAssertEqual(sim.model.selectedID, 3)
        sim.focusMonitor(nil)
        XCTAssertEqual(sim.model.selectedID, 4)
        sim.focusMonitor(nil)
        XCTAssertEqual(sim.model.currentMonitorID, 1, "round all three, not back and forth between two")
        XCTAssertEqual(sim.flashes, [1, 2, 3, 1])
        sim.focusMonitor(1)
        XCTAssertEqual(sim.flashes.count, 4, "no flash when the monitor does not change")
        sim.checkInvariants()
    }

    func testFocusingAnEmptyMonitorSendsThePointerAndNextGoesOnFromThere() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.open(3, "Safari", on: 3)
        sim.focus(1)
        sim.focusMonitor(nil)
        XCTAssertEqual(sim.model.selectedID, 1, "nothing to select on the main monitor")
        XCTAssertEqual(sim.warps.count, 1)
        XCTAssertTrue(sim.screens.first { $0.id == 2 }!.frame.contains(sim.pointer), "the pointer is on the main monitor")
        XCTAssertEqual(sim.workedOnDisplay(), 2)
        sim.focusMonitor(nil)
        XCTAssertEqual(sim.model.selectedID, 3, "next from the empty monitor, not from the selected window's")
        sim.checkInvariants()
    }

    func testAMinimizedOrHiddenWindowIsNotLandedOn() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.open(2, "Mail", on: 2)
        sim.windows[2]!.minimized = true
        // On the Dell's other desktop, not on show.
        sim.open(3, "Safari", on: 1)
        sim.windows[3]!.space = 11
        sim.refresh()
        sim.focus(1)
        sim.focusMonitor(2)
        XCTAssertEqual(sim.model.selectedID, 1)
        XCTAssertEqual(sim.warps.count, 1, "an empty monitor as far as the eye can see")
        sim.focusMonitor(1)
        XCTAssertEqual(sim.model.selectedID, 1)
    }

    func testOneMonitorOnly() {
        let sim = Sim([.init(id: 7, frame: NSRect(x: 0, y: 0, width: 1512, height: 982), spaces: [1], shown: 1, name: "Built-in")])
        sim.open(1, "Notes", on: 7)
        sim.moveToMonitor(nil)
        sim.focusMonitor(nil)
        XCTAssertEqual(sim.toasts, ["Only one monitor", "Only one monitor"])
        XCTAssertTrue(sim.flashes.isEmpty)
        sim.noteLaunch()
        XCTAssertNil(sim.launchTarget, "launches are not redirected with a single screen")
        sim.checkInvariants()
    }

    func testWithoutMultiMonitorModeTheShortcutsDoNothing() {
        var prefs = Sim.defaultPrefs
        prefs.multiMonitorMode = false
        let sim = Sim.usersDesk(prefs: prefs)
        sim.open(1, "Notes", on: 1)
        let before = sim.windows[1]!.frame
        sim.moveToMonitor(2)
        sim.focusMonitor(3)
        XCTAssertEqual(sim.windows[1]!.frame, before)
        XCTAssertEqual(sim.model.selectedID, 1)
        XCTAssertTrue(sim.toasts.isEmpty)
        // Every strip shows the focused monitor's queue.
        sim.open(2, "Mail", on: 3, focus: false)
        XCTAssertEqual(sim.strip(1), sim.strip(3))
    }

    // MARK: - Launching

    func testANewWindowIsBroughtToTheMonitorWorkedOn() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 3)
        sim.noteLaunch()
        // macOS opens it on the app's last screen, the Dell.
        sim.launch(2, "Safari", at: NSRect(x: -2000, y: 300, width: 1200, height: 800))
        XCTAssertEqual(sim.display(of: 2), 3)
        XCTAssertEqual(sim.stripNumber(of: 2), 3)
        // Only the next window: one after it opens where macOS puts it.
        sim.launch(3, "Safari", at: NSRect(x: -2000, y: 300, width: 1200, height: 800))
        XCTAssertEqual(sim.display(of: 3), 1)
        sim.checkInvariants()
    }

    func testALaunchLongForgottenIsNotRedirected() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 3)
        sim.noteLaunch()
        sim.clock += 30
        sim.launch(2, "Safari", at: NSRect(x: -2000, y: 300, width: 1200, height: 800))
        XCTAssertEqual(sim.display(of: 2), 1)
    }

    func testALaunchFromAnEmptyMonitorGoesThere() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.focusMonitor(3)
        XCTAssertEqual(sim.warps.count, 1)
        sim.noteLaunch()
        sim.launch(2, "Terminal", at: NSRect(x: 200, y: 200, width: 800, height: 600))
        XCTAssertEqual(sim.display(of: 2), 3)
        sim.checkInvariants()
    }

    // MARK: - Odd arrangements

    func testStackedMonitorsCountTopToBottomAndMoveBothWays() {
        // An external display above the laptop, another below-right.
        let sim = Sim([
            .init(id: 1, frame: NSRect(x: 0, y: 0, width: 1512, height: 982), spaces: [1], shown: 1, name: "Built-in"),
            .init(id: 2, frame: NSRect(x: 0, y: 982, width: 2560, height: 1440), spaces: [2], shown: 2, name: "Above"),
            .init(id: 3, frame: NSRect(x: 1512, y: -600, width: 1920, height: 1080), spaces: [3], shown: 3, name: "Right"),
        ])
        XCTAssertEqual(sim.displays.map(\.id), [2, 1, 3], "same x: the upper one first")
        XCTAssertEqual(sim.model.monitors[0].frame.minY, -1440, "above the primary: negative WindowServer y")
        sim.open(1, "Notes", on: 1)
        sim.moveToMonitor(1)
        XCTAssertEqual(sim.display(of: 1), 2)
        XCTAssertEqual(sim.stripNumber(of: 1), 1)
        sim.moveToMonitor(3)
        XCTAssertEqual(sim.display(of: 1), 3)
        sim.moveToMonitor(nil)
        XCTAssertEqual(sim.display(of: 1), 2)
        sim.checkInvariants()
    }

    func testAWindowStraddlingTwoMonitorsBelongsToTheOneHoldingMostOfIt() {
        let sim = Sim.usersDesk()
        // 700 pt on the Dell, 300 on the main monitor.
        sim.open(1, "Notes", NSRect(x: -700, y: 300, width: 1000, height: 600))
        XCTAssertEqual(sim.stripNumber(of: 1), 1)
        sim.moveToMonitor(nil)
        XCTAssertEqual(sim.display(of: 1), 2)
        XCTAssertTrue(sim.area(of: 2).contains(sim.windows[1]!.frame), "lands wholly inside the main monitor")
        sim.checkInvariants()
    }

    func testTheStripOnEachSideTakesItsRoomOnEveryMonitor() {
        for side in [StripSide.left, .right, .top, .bottom] {
            var prefs = Sim.defaultPrefs
            prefs.stripSide = side
            let sim = Sim.usersDesk(prefs: prefs)
            sim.open(1, "Spotify", on: 1)
            sim.maximize()
            for _ in 0..<3 {
                sim.moveToMonitor(nil)
                let display = sim.display(of: 1)!
                let screen = sim.screens.first { $0.id == display }!
                let area = sim.area(of: display)
                assertFrame(sim.windows[1]!.frame, area, accuracy: 0, "\(side)")
                XCTAssertTrue(sim.visibleFrame(screen).contains(area))
                XCTAssertLessThan(area.width * area.height, sim.visibleFrame(screen).width * sim.visibleFrame(screen).height,
                                  "\(side): the strip keeps room on every monitor")
            }
        }
    }

    // MARK: - Plugging and unplugging

    func testUnpluggingAMonitorGathersItsWindowsOnTheStripsLeft() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.open(2, "Mail", on: 2)
        sim.open(3, "Safari", on: 3)
        sim.focus(3)
        sim.unplug(3)
        XCTAssertEqual(sim.displays.map(\.id), [1, 2])
        XCTAssertEqual(sim.display(of: 3), 2)
        XCTAssertEqual(Set(sim.strip(2)), [2, 3])
        sim.checkInvariants("after unplugging")
        // Monitor numbers close up: what was 3 is gone, the main one is still 2.
        sim.moveToMonitor(3)
        XCTAssertEqual(sim.toasts.last, "No monitor 3")
        sim.moveToMonitor(nil)
        XCTAssertEqual(sim.display(of: 3), 1)
        sim.checkInvariants()

        // Plugged back in, it is monitor 3 again and empty.
        sim.plug(.init(id: 3, frame: NSRect(x: 3008, y: 0, width: 1512, height: 982), spaces: [30], shown: 30, name: "Built-in"))
        XCTAssertEqual(sim.displays.map(\.id), [1, 2, 3])
        XCTAssertTrue(sim.strip(3).isEmpty)
        sim.moveToMonitor(3)
        XCTAssertEqual(sim.stripNumber(of: 3), 3)
        sim.checkInvariants("after plugging back")
    }

    func testLeavingFullscreenAfterItsMonitorWasUnpluggedStaysOnScreen() {
        let sim = Sim.usersDesk()
        sim.open(1, "Spotify", on: 3, fraction: 0.5)
        sim.toggleFullscreen()
        sim.unplug(3)
        XCTAssertEqual(sim.display(of: 1), 2)
        // ⌥M keeps the frame remembered on the built-in screen, which is gone now.
        sim.maximize()
        sim.toggleFullscreen()
        XCTAssertEqual(sim.display(of: 1), 2)
        XCTAssertTrue(sim.area(of: 2).contains(sim.windows[1]!.frame), "\(sim.windows[1]!.frame) is not lost off screen")
        sim.checkInvariants()
    }

    func testPluggingAMonitorInOnTheLeftRenumbersTheOthers() {
        let sim = Sim([
            .init(id: 2, frame: NSRect(x: 0, y: 0, width: 3008, height: 1692), spaces: [20], shown: 20, name: "Main"),
        ])
        sim.open(1, "Notes", on: 2)
        sim.plug(.init(id: 1, frame: NSRect(x: -2560, y: 0, width: 2560, height: 1440), spaces: [10], shown: 10, name: "Dell"))
        XCTAssertEqual(sim.stripNumber(of: 1), 2, "the main monitor is number 2 now")
        sim.moveToMonitor(1)
        XCTAssertEqual(sim.display(of: 1), 1)
        sim.checkInvariants()
    }

    func testClosingTheWindowWorkedOnLeavesTheMonitorStillWorkedOn() {
        let sim = Sim.usersDesk()
        sim.open(1, "Notes", on: 1)
        sim.open(2, "Mail", on: 3)
        sim.open(3, "Safari", on: 3)
        sim.focus(2)
        sim.close(2)
        sim.focus(3)
        XCTAssertEqual(sim.model.currentMonitorID, 3)
        XCTAssertEqual(sim.model.visibleWindows.map(\.id), [3])
        sim.checkInvariants()
    }

    // MARK: - Fuzz

    /// Random desks of two to four screens in any arrangement, random windows, a few hundred random
    /// shortcuts each; everything `checkInvariants` covers must hold after every step, plus what each
    /// shortcut promises.
    func testRandomDesksAndShortcutsKeepEveryWindowOnItsOwnMonitorsStrip() {
        for seed in 1...120 as ClosedRange<UInt64> {
            var rng = SplitMix(seed: seed)
            let sim = randomDesk(&rng)
            var nextID: CGWindowID = 1
            for _ in 0..<Int.random(in: 2...6, using: &rng) {
                openRandomWindow(sim, id: nextID, &rng)
                nextID += 1
            }
            for step in 0..<60 {
                let context = "seed \(seed) step \(step)"
                let ids = Array(sim.windows.keys).sorted()
                let count = sim.displays.count
                switch Int.random(in: 0..<11, using: &rng) {
                case 0, 1:
                    guard let id = ids.randomElement(using: &rng) else { break }
                    sim.focus(id)
                case 2:
                    let number = Bool.random(using: &rng) ? nil : Int.random(in: 1...count + 1, using: &rng)
                    let selected = sim.model.selectedID
                    let before = selected.flatMap(sim.display(of:))
                    let filled = selected.map { MonitorPlanner.fills(sim.windows[$0]!.frame, sim.tilingArea(of: $0), gaps: sim.gaps) }
                    sim.moveToMonitor(number)
                    guard let id = selected, let before, number.map({ $0 <= count }) ?? true else { break }
                    let expected = number.map { sim.displays[$0 - 1].id }
                        ?? sim.displays[(sim.number(of: before)! % count)].id
                    XCTAssertEqual(sim.display(of: id), expected, "moved to the monitor asked \(context)")
                    XCTAssertEqual(sim.stripNumber(of: id), sim.number(of: expected), "\(context)")
                    if filled == true, expected != before, sim.windows[id]!.minSize.width <= 1 {
                        assertFrame(sim.windows[id]!.frame, MonitorPlanner.filledFrame(in: sim.area(of: expected), gaps: sim.gaps),
                                    accuracy: 0, "a maximized window fills its new monitor \(context)")
                    }
                case 3:
                    let selected = sim.model.selectedID
                    guard let lead = selected else { break }
                    let aimed = [lead] + ids.filter { $0 != lead && Bool.random(using: &rng) }
                    let number = Int.random(in: 1...count, using: &rng)
                    sim.moveToMonitor(number, aimed: aimed)
                    for id in aimed {
                        XCTAssertEqual(sim.display(of: id), sim.displays[number - 1].id, "aimed window \(id) \(context)")
                    }
                case 4:
                    let number = Bool.random(using: &rng) ? nil : Int.random(in: 1...count, using: &rng)
                    let from = sim.workedOnDisplay()
                    sim.focusMonitor(number)
                    let expected = number.map { sim.displays[$0 - 1].id }
                        ?? sim.displays[((sim.number(of: from) ?? 1)) % count].id
                    XCTAssertEqual(sim.workedOnDisplay(), expected, "worked-on monitor \(context)")
                    if let selected = sim.model.selectedID, sim.display(of: selected) == expected {
                        XCTAssertEqual(sim.model.currentMonitorID, expected, "\(context)")
                    }
                case 5:
                    guard let id = sim.model.selectedID else { break }
                    let display = sim.display(of: id)
                    sim.maximize()
                    XCTAssertEqual(sim.display(of: id), display, "maximize keeps the monitor \(context)")
                    if sim.windows[id]!.minSize.width <= 1 {
                        assertFrame(sim.windows[id]!.frame, MonitorPlanner.filledFrame(in: sim.area(of: display!), gaps: sim.gaps),
                                    accuracy: 0, "\(context)")
                    }
                case 6:
                    guard let id = sim.model.selectedID else { break }
                    let display = sim.display(of: id)
                    sim.toggleFullscreen()
                    XCTAssertEqual(sim.display(of: id), display, "fullscreen keeps the monitor \(context)")
                case 7:
                    sim.noteLaunch()
                    let target = sim.workedOnDisplay()
                    let screen = sim.screens.randomElement(using: &rng)!
                    let frame = NSRect(x: screen.frame.minX + 50, y: screen.frame.minY + 80, width: 700, height: 500)
                    sim.launch(nextID, "App\(nextID)", at: frame)
                    XCTAssertEqual(sim.display(of: nextID), target, "a new window goes to the monitor worked on \(context)")
                    nextID += 1
                case 8:
                    if sim.windows.count < 10 {
                        openRandomWindow(sim, id: nextID, &rng)
                        nextID += 1
                    }
                case 9:
                    if sim.windows.count > 1, let id = ids.randomElement(using: &rng) { sim.close(id) }
                default:
                    // A window dragged by hand somewhere on another screen.
                    guard let id = ids.randomElement(using: &rng) else { break }
                    let screen = sim.screens.randomElement(using: &rng)!
                    let size = sim.windows[id]!.frame.size
                    let room = sim.visibleFrame(screen)
                    let width = min(size.width, room.width), height = min(size.height, room.height)
                    sim.setFrame(id, NSRect(x: room.minX + CGFloat.random(in: 0...max(0, room.width - width), using: &rng),
                                            y: room.minY + CGFloat.random(in: 0...max(0, room.height - height), using: &rng),
                                            width: width, height: height))
                    sim.refresh()
                }
                sim.checkInvariants(context)
            }
        }
    }

    func testRandomPlugAndUnplugKeepsTheStripsWhole() {
        for seed in 500...560 as ClosedRange<UInt64> {
            var rng = SplitMix(seed: seed)
            let sim = randomDesk(&rng)
            for id in 1...6 as ClosedRange<CGWindowID> { openRandomWindow(sim, id: id, &rng) }
            var unplugged: [MultiMonitorSim.Screen] = []
            for step in 0..<20 {
                if Bool.random(using: &rng), sim.screens.count > 1 {
                    let screen = sim.screens[Int.random(in: 1..<sim.screens.count, using: &rng)]
                    unplugged.append(screen)
                    sim.unplug(screen.id)
                } else if let screen = unplugged.popLast() {
                    sim.plug(screen)
                }
                if let id = sim.windows.keys.randomElement(using: &rng) {
                    sim.focus(id)
                    sim.moveToMonitor(nil)
                }
                sim.checkInvariants("seed \(seed) step \(step)")
            }
        }
    }

    // MARK: - Random desks

    private func randomDesk(_ rng: inout SplitMix) -> MultiMonitorSim {
        let sizes: [NSSize] = [.init(width: 1512, height: 982), .init(width: 1728, height: 1117),
                               .init(width: 2560, height: 1440), .init(width: 3008, height: 1692),
                               .init(width: 1920, height: 1080), .init(width: 1080, height: 1920)]
        var frames = [NSRect(origin: .zero, size: sizes.randomElement(using: &rng)!)]
        let count = Int.random(in: 2...4, using: &rng)
        var attempts = 0
        while frames.count < count, attempts < 200 {
            attempts += 1
            let anchor = frames.randomElement(using: &rng)!
            let size = sizes.randomElement(using: &rng)!
            let slide = CGFloat.random(in: -0.8...0.8, using: &rng)
            let frame: NSRect
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: frame = NSRect(x: anchor.maxX, y: anchor.minY + slide * anchor.height, width: size.width, height: size.height)
            case 1: frame = NSRect(x: anchor.minX - size.width, y: anchor.minY + slide * anchor.height, width: size.width, height: size.height)
            case 2: frame = NSRect(x: anchor.minX + slide * anchor.width, y: anchor.maxY, width: size.width, height: size.height)
            default: frame = NSRect(x: anchor.minX + slide * anchor.width, y: anchor.minY - size.height, width: size.width, height: size.height)
            }
            let rounded = frame.integral
            guard !frames.contains(where: { $0.intersects(rounded) }) else { continue }
            frames.append(rounded)
        }
        var prefs = MultiMonitorSim.defaultPrefs
        prefs.stripSide = [StripSide.left, .right, .top, .bottom].randomElement(using: &rng)!
        prefs.tileOuterGap = [0, 8, 24].randomElement(using: &rng)!
        let screens = frames.enumerated().map { index, frame in
            let id = CGDirectDisplayID(index + 1)
            let spaces = (0..<Int.random(in: 1...3, using: &rng)).map { UInt64(index * 10 + 10 + $0) }
            return MultiMonitorSim.Screen(id: id, frame: frame, dock: index == 0 ? 60 : 0,
                                          spaces: spaces, shown: spaces[0], name: "D\(id)")
        }
        return MultiMonitorSim(screens, prefs: prefs)
    }

    private func openRandomWindow(_ sim: MultiMonitorSim, id: CGWindowID, _ rng: inout SplitMix) {
        let screen = sim.screens.randomElement(using: &rng)!
        let minSize = Int.random(in: 0..<5, using: &rng) == 0
            ? NSSize(width: 1300, height: 900) : NSSize(width: 1, height: 1)
        sim.open(id, "App\(id)", on: screen.id, fraction: CGFloat.random(in: 0.2...0.9, using: &rng), minSize: minSize,
                 focus: Bool.random(using: &rng))
    }
}

/// A small seeded generator, so a failing fuzz run can be replayed by its seed.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
