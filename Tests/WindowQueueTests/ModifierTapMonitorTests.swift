import AppKit
import XCTest
@testable import WindowQueue

final class ModifierTapMonitorTests: XCTestCase {
    private func monitor(_ modifiers: NSEvent.ModifierFlags = .option) -> (ModifierTapMonitor, () -> Int) {
        let taps = ModifierTapMonitor()
        taps.modifiers = modifiers
        var count = 0
        taps.onTap = { count += 1 }
        return (taps, { count })
    }

    private func play(_ taps: ModifierTapMonitor, _ steps: [NSEvent.ModifierFlags], step: TimeInterval = 0.05) {
        var now = Date()
        for flags in steps {
            taps.handle(flags: flags, at: now)
            now += step
        }
    }

    func testCleanTapCounts() {
        let (taps, count) = monitor()
        play(taps, [.option, []])
        XCTAssertEqual(count(), 1)
    }

    /// The tap is dated by its release, not by when it got handled.
    func testTapIsDatedByItsRelease() {
        let (taps, _) = monitor()
        let start = Date(timeIntervalSinceNow: -5)
        taps.handle(flags: .option, at: start)
        taps.handle(flags: [], at: start + 0.1)
        XCTAssertEqual(taps.lastTapAt.timeIntervalSince(start), 0.1, accuracy: 0.001)
    }

    func testLongHoldIsNoTap() {
        let (taps, count) = monitor()
        play(taps, [.option, []], step: 0.6)
        XCTAssertEqual(count(), 0)
    }

    /// `⌃⌥Space` (next monitor) pressed Control first and let go of Control first.
    func testNextMonitorComboControlFirstIsNoTap() {
        let (taps, count) = monitor()
        var now = Date()
        taps.handle(flags: .control, at: now); now += 0.05
        taps.handle(flags: [.control, .option], at: now); now += 0.05
        taps.cancel() // the Carbon hotkey fired
        taps.handle(flags: .option, at: now); now += 0.05
        taps.handle(flags: [], at: now)
        XCTAssertEqual(count(), 0)
    }

    /// Same, without the hotkey firing (e.g. Space never reached us).
    func testControlReleasedBeforeOptionIsNoTap() {
        let (taps, count) = monitor()
        play(taps, [.control, [.control, .option], .option, []])
        XCTAssertEqual(count(), 0)
    }

    func testShiftComboTailIsNoTap() {
        let (taps, count) = monitor()
        play(taps, [.option, [.option, .shift], .option, []])
        XCTAssertEqual(count(), 0)
    }

    func testMoveToMonitorComboIsNoTap() {
        let (taps, count) = monitor()
        play(taps, [.control, [.control, .shift], [.control, .shift, .option], [.shift, .option], .option, []])
        XCTAssertEqual(count(), 0)
    }

    func testTwoKeySuperTapCounts() {
        let (taps, count) = monitor([.control, .option])
        play(taps, [.control, [.control, .option], .option, []])
        XCTAssertEqual(count(), 1)
    }

    func testTwoKeySuperAfterOtherModifierIsNoTap() {
        let (taps, count) = monitor([.control, .option])
        play(taps, [.shift, [.shift, .control], [.shift, .control, .option], [.control, .option], []])
        XCTAssertEqual(count(), 0)
    }

    func testCapsLockDoesNotBlockTaps() {
        let (taps, count) = monitor()
        play(taps, [.capsLock, [.capsLock, .option], .capsLock])
        XCTAssertEqual(count(), 1)
    }

    func testTapAfterComboStillCounts() {
        let (taps, count) = monitor()
        play(taps, [.control, [.control, .option], .option, [], .option, []])
        XCTAssertEqual(count(), 1)
    }
}
