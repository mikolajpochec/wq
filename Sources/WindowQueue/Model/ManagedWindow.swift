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

    /// The same image object every time for a given app. `NSRunningApplication.icon` hands out a
    /// fresh one on each call, and SwiftUI takes a new image for a changed one: inside an animated
    /// reorder, every icon on the strip would cross-fade into itself and blink.
    var icon: NSImage? {
        IconCache.icon(for: pid)
    }

    static func == (lhs: ManagedWindow, rhs: ManagedWindow) -> Bool {
        lhs.id == rhs.id
            && lhs.title == rhs.title
            && lhs.isMinimized == rhs.isMinimized
            && lhs.spaceID == rhs.spaceID
    }
}

private enum IconCache {
    private static var icons: [pid_t: NSImage] = [:]

    static func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        // Process ids are reused, so an app that has gone is not worth remembering.
        icons = icons.filter { NSRunningApplication(processIdentifier: $0.key) != nil }
        icons[pid] = icon
        return icon
    }
}
