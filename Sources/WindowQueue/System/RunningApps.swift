import AppKit

/// Process ids for running applications, including the ones LaunchServices gets wrong.
///
/// Xcode 27's Device Hub (the iOS Simulator, `com.apple.dt.Devices`) is started through a
/// trampoline executable, and LaunchServices keeps reporting it with a process id of -1 even
/// though the real process owns the simulator windows. Such an app is found again through the
/// owners of the WindowServer's windows.
enum RunningApps {
    private static var resolved: [String: pid_t] = [:]
    private static let lock = NSLock()

    /// The application's real process id, or nil when it cannot be found.
    static func pid(of app: NSRunningApplication) -> pid_t? {
        let pid = app.processIdentifier
        if pid > 0 { return pid }
        guard let bundleID = app.bundleIdentifier else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let cached = resolved[bundleID], matches(cached, bundleID) { return cached }
        resolved[bundleID] = nil
        let owners = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var seen: Set<pid_t> = []
        for info in owners {
            guard let owner = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  seen.insert(owner).inserted, matches(owner, bundleID)
            else { continue }
            resolved[bundleID] = owner
            return owner
        }
        return nil
    }

    /// The frontmost application's real process id.
    static var frontmostPID: pid_t? {
        NSWorkspace.shared.frontmostApplication.flatMap(pid(of:))
    }

    private static func matches(_ pid: pid_t, _ bundleID: String) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        return app.bundleIdentifier == bundleID
    }
}
