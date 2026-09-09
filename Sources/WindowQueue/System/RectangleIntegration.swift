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
        side == .left ? "screenEdgeGapLeft" : "screenEdgeGapRight"
    }

    /// Total width the strip occupies, including the margin it is inset by.
    static func reservedWidth(for prefs: Preferences) -> Int {
        Int((prefs.stripWidth + StripMetrics.screenMargin * 2).rounded(.up))
    }

    /// Writes the gap for the strip's side and clears the other one.
    /// Returns true when a value actually changed, meaning Rectangle has to be restarted.
    @discardableResult
    static func apply(prefs: Preferences) -> Bool {
        let gap = prefs.reserveScreenSpace ? reservedWidth(for: prefs) : 0
        let changed = write(key(for: prefs.stripSide), gap)
        let cleared = write(key(for: prefs.stripSide == .left ? .right : .left), 0)
        return changed || cleared
    }

    /// Writes the gaps and, if they changed while Rectangle is running, restarts it so they apply.
    static func applyAndReloadIfNeeded(prefs: Preferences) {
        guard isInstalled, apply(prefs: prefs), isRunning else { return }
        restart { _ in }
    }

    static func clear() {
        write("screenEdgeGapLeft", 0)
        write("screenEdgeGapRight", 0)
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            // Rectangle opens its main window on a plain launch; start it hidden instead.
            configuration.hides = true
            configuration.addsToRecentItems = false
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                DispatchQueue.main.async { completion(error == nil) }
            }
        }
    }
}
