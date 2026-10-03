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

    func testReadsGitHubsLatestRelease() throws {
        let json = #"{"tag_name": "v1.2.0", "html_url": "https://github.com/mikolajpochec/wq/releases/tag/v1.2.0", "body": "Notes"}"#
        let release = try XCTUnwrap(UpdateChecker.release(from: Data(json.utf8)))
        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.page.absoluteString, "https://github.com/mikolajpochec/wq/releases/tag/v1.2.0")
        XCTAssertEqual(release.notes, "Notes")
        XCTAssertNil(UpdateChecker.release(from: Data(#"{"message": "Not Found"}"#.utf8)))
    }

    func testUpdateChecksAreOnForEveryone() throws {
        XCTAssertTrue(Preferences().checkForUpdates)
        XCTAssertTrue(try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8)).checkForUpdates)
    }
}
