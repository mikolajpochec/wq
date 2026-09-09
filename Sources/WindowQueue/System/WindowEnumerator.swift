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
    /// Apps we have already asked to expose their accessibility tree.
    private var accessibilityEnabledPIDs: Set<pid_t> = []
    /// Apps that needed the second, more intrusive request before they exposed anything.
    private var accessibilityRepairedPIDs: Set<pid_t> = []

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
        var axCapablePIDs: Set<pid_t> = []
        for (pid, app) in apps where pid != ownPID {
            let appElement = AXUIElementCreateApplication(pid)
            enableAccessibility(for: pid, appElement: appElement)
            guard let windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self) else {
                continue
            }
            axCapablePIDs.insert(pid)
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

        // 3. Fallback ghost filter for systems where the WindowServer cannot be asked whether a
        // window is ordered in: on the active Space the Accessibility API is authoritative, so
        // anything an AX-capable app did not list there is not a window the user can see.
        if SpacesBridge.shared.isOrderedIn(CGWindowID(1)) == nil, let current = model.currentSpaceID {
            for (id, window) in discovered
            where window.element == nil && window.spaceID == current && axCapablePIDs.contains(window.pid) {
                discovered.removeValue(forKey: id)
            }
        }

        // Deterministic first population: grouped by Space, then by creation order.
        let ordered = discovered.values.sorted {
            ($0.spaceID ?? .max, $0.id) < ($1.spaceID ?? .max, $1.id)
        }
        repairUnreadableApps(discovered: discovered, apps: apps)

        model.reconcile(with: ordered)
        refreshWindowSpaces()

        if Diagnostics.isEnabled { Diagnostics.dump(model: model) }
    }

    /// Second-chance accessibility request for apps that still expose nothing.
    ///
    /// An app with a window on the *active* Space that AX cannot see is an app whose accessibility
    /// tree is switched off — without it we can activate the app but never raise one specific
    /// window of it. Chrome in particular refuses `AXManualAccessibility` and only responds to
    /// `AXEnhancedUserInterface`, the attribute VoiceOver sets. That one is applied narrowly, to
    /// apps showing this exact symptom, because some applications change their window behaviour
    /// while it is set.
    private func repairUnreadableApps(discovered: [CGWindowID: ManagedWindow],
                                      apps: [pid_t: NSRunningApplication]) {
        guard let current = model.currentSpaceID else { return }

        var offenders: Set<pid_t> = []
        for window in discovered.values where window.spaceID == current && window.element == nil {
            offenders.insert(window.pid)
        }

        for pid in offenders where !accessibilityRepairedPIDs.contains(pid) {
            accessibilityRepairedPIDs.insert(pid)
            let element = AXUIElementCreateApplication(pid)
            let ok = element.setAttribute("AXEnhancedUserInterface", value: kCFBooleanTrue)
            if Diagnostics.isEnabled {
                let name = apps[pid]?.localizedName ?? "?"
                Diagnostics.note("AXEnhancedUserInterface \(name) pid=\(pid) ok=\(ok)")
            }
        }
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

        // A real window is placed on a Space *and* ordered into the WindowServer's display list.
        // Applications keep plenty of full-size windows around that satisfy neither: closed
        // documents they have not released, off-screen scratch windows, and so on.
        let spaces = SpacesBridge.shared.spaces(forWindows: candidates.map(\.id))
        return candidates.compactMap { candidate in
            guard let space = spaces[candidate.id] else { return nil }
            guard SpacesBridge.shared.isOrderedIn(candidate.id) != false else { return nil }
            return ServerWindow(id: candidate.id, pid: candidate.pid, spaceID: space, title: candidate.title)
        }
    }

    /// Chromium and Electron applications keep their accessibility tree switched off until a client
    /// asks for it, which is why Chrome, Slack and friends otherwise report zero windows — and why
    /// focusing one of them could only ever raise whichever window happened to be in front.
    private func enableAccessibility(for pid: pid_t, appElement: AXUIElement) {
        guard !accessibilityEnabledPIDs.contains(pid) else { return }
        accessibilityEnabledPIDs.insert(pid)
        let manual = appElement.setAttribute("AXManualAccessibility", value: kCFBooleanTrue)
        if Diagnostics.isEnabled {
            Diagnostics.note("AXManualAccessibility pid=\(pid) ok=\(manual)")
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
        accessibilityEnabledPIDs.remove(app.processIdentifier)
        accessibilityRepairedPIDs.remove(app.processIdentifier)
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
