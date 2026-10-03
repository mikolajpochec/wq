import XCTest
@testable import WindowQueue

final class UpdateCheckerTests: XCTestCase {
    func testVersionsCompareNumerically() {
        XCTAssertTrue(UpdateChecker.isVersion("1.0.2", newerThan: "1.0.1"))
        XCTAssertTrue(UpdateChecker.isVersion("1.10.0", newerThan: "1.9.3"), "not by text")
        XCTAssertTrue(UpdateChecker.isVersion("2", newerThan: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0", newerThan: "1.0.0"), "a missing part is 0")
        XCTAssertFalse(UpdateChecker.isVersion("1.0.1", newerThan: "1.0.1"))
        XCTAssertFalse(UpdateChecker.isVersion("1.0.0", newerThan: "1.0.1"))
    }

    func testReadsTheTagFromTheReleasePage() {
        XCTAssertEqual(UpdateChecker.tag(fromReleasePage: URL(string: "https://github.com/mikolajpochec/wq/releases/tag/v1.2.0")!), "v1.2.0")
        XCTAssertNil(UpdateChecker.tag(fromReleasePage: URL(string: "https://github.com/mikolajpochec/wq/releases")!))
    }

    func testTakesAVersionsNotesFromTheChangelog() {
        let changelog = """
        # Changelog

        ## 1.2.0 — 2026-11-01

        - **New:** something, written over
          two lines.
        - Another.

        ## 1.1.0 — 2026-10-03

        - Older.
        """
        XCTAssertEqual(UpdateChecker.notes(for: "1.2.0", in: changelog), "- **New:** something, written over two lines.\n- Another.")
        XCTAssertEqual(UpdateChecker.notes(for: "1.1.0", in: changelog), "- Older.")
        XCTAssertEqual(UpdateChecker.notes(for: "1.1", in: changelog), "", "not a prefix match")
    }

    func testUpdateChecksAreOnForEveryone() throws {
        XCTAssertTrue(Preferences().checkForUpdates)
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).checkForUpdates)
    }
}
