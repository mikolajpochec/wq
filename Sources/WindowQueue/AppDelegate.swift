import AppKit
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PreferencesStore()
    private let model = WindowQueueModel()
    private let permissions = Permissions()
    private let hotkeys = HotkeyManager()
    private let modifierTaps = ModifierTapMonitor()
    private let aimingKeys = AimingKeyCapture()
    private var dimOverlay: DimOverlay?
    private let orderStore = QueueOrderStore()
    private var search: SearchController?
    private var hoverFocus: FocusFollowsMouse?

    private var enumerator: WindowEnumerator?
    private var strip: StripController?
    private var toast: ToastController?
    private var settingsWindow: SettingsWindowController?
    private var scrollFocusWork: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private lazy var dockReservation = DockReservation(store: store)
    private var terminationSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DockReservation.shared = dockReservation
        dockReservation.start()
        restoreDockOnSignals()
        Diagnostics.note("launch: trusted=\(AXIsProcessTrusted()) windowIDs=\(AXPrivate.supportsWindowNumbers) spaces=\(SpacesBridge.shared.isAvailable)")
        setUpStatusItem()

        model.scope = store.prefs.scope
        model.autoSortByWorkspace = store.prefs.autoSortByWorkspace
        model.onManualReorder = { [weak self] in
            self?.store.prefs.autoSortByWorkspace = false
        }
        store.$prefs
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.model.scope = prefs.scope
                self.model.autoSortByWorkspace = prefs.autoSortByWorkspace
                self.modifierTaps.modifiers = prefs.superModifier.eventFlags
                self.hotkeys.apply(prefs)
                LoginItem.apply(enabled: prefs.launchAtLogin)
                // `@Published` fires before the new value lands; read it on the next turn.
                DispatchQueue.main.async { self.dockReservation.update() }
            }
            .store(in: &cancellables)

        // Restarting Rectangle is the only way it picks up a new gap, so it must not happen on
        // every step of a slider drag: wait until the settings have been still for a moment.
        store.$prefs
            .debounce(for: .seconds(1.0), scheduler: RunLoop.main)
            .sink { prefs in RectangleIntegration.applyAndReloadIfNeeded(prefs: prefs) }
            .store(in: &cancellables)

        let dimOverlay = DimOverlay(store: store)
        self.dimOverlay = dimOverlay
        search = SearchController(model: model, store: store, dim: dimOverlay) { [weak self] window in
            self?.model.select(id: window.id, announce: false)
            self?.focus(window)
        }

        let toast = ToastController(store: store)
        self.toast = toast
        model.announcement
            .receive(on: RunLoop.main)
            .sink { window in toast.show(window) }
            .store(in: &cancellables)

        let strip = StripController(
            model: model,
            store: store,
            onSelect: { [weak self] window in
                self?.model.select(id: window.id, announce: false)
                self?.focus(window, warpCursor: false)
            },
            onHold: { window in
                if let window {
                    toast.show(window, pinned: true)
                } else {
                    toast.endHold()
                }
            },
            onClose: { [weak self] window in self?.close(window) },
            onScroll: { [weak self] steps in self?.scrolled(by: steps) }
        )
        self.strip = strip
        toast.anchorProvider = { [weak strip] id in
            guard let strip, let frame = strip.rowFrame(for: id) else { return nil }
            return (frame, strip.side)
        }

        modifierTaps.modifiers = store.prefs.superModifier.eventFlags
        modifierTaps.onTap = { [weak self] in self?.toggleAiming() }
        modifierTaps.start()

        // Hover focus never moves the pointer: the pointer is already where the user wants it.
        let hoverFocus = FocusFollowsMouse(model: model, store: store) { [weak self] window in
            guard let self else { return }
            if !self.store.prefs.focusFollowsMouseRaises, WindowFocuser.focusWithoutRaising(window) { return }
            WindowFocuser.focus(window, siblingCount: self.model.windows.count { $0.pid == window.pid })
        }
        hoverFocus.isSuspended = { [weak self] in
            guard let self else { return false }
            return self.model.aimingID != nil || self.search?.isOpen == true
        }
        hoverFocus.start()
        self.hoverFocus = hoverFocus

        aimingKeys.onKey = { [weak self] key in self?.handleAimingKey(key) }
        aimingKeys.onDismiss = { [weak self] in self?.endAiming(commit: false) }

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.apply(store.prefs)
        RectangleIntegration.applyAndReloadIfNeeded(prefs: store.prefs)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow,
                      window === self?.settingsWindow?.window else { return }
                NSApp.setActivationPolicy(.accessory)
                self?.enumerator?.refresh()
            }
            .store(in: &cancellables)

        permissions.requestAndWait { [weak self] in
            guard let self else { return }
            Diagnostics.note("accessibility granted, starting enumeration")
            // The saved order can only be applied once there is something to apply it to.
            // `@Published` fires from `willSet`, so the model still holds the old value when a
            // subscriber runs. Hopping to the next turn of the run loop is what makes the queue
            // actually be there to reorder.
            self.model.$windows
                .filter { !$0.isEmpty }
                .prefix(1)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    self.orderStore.restore(into: self.model)
                    self.orderStore.startSaving(self.model)
                }
                .store(in: &self.cancellables)

            let enumerator = WindowEnumerator(model: self.model)
            let edgeGuard = ScreenEdgeGuard(store: self.store)
            enumerator.onWindowResized = { element in edgeGuard.windowResized(element) }
            enumerator.onWindowSettled = { element in edgeGuard.windowSettled(element) }
            self.enumerator = enumerator
            enumerator.start()
            strip.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dockReservation.restore()
    }

    /// Quitting through `kill` — as `make install` does — skips `applicationWillTerminate`, and the
    /// Dock rect would outlive the app. Catch the usual signals and hand it back first.
    private func restoreDockOnSignals() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.dockReservation.restore()
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { app in RectangleIntegration.handleLaunch(of: app) }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    // MARK: - Aiming

    /// Aiming mode: move a highlight around the strip without focusing anything, then confirm.
    private func toggleAiming() {
        guard store.prefs.aimingEnabled else { return }
        if model.aimingID != nil {
            // The same tap that opened the mode confirms it, so a switch is one key, twice.
            endAiming(commit: true)
        } else {
            beginAiming()
        }
    }

    private func beginAiming() {
        guard !model.visibleWindows.isEmpty else { return }
        let aimed = model.beginAiming()
        aimingKeys.begin()
        dimOverlay?.show()
        if let aimed { toast?.show(aimed, pinned: true) }
    }

    private func endAiming(commit: Bool) {
        guard model.aimingID != nil else { return }
        let aimed = model.aimedWindow
        model.endAiming()
        aimingKeys.end()
        dimOverlay?.hide()
        toast?.endHold()

        guard commit, let aimed else { return }
        model.select(id: aimed.id, announce: false)
        focus(aimed)
    }

    private func handleAimingKey(_ key: AimingKeyCapture.Key) {
        switch key {
        case .previous:
            if let aimed = model.moveAim(by: -1) { toast?.show(aimed, pinned: true) }
        case .next:
            if let aimed = model.moveAim(by: 1) { toast?.show(aimed, pinned: true) }
        case .commit:
            endAiming(commit: true)
        case .cancel:
            endAiming(commit: false)
        }
    }

    private func perform(_ action: HotkeyAction) {
        // Carbon consumes the key event, so the tap detector never sees what interrupted it.
        modifierTaps.cancel()

        // While aiming, the cycle shortcuts move the aim rather than the focus.
        if model.aimingID != nil {
            switch action {
            case .cyclePrevious:
                handleAimingKey(.previous)
                return
            case .cycleNext:
                handleAimingKey(.next)
                return
            default:
                endAiming(commit: false)
            }
        }

        if let space = action.spaceIndex {
            switchToSpace(space)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.refreshSpaceState()
            }
            return
        }

        switch action {
        case .cyclePrevious:
            if let window = model.cycle(by: -1) { focus(window) }
        case .cycleNext:
            if let window = model.cycle(by: 1) { focus(window) }
        case .moveLeft:
            model.move(by: -1)
        case .moveRight:
            model.move(by: 1)
        case .moveToStart:
            model.moveToStart()
        case .moveToEnd:
            model.moveToEnd()
        case .sortByWorkspace:
            sortByWorkspace()
        case .closeWindow:
            closeSelectedWindow()
        case .search:
            search?.toggle()
        default:
            break
        }
    }

    /// Scrolling moves the selection immediately but defers focusing: spinning through the queue
    /// would otherwise fire a burst of app activations and workspace switches on the way past.
    private func scrolled(by steps: Int) {
        guard model.cycle(by: steps) != nil else { return }
        scrollFocusWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.model.selectedWindow else { return }
            // The pointer is on the strip because the user is using it there; leave it be.
            self.focus(window, warpCursor: false)
        }
        scrollFocusWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + store.prefs.scrollFocusDelay,
                                      execute: work)
    }

    private func closeSelectedWindow() {
        guard let window = model.selectedWindow else { return }
        close(window)
    }

    private func close(_ window: ManagedWindow) {
        // Hand the selection to a neighbour up front: the window is about to stop existing, and
        // otherwise the selection would fall back to the top of the queue when it does.
        let successor = model.neighbour(after: window.id)

        WindowCloser.close(window,
                           workspaceIndex: model.workspaceNumber(of: window),
                           siblingCount: model.windows.count { $0.pid == window.pid })

        if let successor { model.select(id: successor.id, announce: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.enumerator?.refresh()
        }
    }

    /// - Parameter warpCursor: false when the focus came from the mouse, which is already where the
    ///   user wants it; the pointer only follows focus changes made from the keyboard.
    private func focus(_ window: ManagedWindow, warpCursor: Bool = true) {
        let siblings = model.windows.count { $0.pid == window.pid }
        WindowFocuser.focus(window,
                            workspaceIndex: model.workspaceNumber(of: window),
                            siblingCount: siblings,
                            warpCursor: warpCursor && store.prefs.warpCursorToWindow)
    }

    /// Changes workspace using the configured strategy, falling back through the others.
    private func switchToSpace(_ index: Int) {
        switch store.prefs.spaceSwitchMethod {
        case .focusWindow:
            if focusWindow(onSpaceIndex: index) { return }
            SpaceSwitcher.sendSystemShortcut(index: index)
        case .systemShortcut:
            SpaceSwitcher.sendSystemShortcut(index: index)
        case .privateAPI:
            SpacesBridge.shared.switchToSpace(index: index)
        }
    }

    /// Activating a window that already lives on a workspace makes macOS animate over to it.
    private func focusWindow(onSpaceIndex index: Int) -> Bool {
        guard let target = SpacesBridge.shared.spaceID(atIndex: index) else { return false }
        let candidates = model.windows.filter { $0.spaceID == target && !$0.isMinimized }
        guard let window = candidates.first(where: { $0.id == model.selectedID }) ?? candidates.first
        else { return false }
        model.select(id: window.id, announce: false)
        focus(window)
        return true
    }

    private func refreshSpaceState() {
        model.currentSpaceID = SpacesBridge.shared.currentSpaceID
        model.currentSpaceIndex = SpacesBridge.shared.currentSpaceIndex
        model.currentSpaceIsFullscreen = SpacesBridge.shared.isCurrentSpaceFullscreen
        model.spaceOrder = SpacesBridge.shared.userSpaceIDs
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.stack",
                                     accessibilityDescription: "WindowQueue")
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Sort queue by workspace", action: #selector(sortByWorkspace),
                     keyEquivalent: "s")
            .target = self
        menu.addItem(withTitle: "Refresh windows", action: #selector(refreshWindows), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WindowQueue", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item
    }

    /// Opening WindowQueue again — from Spotlight, Launchpad or Finder — while it is already running
    /// has nothing to show but its settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                store: store,
                failures: { [weak self] in self?.hotkeys.failures.map(\.action) ?? [] },
                spacesAvailable: SpacesBridge.shared.isAvailable
            )
        }
        settingsWindow?.present()
        // Our own window is discovered like any other, just not instantly by the poll timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enumerator?.refresh()
        }
    }

    /// Sorting by hand also re-arms automatic sorting, which a manual reorder had switched off.
    @objc private func sortByWorkspace() {
        store.prefs.autoSortByWorkspace = true
        model.autoSortByWorkspace = true
        model.sortByWorkspace()
    }

    @objc private func refreshWindows() {
        enumerator?.refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
