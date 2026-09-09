import AppKit
import ApplicationServices

/// Discovers standard windows of every regular application and keeps the queue in sync.
///
/// Accessibility notifications drive updates; a slow timer reconciles anything the notifications
/// miss (some apps are sloppy about posting them).
final class WindowEnumerator {
    private let model: WindowQueueModel
    private var observers: [pid_t: AXObserver] = [:]
    private var refreshWorkItem: DispatchWorkItem?
    private var timer: Timer?
    private var spaceRefreshCounter = 0

    private static let observedNotifications = [
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXFocusedWindowChangedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
    ]

    init(model: WindowQueueModel) {
        self.model = model
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appLaunched(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appTerminated(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(activeSpaceChanged),
                           name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)

        for app in regularApplications() {
            registerObserver(for: app.processIdentifier)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refreshSpaceState()
        refresh()
    }

    // MARK: - Enumeration

    private func regularApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    }

    /// Rebuilds the window set.
    ///
    /// The WindowServer is the only source that sees every Space, but it exposes no titles without
    /// Screen Recording access. The Accessibility API has titles and is what we need for focusing,
    /// but it only lists an app's windows while they are on the active Space. So: seed the set from
    /// the WindowServer, enrich whatever AX can currently see, and keep previously enriched entries
    /// until the WindowServer says the window is really gone.
    func refresh() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = Dictionary(regularApplications().map { ($0.processIdentifier, $0) },
                              uniquingKeysWith: { first, _ in first })

        var discovered: [CGWindowID: ManagedWindow] = [:]

        // 1. Every real window, on every Space.
        for candidate in serverWindows() where candidate.pid != ownPID {
            guard let app = apps[candidate.pid] else { continue }
            discovered[candidate.id] = ManagedWindow(
                id: candidate.id,
                element: nil,
                pid: candidate.pid,
                appName: app.localizedName ?? "Unknown",
                title: candidate.title,
                isMinimized: false,
                spaceID: candidate.spaceID
            )
        }

        // 2. Anything AX can see right now: real titles, elements and minimised state.
        for (pid, app) in apps where pid != ownPID {
            let appElement = AXUIElementCreateApplication(pid)
            guard let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self) else {
                continue
            }
            for element in windows {
                guard isStandardWindow(element), let id = AXPrivate.windowID(of: element) else { continue }
                let minimized = element.boolAttribute(kAXMinimizedAttribute) ?? false
                if !minimized && discovered[id] == nil { continue }
                discovered[id] = ManagedWindow(
                    id: id,
                    element: element,
                    pid: pid,
                    appName: app.localizedName ?? "Unknown",
                    title: element.attribute(kAXTitleAttribute, as: String.self) ?? "",
                    isMinimized: minimized,
                    spaceID: discovered[id]?.spaceID
                )
            }
        }

        // Deterministic first population: grouped by Space, then by creation order.
        let ordered = discovered.values.sorted {
            ($0.spaceID ?? .max, $0.id) < ($1.spaceID ?? .max, $1.id)
        }
        model.reconcile(with: ordered)
        refreshWindowSpaces()

        if Diagnostics.isEnabled { Diagnostics.dump(model: model) }
    }

    private struct ServerWindow {
        let id: CGWindowID
        let pid: pid_t
        let spaceID: UInt64?
        /// Only populated when Screen Recording access has been granted.
        let title: String
    }

    /// Real windows as the WindowServer sees them, filtered down from the many tiny helper and
    /// shadow windows every application also owns.
    private func serverWindows() -> [ServerWindow] {
        let raw = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates: [(id: CGWindowID, pid: pid_t, title: String)] = raw.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width >= 120, height >= 80
            else { return nil }
            return (id, pid, (info[kCGWindowName as String] as? String) ?? "")
        }

        // Only windows the WindowServer has actually placed on a Space are real, on-screen windows;
        // the rest are off-screen scratch windows apps keep around.
        let spaces = SpacesBridge.shared.spaces(forWindows: candidates.map(\.id))
        return candidates.compactMap { candidate in
            guard let space = spaces[candidate.id] else { return nil }
            return ServerWindow(id: candidate.id, pid: candidate.pid, spaceID: space, title: candidate.title)
        }
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        let subrole = element.attribute(kAXSubroleAttribute, as: String.self)
        guard subrole == nil || subrole == kAXStandardWindowSubrole else { return false }
        let role = element.attribute(kAXRoleAttribute, as: String.self)
        return role == nil || role == kAXWindowRole
    }

    private func refreshWindowSpaces() {
        guard SpacesBridge.shared.isAvailable else { return }
        let ids = model.windows.map(\.id)
        let mapping = SpacesBridge.shared.spaces(forWindows: ids)
        model.updateSpaces(mapping)
    }

    private func refreshSpaceState() {
        model.currentSpaceID = SpacesBridge.shared.currentSpaceID
        model.currentSpaceIndex = SpacesBridge.shared.currentSpaceIndex
        model.spaceOrder = SpacesBridge.shared.userSpaceIDs
    }

    private func scheduleRefresh() {
        refreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - Accessibility observers

    private func registerObserver(for pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier, observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let enumerator = Unmanaged<WindowEnumerator>.fromOpaque(refcon).takeUnretainedValue()
            enumerator.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.observedNotifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func unregisterObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func handle(notification: String, element: AXUIElement) {
        if notification == kAXFocusedWindowChangedNotification,
           let id = AXPrivate.windowID(of: element),
           model.windows.contains(where: { $0.id == id }) {
            model.select(id: id, announce: false)
        }
        scheduleRefresh()
    }

    // MARK: - Workspace notifications

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular
        else { return }
        registerObserver(for: app.processIdentifier)
        scheduleRefresh()
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        unregisterObserver(for: app.processIdentifier)
        scheduleRefresh()
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        registerObserver(for: app.processIdentifier)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self),
           let id = AXPrivate.windowID(of: focused),
           model.windows.contains(where: { $0.id == id }) {
            model.select(id: id, announce: false)
        }
        scheduleRefresh()
    }

    @objc private func activeSpaceChanged() {
        refreshSpaceState()
        scheduleRefresh()
    }
}
