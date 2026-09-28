import XCTest
@testable import WindowQueue

final class GroupStripPlacementTests: XCTestCase {
    func testAutomaticFollowsAlignment() {
        var prefs = Preferences()
        prefs.stripAlignment = .end
        XCTAssertTrue(prefs.groupStripIsBefore)
        prefs.stripAlignment = .center
        XCTAssertFalse(prefs.groupStripIsBefore)
    }

    func testExplicitPlacementWins() {
        var prefs = Preferences()
        prefs.stripAlignment = .end
        prefs.groupStripPlacement = .after
        XCTAssertFalse(prefs.groupStripIsBefore)
        XCTAssertEqual(prefs.stripShift(forCompanion: 40), 40)
        prefs.stripAlignment = .start
        prefs.groupStripPlacement = .before
        XCTAssertTrue(prefs.groupStripIsBefore)
        XCTAssertEqual(prefs.stripShift(forCompanion: 40), -40)
    }

    func testCentredPairSharesTheMiddle() {
        var prefs = Preferences()
        prefs.stripAlignment = .center
        prefs.groupStripPlacement = .after
        XCTAssertEqual(prefs.stripShift(forCompanion: 40), 20)
        prefs.groupStripPlacement = .before
        XCTAssertEqual(prefs.stripShift(forCompanion: 40), -20)
    }

    func testOldPreferencesDecodeToAutomatic() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.groupStripPlacement, .automatic)
    }
}
