import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Brings a specific window forward.
///
/// Three things make this harder than a single Accessibility call:
///
/// * `NSRunningApplication.activate()` is unreliable from an accessory app that is never itself
///   active, so activation goes through `kAXFrontmostAttribute`, which a trusted process may set.
/// * macOS only lists an application's windows through AX while they are on the active Space, and
///   some applications — Chrome in particular — never list them at all, answering only
///   `AXFocusedWindow`. For those the app's own ⌘` "cycle windows" shortcut is the only way to walk
///   to a specific window.
/// * Applications answer asynchronously, and an app that has just been activated will report the
///   wrong window for a moment. So focusing is a short retry loop rather than one call, and each
///   new request cancels the previous loop.
enum WindowFocuser {
    private static let maxAttempts = 20
    private static let retryInterval: TimeInterval = 0.1
    /// Attempt after which we stop waiting for the app to change Space on its own.
    private static let forceSpaceSwitchAttempt = 3

    /// Identifies the current focus request; an older loop sees a stale token and gives up.
    private static var generation: UInt64 = 0
    /// Whether the request in flight should bring the pointer along.
    private static var warpCursor = false
    /// Remaining ⌘` presses allowed for the running request.
    private static var cyclePressBudget = 0

    /// The window a focus request is currently trying to reach.
    ///
    /// While this is set, incoming accessibility focus notifications for a *different* window are
    /// ignored, so that an app reporting its old window mid-transition cannot drag the queue's
    /// selection back with it.
    private(set) static var pendingTargetID: CGWindowID?

    /// - Parameters:
    ///   - workspaceIndex: 1-based workspace the window sits on, when known.
    ///   - siblingCount: how many windows the same application has, which bounds the ⌘` fallback.
    static func focus(_ window: ManagedWindow, workspaceIndex: Int? = nil, siblingCount: Int = 1,
                      warpCursor: Bool = false) {
        self.warpCursor = warpCursor
        generation &+= 1
        let token = generation
        pendingTargetID = window.id
        cyclePressBudget = max(0, siblingCount - 1) * 2

        if Diagnostics.isEnabled {
            Diagnostics.note("focus \(window.appName) id=\(window.id) element=\(window.element != nil) siblings=\(siblingCount)")
        }

        // The window's frame is known before it comes forward — even on another workspace — so the
        // pointer goes there with the key press rather than after the focus has been confirmed.
        if warpCursor { warp(to: window) }

        // Activating an app only takes macOS to its workspace when "switch to a Space with open
        // windows for the application" is on, and many people turn it off. So a window on another
        // desktop is travelled to first, and brought forward once the switch is under way.
        // While an earlier jump is still travelling, even a window on the desktop in view goes
        // through a jump of its own: that one takes over, rather than the earlier one landing after
        // this window was raised and carrying the user away from it.
        if let space = window.spaceID,
           SpacesBridge.shared.userSpaceIDs.contains(space),
           SpaceSwitcher.destination != nil || !SpacesBridge.shared.isShowing(space),
           SpaceSwitcher.jump(toSpace: space, then: {
               guard token == generation else { return }
               bringForward(window, workspaceIndex: workspaceIndex, token: token)
           }) {
            return
        }
        bringForward(window, workspaceIndex: workspaceIndex, token: token)
    }

    private static func bringForward(_ window: ManagedWindow, workspaceIndex: Int?, token: UInt64) {
        let appElement = AXPrivate.application(window.pid)
        if let element = window.element,
           raise(element, appElement: appElement, wasMinimized: window.isMinimized) {
            // Raised through the element; nothing else needed.
        } else {
            activate(window, appElement: appElement)
        }

        verify(window, workspaceIndex: workspaceIndex, token: token, attempt: 0)
    }

    // MARK: - Focus without raising

    private typealias SetFrontFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias PSNForPIDFn = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let setFrontProcess = skyLight.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }
        .map { unsafeBitCast($0, to: SetFrontFn.self) }
    private static let postEventRecord = skyLight.flatMap { dlsym($0, "SLPSPostEventRecordTo") }
        .map { unsafeBitCast($0, to: PostRecordFn.self) }
    private static let processForPID = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
        .map { unsafeBitCast($0, to: PSNForPIDFn.self) }

    /// `kCPSUserGenerated`: bring the process to the front as a user action would, without asking
    /// it to order its windows forward. `kCPSNoWindows` looks like the better fit, but leaves the app
    /// only half active: its window draws as focused while the keyboard stays with the old app.
    private static let userGeneratedMode: UInt32 = 0x200

    /// Gives a window keyboard focus where it lies, without bringing it in front of anything.
    ///
    /// There is no public way to do this: activating an app raises its windows. The WindowServer
    /// can make a process frontmost without reordering anything, and then be told which window is
    /// key through the same synthesized event records it uses internally — the sequence yabai and
    /// AutoRaise use. Within one app, the window that had focus is told to resign it first, since
    /// the app is already in front and would otherwise keep drawing both as active.
    ///
    /// - Returns: false when the private symbols are missing, so the caller can fall back to an
    ///   ordinary raise.
    @discardableResult
    static func focusWithoutRaising(_ window: ManagedWindow) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID else { return false }
        var target = ProcessSerialNumber()
        guard processForPID(window.pid, &target) == 0 else { return false }

        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == window.pid,
           let focused = AXPrivate.application(front.processIdentifier)
               .attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
               .flatMap(AXPrivate.windowID(of:)),
           focused != window.id {
            var resign = focusRecord(windowID: focused, kind: 0x02)
            _ = postEventRecord(&target, &resign)
            var gain = focusRecord(windowID: window.id, kind: 0x01)
            _ = postEventRecord(&target, &gain)
        }

        guard setFrontProcess(&target, window.id, userGeneratedMode) == 0 else { return false }
        makeKeyWindow(window.id, process: &target, post: postEventRecord)

        // Some applications ignore the synthesized records and keep the keyboard on whichever of
        // their windows had it — Ghostty among them. Asking through accessibility as well moves the
        // focus inside the app, and unlike `AXRaise` it does not bring the window forward.
        if let element = window.element ?? WindowSpaceMover.element(for: window) {
            element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
            AXPrivate.application(window.pid).setAttribute(kAXFocusedWindowAttribute, value: element)
        }
        Diagnostics.note("focus without raise \(window.appName) id=\(window.id)")
        if Diagnostics.isEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                let front = NSWorkspace.shared.frontmostApplication
                let focused = front.flatMap {
                    AXPrivate.application($0.processIdentifier).attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
                }.flatMap(AXPrivate.windowID(of:))
                let landed = front?.processIdentifier == window.pid && focused == window.id
                Diagnostics.note("  hover result: \(landed ? "ok" : "MISSED") front=\(front?.localizedName ?? "nil") focused=\(focused.map(String.init) ?? "nil") wanted=\(window.id)")
            }
        }
        return true
    }

    /// Makes the WindowServer put a process in front with the given window key, the way a click
    /// on that window would. Unlike an activation request, which macOS may turn down and which does
    /// nothing for an app already in front, this goes to the window's desktop every time.
    @discardableResult
    static func bringToFront(pid: pid_t, windowID: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord, let processForPID else { return false }
        var target = ProcessSerialNumber()
        guard processForPID(pid, &target) == 0,
              setFrontProcess(&target, windowID, userGeneratedMode) == 0
        else { return false }
        makeKeyWindow(windowID, process: &target, post: postEventRecord)
        return true
    }

    /// Whether the window really has the keyboard: its application is in front and it is the one
    /// that application says is focused.
    static func isFocused(_ window: ManagedWindow) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid else { return false }
        let focused = AXPrivate.application(window.pid)
            .attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
            .flatMap(AXPrivate.windowID(of:))
        return focused == window.id
    }

    /// Focus handed between two windows of the app in front: 0x01 gains it, 0x02 resigns it.
    private static func focusRecord(windowID: CGWindowID, kind: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x0d
        bytes[0x8a] = kind
        write(windowID, into: &bytes)
        return bytes
    }

    /// The pair of records that makes a window key in its now-frontmost process.
    private static func makeKeyWindow(_ windowID: CGWindowID, process: inout ProcessSerialNumber,
                                      post: PostRecordFn) {
        for phase: UInt8 in [0x01, 0x02] {
            var bytes = [UInt8](repeating: 0, count: 0xf8)
            bytes[0x04] = 0xf8
            bytes[0x08] = phase
            bytes[0x3a] = 0x10
            for offset in 0x20..<0x30 { bytes[offset] = 0xff }
            write(windowID, into: &bytes)
            _ = post(&process, &bytes)
        }
    }

    private static func write(_ windowID: CGWindowID, into bytes: inout [UInt8]) {
        withUnsafeBytes(of: windowID) { raw in
            for offset in 0..<4 { bytes[0x3c + offset] = raw[offset] }
        }
    }

    /// - Returns: whether the element still accepted the raise. A cached element goes stale when
    ///   its window is recreated, and every call then fails silently.
    @discardableResult
    private static func raise(_ element: AXUIElement, appElement: AXUIElement,
                              wasMinimized: Bool) -> Bool {
        if wasMinimized {
            element.setAttribute(kAXMinimizedAttribute, value: kCFBooleanFalse)
        }
        element.setAttribute(kAXMainAttribute, value: kCFBooleanTrue)
        element.setAttribute(kAXFocusedAttribute, value: kCFBooleanTrue)
        let raised = element.perform(kAXRaiseAction)
        appElement.setAttribute(kAXFocusedWindowAttribute, value: element)
        appElement.setAttribute(kAXFrontmostAttribute, value: kCFBooleanTrue)
        return raised
    }

    private static func activate(_ window: ManagedWindow, appElement: AXUIElement) {
        NSRunningApplication(processIdentifier: window.pid)?.activate()
        appElement.setAttribute(kAXFrontmostAttribute, value: kCFBooleanTrue)
    }

    private static func finish(token: UInt64, window: ManagedWindow? = nil) {
        guard token == generation else { return }
        pendingTargetID = nil
        cyclePressBudget = 0

        // The pointer went ahead at the start. A window that moved on its way forward — restored
        // from the Dock, say — gets it once more, but a pointer already on it stays where it is.
        if warpCursor, let window {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard let frame = serverFrame(of: window.id), !frame.contains(currentPointer()) else { return }
                warp(to: window)
            }
        }
    }

    /// Puts the pointer in the middle of the window, so the cursor ends up where the user is
    /// looking rather than stranded on whatever screen they came from.
    private static func warp(to window: ManagedWindow) {
        guard let frame = serverFrame(of: window.id) else { return }
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
        // Warping breaks the tie between the mouse and the cursor until this is called back.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// The pointer in the same top-left-origin coordinates as `serverFrame(of:)`.
    private static func currentPointer() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// The window's frame in global display coordinates, which is the space `CGWarpMouseCursorPosition`
    /// works in — unlike the accessibility API, whose per-screen origins would need converting.
    private static func serverFrame(of id: CGWindowID) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id)
            as? [[String: Any]])?.first,
            let bounds = info[kCGWindowBounds as String] as? [String: Any],
            let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        else { return nil }
        return frame
    }

    private static func verify(_ window: ManagedWindow, workspaceIndex: Int?,
                               token: UInt64, attempt: Int) {
        guard attempt < maxAttempts else {
            finish(token: token)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval) {
            // A newer request has taken over; stop competing with it.
            guard token == generation else { return }

            let appElement = AXPrivate.application(window.pid)
            let focusedID = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
                .flatMap { AXPrivate.windowID(of: $0) }

            if Diagnostics.isEnabled {
                let listed = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self)?.count ?? -1
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                Diagnostics.note("  verify #\(attempt) target=\(window.id) focused=\(focusedID.map(String.init) ?? "nil") axWindows=\(listed) front=\(front)")
            }
            // The app's own focused window is not enough: an activation requested for an earlier
            // window in a quick run of presses can land after ours and put a different app in
            // front, while this app still reports our window as its focused one.
            let isFrontmostApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
            if focusedID == window.id, isFrontmostApp {
                confirm(window, workspaceIndex: workspaceIndex, token: token)
                return
            }

            // Some applications — Spotify and other Chromium shells — expose neither a window list
            // nor a focused window, so there is no way to confirm the result and nothing further to
            // try. Once the app is frontmost and has had its chance to change Space, treat that as
            // done rather than looping until the attempt budget runs out and fighting the user.
            let listedCount = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self)?.count ?? 0
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
            if focusedID == nil, listedCount == 0, isFrontmost, attempt >= forceSpaceSwitchAttempt {
                finish(token: token, window: window)
                return
            }

            // Activating an app usually makes macOS follow it to its Space, but not every app
            // cooperates. Fall back to the system's own ⌃N shortcut. (The private SkyLight call
            // does move Spaces, but leaves the WindowServer drawing several desktops at once.)
            if attempt == forceSpaceSwitchAttempt,
               let index = workspaceIndex,
               let target = window.spaceID,
               SpacesBridge.shared.userSpaceIDs.contains(target),
               !SpacesBridge.shared.isShowing(target) {
                SpaceSwitcher.sendSystemShortcut(index: index)
            }

            if let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self),
               let match = windows.first(where: { AXPrivate.windowID(of: $0) == window.id }) {
                if !raise(match, appElement: appElement, wasMinimized: window.isMinimized) {
                    activate(window, appElement: appElement)
                }
            } else if attempt >= forceSpaceSwitchAttempt {
                activate(window, appElement: appElement)
                cycleWindows(of: window, appElement: appElement)
            }

            verify(window, workspaceIndex: workspaceIndex, token: token, attempt: attempt + 1)
        }
    }

    /// Looks once more a moment after focus seemed to land, because a late activation from an
    /// earlier request can still take it away; if it has, the verification starts over.
    private static func confirm(_ window: ManagedWindow, workspaceIndex: Int?, token: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmDelay) {
            guard token == generation else { return }
            let isFrontmostApp = NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
            let focusedID = AXPrivate.application(window.pid)
                .attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
                .flatMap { AXPrivate.windowID(of: $0) }
            if isFrontmostApp, focusedID == window.id {
                finish(token: token, window: window)
                return
            }
            Diagnostics.note("focus of \(window.id) was taken back; retrying")
            let appElement = AXPrivate.application(window.pid)
            let raised = window.element.map {
                raise($0, appElement: appElement, wasMinimized: window.isMinimized)
            } ?? false
            if !raised { activate(window, appElement: appElement) }
            verify(window, workspaceIndex: workspaceIndex, token: token, attempt: forceSpaceSwitchAttempt + 1)
        }
    }

    private static let confirmDelay: TimeInterval = 0.25

    /// Walks an application through its own windows with ⌘`.
    ///
    /// This is the only route to a window of an app that keeps `AXWindows` empty: there is no
    /// element to raise, but the app still responds to its standard cycle-windows shortcut. The
    /// verification loop stops the moment the focused window is ours, and the press budget bounds
    /// the cost for a window that cannot be reached this way.
    private static func cycleWindows(of window: ManagedWindow, appElement: AXUIElement) {
        guard cyclePressBudget > 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        else { return }
        cyclePressBudget -= 1

        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_Grave), keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        if Diagnostics.isEnabled {
            Diagnostics.note("  cycle press for pid=\(window.pid) budget=\(cyclePressBudget)")
        }
    }
}
