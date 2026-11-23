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

    func testUpdaterDownloadsTheReleaseZip() {
        XCTAssertEqual(Updater.assetURL(version: "1.6.0").absoluteString,
                       "https://github.com/mikolajpochec/wq/releases/download/v1.6.0/WindowQueue-1.6.0.zip")
    }

    func testUpdaterRejectsADownloadWithoutTheApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("WindowQueue-9.9.9.zip")
        try Data("not a zip".utf8).write(to: zip)
        guard case .failure = Updater.prepare(zip: zip, version: "9.9.9") else { return XCTFail("installed junk") }
    }

    func testUpdaterDoesNotTrustAnUnsignedApp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = dir.appendingPathComponent("WindowQueue.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: app.appendingPathComponent("WindowQueue").path)
        XCTAssertFalse(Updater.isTrusted(dir.appendingPathComponent("WindowQueue.app")))
    }
}
