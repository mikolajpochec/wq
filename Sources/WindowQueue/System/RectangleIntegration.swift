import AppKit

/// Makes tiling apps leave room for the strip.
///
/// macOS has no public way for a third-party window to shrink `NSScreen.visibleFrame` — only the
/// Dock and menu bar do that. Rectangle instead reads its own hidden "screen edge gap" preferences,
/// so reserving space means writing those and restarting it.
enum RectangleIntegration {
    static let bundleID = "com.knollsoft.Rectangle"

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private static func key(for side: StripSide) -> String {
        "screenEdgeGap" + side.rawValue.capitalized
    }

    /// Total width the strip occupies, including the margin it is inset by.
    static func reservedWidth(for prefs: Preferences) -> Int {
        // A strip that is only there while aiming takes no room from the windows.
        guard !prefs.invisibleStrip else { return 0 }
        return Int((StripMetrics.thickness(prefs: prefs) + prefs.stripMargin * 2).rounded(.up))
    }

    /// Writes the gap for the strip's side and clears the other one.
    /// Returns true when a value actually changed, meaning Rectangle has to be restarted.
    @discardableResult
    static func apply(prefs: Preferences) -> Bool {
        let gap = prefs.reserveScreenSpace ? reservedWidth(for: prefs) : 0
        var changed = write(key(for: prefs.stripSide), gap)
        for side in StripSide.allCases where side != prefs.stripSide {
            changed = write(key(for: side), 0) || changed
        }
        return changed
    }

    /// Writes the gaps and, if they changed while Rectangle is running, restarts it so they apply.
    static func applyAndReloadIfNeeded(prefs: Preferences) {
        guard isInstalled, apply(prefs: prefs), isRunning else { return }
        restart { _ in }
    }

    /// True while WindowQueue itself is relaunching Rectangle.
    private(set) static var isRestarting = false

    /// Rectangle started on its own — at login, say — while the Dock reservation was in place, so
    /// it read a screen that already leaves room for the strip. Relaunch it to read the real one.
    static func handleLaunch(of app: NSRunningApplication) {
        guard app.bundleIdentifier == bundleID, !isRestarting,
              DockReservation.shared?.isInstalled == true
        else { return }
        Diagnostics.note("rectangle launched under the dock reservation; restarting it")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { restart { _ in } }
    }

    static func clear() {
        StripSide.allCases.forEach { write(key(for: $0), 0) }
    }

    @discardableResult
    private static func write(_ key: String, _ value: Int) -> Bool {
        let existing = CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) as? Int
        guard existing != value else { return false }
        CFPreferencesSetAppValue(key as CFString, value as CFNumber, bundleID as CFString)
        CFPreferencesAppSynchronize(bundleID as CFString)
        return true
    }

    /// Rectangle reads its gaps at launch, so the new value only takes effect after a restart.
    static func restart(completion: @escaping (Bool) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            completion(false)
            return
        }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        running.forEach { $0.terminate() }
        isRestarting = true
        // Rectangle adds its gap to the visible frame it reads at launch; it must not also see the
        // room the Dock reservation already makes for the strip.
        DockReservation.shared?.suspend(for: 6)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Rectangle opens its main window on a plain launch; start it hidden instead.
            configuration.hides = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async {
                    isRestarting = false
                    completion(error == nil)
                }
            }
        }
    }
}
