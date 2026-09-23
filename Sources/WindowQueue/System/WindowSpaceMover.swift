import AppKit
import ApplicationServices

/// Carries windows of other apps onto one workspace.
///
/// macOS 26 refuses `SLSMoveWindowsToManagedSpace` for windows another process owns. What it still
/// allows is assigning a whole application to a workspace — the Dock's "Assign To" option — which
/// moves every window the app has there at once. Clearing the assignment straight away leaves the
/// windows where they landed and lets the app open new windows wherever the user is, as before.
///
/// The move is per application, so a window is only carried over when every other window of its
/// app is going along or is already there; otherwise it would drag unrelated windows with it.
final class WindowSpaceMover {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias AssignFn = @convention(c) (Int32, pid_t, UInt64) -> Int32
    private typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SpaceWindowsFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias SwapSpacesFn = @convention(c) (Int32, CFArray, CFArray, CFArray) -> Void

    private let connectionID: Int32
    private let assign: AssignFn?
    private let moveWindows: MoveWindowsFn?
    private let addWindowsToSpaces: SpaceWindowsFn?
    private let removeWindowsFromSpaces: SpaceWindowsFn?
    private let swapSpaces: SwapSpacesFn?

    init() {
        let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let skyLight, let pointer = dlsym(skyLight, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        connectionID = symbol("CGSMainConnectionID", as: ConnectionFn.self)?() ?? 0
        assign = symbol("SLSProcessAssignToSpace", as: AssignFn.self)
        moveWindows = symbol("SLSMoveWindowsToManagedSpace", as: MoveWindowsFn.self)
            ?? symbol("CGSMoveWindowsToManagedSpace", as: MoveWindowsFn.self)
        addWindowsToSpaces = symbol("CGSAddWindowsToSpaces", as: SpaceWindowsFn.self)
        removeWindowsFromSpaces = symbol("CGSRemoveWindowsFromSpaces", as: SpaceWindowsFn.self)
        swapSpaces = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: SwapSpacesFn.self)
    }

    var isAvailable: Bool { connectionID != 0 && (assign != nil || moveWindows != nil) }

    /// Whether single windows can be moved without their application coming along.
    var movesSingleWindows: Bool { connectionID != 0 && moveWindows != nil }

    struct Result {
        /// Windows now on the target workspace, the ones already there included.
        var arrived: [ManagedWindow]
        /// Windows left behind because moving them would have moved other windows of their app.
        var leftBehind: [ManagedWindow]
    }

    /// - Parameters:
    ///   - windows: the windows to gather, in queue order.
    ///   - queue: every window in the queue, to tell whether an app has windows outside the group.
    func move(_ windows: [ManagedWindow], to target: UInt64, queue: [ManagedWindow]) -> Result {
        var result = Result(arrived: [], leftBehind: [])
        let selected = Set(windows.map(\.id))

        // One window at a time, if the WindowServer will do it. `SLSMoveWindowsToManagedSpace` takes
        // a list of window ids and a space, which is exactly what is wanted here — no application
        // dragged along. Whether a process that is not the Dock is allowed to call it is not
        // something the call itself says, so the windows' spaces are read back afterwards and
        // anything that did not move falls through to moving its application.
        let stragglers = moveIndividually(windows, to: target)

        for (pid, group) in Dictionary(grouping: stragglers, by: \.pid) {
            let away = group.filter { $0.spaceID != target }
            guard !away.isEmpty else { continue }

            let bystanders = queue.filter {
                $0.pid == pid && !selected.contains($0.id) && !$0.isMinimized && $0.spaceID != target
            }
            guard bystanders.isEmpty, let assign else {
                Diagnostics.note("space mover: \(group.first?.appName ?? "?") has other windows elsewhere; not moving")
                result.leftBehind.append(contentsOf: away)
                continue
            }

            _ = assign(connectionID, pid, target)
            // Zero clears the assignment: the windows stay put, new ones open where the user is.
            _ = assign(connectionID, pid, 0)
            Diagnostics.note("space mover: moved \(away.count) window(s) of \(group.first?.appName ?? "?")")
        }

        let current = SpacesBridge.shared.spaces(forWindows: windows.map(\.id))
        let leftIDs = Set(result.leftBehind.map(\.id))
        for window in windows where !leftIDs.contains(window.id) {
            var updated = window
            updated.spaceID = current[window.id] ?? window.spaceID
            if updated.spaceID == target {
                result.arrived.append(updated)
            } else {
                result.leftBehind.append(window)
            }
        }
        return result
    }

    /// Asks the WindowServer to move each window on its own, and hands back the ones still where
    /// they were — the ones that have to travel with their application instead.
    private func moveIndividually(_ windows: [ManagedWindow], to target: UInt64) -> [ManagedWindow] {
        guard let moveWindows else { return windows }
        let away = windows.filter { $0.spaceID != target }
        guard !away.isEmpty else { return [] }
        let ids = away.map { NSNumber(value: $0.id) } as CFArray
        moveWindows(connectionID, ids, target)

        // Three ways of saying the same thing, because which of them a plain application is allowed
        // to use is not documented and has changed between releases. They cost one call each, and
        // the windows' own spaces, read back below, are what says whether any of them worked.
        addWindowsToSpaces?(connectionID, ids, [NSNumber(value: target)] as CFArray)
        let sources = Set(away.compactMap(\.spaceID)).map { NSNumber(value: $0) } as CFArray
        removeWindowsFromSpaces?(connectionID, ids, sources)
        swapSpaces?(connectionID, ids, [NSNumber(value: target)] as CFArray, sources)

        // The WindowServer moves the windows on its own schedule, and asking where they are the
        // instant after asking them to move answers with where they were. A few short looks give it
        // time to catch up; anything still behind really is not coming this way.
        var left = away
        for _ in 0..<6 {
            let now = SpacesBridge.shared.spaces(forWindows: left.map(\.id))
            left = left.filter { now[$0.id] != target }
            if left.isEmpty { break }
            usleep(40_000)
        }
        Diagnostics.note("space mover: one by one, \(away.count - left.count) of \(away.count) reached \(target)")
        return left
    }

    /// Brings one window onto the workspace in view, without its application's other windows.
    ///
    /// This is a trick, not an interface. With "switch to a Space with open windows for the
    /// application" turned off — which WindowQueue needs anyway to do its own travelling — macOS
    /// answers an application being activated by bringing its focused window to where the user is,
    /// rather than taking the user to the window. So: focus the one window we want through the
    /// accessibility API, activate its application, and macOS carries that window here. Its other
    /// windows are not focused and stay where they are.
    ///
    /// It is worth exactly as much as that setting and that behaviour, so the result is read back
    /// from the WindowServer and the caller is told whether it worked.
    @discardableResult
    func pullToCurrentSpace(_ window: ManagedWindow) -> Bool {
        guard let current = SpacesBridge.shared.currentSpaceID,
              let app = NSRunningApplication(processIdentifier: window.pid)
        else { return false }
        if SpacesBridge.shared.spaces(forWindows: [window.id])[window.id] == current { return true }

        let element = Self.element(for: window) ?? window.element
        if let element {
            _ = element.setAttribute(kAXMainAttribute, value: kCFBooleanTrue)
            _ = element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
            _ = AXPrivate.application(window.pid).setAttribute(kAXFocusedWindowAttribute, value: element)
        }
        app.activate(options: [.activateIgnoringOtherApps])

        for _ in 0..<10 {
            usleep(60_000)
            if SpacesBridge.shared.spaces(forWindows: [window.id])[window.id] == current {
                Diagnostics.note("space mover: pulled \(window.appName) \(window.id) here by activating it")
                return true
            }
        }
        Diagnostics.note("space mover: \(window.appName) \(window.id) would not come here")
        return false
    }

    /// The window's accessibility element as its app lists it now. A window that arrived from a
    /// workspace we never visited has no element until its app is asked again.
    static func element(for window: ManagedWindow) -> AXUIElement? {
        AXPrivate.application(window.pid)
            .attribute(kAXWindowsAttribute, as: [AXUIElement].self)?
            .first { AXPrivate.windowID(of: $0) == window.id }
    }
}
