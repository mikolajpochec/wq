import XCTest
@testable import WindowQueue

final class WindowSizeLimitsTests: XCTestCase {
    private let area = CGSize(width: 1000, height: 800)

    // Landings recorded from an AppKit window with `contentAspectRatio` 1:2 and a 32 pt title bar.
    func testInfersAspectRatio() throws {
        let limits = try XCTUnwrap(SizeLimits.infer(tiny: CGSize(width: 9, height: 50),
                                                    full: CGSize(width: 384, height: 800),
                                                    wide: CGSize(width: 184, height: 400),
                                                    tall: CGSize(width: 384, height: 800), area: area))
        XCTAssertEqual(try XCTUnwrap(limits.aspect), 0.5, accuracy: 0.001)
        XCTAssertEqual(limits.chrome, 32)
        XCTAssertEqual(limits.fitted(in: CGSize(width: 900, height: 432)), CGSize(width: 200, height: 432))
        XCTAssertEqual(limits.fitted(in: CGSize(width: 100, height: 800)), CGSize(width: 100, height: 232))
    }

    func testInfersMinimumAndMaximum() throws {
        let limits = try XCTUnwrap(SizeLimits.infer(tiny: CGSize(width: 400, height: 332),
                                                    full: CGSize(width: 700, height: 532),
                                                    wide: CGSize(width: 700, height: 400),
                                                    tall: CGSize(width: 500, height: 532), area: area))
        XCTAssertNil(limits.aspect)
        XCTAssertEqual(limits.min, CGSize(width: 400, height: 332))
        XCTAssertEqual(limits.max, CGSize(width: 700, height: 532))
    }

    func testMinimumOnlyLeavesMaximumOpen() throws {
        let limits = try XCTUnwrap(SizeLimits.infer(tiny: CGSize(width: 600, height: 200),
                                                    full: CGSize(width: 1000, height: 800),
                                                    wide: CGSize(width: 1000, height: 400),
                                                    tall: CGSize(width: 600, height: 800), area: area))
        XCTAssertNil(limits.aspect)
        XCTAssertEqual(limits.max.width, .infinity)
        XCTAssertEqual(limits.max.height, .infinity)
    }

    func testWindowThatNeverMovedTellsNothing() {
        let same = CGSize(width: 500, height: 500)
        XCTAssertNil(SizeLimits.infer(tiny: same, full: same, wide: same, tall: same, area: area))
    }

    func testColumnsGiveAFixedWindowsSpareRoomToTheOthers() {
        let units = (0..<3).map { CGRect(x: CGFloat($0) / 3, y: 0, width: 1.0 / 3, height: 1) }
        let limits: [SizeLimits] = [.none, .fixed(CGSize(width: 200, height: 300)), .none]
        let frames = TileSolver.frames(units: units, limits: limits,
                                       in: CGRect(x: 0, y: 0, width: 1200, height: 800), inset: 0)
        XCTAssertEqual(frames[1].size, CGSize(width: 200, height: 300))
        XCTAssertEqual(frames[1].minY, 250)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: 500, height: 800))
        XCTAssertEqual(frames[2], CGRect(x: 700, y: 0, width: 500, height: 800))
    }

    func testMinimumWidthTakesRoomFromNeighbours() {
        let units = [CGRect(x: 0, y: 0, width: 0.5, height: 1), CGRect(x: 0.5, y: 0, width: 0.5, height: 1)]
        var wide = SizeLimits.none
        wide.min = CGSize(width: 800, height: 0)
        let frames = TileSolver.frames(units: units, limits: [wide, .none],
                                       in: CGRect(x: 0, y: 0, width: 1200, height: 800), inset: 2)
        XCTAssertEqual(frames[0], CGRect(x: 2, y: 2, width: 800, height: 796))
        XCTAssertEqual(frames[1], CGRect(x: 806, y: 2, width: 392, height: 796))
    }

    func testAspectWindowInMainAndStackShrinksItsColumn() {
        let units = [CGRect(x: 0, y: 0, width: 0.5, height: 1),
                     CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)]
        var simulator = SizeLimits.none
        simulator.aspect = 0.5
        simulator.chrome = 0
        let frames = TileSolver.frames(units: units, limits: [simulator, .none, .none],
                                       in: CGRect(x: 0, y: 0, width: 1600, height: 800), inset: 0)
        XCTAssertEqual(frames[0], CGRect(x: 0, y: 0, width: 400, height: 800))
        XCTAssertEqual(frames[1], CGRect(x: 400, y: 0, width: 1200, height: 400))
        XCTAssertEqual(frames[2], CGRect(x: 400, y: 400, width: 1200, height: 400))
    }

    func testMaximizeCentresAnAspectWindow() {
        var simulator = SizeLimits.none
        simulator.aspect = 0.5
        simulator.chrome = 28
        let frames = TileSolver.frames(units: [CGRect(x: 0, y: 0, width: 1, height: 1)], limits: [simulator],
                                       in: CGRect(x: 0, y: 0, width: 1600, height: 828), inset: 0)
        XCTAssertEqual(frames[0], CGRect(x: 600, y: 0, width: 400, height: 828))
    }

    func testShareStaysInProportionWithinLimits() {
        let sizes = TileSolver.share(900, ranges: [0...100, 0...CGFloat.infinity, 0...CGFloat.infinity],
                                     weights: [1, 1, 1])
        XCTAssertEqual(sizes[0], 100, accuracy: 0.01)
        XCTAssertEqual(sizes[1], 400, accuracy: 0.01)
        XCTAssertEqual(sizes[2], 400, accuracy: 0.01)
    }
}
