import XCTest
@testable import WindowQueue

final class GroupStripPlacementTests: XCTestCase {
    func testAutomaticFollowsAlignment() {
        var prefs = Preferences()
        prefs.groupStripPlacement = .automatic
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

    func testReplacingOrOverlayingTakesNoRoom() {
        var prefs = Preferences()
        prefs.stripAlignment = .center
        for placement in [GroupStripPlacement.replace, .overGroup] {
            prefs.groupStripPlacement = placement
            XCTAssertFalse(placement.isBeside)
            XCTAssertEqual(prefs.stripShift(forCompanion: 40), 0)
        }
    }

    func testNewPlacementsRoundTrip() throws {
        var prefs = Preferences()
        prefs.groupStripPlacement = .overGroup
        let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(decoded.groupStripPlacement, .overGroup)
    }

    func testOldPreferencesDecodeToTheDefault() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertEqual(prefs.groupStripPlacement, Preferences().groupStripPlacement)
    }
}
