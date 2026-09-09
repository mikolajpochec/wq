import AppKit
import ApplicationServices
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = PreferencesStore()
    private let model = WindowQueueModel()
    private let permissions = Permissions()
    private let hotkeys = HotkeyManager()

    private var enumerator: WindowEnumerator?
    private var strip: StripController?
    private var toast: ToastController?
    private var settingsWindow: SettingsWindowController?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.note("launch: trusted=\(AXIsProcessTrusted()) windowIDs=\(AXPrivate.supportsWindowNumbers) spaces=\(SpacesBridge.shared.isAvailable)")
        setUpStatusItem()

        model.scope = store.prefs.scope
        store.$prefs
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                self.model.scope = prefs.scope
                self.hotkeys.apply(prefs)
                RectangleIntegration.applyAndReloadIfNeeded(prefs: prefs)
            }
            .store(in: &cancellables)

        let toast = ToastController(store: store)
        self.toast = toast
        model.announcement
            .receive(on: RunLoop.main)
            .sink { window in toast.show(window) }
            .store(in: &cancellables)

        let strip = StripController(model: model, store: store) { [weak self] window in
            self?.model.select(id: window.id, announce: false)
            self?.focus(window)
        }
        self.strip = strip
        toast.anchorProvider = { [weak strip] id in
            guard let strip, let frame = strip.rowFrame(for: id) else { return nil }
            return (frame, strip.side)
        }

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        hotkeys.apply(store.prefs)
        RectangleIntegration.applyAndReloadIfNeeded(prefs: store.prefs)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let window = note.object as? NSWindow,
                      window === self?.settingsWindow?.window else { return }
                NSApp.setActivationPolicy(.accessory)
            }
            .store(in: &cancellables)

        permissions.requestAndWait { [weak self] in
            guard let self else { return }
            Diagnostics.note("accessibility granted, starting enumeration")
            let enumerator = WindowEnumerator(model: self.model)
            self.enumerator = enumerator
            enumerator.start()
            strip.start()
        }
    }

    // MARK: - Actions

    private func perform(_ action: HotkeyAction) {
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
        default:
            break
        }
    }

    private func focus(_ window: ManagedWindow) {
        let siblings = model.windows.count { $0.pid == window.pid }
        WindowFocuser.focus(window,
                            workspaceIndex: model.workspaceNumber(of: window),
                            siblingCount: siblings)
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
        menu.addItem(withTitle: "Refresh windows", action: #selector(refreshWindows), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit WindowQueue", action: #selector(quit), keyEquivalent: "q")
            .target = self
        item.menu = menu
        statusItem = item
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
    }

    @objc private func refreshWindows() {
        enumerator?.refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
