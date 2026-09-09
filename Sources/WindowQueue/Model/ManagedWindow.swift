import AppKit
import ApplicationServices

/// One standard window of another application, as tracked by the queue.
struct ManagedWindow: Identifiable, Equatable {
    let id: CGWindowID
    /// The accessibility element, once we have been able to enumerate it. macOS only exposes an
    /// app's windows through AX while they are on the active Space, so a window discovered on
    /// another Space starts out with no element and gains one when that Space is visited.
    var element: AXUIElement?
    let pid: pid_t
    var appName: String
    /// Bundle identifier of the owning application, used to recognise a window across restarts.
    var bundleID: String?
    var title: String
    var isMinimized: Bool
    /// Space the window lives on, resolved lazily through `SpacesBridge`.
    var spaceID: UInt64?

    /// Identity that survives a relaunch. Window ids are handed out per session, so a saved order
    /// is stored as these instead — good enough to put familiar windows back where they were, and
    /// harmless when a title has changed in the meantime.
    var orderKey: String {
        "\(bundleID ?? appName)\u{1}\(title)"
    }

    var displayTitle: String {
        title.isEmpty ? appName : title
    }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.spaceID == rhs.spaceID
    }
}
