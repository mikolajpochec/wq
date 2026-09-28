import XCTest
@testable import WindowQueue

final class DeclutterTests: XCTestCase {
    private let area = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func assertInside(_ frames: [CGRect], file: StaticString = #filePath, line: UInt = #line) {
        for frame in frames {
            XCTAssertTrue(area.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(frame) outside \(area)", file: file, line: line)
        }
    }

    func testWindowsThatDoNotOverlapAreLeftAlone() {
        let frames = [CGRect(x: 0, y: 0, width: 700, height: 900), CGRect(x: 800, y: 50, width: 700, height: 600)]
        XCTAssertEqual(Declutter.arrange(frames, in: area, gap: 8), frames)
    }

    func testWindowOffScreenIsPulledBackWithoutResizing() {
        let frames = [CGRect(x: 1400, y: 100, width: 500, height: 400)]
        XCTAssertEqual(Declutter.arrange(frames, in: area), [CGRect(x: 1100, y: 100, width: 500, height: 400)])
    }

    func testSlightOverlapIsSettledByMovingNotShrinking() {
        let frames = [CGRect(x: 100, y: 100, width: 600, height: 700), CGRect(x: 650, y: 150, width: 600, height: 700)]
        let out = Declutter.arrange(frames, in: area, gap: 0)
        XCTAssertFalse(Declutter.overlaps(out))
        XCTAssertEqual(out.map(\.size), frames.map(\.size), "there is room for both at their own size")
        assertInside(out)
    }

    func testStackOfMaximizedWindowsBecomesVisibleSideBySide() {
        let frames = Array(repeating: area, count: 3)
        let out = Declutter.arrange(frames, in: area, gap: 4)
        XCTAssertFalse(Declutter.overlaps(out))
        assertInside(out)
        for frame in out {
            XCTAssertGreaterThan(frame.width * frame.height, 0.25 * area.width * area.height, "\(out)")
        }
    }

    func testFourMaximizedWindowsShareTheScreenAboutEvenly() {
        let out = Declutter.arrange(Array(repeating: area, count: 4), in: area, gap: 0)
        XCTAssertFalse(Declutter.overlaps(out))
        for frame in out {
            XCTAssertEqual(frame.width * frame.height, area.width * area.height / 4, accuracy: area.width * area.height * 0.05, "\(out)")
        }
    }

    func testManyOverlappingWindowsNeverOverlapAfterwards() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<50 {
            let count = Int.random(in: 2...9, using: &generator)
            let frames = (0..<count).map { _ in
                CGRect(x: .random(in: -200...1400, using: &generator), y: .random(in: -100...900, using: &generator),
                       width: .random(in: 200...1700, using: &generator), height: .random(in: 150...1100, using: &generator))
            }
            let out = Declutter.arrange(frames, in: area, gap: 6)
            XCTAssertEqual(out.count, frames.count)
            XCTAssertFalse(Declutter.overlaps(out), "\(frames) -> \(out)")
            assertInside(out)
        }
    }

    func testWindowOutOfTheWayOfTheClashStaysPut() {
        let aside = CGRect(x: 1300, y: 700, width: 280, height: 280)
        let frames = [CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 200, y: 100, width: 800, height: 600), aside]
        let out = Declutter.arrange(frames, in: area, gap: 0)
        XCTAssertFalse(Declutter.overlaps(out))
        XCTAssertEqual(out[2], aside)
    }
}
