import Foundation

/// New features that get a "What's new" showcase for people updating from an older version.
///
/// Only features the user has explicitly marked for a showcase belong here (see CLAUDE.md). Each
/// case is a key of `Preferences.seenNewFeatures`; never rename or remove a case's raw value once
/// released, or people would be shown it again (or a stored flag would be orphaned).
enum ShowcasedFeature: String, CaseIterable, Codable {
    /// super-Control-[ / ] to the monitor on the left or right, with Shift taking the window along.
    case monitorBrackets

    /// The flags a fresh install starts with: every feature counts as seen, since a new user meets
    /// them in the tour and the docs instead.
    static var allSeen: [String: Bool] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, true) })
    }

    /// The features not yet shown, in the order they were added.
    static func unseen(in seen: [String: Bool]) -> [ShowcasedFeature] {
        allCases.filter { seen[$0.rawValue] != true }
    }
}
