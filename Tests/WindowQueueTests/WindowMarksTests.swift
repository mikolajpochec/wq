import XCTest
@testable import WindowQueue

final class WindowMarksTests: XCTestCase {
    func testGroupColourReachesItsWindowsAndOwnColourWins() {
        let marks = WindowMarks()
        marks.syncGroups([WindowQueueModel.WindowGroup(id: 1, ids: [10, 11])])
        marks.setTint(.blue, forGroup: 1)
        XCTAssertEqual(marks.tint(for: 10), .blue)
        XCTAssertEqual(marks.tint(for: 11), .blue)
        XCTAssertNil(marks.tint(for: 12))
        marks.setTint(.red, for: 11)
        XCTAssertEqual(marks.tint(for: 11), .red)
        XCTAssertEqual(marks.tintedWindowIDs, [10, 11])
    }

    func testAGroupThatGoesLosesItsColour() {
        let marks = WindowMarks()
        marks.syncGroups([WindowQueueModel.WindowGroup(id: 1, ids: [10, 11])])
        marks.setTint(.green, forGroup: 1)
        marks.syncGroups([])
        XCTAssertNil(marks.tint(for: 10))
        // A new group given the same number starts uncoloured.
        marks.syncGroups([WindowQueueModel.WindowGroup(id: 1, ids: [20, 21])])
        XCTAssertNil(marks.tint(for: 20))
    }

    func testNamesAreTrimmedAndForgottenWithTheirWindows() {
        let marks = WindowMarks()
        marks.setName("  Docs  ", for: 5)
        XCTAssertEqual(marks.name(for: 5), "Docs")
        marks.setName("   ", for: 5)
        XCTAssertNil(marks.name(for: 5))
        marks.setName("API", for: 6)
        marks.setTint(.pink, for: 6)
        marks.prune(keeping: [7])
        XCTAssertNil(marks.name(for: 6))
        XCTAssertNil(marks.tint(for: 6))
    }
}
