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
    /// Enumeration runs here rather than on the main thread: an accessibility call to a busy or
    /// wedged application blocks until it times out, which on the main thread freezes the strip.
    private let enumerationQueue = DispatchQueue(label: "com.mpochec.windowqueue.enumeration")
    private var isRefreshing = false

    /// A window that took focus before we had it in the queue, adopted once it appears.
    private var pendingExternalFocusID: CGWindowID?
    /// Apps we have already asked to expose their accessibility tree.
    private var accessibilityEnabledPIDs: Set<pid_t> = []
    /// Apps we have additionally switched into enhanced accessibility mode.
    private var accessibilityEscalatedPIDs: Set<pid_t> = []

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

        for app in candidateApplications() {
            registerObserver(for: app.processIdentifier)
        }

        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        refreshSpaceState()
        refresh()
    }

    // MARK: - Enumeration

    /// Applications whose windows can belong in the queue.
    ///
    /// Accessory apps are included alongside regular ones: a menu-bar app has no Dock icon but its
    /// settings window is a real window the user wants to reach — including WindowQueue's own. The
    /// strip and the title popup are never picked up, because they sit above the normal window
    /// level and the enumeration only considers layer 0.
    private func candidateApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular || $0.activationPolicy == .accessory
        }
    }

    /// Rebuilds the window set.
    ///
    /// The WindowServer is the only source that sees every Space, but it exposes no titles without
    /// Screen Recording access. The Accessibility API has titles and is what we need for focusing,
    /// but it only lists an app's windows while they are on the active Space. So: seed the set from
    /// the WindowServer, enrich whatever AX can currently see, and keep previously enriched entries
    /// until the WindowServer says the window is really gone.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true

        // Cheap, and the Space a window reports has to be compared against a current value.
        refreshSpaceState()
        let currentSpaceID = model.currentSpaceID

        // Snapshot what the main thread owns, then do the slow accessibility work off it.
        let names = Dictionary(candidateApplications().map {
            ($0.processIdentifier,
             AppInfo(name: $0.localizedName ?? "Unknown", bundleID: $0.bundleIdentifier))
        }, uniquingKeysWith: { first, _ in first })
        let needsAccessibility = names.keys.filter { !accessibilityEnabledPIDs.contains($0) }
        accessibilityEnabledPIDs.formUnion(needsAccessibility)
        let needsEscalation = names.keys.filter { !accessibilityEscalatedPIDs.contains($0) }

        enumerationQueue.async { [weak self] in
            guard let self else { return }
            let result = self.enumerate(names: names,
                                        enable: Set(needsAccessibility),
                                        mayEscalate: Set(needsEscalation),
                                        currentSpaceID: currentSpaceID)

            DispatchQueue.main.async {
                self.isRefreshing = false
                self.accessibilityEscalatedPIDs.formUnion(result.escalated)
                self.model.reconcile(with: result.windows)
                self.adoptPendingFocus()
                if Diagnostics.isEnabled { Diagnostics.dump(model: self.model) }
            }
        }
    }

    /// What the main thread knows about an application, snapshotted for the enumeration queue.
    private struct AppInfo {
        let name: String
        let bundleID: String?
    }

    private struct EnumerationResult {
        let windows: [ManagedWindow]
        let escalated: Set<pid_t>
    }

    /// Rebuilds the window set.
    ///
    /// The WindowServer is the only source that sees every Space, but it exposes no titles without
    /// Screen Recording access. The Accessibility API has titles and is what we need for focusing,
    /// but it only lists an app's windows while they are on the active Space. So: seed the set from
    /// the WindowServer, enrich whatever AX can currently see, and keep previously enriched entries
    /// until the WindowServer says the window is really gone.
    private func enumerate(names: [pid_t: AppInfo],
                           enable: Set<pid_t>,
                           mayEscalate: Set<pid_t>,
                           currentSpaceID: UInt64?) -> EnumerationResult {
        var discovered: [CGWindowID: ManagedWindow] = [:]
        var escalated: Set<pid_t> = []

        // 1. Every real window, on every Space.
        for candidate in serverWindows() {
            guard let app = names[candidate.pid] else { continue }
            discovered[candidate.id] = ManagedWindow(
                id: candidate.id,
                element: nil,
                pid: candidate.pid,
                appName: app.name,
                bundleID: app.bundleID,
                title: candidate.title,
                isMinimized: false,
                spaceID: candidate.spaceID
            )
        }

        // 2. Anything AX can see right now: real titles, elements and minimised state.
        var axCapablePIDs: Set<pid_t> = []
        for (pid, app) in names {
            let appElement = AXPrivate.application(pid)
            if enable.contains(pid) { enableAccessibility(pid: pid, appElement: appElement) }

            guard var windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self) else {
                continue
            }
            if windows.isEmpty, mayEscalate.contains(pid) {
                escalated.insert(pid)
                if escalateAccessibility(pid: pid, appElement: appElement) {
                    windows = appElement.attribute(kAXWindowsAttribute, as: [AXUIElement].self) ?? []
                }
            }
            axCapablePIDs.insert(pid)

            // Some applications (Chrome among them) never populate AXWindows but still answer
            // AXFocusedWindow, so grab that element while we can: it is the only handle we will
            // ever get on that window.
            if let focused = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self),
               let focusedID = AXPrivate.windowID(of: focused),
               discovered[focusedID] != nil {
                discovered[focusedID]?.element = focused
                if let title = focused.attribute(kAXTitleAttribute, as: String.self), !title.isEmpty {
                    discovered[focusedID]?.title = title
                }
            }
            for element in windows {
                guard isStandardWindow(element), let id = AXPrivate.windowID(of: element) else { continue }
                let minimized = element.boolAttribute(kAXMinimizedAttribute) ?? false
                if !minimized && discovered[id] == nil { continue }
                discovered[id] = ManagedWindow(
                    id: id,
                    element: element,
                    pid: pid,
                    appName: app.name,
                    bundleID: app.bundleID,
                    title: element.attribute(kAXTitleAttribute, as: String.self) ?? "",
                    isMinimized: minimized,
                    spaceID: discovered[id]?.spaceID
                )
            }
        }

        // 3. Fallback ghost filter for systems where the WindowServer cannot be asked whether a
        // window is ordered in: on the active Space the Accessibility API is authoritative, so
        // anything an AX-capable app did not list there is not a window the user can see.
        if SpacesBridge.shared.isOrderedIn(CGWindowID(1)) == nil, let current = currentSpaceID {
            for (id, window) in discovered
            where window.element == nil && window.spaceID == current && axCapablePIDs.contains(window.pid) {
                discovered.removeValue(forKey: id)
            }
        }

        // Deterministic first population: grouped by Space, then by creation order.
        let ordered = discovered.values.sorted {
            ($0.spaceID ?? .max, $0.id) < ($1.spaceID ?? .max, $1.id)
        }
        noteUnreadableApps(discovered: discovered, names: names, currentSpaceID: currentSpaceID)
        return EnumerationResult(windows: ordered, escalated: escalated)
    }

    /// Turns on enhanced accessibility for an app that reports no windows at all.
    ///
    /// Chrome is the case that needs this: it answers `AXFocusedWindow` but keeps `AXWindows`
    /// empty, so only the window that already has focus can ever be raised. It does advertise
    /// `AXEnhancedUserInterface` — the attribute VoiceOver sets — and switches its full tree on
    /// when that is set. It is applied only to apps showing this symptom, because some
    /// applications change how their windows animate and resize while it is on.
    ///
    /// - Returns: true when the request was accepted and the window list is worth re-reading.
    private func escalateAccessibility(pid: pid_t, appElement: AXUIElement) -> Bool {
        let ok = appElement.setAttribute("AXEnhancedUserInterface", value: kCFBooleanTrue)
        if Diagnostics.isEnabled {
            Diagnostics.note("AXEnhancedUserInterface pid=\(pid) ok=\(ok)")
        }
        return ok
    }

    /// Logs apps that have a window on the active Space which AX still cannot see; without an
    /// element we can activate such an app but not raise one specific window of it.
    private func noteUnreadableApps(discovered: [CGWindowID: ManagedWindow],
                                    names: [pid_t: AppInfo],
                                    currentSpaceID: UInt64?) {
        guard Diagnostics.isEnabled, let current = currentSpaceID else { return }
        var offenders: Set<pid_t> = []
        for window in discovered.values where window.spaceID == current && window.element == nil {
            offenders.insert(window.pid)
        }
        for pid in offenders {
            Diagnostics.note("AX blind on active space: \(names[pid]?.name ?? "?") pid=\(pid)")
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
    private func enableAccessibility(pid: pid_t, appElement: AXUIElement) {
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

        let appElement = AXPrivate.application(pid)
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
           let id = AXPrivate.windowID(of: element) {
            adoptExternalFocus(id)
        }
        scheduleRefresh()
    }

    /// Follows focus changes the user made themselves, but not the ones an application reports
    /// while we are still steering it towards a different window — otherwise an app that briefly
    /// re-focuses its previous window drags the selection back there.
    ///
    /// A brand new window takes focus before the enumeration has seen it, so an id we do not know
    /// yet is remembered and adopted on the next refresh instead of being dropped.
    private func adoptExternalFocus(_ id: CGWindowID) {
        if let pending = WindowFocuser.pendingTargetID, pending != id { return }
        guard model.windows.contains(where: { $0.id == id }) else {
            pendingExternalFocusID = id
            return
        }
        pendingExternalFocusID = nil
        model.select(id: id, announce: false)
    }

    /// Picks up a focus change that arrived before its window was in the queue.
    private func adoptPendingFocus() {
        guard let id = pendingExternalFocusID else { return }
        guard model.windows.contains(where: { $0.id == id }) else { return }
        pendingExternalFocusID = nil
        if let target = WindowFocuser.pendingTargetID, target != id { return }
        model.select(id: id, announce: false)
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
        accessibilityEscalatedPIDs.remove(app.processIdentifier)
        unregisterObserver(for: app.processIdentifier)
        scheduleRefresh()
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else { return }
        registerObserver(for: app.processIdentifier)
        let appElement = AXPrivate.application(app.processIdentifier)
        // Some applications only honour the request while they are frontmost; the next refresh
        // asks again, off the main thread.
        accessibilityEnabledPIDs.remove(app.processIdentifier)
        if let focused = appElement.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self),
           let id = AXPrivate.windowID(of: focused) {
            adoptExternalFocus(id)
        }
        scheduleRefresh()
    }

    @objc private func activeSpaceChanged() {
        refreshSpaceState()
        scheduleRefresh()
    }
}
