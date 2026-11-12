import Foundation

/// The system's own ⌘Tab and ⌘⇧Tab app switcher, which takes those keys before any app shortcut
/// sees them. Turning it off (a private WindowServer call, as AltTab does) frees the keys for
/// WindowQueue. The switch outlives the process, so it is handed back on quit, and a launch after a
/// crash restores it from the note left in the defaults.
enum SystemCommandTab {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32
    private static let setEnabled: SetEnabled? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSSetSymbolicHotKeyEnabled")
        .map { unsafeBitCast($0, to: SetEnabled.self) }

    /// Symbolic hot key ids: ⌘Tab and ⌘⇧Tab.
    private static let hotKeys: [Int32] = [1, 2]
    private static let noteKey = "systemCommandTabDisabled"
    private static var applied: Bool?

    /// Turns the system switcher off or back on. Back on only if WindowQueue turned it off, so a
    /// switcher another app disabled stays its business.
    static func setTakenOver(_ takenOver: Bool) {
        let defaults = UserDefaults.standard
        // The note can be stale after a logout, which resets the switcher, so the first call in a
        // process takes over for real; handing back still needs the note.
        let current = applied ?? (takenOver ? false : defaults.bool(forKey: noteKey))
        guard takenOver != current, let setEnabled else { return }
        applied = takenOver
        for key in hotKeys { _ = setEnabled(key, !takenOver) }
        defaults.set(takenOver, forKey: noteKey)
        defaults.synchronize()
        Diagnostics.note("system ⌘Tab \(takenOver ? "taken over" : "handed back")")
    }
}
