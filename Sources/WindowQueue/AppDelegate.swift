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
    private lazy var tilingMenu = TilingMenuController(store: store)
    private let spaceMover = WindowSpaceMover()
    private var settingsWindow: SettingsWindowController?
    private var scrollFocusWork: DispatchWorkItem?
    private var statusItem: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()

    private lazy var dockReservation = DockReservation(store: store)
    private var terminationSources: [DispatchSourceSignal] = []
    private var debugCommands: DebugCommands?

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

        model.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.retileIfOrderChanged() }
            .store(in: &cancellables)

        let strip = StripController(
            model: model,
            store: store,
            onSelect: { [weak self] window in
                guard let self else { return }
                // Shift-clicking while aiming adds the icon's window to the aim, or takes it out.
                if self.model.aimingID != nil, NSEvent.modifierFlags.contains(.shift) {
                    self.model.toggleAim(window.id)
                    self.aimChanged()
                    return
                }
                // A click picks a window outright, so it also settles an aim in progress.
                self.endAiming(commit: false)
                // Clicking the collapsed tile asks for one of the windows hiding behind the
                // fullscreen one, so the queue comes back to normal first — otherwise the window
                // would be selected while still out of reach and out of the cycle.
                if self.model.isCovered(window) { self.model.endFocus() }
                self.model.select(id: window.id, announce: false)
                self.focus(window, warpCursor: false)
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
        strip.onHiddenStackHold = { [weak self] hidden in
            guard let self else { return }
            guard let first = hidden.first else {
                toast.endHold()
                return
            }
            let combo = self.store.prefs.combo(for: .toggleMaximize).displayString
            toast.show(title: "+\(hidden.count) window\(hidden.count == 1 ? "" : "s") hidden",
                       subtitle: "\(combo) restores the maximized window and brings them back",
                       beside: first.id, pinned: true)
        }
        self.strip = strip
        toast.anchorProvider = { [weak strip] id in
            guard let strip, let frame = strip.rowFrame(for: id) else { return nil }
            return (frame, strip.side)
        }
        toast.everyAnchorProvider = { [weak strip] id in strip?.rowFramesOnEveryStrip(for: id) ?? [] }

        modifierTaps.modifiers = store.prefs.superModifier.eventFlags
        modifierTaps.onTap = { [weak self] in self?.toggleAiming() }
        modifierTaps.start()

        // Hover focus never moves the pointer: the pointer is already where the user wants it.
        let hoverFocus = FocusFollowsMouse(model: model, store: store) { [weak self] window in
            guard let self else { return }
            let siblings = self.model.windows.count { $0.pid == window.pid }
            guard !self.store.prefs.focusFollowsMouseRaises,
                  WindowFocuser.focusWithoutRaising(window)
            else {
                WindowFocuser.focus(window, siblingCount: siblings)
                return
            }
            // Some applications keep the keyboard on whichever of their windows had it, however
            // they are asked — Ghostty does. Typing where the pointer is matters more than leaving
            // the stacking order alone, so an attempt that did not land is followed by a real raise.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.store.prefs.focusFollowsMouse,
                      WindowFocuser.isFocused(window) == false,
                      // Only if the pointer is still there: the user may have moved on since.
                      FocusFollowsMouse.windowUnderPointer() == window.id
                else { return }
                Diagnostics.note("hover focus did not land on \(window.id); raising it")
                WindowFocuser.focus(window, siblingCount: siblings)
            }
        }
        hoverFocus.isSuspended = { [weak self] in
            guard let self else { return false }
            return self.model.aimingID != nil || self.search?.isOpen == true
        }
        hoverFocus.start()
        self.hoverFocus = hoverFocus

        aimingKeys.onKey = { [weak self] press in self?.handleAimingPress(press) }
        aimingKeys.onShortcut = { [weak self] keyCode, flags in
            guard let self, let action = HotkeyAction.allCases.first(where: {
                self.store.prefs.combo(for: $0).matches(keyCode: keyCode, flags: flags)
            }) else { return }
            self.perform(action)
        }
        tilingMenu.anchorProvider = { [weak strip] ids in
            guard let strip, let first = ids.first, let last = ids.last,
                  let start = strip.rowFrame(for: first), let end = strip.rowFrame(for: last)
            else { return nil }
            return (start.union(end), strip.side)
        }
        aimingKeys.onDismiss = { [weak self] in self?.endAiming(commit: false) }
        tilingMenu.onPick = { [weak self] in self?.tileAimedWindows() }

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        debugCommands = DebugCommands { [weak self] words in self?.runDebugCommand(words) }
        debugCommands?.start()
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
            // Focus changes arrive as "settled" too, and focusing a window is not moving it.
            enumerator.onWindowFrameChanged = { [weak self] element in
                self?.windowFrameChanged(element)
            }
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
        // The finder has the keyboard; a second grab on top of it would leave it deaf to typing.
        guard store.prefs.aimingEnabled, search?.isOpen != true else { return }
        if model.aimingID != nil {
            // The same tap that opened the mode confirms it, so a switch is one key, twice.
            endAiming(commit: true)
        } else {
            beginAiming()
        }
    }

    private func beginAiming() {
        guard !model.visibleWindows.isEmpty else {
            Diagnostics.note("aiming: nothing to aim at")
            return
        }
        let aimed = model.beginAiming()
        Diagnostics.note("aiming: begin at \(aimed.map { "\($0.appName) \($0.id)" } ?? "nil")")
        aimingKeys.begin()
        dimOverlay?.show()
        if let aimed { toast?.show(aimed, pinned: true, everywhere: true) }
    }

    private func endAiming(commit: Bool) {
        guard model.aimingID != nil else { return }
        let aimed = model.aimedWindow
        model.endAiming()
        tilingMenu.hide()
        aimingKeys.end()
        dimOverlay?.hide()
        toast?.endHold()

        guard commit, let aimed else { return }
        model.select(id: aimed.id, announce: false)
        focus(aimed)
    }

    /// Keys while aiming. Along the strip, the arrows and [ ] move the aim; with Shift they grow a
    /// run of aimed windows, and with Option, Command or Control they carry the aimed windows along
    /// the queue. Once two or more are aimed, a menu of layouts sits beside them: Return or the arrow
    /// pointing into the screen enters it, and Return there tiles the windows.
    private func handleAimingPress(_ press: AimingKeyCapture.Press) {
        if tilingMenu.state.isFocused {
            handleTilingMenuPress(press)
            return
        }

        let side = store.prefs.stripSide
        let canTile = model.aimedWindows.count >= 2

        if let step = step(for: press.key, side: side, canTile: canTile) {
            if press.moves {
                model.moveAimedGroup(by: step)
            } else if press.extends {
                model.extendAim(by: step)
            } else {
                model.moveAim(by: step)
            }
            aimChanged()
            return
        }

        switch press.key {
        case .enter where canTile:
            tilingMenu.state.isFocused = true
        case _ where canTile && press.key == Self.intoScreen(from: side):
            tilingMenu.state.isFocused = true
        case .enter, .space:
            endAiming(commit: true)
        case .cancel:
            endAiming(commit: false)
        default:
            break
        }
    }

    /// Which way a key moves along the strip, or nil when it does not.
    private func step(for key: AimingKeyCapture.Key, side: StripSide, canTile: Bool) -> Int? {
        switch key {
        case .back: return -1
        case .forward: return 1
        case .up, .down, .left, .right:
            let alongPrevious: AimingKeyCapture.Key = side.isVertical ? .up : .left
            let alongNext: AimingKeyCapture.Key = side.isVertical ? .down : .right
            if key == alongPrevious { return -1 }
            if key == alongNext { return 1 }
            // Across the strip the arrows lead into the menu when there is one; otherwise they
            // keep moving the aim, as they always have.
            if canTile { return nil }
            return key == .left || key == .up ? -1 : 1
        default:
            return nil
        }
    }

    private static func intoScreen(from side: StripSide) -> AimingKeyCapture.Key {
        switch side {
        case .left: return .right
        case .right: return .left
        case .top: return .down
        case .bottom: return .up
        }
    }

    private func handleTilingMenuPress(_ press: AimingKeyCapture.Press) {
        let side = store.prefs.stripSide
        switch press.key {
        case .up, .back: tilingMenu.moveHighlight(by: -1)
        case .down, .forward: tilingMenu.moveHighlight(by: 1)
        case .left where side == .top || side == .bottom: tilingMenu.moveHighlight(by: -1)
        case .right where side == .top || side == .bottom: tilingMenu.moveHighlight(by: 1)
        case .enter, .space: tileAimedWindows()
        default:
            // Escape, or the arrow back towards the strip, returns to aiming.
            tilingMenu.state.isFocused = false
        }
    }

    /// Keeps the popup and the tiling menu in step with what is aimed.
    private func aimChanged() {
        let aimed = model.aimedWindows
        if aimed.count >= 2 {
            toast?.hideNow()
            tilingMenu.update(for: aimed)
        } else {
            tilingMenu.hide()
            if let window = aimed.first { toast?.show(window, pinned: true, everywhere: true) }
        }
    }

    private func tileAimedWindows() {
        let windows = model.aimedWindows
        guard let layout = tilingMenu.selectedLayout, windows.count >= 2 else { return }
        endAiming(commit: false)

        // Everything goes to the workspace of the last aimed window and is tiled there.
        guard let last = windows.last, let target = last.spaceID else {
            finishTiling(windows, layout: layout)
            return
        }
        var group = windows
        if windows.contains(where: { $0.spaceID != target }) {
            if spaceMover.isAvailable {
                let result = spaceMover.move(windows, to: target, queue: model.windows)
                model.relocate(result.arrived.map(\.id), toSpace: target)
                group = result.arrived
                if !result.leftBehind.isEmpty {
                    Diagnostics.note("tiling without \(result.leftBehind.map(\.appName)): their apps have other windows elsewhere")
                }
            } else {
                group = windows.filter { $0.spaceID == target }
            }
        } else if target == model.currentSpaceID {
            finishTiling(windows, layout: layout)
            return
        }

        // Go there, then give the windows time to show up in their apps' window lists: one that
        // arrived from, or still sits on, a workspace out of view has no accessibility element yet.
        focus(last, warpCursor: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let ready = group.map { window -> ManagedWindow in
                var copy = window
                copy.element = WindowSpaceMover.element(for: window) ?? window.element
                return copy
            }
            self.enumerator?.refresh()
            self.finishTiling(ready, layout: layout)
        }
    }

    /// While a layout is being applied, the frame changes it causes are ours, not the user's.
    private var tilingSettledAt = Date.distantPast
    /// The order the tiled windows were last laid out in, to notice a reorder.
    private var tiledOrder: [CGWindowID] = []
    /// The frames the layout gave them, to tell a real move from a notification about nothing.
    private var tiledFrames: [CGWindowID: NSRect] = [:]

    private func finishTiling(_ windows: [ManagedWindow], layout: TileLayout) {
        // Only windows with an element can be placed; the layout is picked for the ones that can,
        // so a window that could not be reached does not leave a hole.
        let windows = windows.filter { $0.element != nil }
        let layout = windows.count == layout.frames.count
            ? layout
            : TileLayout.options(for: windows.count).first { $0.kind == layout.kind }
                ?? TileLayout.options(for: windows.count).first
        guard let layout else { return }
        let placed = WindowTiler.tile(windows, layout: layout, in: tilingArea(),
                                      gaps: WindowTiler.Gaps(prefs: store.prefs))
        guard let first = placed.first else { return }
        WindowTiler.raise(placed)
        noteTiled(placed, layout: layout)
        model.select(id: first.id, announce: false)
        focus(first, warpCursor: false)
    }

    /// Remembers that these windows are holding a layout, and from when their frames are their own
    /// again — the tiler keeps correcting them for a moment after it places them.
    private func noteTiled(_ windows: [ManagedWindow], layout: TileLayout) {
        tiledOrder = windows.map(\.id)
        tilingSettledAt = Date().addingTimeInterval(2)
        model.setTiled(tiledOrder, layout: layout.name)
        // Read once the tiler has finished its own corrections, so what is stored is where the
        // windows actually came to rest.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            for window in windows where self.model.tiledIDs.contains(window.id) {
                self.tiledFrames[window.id] = WindowTiler.frame(of: window)
            }
        }
    }

    /// A window was resized or moved. If it was holding a layout and the change was not ours, the
    /// group is broken: the windows stay exactly where they are, they are simply free again.
    private func windowFrameChanged(_ element: AXUIElement) {
        guard !model.tiledIDs.isEmpty, Date() > tilingSettledAt,
              let id = AXPrivate.windowID(of: element), model.tiledIDs.contains(id),
              let window = model.windows.first(where: { $0.id == id })
        else { return }
        // Apps report a move for all sorts of reasons, focus among them; only a frame that is
        // really somewhere else means the user has taken the window out of the layout.
        if let placed = tiledFrames[id], let now = WindowTiler.frame(of: window),
           abs(now.minX - placed.minX) <= 4, abs(now.minY - placed.minY) <= 4,
           abs(now.width - placed.width) <= 4, abs(now.height - placed.height) <= 4 {
            return
        }
        Diagnostics.note("tiling broken by a change to window \(id)")
        model.clearTiled()
        tiledOrder = []
        tiledFrames = [:]
    }

    /// The queue order of tiled windows decides their places in the layout, so moving one of them
    /// along the queue lays the group out again — the quickest way to say "this one is the main".
    private func retileIfOrderChanged() {
        guard !model.tiledIDs.isEmpty, let name = model.tiledLayout else { return }
        let windows = model.tiledWindowsInQueueOrder
        let order = windows.map(\.id)
        guard order != tiledOrder, order.count > 1 else { return }
        guard let layout = TileLayout.options(for: windows.count).first(where: { $0.name == name })
            ?? TileLayout.options(for: windows.count).first
        else { return }
        let placed = WindowTiler.tile(windows, layout: layout, in: tilingArea(),
                                      gaps: WindowTiler.Gaps(prefs: store.prefs))
        guard !placed.isEmpty else { return }
        noteTiled(placed, layout: layout)
    }

    /// The screen being worked on, less the room the strip keeps for itself.
    private func tilingArea() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        var area = screen?.visibleFrame ?? .zero
        let prefs = store.prefs
        guard prefs.stripDisplay != .hidden, prefs.reserveScreenSpace else { return area }
        let gap = CGFloat(RectangleIntegration.reservedWidth(for: prefs))
        switch prefs.stripSide {
        case .left:
            area.origin.x += gap
            area.size.width -= gap
        case .right:
            area.size.width -= gap
        case .top:
            area.size.height -= gap
        case .bottom:
            area.origin.y += gap
            area.size.height -= gap
        }
        return area
    }

    private func perform(_ action: HotkeyAction) {
        // Carbon consumes the key event, so the tap detector never sees what interrupted it.
        modifierTaps.cancel()

        // While aiming, the cycle shortcuts move the aim rather than the focus.
        if model.aimingID != nil {
            switch action {
            case .cyclePrevious:
                handleAimingPress(.init(key: .back, extends: false, moves: false))
                return
            case .cycleNext:
                handleAimingPress(.init(key: .forward, extends: false, moves: false))
                return
            case .moveLeft:
                handleAimingPress(.init(key: .back, extends: false, moves: true))
                return
            case .moveRight:
                handleAimingPress(.init(key: .forward, extends: false, moves: true))
                return
            case _ where action.moveSpaceIndex != nil:
                moveWindows(toWorkspace: action.moveSpaceIndex!)
                return
            // Fullscreen hides every other window of its workspace, so several windows cannot each
            // be the one on top: the aim stays as it is and nothing happens.
            case .toggleMaximize where model.aimedWindows.count > 1:
                toast?.showCentred(title: "Fullscreen takes one window",
                                   subtitle: "Aim at a single window, or tile the group with Return")
                return
            // Anything that makes sense window by window is applied to every aimed window. (The
            // `where` would only bind to the last pattern, so the count is checked in the body.)
            case .maximizeWindow, .minimizeWindow, .closeWindow, .moveToStart, .moveToEnd:
                if model.aimedWindows.count > 1 {
                    applyToAimedGroup(action)
                    return
                }
                endAiming(commit: false)
            default:
                endAiming(commit: false)
            }
        }

        if let index = action.moveSpaceIndex {
            moveWindows(toWorkspace: index)
            return
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
        case .toggleMaximize:
            toggleMaximize()
        case .maximizeWindow:
            maximizeWindow()
        case .minimizeWindow:
            if let window = model.selectedWindow { minimize(window) }
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
        // While aiming, the wheel moves the aim like the cycle shortcuts do, focusing nothing.
        if model.aimingID != nil {
            for _ in 0..<abs(steps) {
                handleAimingPress(.init(key: steps > 0 ? .forward : .back, extends: false, moves: false))
            }
            return
        }
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

    /// Frames windows had before they were maximized, so the same shortcut puts them back.
    private var framesBeforeMaximize: [CGWindowID: NSRect] = [:]

    /// Runs an action over every aimed window at once, then leaves aiming mode.
    private func applyToAimedGroup(_ action: HotkeyAction) {
        let group = model.aimedWindows
        guard group.count > 1 else { return }
        endAiming(commit: false)
        let count = group.count
        switch action {
        case .maximizeWindow:
            // One after another, so an app that snaps its own frame does not fight the next one.
            for window in group { maximize(window) }
            announceGroup("Maximized \(count) windows")
        case .minimizeWindow:
            for window in group { minimize(window) }
            announceGroup("Minimized \(count) windows")
        case .closeWindow:
            for window in group { close(window) }
            announceGroup("Closed \(count) windows")
        case .moveToStart:
            model.move(ids: group.map(\.id), toVisiblePosition: 0)
            announceGroup("Moved \(count) windows to the start of the queue")
        case .moveToEnd:
            model.move(ids: group.map(\.id), toVisiblePosition: model.visibleWindows.count)
            announceGroup("Moved \(count) windows to the end of the queue")
        default:
            break
        }
    }

    /// What a group action did, in the middle of the screen: it is about several windows at once,
    /// so there is no one icon for the popup to point at.
    private func announceGroup(_ title: String) {
        toast?.showCentred(title: title, subtitle: "WindowQueue")
    }

    private func minimize(_ window: ManagedWindow) {
        let element = window.element ?? WindowSpaceMover.element(for: window)
        element?.setAttribute(kAXMinimizedAttribute, value: kCFBooleanTrue)
    }

    /// Fills the screen with the selected window, less the strip's room. Nothing else changes: no
    /// way back through the same shortcut, and the rest of the workspace stays where it is.
    private func maximizeWindow() {
        guard let window = model.selectedWindow else { return }
        maximize(window)
    }

    private func maximize(_ window: ManagedWindow) {
        var window = window
        window.element = window.element ?? WindowSpaceMover.element(for: window)
        // Its old frame is still worth keeping: the fullscreen shortcut can put it back later.
        if framesBeforeMaximize[window.id] == nil {
            framesBeforeMaximize[window.id] = WindowTiler.frame(of: window)
        }
        WindowTiler.fill(window, in: tilingArea(), gaps: WindowTiler.Gaps(prefs: store.prefs))
    }

    /// Fills the screen with the selected window, less the strip's room; again restores it.
    private func toggleMaximize() {
        guard var window = model.selectedWindow else { return }
        window.element = window.element ?? WindowSpaceMover.element(for: window)
        let area = tilingArea()

        if let previous = framesBeforeMaximize[window.id],
           let frame = WindowTiler.frame(of: window), Self.fills(frame, area) {
            framesBeforeMaximize[window.id] = nil
            WindowTiler.restore(window, to: previous)
            model.endFocus()
            return
        }
        framesBeforeMaximize[window.id] = WindowTiler.frame(of: window)
        WindowTiler.fill(window, in: area, gaps: WindowTiler.Gaps(prefs: store.prefs))
        if store.prefs.focusMaximizedWindow { model.beginFocus(on: window.id) }
    }

    /// Near enough to the maximized frame to count as maximized; apps round and snap to their own
    /// grids, so an exact match would leave the shortcut one-way.
    private static func fills(_ frame: NSRect, _ area: NSRect) -> Bool {
        abs(frame.minX - area.minX) <= 12 && abs(frame.minY - area.minY) <= 12
            && abs(frame.width - area.width) <= 24 && abs(frame.height - area.height) <= 24
    }

    private func closeSelectedWindow() {
        guard let window = model.selectedWindow else { return }
        close(window)
    }

    private func close(_ window: ManagedWindow) {
        // Hand the selection to a neighbour up front: the window is about to stop existing, and
        // otherwise the selection would fall back to the top of the queue when it does.
        // On the workspace in view, only a window that is also here can take over; with none left
        // the strip falls back to an empty slot once the window is gone.
        let onCurrentSpace = window.spaceID != nil && window.spaceID == model.currentSpaceID
        let successor = onCurrentSpace
            ? window.spaceID.flatMap { model.nearestWindow(on: $0, to: window.id, in: model.windows.map(\.id)) }
            : model.neighbour(after: window.id)

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

    /// Sends the selected window — or every aimed window, while aiming — to a workspace, staying
    /// where the user is. Windows move with their whole app, so one whose app has other windows
    /// elsewhere stays put, and the popup says so.
    private func moveWindows(toWorkspace index: Int) {
        let windows = model.aimingID != nil ? model.aimedWindows : model.selectedWindow.map { [$0] } ?? []
        if model.aimingID != nil { endAiming(commit: false) }
        let spaces = SpacesBridge.shared.userSpaceIDs
        guard !windows.isEmpty, spaces.indices.contains(index - 1), spaceMover.isAvailable else { return }

        let target = spaces[index - 1]
        let orderBefore = model.visibleWindows.map(\.id)
        let selectedBefore = model.selectedID

        let result = spaceMover.move(windows, to: target, queue: model.windows)
        model.relocate(result.arrived.map(\.id), toSpace: target)

        // The selected window has left the workspace the user is on, so the selection follows
        // what is still here rather than pointing at something out of sight.
        let movedAway = Set(result.arrived.filter { $0.id == selectedBefore }.map(\.id))
        if let selectedBefore, movedAway.contains(selectedBefore),
           let current = model.currentSpaceID, current != target {
            selectNearestRemaining(to: selectedBefore, in: orderBefore, on: current,
                                   excluding: Set(result.arrived.map(\.id)))
        }
        if let kept = result.leftBehind.first {
            let others = result.leftBehind.count > 1 ? " and \(result.leftBehind.count - 1) more" : ""
            toast?.show(title: "\(kept.appName) stayed here\(others)",
                        subtitle: "Its app has windows on other workspaces, and moves as a whole",
                        beside: kept.id)
        } else if let first = windows.first {
            toast?.show(title: windows.count == 1 ? first.displayTitle : "\(windows.count) windows",
                        subtitle: "Moved to workspace \(index)", beside: first.id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enumerator?.refresh()
        }
    }

    /// Focuses the window on `space` closest in the queue to where `id` was, or, when the workspace
    /// has nothing left, leaves the strip showing an empty slot there.
    private func selectNearestRemaining(to id: CGWindowID, in order: [CGWindowID], on space: UInt64,
                                        excluding moved: Set<CGWindowID>) {
        if let nearest = model.nearestWindow(on: space, to: id, in: order, excluding: moved) {
            model.select(id: nearest.id, announce: false)
            focus(nearest)
        } else {
            model.showEmptySlot(for: space)
        }
    }

    /// Changes workspace using the configured strategy, falling back through the others.
    private func switchToSpace(_ index: Int) {
        switch store.prefs.spaceSwitchMethod {
        case .focusWindow:
            if focusWindow(onSpaceIndex: index) { return }
            // Nothing to focus there: carry a window of our own over instead, and only fall back to
            // the system shortcut if that is unavailable.
            if let space = SpacesBridge.shared.userSpaceID(atIndex: index),
               SpaceSwitcher.jump(toSpace: space) { return }
            SpaceSwitcher.sendSystemShortcut(index: index)
        case .systemShortcut:
            SpaceSwitcher.sendSystemShortcut(index: index)
        case .privateAPI:
            SpacesBridge.shared.switchToSpace(index: index)
        }
    }

    /// Activating a window that already lives on a workspace makes macOS animate over to it.
    private func focusWindow(onSpaceIndex index: Int) -> Bool {
        // Counted across displays, like the numbers the strip shows and the move shortcuts use.
        guard let target = SpacesBridge.shared.userSpaceID(atIndex: index) else { return false }
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

    // MARK: - Debug commands

    private func runDebugCommand(_ words: [String]) {
        guard let verb = words.first else { return }
        Diagnostics.note("debug command: \(words.joined(separator: " "))")
        switch verb {
        case "action":
            if let name = words.dropFirst().first, let action = HotkeyAction(rawValue: name) { perform(action) }
        case "aim":
            toggleAiming()
        case "aimkey":
            let keys: [String: AimingKeyCapture.Key] = [
                "up": .up, "down": .down, "left": .left, "right": .right, "back": .back,
                "forward": .forward, "enter": .enter, "space": .space, "cancel": .cancel,
            ]
            guard let name = words.dropFirst().first, let key = keys[name], model.aimingID != nil else { return }
            handleAimingPress(.init(key: key, extends: words.contains("shift"), moves: words.contains("move")))
        case "focus":
            guard let id = words.dropFirst().first.flatMap({ CGWindowID($0) }),
                  let window = model.windows.first(where: { $0.id == id }) else { return }
            model.select(id: id, announce: true)
            focus(window)
        case "refresh":
            enumerator?.refresh()
        case "dump":
            DebugCommands.writeState(model)
        default:
            break
        }
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
