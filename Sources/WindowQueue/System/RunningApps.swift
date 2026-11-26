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

    private struct PolicyKey: Hashable {
        let pid: pid_t
        let bundleID: String?
    }
    private static var policies: [PolicyKey: (policy: NSApplication.ActivationPolicy, checked: Date)] = [:]
    /// A background process can turn into one with windows (and a Dock icon) later on, so a
    /// `.prohibited` answer is asked again after this long; the others are kept for good.
    private static let prohibitedRecheck: TimeInterval = 10
    private static let policyLock = NSLock()

    /// The running applications that may own windows the queue lists (regular and accessory ones),
    /// paired with their real process ids. Any thread; slow (see below), so not the main one.
    ///
    /// `activationPolicy` is not a stored value: every read is a synchronous round trip to
    /// LaunchServices, and there are well over a hundred processes to ask. That ran on the main
    /// thread on every refresh (every few seconds, and on every switch), costing 10–30 ms when
    /// LaunchServices is idle and freezing the app for as long as it is busy (an app launching or
    /// updating). An app's policy hardly ever changes, so it is asked once per process.
    static func windowOwners() -> [(pid: pid_t, app: NSRunningApplication)] {
        let apps = NSWorkspace.shared.runningApplications
        let now = Date()
        var live: Set<PolicyKey> = []
        var owners: [(pid: pid_t, app: NSRunningApplication)] = []
        for app in apps {
            let key = policyKey(of: app)
            live.insert(key)
            let policy = policy(of: app, key: key, now: now)
            guard policy == .regular || policy == .accessory, let pid = pid(of: app) else { continue }
            owners.append((pid, app))
        }
        policyLock.lock()
        if policies.count > live.count {
            policies = policies.filter { live.contains($0.key) }
        }
        policyLock.unlock()
        return owners
    }

    /// `activationPolicy`, remembered (see `windowOwners`).
    static func policy(of app: NSRunningApplication) -> NSApplication.ActivationPolicy {
        policy(of: app, key: policyKey(of: app), now: Date())
    }

    /// Drops what is remembered about an app, for one that has just launched: it may have been
    /// seen as a background process a moment before it put up its first window.
    static func forgetPolicy(of app: NSRunningApplication) {
        let key = policyKey(of: app)
        policyLock.lock()
        policies[key] = nil
        policyLock.unlock()
    }

    private static func policyKey(of app: NSRunningApplication) -> PolicyKey {
        PolicyKey(pid: app.processIdentifier, bundleID: app.processIdentifier > 0 ? nil : app.bundleIdentifier)
    }

    private static func policy(of app: NSRunningApplication, key: PolicyKey, now: Date) -> NSApplication.ActivationPolicy {
        policyLock.lock()
        let cached = policies[key]
        policyLock.unlock()
        if let cached, cached.policy != .prohibited || now.timeIntervalSince(cached.checked) < prohibitedRecheck {
            return cached.policy
        }
        let policy = app.activationPolicy
        policyLock.lock()
        policies[key] = (policy, now)
        policyLock.unlock()
        return policy
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
