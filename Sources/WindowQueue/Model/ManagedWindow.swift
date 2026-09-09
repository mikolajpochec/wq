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
    var title: String
    var isMinimized: Bool
    /// Space the window lives on, resolved lazily through `SpacesBridge`.
    var spaceID: UInt64?

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
