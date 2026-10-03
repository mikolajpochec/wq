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
    private lazy var actionPanel = ActionPanelController(store: store)
    private let aimHighlight = AimHighlightOverlay()
    private let monitorFrame = MonitorFrameOverlay()
    /// When aiming mode last opened, for telling a double tap of the super key from two separate ones.
    private var aimingOpenedAt = Date.distantPast
    /// Aiming was opened with the mouse, so it offers its actions as tiles to click.
    private var aimStartedWithPointer = false
    /// Watches for a click anywhere outside WindowQueue's own panels while aiming.
    private var aimClickMonitor: Any?
    /// Shows the mode once it is clear the tap was not the first half of a double tap.
    private var aimingReveal: DispatchWorkItem?
    private var dimOverlay: DimOverlay?
    private let orderStore = QueueOrderStore()
    private var search: SearchController?
    private var hoverFocus: FocusFollowsMouse?

    private var enumerator: WindowEnumerator?
    private var strip: StripController?
    private var toast: ToastController?
    private lazy var tilingMenu = TilingMenuController(store: store)
    private lazy var groupPanel = GroupPanelController(store: store)
    private let tilePreview = TilePreviewOverlay()
    /// A group the pointer is resting on, shown without stepping into it.
    private let spaceMover = WindowSpaceMover()
    private var settingsWindow: SettingsWindowController?
    private var tour: TourWindowController?
    /// The tour's window has the keyboard: the shortcuts and the super key tap go to its pretend
    /// desktop rather than to the real windows.
    private var tourHasKeyboard = false
    private let updates = UpdateChecker()
    private var updateWindow: UpdateWindowController?
    /// Up at the top of the menu once a newer release is out, until this copy is updated.
    private let updateItem = NSMenuItem(title: "", action: #selector(showUpdate), keyEquivalent: "")
    /// Accessibility is granted, so the shortcuts can do what they promise.
    private var accessGranted = false
    private let grantAccessItem = NSMenuItem(title: "Grant Accessibility Access…",
                                             action: #selector(grantAccessibility), keyEquivalent: "")
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

        model.scope = store.prefs.effectiveScope
        model.queuePerMonitor = store.prefs.multiMonitorMode
        model.autoSortByWorkspace = store.prefs.autoSortByWorkspace
        model.onManualReorder = { [weak self] in
            self?.store.prefs.autoSortByWorkspace = false
        }
        // A tab that came to the front is the same window to the user: whatever was remembered
        // about the tab it replaced — its layout, its frame before fullscreen — is its now.
        model.onHandoff = { [weak self] old, new in
            guard let self else { return }
            if let frame = self.tiledFrames.removeValue(forKey: old) { self.tiledFrames[new] = frame }
            if let frame = self.framesBeforeMaximize.removeValue(forKey: old) { self.framesBeforeMaximize[new] = frame }
            for (group, order) in self.tiledOrders where order.contains(old) {
                self.tiledOrders[group] = order.map { $0 == old ? new : $0 }
            }
        }
        updates.onAvailable = { [weak self] release, announce in
            guard let self else { return }
            self.updateItem.title = "Update Available: \(release.version)…"
            self.updateItem.isHidden = false
            if announce { self.showUpdate() }
        }
        updates.onUpToDate = { [weak self] in
            self?.updateItem.isHidden = true
            self?.toast?.showCentred(title: "WindowQueue is up to date",
                                     subtitle: "Version \(UpdateChecker.currentVersion) is the latest")
        }
        updates.onFailure = { [weak self] reason in
            self?.toast?.showCentred(title: "Couldn't check for updates", subtitle: reason)
        }
        store.$prefs
            .receive(on: RunLoop.main)
            .sink { [weak self] prefs in
                guard let self else { return }
                if prefs.checkForUpdates { self.updates.start() } else { self.updates.stop() }
                self.model.scope = prefs.effectiveScope
                self.model.queuePerMonitor = prefs.multiMonitorMode
                self.model.autoSortByWorkspace = prefs.autoSortByWorkspace
                self.modifierTaps.modifiers = prefs.superModifier.eventFlags
                self.syncHotkeys(prefs)
                WindowTiler.respectsSizeLimits = prefs.respectWindowSizeLimits
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

        // However focus gets to a tiled window — the strip, the keyboard, hovering, a click, ⌘Tab —
        // its layout comes up with it.
        model.$selectedID
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] id in self?.raiseLayoutOnceFocused(id) }
            .store(in: &cancellables)
        model.onFocusFollowed = { [weak self] id in self?.raiseLayoutOnceFocused(id) }
        model.onWindowsArrived = { [weak self] windows in
            DispatchQueue.main.async { self?.placeLaunched(windows) }
        }

        model.$windows
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.releaseTiledWindowsThatLeft()
                self?.retileIfOrderChanged()
            }
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
                // Clicking a row greyed out behind the fullscreen window asks for that window, so
                // the queue comes back to normal first — otherwise the window would be selected
                // while still out of reach and out of the cycle. (The collapsed tile hands over the
                // fullscreen window itself.)
                if self.model.isCovered(window) { self.model.endFocus() }
                self.model.select(id: window.id, announce: false)
                self.focus(window, warpCursor: false)
            },
            onHold: { [weak self] window in
                if let window {
                    toast.show(window, pinned: true)
                } else if self?.strip?.isDragging == true {
                    // Dropped mid-drag, so it goes at once rather than trailing the icon.
                    toast.hideNow()
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
        toast.anchorProvider = { [weak self, weak strip] id in
            // A window shown in the group's strip is named there; the group's entry in the main
            // strip is not where the user is looking.
            if let inGroup = self?.groupPanel.rowFrame(for: id) { return inGroup }
            guard let strip, let frame = strip.rowFrame(for: id) else { return nil }
            return (frame, strip.side)
        }
        toast.everyAnchorProvider = { [weak self, weak strip] id in
            // Aiming shows the name on every strip, but a window listed in the group's strip lives
            // on that one only — the main strip holds the group's single entry, not the window.
            if let inGroup = self?.groupPanel.rowFrame(for: id) { return [inGroup.frame] }
            return strip?.rowFramesOnEveryStrip(for: id) ?? []
        }
        groupPanel.stripFrameProvider = { [weak strip] in strip?.contentFrame() }
        groupPanel.entryFrameProvider = { [weak strip] id in strip?.rowFrame(for: id) }
        actionPanel.stripFrameProvider = { [weak strip] in strip?.contentFrame() }
        actionPanel.onPick = { [weak self] action in self?.pick(action) }
        groupPanel.onHover = { [weak self] window in
            guard self != nil else { return }
            if let window {
                toast.show(window, pinned: true)
            } else {
                toast.endHold()
            }
        }
        groupPanel.onClose = { [weak self] window in self?.close(window) }
        groupPanel.onPick = { [weak self] window in
            self?.model.select(id: window.id, announce: false)
            self?.focus(window, warpCursor: false)
        }
        strip.onDragTarget = { [weak self] window, target in
            self?.previewTilePlacement(of: window, at: target)
        }
        // The workspace badge stands for the workspace itself: clicking it opens aiming mode, which
        // is the keyboard-free way into everything the mode can do.
        strip.onBadgeTap = { [weak self] in
            guard let self, self.model.aimingID == nil else { return }
            self.beginAiming(fromPointer: true)
        }
        // Hovering a group names it; opening it is a click, so the pointer can cross the strip
        // without strips unfolding under it.
        strip.onGroupHover = { [weak self] hovered in
            guard self != nil else { return }
            guard let hovered else {
                toast.endHold()
                return
            }
            let count = hovered.group.ids.count
            toast.show(title: "Group \(hovered.group.id) — \(count) windows",
                       subtitle: "Click to open it in a strip of its own",
                       beside: hovered.row.id, pinned: true)
        }
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncGroupPanel() }
            .store(in: &cancellables)

        modifierTaps.modifiers = store.prefs.superModifier.eventFlags
        modifierTaps.onTap = { [weak self] in
            // The tour watches its own window for the tap.
            guard self?.tourHasKeyboard == false else { return }
            self?.toggleAiming()
        }

        // Hover focus never moves the pointer: the pointer is already where the user wants it.
        let hoverFocus = FocusFollowsMouse(model: model, store: store) { [weak self] window in
            guard let self else { return }
            let siblings = self.model.windows.count { $0.pid == window.pid }
            self.raiseLayoutOnceFocused(window.id)
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
                      FocusFollowsMouse.windowUnderPointer(isKnown: { id in self.model.windows.contains { $0.id == id } }) == window.id
                else { return }
                Diagnostics.note("hover focus did not land on \(window.id); raising it")
                WindowFocuser.focus(window, siblingCount: siblings)
            }
        }
        hoverFocus.isSuspended = { [weak self] in
            guard let self else { return false }
            // Nor while a jump to another desktop is under way: whatever slides under the pointer
            // on the way is not where the user is going, and focusing it would turn the jump back.
            return self.model.aimingID != nil || self.search?.isOpen == true || self.tourHasKeyboard
                || OwnWindows.justPresented
                || SpaceSwitcher.destination != nil || WindowDragMover.isCarrying
        }
        hoverFocus.start()
        self.hoverFocus = hoverFocus

        aimingKeys.onKey = { [weak self] press in self?.handleAimingPress(press) }
        aimingKeys.onShortcut = { [weak self] keyCode, flags in
            guard let self else { return }
            let prefs = self.store.prefs
            // The mode has the keyboard to itself, so a shortcut works with or without its super
            // key: `G` groups the aimed windows just as `⌥G` does.
            let bare = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
            // A key the user bound for aiming mode alone comes first: it is the more specific
            // answer, and it is the one they set deliberately.
            let action = (bare ? prefs.aimBindings["\(keyCode)"] : nil)
                ?? HotkeyAction.allCases.first { prefs.combo(for: $0).matches(keyCode: keyCode, flags: flags) }
                ?? (bare ? HotkeyAction.allCases.first { action in
                    let combo = prefs.combo(for: action)
                    return combo.keyCode == UInt32(keyCode) && combo.modifiers == prefs.superModifier.carbonMask
                } : nil)
            guard let action else { return }
            self.perform(action)
        }
        tilingMenu.anchorProvider = { [weak self, weak strip] ids in
            guard let first = ids.first, let last = ids.last else { return nil }
            // Aimed inside a group, the windows are shown in the group's own strip; the menu belongs
            // beside those icons, not beside the group's single entry in the main strip.
            if let group = self?.groupPanel,
               let start = group.rowFrame(for: first), let end = group.rowFrame(for: last) {
                return (start.frame.union(end.frame), start.side)
            }
            guard let strip, let start = strip.rowFrame(for: first), let end = strip.rowFrame(for: last)
            else { return nil }
            return (start.union(end), strip.side)
        }
        aimingKeys.onDismiss = { [weak self] in self?.endAiming(commit: false) }
        tilingMenu.onPick = { [weak self] in self?.tileAimedWindows() }

        hotkeys.onAction = { [weak self] action in self?.perform(action) }
        debugCommands = DebugCommands { [weak self] words in self?.runDebugCommand(words) }
        debugCommands?.start()
        // Until Accessibility is granted the shortcuts would swallow their keys and do nothing.
        syncHotkeys()
        RectangleIntegration.applyAndReloadIfNeeded(prefs: store.prefs)

        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)
            .sink { [weak self] note in
                guard let self, let window = note.object as? NSWindow,
                      window === self.settingsWindow?.window || window === self.tour?.window
                      || window === self.updateWindow?.window else { return }
                // Back to living in the menu bar once none of our windows is left open.
                let others = [self.settingsWindow?.window, self.tour?.window, self.updateWindow?.window].compactMap { $0 }
                    .filter { $0 !== window && $0.isVisible }
                if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
                self.enumerator?.refresh()
            }
            .store(in: &cancellables)

        // A new user meets the tour, which asks for Accessibility in its own words; the system's
        // prompt on top of it would only be a second dialog saying less.
        let firstRun = !store.prefs.onboardingCompleted
        if firstRun { showTour() }
        permissions.requestAndWait(prompt: !firstRun) { [weak self] in
            guard let self else { return }
            Diagnostics.note("accessibility granted, starting enumeration")
            self.accessGranted = true
            self.grantAccessItem.isHidden = true
            self.syncHotkeys()
            self.modifierTaps.start()
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
            enumerator.onActiveSpaceChanged = { [weak self] in self?.keepHeldWorkspace() }
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
            // A second tap right on the heels of the first is a double tap, which can be bound to
            // an action of its own; later on it is the plain confirm, and a switch is one key twice.
            if let action = store.prefs.superDoubleTapAction,
               Date().timeIntervalSince(aimingOpenedAt) < Self.doubleTapInterval {
                endAiming(commit: false)
                // Nothing of the mode should linger behind the action the double tap asked for.
                toast?.hideNow()
                perform(action)
                return
            }
            endAiming(commit: true)
        } else {
            beginAiming()
        }
    }

    /// A click anywhere that is not WindowQueue's own — the strip, a group's strip, the popups —
    /// leaves aiming mode. A global monitor sees exactly those clicks: the ones that land in our own
    /// panels are delivered to this app and never reach it, which is the distinction wanted here.
    private func watchForClicksOutside() {
        guard aimClickMonitor == nil else { return }
        aimClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let self, self.model.aimingID != nil else { return }
            self.endAiming(commit: false)
        }
    }

    private func stopWatchingForClicksOutside() {
        if let aimClickMonitor { NSEvent.removeMonitor(aimClickMonitor) }
        aimClickMonitor = nil
    }

    /// How long after opening aiming mode a second tap of the super key still counts as a double tap.
    private static let doubleTapInterval: TimeInterval = 0.4

    private func beginAiming(fromPointer: Bool = false) {
        aimingOpenedAt = Date()
        aimStartedWithPointer = fromPointer
        guard !model.visibleWindows.isEmpty else {
            Diagnostics.note("aiming: nothing to aim at")
            return
        }
        let aimed = model.beginAiming()
        Diagnostics.note("aiming: begin at \(aimed.map { "\($0.appName) \($0.id)" } ?? "nil")")
        aimingKeys.begin()
        watchForClicksOutside()

        // With a double tap bound to something, the first tap may only be the start of it: hold the
        // popup and the dimming back for as long as the second tap could still arrive, so the screen
        // does not flash the mode up and take it away again. The keys are grabbed from the off all
        // the same, so nothing typed in between reaches the app in front.
        // Whatever the aim is on when this runs, not what it was on when the mode opened: the user
        // can have stepped along the strip in the meantime, and naming the window they left would
        // undo the popup that step already put up.
        let show = { [weak self] in
            guard let self, self.model.aimingID != nil else { return }
            self.aimingReveal = nil
            self.syncActionPanel()
            self.syncAimHighlight()
            self.dimOverlay?.show()
            if let window = self.model.aimedWindow, self.model.aimedWindows.count == 1 {
                self.toast?.show(window, pinned: true, everywhere: true)
            }
        }
        aimingReveal?.cancel()
        guard store.prefs.superDoubleTapAction != nil, !fromPointer, !store.prefs.instantAiming else {
            show()
            return
        }
        let work = DispatchWorkItem(block: show)
        aimingReveal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapInterval, execute: work)
    }

    private func endAiming(commit: Bool) {
        guard model.aimingID != nil else { return }
        let aimed = model.aimedWindow
        model.endAiming()
        tilingMenu.hide()
        aimingKeys.end()
        stopWatchingForClicksOutside()
        aimingReveal?.cancel()
        aimingReveal = nil
        actionPanel.hide()
        aimHighlight.hide()
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
        // A group aimed at as a whole covers several windows, but the arrow into the screen steps
        // into it rather than opening the layout menu; the menu is for a run the user built.
        let aimedGroup = model.aimedGroup
        let canTile = model.aimedWindows.count >= 2 && aimedGroup == nil

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
        // Into the screen steps into the group the aim is on; back towards the strip steps out.
        case Self.intoScreen(from: side) where aimedGroup != nil:
            model.enterAimedGroup()
            aimChanged()
        case Self.awayFromScreen(from: side) where model.aimInsideGroupID != nil:
            model.leaveAimedGroup()
            aimChanged()
        case .enter where aimedGroup != nil:
            model.enterAimedGroup()
            aimChanged()
        case .enter where canTile:
            tilingMenu.state.isFocused = true
        case _ where canTile && press.key == Self.intoScreen(from: side):
            tilingMenu.state.isFocused = true
        case .all:
            model.aimAll()
            aimChanged()
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

    /// The arrow pointing back at the strip, which steps out of a group.
    private static func awayFromScreen(from side: StripSide) -> AimingKeyCapture.Key {
        switch side {
        case .left: return .left
        case .right: return .right
        case .top: return .up
        case .bottom: return .down
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

    /// Outlines the aimed windows where they actually are, for the ones on the workspace in view.
    private func syncAimHighlight() {
        guard model.aimingID != nil else {
            aimHighlight.hide()
            return
        }
        // What is on screen, on every display, as the WindowServer says — not the workspace the
        // model last read for each window, nor the one desktop of the main display.
        let onScreen = WindowTiler.onScreenWindowIDs()
        let here = model.aimedWindows.filter { onScreen.contains($0.id) }
        aimHighlight.show(here, cursor: model.aimingID,
                          animated: !store.prefs.instantAiming && store.prefs.animates(.aimCursor))
    }

    /// The tiles beside the strip, for aiming started with the mouse: what the mode's keys do, in a
    /// form a pointer can reach. What is offered follows the aim — a run of windows can be tiled and
    /// cannot be sent fullscreen, a single one is the other way round.
    private func syncActionPanel() {
        guard aimStartedWithPointer, model.aimingID != nil else {
            actionPanel.hide()
            return
        }
        let aimed = model.aimedWindows
        var actions: [AimAction] = []
        if aimed.count > 1 {
            actions.append(AimAction(kind: .shortcut(.toggleGroup), title: "Group", symbol: "square.stack.3d.up"))
            if model.aimedGroup == nil {
                actions.append(AimAction(kind: .confirm, title: "Tile", symbol: "square.grid.2x2"))
            }
        } else {
            actions.append(AimAction(kind: .confirm, title: "Focus", symbol: "scope"))
            actions.append(AimAction(kind: .shortcut(.toggleMaximize), title: "Fullscreen", symbol: "arrow.up.left.and.arrow.down.right"))
        }
        actions.append(AimAction(kind: .shortcut(.maximizeWindow), title: "Maximize", symbol: "rectangle.expand.vertical"))
        actions.append(AimAction(kind: .shortcut(.minimizeWindow), title: "Minimize", symbol: "minus.rectangle"))
        actions.append(AimAction(kind: .shortcut(.declutter), title: "Declutter", symbol: "rectangle.3.group"))
        actions.append(AimAction(kind: .shortcut(.closeWindow), title: "Close", symbol: "xmark"))
        actions.append(AimAction(kind: .selectAll, title: "Select all", symbol: "checklist"))
        actions.append(AimAction(kind: .shortcut(.openLauncher), title: store.prefs.launcher.title,
                                 symbol: "magnifyingglass"))
        actions.append(AimAction(kind: .shortcut(.showOverview), title: "Overview", symbol: "square.grid.3x3"))
        actions.append(AimAction(kind: .shortcut(.screenshotWindow), title: "Screenshot", symbol: "camera"))
        actions.append(AimAction(kind: .shortcut(.toggleRecording),
                                 title: ScreenCapture.shared.isRecording ? "Stop" : "Record",
                                 symbol: ScreenCapture.shared.isRecording ? "stop.circle" : "record.circle"))
        actions.append(AimAction(kind: .shortcut(.toggleInvisibleStrip),
                                 title: store.prefs.invisibleStrip ? "Show strip" : "Hide strip",
                                 symbol: store.prefs.invisibleStrip ? "eye" : "eye.slash"))
        actions.append(AimAction(kind: .cancel, title: "Cancel", symbol: "escape"))
        actionPanel.show(actions)
    }

    /// A tile was clicked, which does exactly what its key does.
    private func pick(_ action: AimAction) {
        switch action.kind {
        case .shortcut(let shortcut):
            perform(shortcut)
        case .selectAll:
            model.aimAll()
            aimChanged()
        case .confirm:
            // A run of windows confirms into the tiling menu, one window into focusing it.
            if model.aimedWindows.count > 1, model.aimedGroup == nil {
                tilingMenu.state.isFocused = true
                syncActionPanel()
            } else {
                endAiming(commit: true)
            }
        case .cancel:
            endAiming(commit: false)
        }
    }

    /// Keeps the popup and the tiling menu in step with what is aimed.
    private func aimChanged() {
        // Moving the aim is the user showing their hand: the mode is theirs, so anything held back
        // for a possible double tap goes up now, in the state it is in.
        if let reveal = aimingReveal {
            reveal.cancel()
            aimingReveal = nil
            dimOverlay?.show()
        }
        syncGroupPanel()
        syncActionPanel()
        syncAimHighlight()
        let aimed = model.aimedWindows
        if model.aimedGroup != nil {
            // The popup would name one window of several; the group's own strip shows what is there.
            toast?.hideNow()
            tilingMenu.hide()
            return
        }
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

        // By default the layout goes where the first aimed window is, and the rest are carried
        // over to it. Optionally a layout wants a screen to itself: it fills the workspace, so
        // anything else living there would end up underneath it. Where it goes is then worked out
        // below; the windows that are not there yet are carried over.
        let separate = store.prefs.tileOnSeparateWorkspace
        let home = separate ? windows.last?.spaceID : windows.first?.spaceID
        var target = home
        let tiled = Set(windows.map(\.id))
        let strangersAtHome = separate && home.map { space in
            model.windows.contains { $0.spaceID == space && !$0.isMinimized && !tiled.contains($0.id) }
        } ?? false

        // Spanning workspaces is not itself a reason to go anywhere new: if the workspace the last
        // aimed window is on holds nothing but windows of this layout, the rest are carried over to
        // it. Only strangers there force the layout to look for a workspace of its own.
        if strangersAtHome {
            if let best = workspaceForLayout(of: windows, from: home) {
                // A workspace already holding nothing but windows of this layout is the cheapest
                // place for it: the rest are carried over to them. Failing that, the nearest one
                // with nothing on it — counted in the numbers the strip shows, which are the
                // numbers Mission Control shows.
                target = best.space
                Diagnostics.note("tiling on workspace \(model.workspaceNumber(ofSpace: best.space).map(String.init) ?? "?")"
                                 + " (space \(best.space)), which already holds \(best.holds) of them")
            } else {
                toast?.showCentred(title: "Tiled where they are",
                                   subtitle: "No workspace on this monitor is free for the layout, and macOS would not add one")
            }
        }

        guard let last = windows.last, let target else {
            finishTiling(windows, layout: layout)
            return
        }
        if !windows.contains(where: { $0.spaceID != target }), SpacesBridge.shared.isShowing(target) {
            finishTiling(windows, layout: layout)
            return
        }

        // The WindowServer moves what it is willing to move; a window of an application with
        // windows elsewhere is carried over by hand, as ⌥⇧N does, and the layout follows once it
        // is there.
        var stragglers: [ManagedWindow] = []
        if windows.contains(where: { $0.spaceID != target }) {
            let result = spaceMover.move(windows, to: target, queue: model.windows)
            model.relocate(result.arrived.map(\.id), toSpace: target)
            stragglers = result.leftBehind
        }
        guard stragglers.isEmpty || WindowDragMover.isCarrying else {
            let destination = target
            Diagnostics.note("tiling: carrying \(stragglers.count) window(s) to space \(destination) by hand")
            WindowDragMover.carry(stragglers, to: destination) { [weak self] carried in
                guard let self else { return }
                self.model.relocate(carried.map(\.id), toSpace: destination)
                self.gatherAndTile(windows, last: last, on: destination, layout: layout)
            }
            return
        }
        gatherAndTile(windows, last: last, on: target, layout: layout)
    }

    /// Goes to the layout's workspace, waits for the windows to be reachable there, and lays out
    /// the ones that made it.
    private func gatherAndTile(_ windows: [ManagedWindow], last: ManagedWindow, on target: UInt64,
                               layout: TileLayout) {
        // Go there, then give the windows time to show up in their apps' window lists: one that
        // arrived from, or still sits on, a workspace out of view has no accessibility element yet.
        // Focusing the last window takes us there when it is there itself — as the model now has
        // it, since the move may just have carried it; otherwise the carrier does, which the Dock
        // follows as it follows any activation.
        let lastNow = model.windows.first { $0.id == last.id } ?? last
        if lastNow.spaceID == target || SpacesBridge.shared.isShowing(target) {
            focus(lastNow, warpCursor: false)
        } else if !SpaceSwitcher.jump(toSpace: target), let index = model.workspaceNumber(ofSpace: target) {
            SpaceSwitcher.sendSystemShortcut(index: index)
        }
        let wanted = windows
        let destination = target
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            // Whatever is still elsewhere is asked to come here the other way: with the workspace
            // now in view, activating a window's application brings that one window over (where
            // macOS is set up for that — the mover checks).
            if SpacesBridge.shared.isShowing(destination) {
                let before = SpacesBridge.shared.spaces(forWindows: wanted.map(\.id))
                for window in wanted where before[window.id] != destination {
                    _ = self.spaceMover.pullToCurrentSpace(window)
                }
            }

            let now = SpacesBridge.shared.spaces(forWindows: wanted.map(\.id))
            // A window whose workspace cannot be read at all is taken at its word and tiled: it is
            // on screen, which is what the layout needs of it.
            var gathered = wanted.filter { now[$0.id] == nil || now[$0.id] == destination }
            self.model.relocate(gathered.map(\.id), toSpace: destination)
            if gathered.count < 2 {
                // Nothing was gained by travelling; the layout happens where the windows are.
                Diagnostics.note("tiling in place: only \(gathered.count) of \(wanted.count) reached \(destination)")
                gathered = wanted
            } else if gathered.count < wanted.count {
                let stranded = wanted.count - gathered.count
                Diagnostics.note("tiling without \(stranded) window(s) that would not move")
                self.toast?.showCentred(title: "Tiled \(gathered.count) windows",
                                        subtitle: "\(stranded) would not leave its workspace")
            }
            let ready = gathered.map { window -> ManagedWindow in
                var copy = window
                copy.element = WindowSpaceMover.element(for: window) ?? window.element
                return copy
            }
            self.enumerator?.refresh()
            self.finishTiling(ready, layout: layout)
        }
    }

    /// The best workspace on this monitor to put a layout on, and how many of its windows are there
    /// already.
    ///
    /// A workspace qualifies when everything on it is part of the layout: an empty one, or one that
    /// already holds some of these windows and nothing else. The more of them are there, the fewer
    /// have to travel, so that is what is preferred, and a tie goes to the nearest one. Each display
    /// owns its desktops, so only this monitor's are considered.
    private func workspaceForLayout(of windows: [ManagedWindow],
                                    from home: UInt64?) -> (space: UInt64, holds: Int)? {
        guard let home else { return nil }
        // This monitor's workspaces, in the order the user counts them — the strip's numbers and
        // Mission Control's are the same numbers, and "the next one along" has to mean that.
        let onThisDisplay = Set(SpacesBridge.shared.spacesSharingDisplay(with: home))
        let spaces = model.spaceOrder.filter { onThisDisplay.contains($0) }
        guard let origin = spaces.firstIndex(of: home) else { return nil }
        let tiled = Set(windows.map(\.id))

        var best: (space: UInt64, holds: Int, distance: Int)?
        for (index, space) in spaces.enumerated() where index != origin {
            let occupants = model.windows.filter { $0.spaceID == space && !$0.isMinimized }
            guard occupants.allSatisfy({ tiled.contains($0.id) }) else { continue }
            let candidate = (space: space, holds: occupants.count, distance: abs(index - origin))
            guard let current = best else {
                best = candidate
                continue
            }
            if candidate.holds > current.holds
                || (candidate.holds == current.holds && candidate.distance < current.distance) {
                best = candidate
            }
        }
        return best.map { (space: $0.space, holds: $0.holds) }
    }

    /// While a layout is being applied, the frame changes it causes are ours, not the user's.
    private var tilingSettledAt = Date.distantPast
    /// The order each group was last laid out in, to notice a reorder.
    private var tiledOrders: [Int: [CGWindowID]] = [:]
    /// The frames the layout gave them, to tell a real move from a notification about nothing.
    private var tiledFrames: [CGWindowID: NSRect] = [:]
    /// The workspace each group was laid out on. A window that turns up on another one has left
    /// the layout, however it got there.
    private var tiledHomes: [Int: UInt64] = [:]

    /// Makes sure every window has a live accessibility element before it is laid out: one kept from
    /// earlier may belong to a window since replaced, and an app that lists nothing leaves none.
    /// The slow way of finding one runs off the main thread; the layout waits for it.
    private func withReachableElements(_ windows: [ManagedWindow],
                                       then: @escaping ([ManagedWindow]) -> Void) {
        let snapshot = windows
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [CGWindowID: AXUIElement] = [:]
            let ready = snapshot.map { window -> ManagedWindow in
                var copy = window
                if let element = window.element, AXPrivate.windowID(of: element) == window.id { return copy }
                copy.element = AXPrivate.windowElement(pid: window.pid, id: window.id)
                if let element = copy.element { found[window.id] = element }
                return copy
            }
            DispatchQueue.main.async {
                if !found.isEmpty {
                    Diagnostics.note("tiling: found elements for \(found.count) window(s) the queue had none for")
                    self?.model.adoptElements(found)
                }
                then(ready)
            }
        }
    }

    private func finishTiling(_ windows: [ManagedWindow], layout: TileLayout) {
        withReachableElements(windows) { [weak self] ready in
            self?.placeTiling(ready, layout: layout)
        }
    }

    private func placeTiling(_ windows: [ManagedWindow], layout: TileLayout) {
        dropFocusFlash()
        // Only windows with an element can be placed; the layout is picked for the ones that can,
        // so a window that could not be reached does not leave a hole — and the user is told.
        let unreachable = windows.filter { $0.element == nil }
        let windows = windows.filter { $0.element != nil }
        if !unreachable.isEmpty {
            Diagnostics.note("tiling without \(unreachable.map { "\($0.appName) \($0.id)" }.joined(separator: ", ")): no element")
            toast?.showCentred(title: "Tiled \(windows.count) of \(windows.count + unreachable.count) windows",
                               subtitle: "\(unreachable.map(\.appName).joined(separator: ", ")) could not be reached")
        }
        let layout = windows.count == layout.frames.count
            ? layout
            : TileLayout.options(for: windows.count).first { $0.kind == layout.kind }
                ?? TileLayout.options(for: windows.count).first
        guard let layout else { return }
        let area = tilingArea()
        let gaps = WindowTiler.Gaps(prefs: store.prefs)
        let placed = WindowTiler.tile(windows, layout: layout, in: area, gaps: gaps)
        finishPlacing(placed, layout: layout)
    }

    private func finishPlacing(_ placed: [ManagedWindow], layout: TileLayout) {
        guard let first = placed.first else { return }
        WindowTiler.raise(placed)
        noteTiled(placed, layout: layout)
        model.select(id: first.id, announce: false)
        focus(first, warpCursor: false)
    }

    /// Remembers that these windows are holding a layout, and from when their frames are their own
    /// again — the tiler keeps correcting them for a moment after it places them.
    private func noteTiled(_ windows: [ManagedWindow], layout: TileLayout) {
        tilingSettledAt = Date().addingTimeInterval(2)
        // A window laid out in a group is no longer a maximized one: its place now comes from the
        // layout, and the size it had before it was ever maximized is no longer anything to go back
        // to — or, worse, to grow back into when the screen's room changes.
        for window in windows { framesBeforeMaximize.removeValue(forKey: window.id) }
        // Whichever layouts these windows came from are short of them now, and the windows still in
        // those layouts take the room the leavers gave up.
        let taken = Set(windows.map(\.id))
        let shorthanded = model.tiledGroups.filter { !$0.ids.filter(taken.contains).isEmpty }
        guard let group = model.setTiled(windows.map(\.id), layout: layout.name) else { return }
        relayout(shorthanded.map(\.id).filter { $0 != group.id })
        tiledOrders[group.id] = group.ids
        // Where the model has them now: the copies passed in can predate a move to this workspace.
        // A layout that could only be made across several workspaces has no home to leave, and is
        // not taken apart for being where it was made.
        let homes = Set(windows.compactMap { window in model.windows.first { $0.id == window.id }?.spaceID })
        tiledHomes[group.id] = homes.count == 1 ? homes.first : nil
        recordTiledFrames(windows)
    }

    /// Remembers where the windows came to rest, read once the tiler has finished its own
    /// corrections — anything else later is the user moving them.
    private func recordTiledFrames(_ windows: [ManagedWindow]) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            for window in windows where self.model.tiledIDs.contains(window.id) {
                self.tiledFrames[window.id] = WindowTiler.frame(of: window)
            }
        }
    }

    /// A window of a layout sent to another workspace has left it: the ones still there close up
    /// and take its room, and a single one left takes the whole screen.
    private func releaseTiledWindowsThatLeft() {
        for group in model.tiledGroups {
            guard let home = tiledHomes[group.id] else { continue }
            let members = model.tiledWindowsInQueueOrder(group)
            let leavers = Set(members.filter { $0.spaceID != nil && $0.spaceID != home }.map(\.id))
            guard !leavers.isEmpty else { continue }
            let staying = members.filter { !leavers.contains($0.id) }
            Diagnostics.note("tiled group \(group.id): \(leavers.count) window(s) left for another workspace, "
                             + "\(staying.count) stay")
            for id in leavers { tiledFrames[id] = nil }
            model.releaseFromTiled(leavers)
            if staying.count > 1 {
                relayout([group.id])
            } else {
                tiledOrders[group.id] = nil
                tiledHomes[group.id] = nil
                for window in staying {
                    tiledFrames[window.id] = nil
                    tilingSettledAt = Date().addingTimeInterval(2)
                    // Left alone by the others, not asked for: it grows in place without taking focus.
                    maximize(window, bringUp: false)
                }
            }
        }
    }

    /// Lays these groups out again for however many windows they have left.
    private func relayout(_ groupIDs: [Int]) {
        guard !groupIDs.isEmpty else { return }
        // After the windows that left have been placed, so the two layouts do not fight over the
        // same corrections.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            for id in groupIDs {
                guard let group = self.model.tiledGroups.first(where: { $0.id == id }) else { continue }
                let windows = self.model.tiledWindowsInQueueOrder(group)
                guard windows.count > 1,
                      let layout = TileLayout.options(for: windows.count).first(where: { $0.name == group.layout })
                        ?? TileLayout.options(for: windows.count).first
                else { continue }
                let placed = WindowTiler.tile(windows, layout: layout, in: self.tilingArea(of: windows),
                                              gaps: WindowTiler.Gaps(prefs: self.store.prefs))
                guard !placed.isEmpty else { continue }
                self.tilingSettledAt = Date().addingTimeInterval(2)
                self.tiledOrders[group.id] = placed.map(\.id)
                // The frames they had are gone; without the new ones, the next notification about
                // any of them would read as the user moving it and break the layout.
                self.recordTiledFrames(placed)
            }
        }
    }

    /// A window was resized or moved. If it was holding a layout and the change was not ours, the
    /// group is broken: the windows stay exactly where they are, they are simply free again.
    private func windowFrameChanged(_ element: AXUIElement) {
        guard Date() > tilingSettledAt, let id = AXPrivate.windowID(of: element),
              let group = model.tiledGroup(of: id),
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
        model.clearTiled(containing: id)
        tiledOrders[group.id] = nil
        for member in group.ids { tiledFrames[member] = nil }
    }

    /// The queue order of tiled windows decides their places in the layout, so moving one of them
    /// along the queue lays the group out again — the quickest way to say "this one is the main".
    private func retileIfOrderChanged() {
        for group in model.tiledGroups {
            let windows = model.tiledWindowsInQueueOrder(group)
            let order = windows.map(\.id)
            guard order.count > 1, order != tiledOrders[group.id] else { continue }
            // A window in fullscreen was put at the head of its workspace by the mode itself, not
            // by the user rearranging the queue; laying the group out again would drag it straight
            // back out of fullscreen. The new order is remembered for when it comes back.
            if let maximized = model.maximizedID, group.ids.contains(maximized) {
                tiledOrders[group.id] = order
                continue
            }
            guard let layout = TileLayout.options(for: windows.count).first(where: { $0.name == group.layout })
                ?? TileLayout.options(for: windows.count).first
            else { continue }
            let placed = WindowTiler.tile(windows, layout: layout, in: tilingArea(of: windows),
                                          gaps: WindowTiler.Gaps(prefs: store.prefs))
            guard !placed.isEmpty else { continue }
            noteTiled(placed, layout: layout)
        }
    }

    /// Starts recording this one window, or ends the recording running, and says which.
    private func toggleRecording(_ window: ManagedWindow?) {
        let capture = ScreenCapture.shared
        if !capture.isRecording {
            guard window != nil else { return }
            guard ScreenRecordingAccess.isGranted else {
                toast?.showCentred(title: "Screen Recording access needed",
                                   subtitle: "System Settings › Privacy & Security › Screen Recording")
                return
            }
        }
        let combo = store.prefs.combo(for: .toggleRecording).displayString
        capture.toggleRecording(window) { [weak self] started, url in
            guard let self else { return }
            if started {
                self.toast?.showCentred(title: "Recording \(window?.appName ?? "the window")",
                                        subtitle: "\(combo) stops it and saves the file")
            } else if let url {
                self.toast?.showCentred(title: "Recording saved",
                                        subtitle: url.deletingPathExtension().lastPathComponent)
            } else {
                self.toast?.showCentred(title: "Recording didn't start",
                                        subtitle: "The window could not be recorded")
            }
        }
    }

    /// The one window aiming mode points at: the one under the aim cursor, else the first aimed.
    private var aimedWindow: ManagedWindow? {
        let aimed = model.aimedWindows
        return aimed.first { $0.id == model.aimingID } ?? aimed.first
    }

    /// Takes a picture of this one window alone, and says whether it was written.
    private func screenshot(_ window: ManagedWindow?) {
        guard let window else { return }
        guard ScreenRecordingAccess.isGranted else {
            toast?.showCentred(title: "Screen Recording access needed",
                               subtitle: "System Settings › Privacy & Security › Screen Recording")
            return
        }
        // Brought forward first, so the picture shows it as it looks in front.
        window.element?.perform(kAXRaiseAction)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let written = ScreenCapture.shared.screenshot(window)
            guard let self else { return }
            guard let written else {
                self.toast?.showCentred(title: "Nothing captured",
                                        subtitle: "The window could not be photographed")
                return
            }
            self.toast?.showCentred(title: "Screenshot saved",
                                    subtitle: written.deletingLastPathComponent().lastPathComponent)
        }
    }

    /// Turns invisible mode on or off, says which it now is, and gives the windows the room back —
    /// or takes it away — since the strip's reservation has just changed.
    private func toggleInvisibleStrip() {
        store.prefs.invisibleStrip.toggle()
        let hidden = store.prefs.invisibleStrip
        let combo = store.prefs.combo(for: .toggleInvisibleStrip).displayString
        toast?.showCentred(title: hidden ? "Strip hidden" : "Strip shown",
                           subtitle: hidden
                               ? "\(combo) brings it back; aiming mode shows it meanwhile"
                               : "\(combo) hides it again")
        dockReservation.update()
        RectangleIntegration.applyAndReloadIfNeeded(prefs: store.prefs)
        // The reservation reaches the WindowServer and comes back as a new visible frame a moment
        // later; laying the windows out before that would measure the screen as it just was.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refitPlacedWindows()
        }
    }

    /// Lays out again everything WindowQueue placed — the tiled groups and a fullscreen window — so
    /// they match the room now on offer.
    private func refitPlacedWindows() {
        let gaps = WindowTiler.Gaps(prefs: store.prefs)
        for group in model.tiledGroups {
            let windows = model.tiledWindowsInQueueOrder(group)
            guard windows.count > 1,
                  let layout = TileLayout.options(for: windows.count).first(where: { $0.name == group.layout })
                    ?? TileLayout.options(for: windows.count).first
            else { continue }
            // A window held fullscreen fills the screen on its own; it is refitted below.
            if let maximized = model.maximizedID, group.ids.contains(maximized) { continue }
            let placed = WindowTiler.tile(windows, layout: layout, in: tilingArea(of: windows), gaps: gaps)
            guard !placed.isEmpty else { continue }
            noteTiled(placed, layout: layout)
        }
        if let id = model.maximizedID, let window = model.windows.first(where: { $0.id == id }) {
            WindowTiler.fill(window, in: tilingArea(of: [window]), gaps: gaps)
        }

        // Windows that were maximized and have not been touched since are still where WindowQueue
        // put them, so they take the new room too. One the user has moved or resized is theirs
        // again, and is left exactly as they left it.
        let tiled = Set(model.tiledGroups.flatMap(\.ids))
        for window in model.windows where window.id != model.maximizedID {
            // Windows held in a layout were laid out above; filling one would break its group.
            guard !tiled.contains(window.id),
                  framesBeforeMaximize[window.id] != nil,
                  let current = WindowTiler.frame(of: window)
            else { continue }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let inAX = CGRect(x: current.minX, y: primaryHeight - current.maxY,
                              width: current.width, height: current.height)
            guard WindowTiler.placed(window.id, at: inAX) else { continue }
            WindowTiler.fill(window, in: tilingArea(of: [window]), gaps: gaps)
        }
    }

    /// The screen being worked on, less the room the strip keeps for itself.
    private func tilingArea() -> NSRect {
        tilingArea(on: NSScreen.main ?? NSScreen.screens.first)
    }

    /// The room on the screen these windows are on (the first one's, for a group spread over
    /// several). Laying out windows already placed must keep them on their own monitor: the
    /// focused screen would pull a group or a maximized window on another one over to it.
    private func tilingArea(of windows: [ManagedWindow]) -> NSRect {
        for window in windows {
            guard let frame = WindowTiler.frame(of: window) ?? WindowTiler.serverFrame(of: window.id),
                  let screen = Monitors.screen(containing: frame)
            else { continue }
            return tilingArea(on: screen)
        }
        return tilingArea()
    }

    /// That screen less the room the strip keeps for itself.
    private func tilingArea(on screen: NSScreen?) -> NSRect {
        let prefs = store.prefs
        // The room the strip keeps is taken off here, so the screen has to be measured without the
        // reservation that keeps it — otherwise it is subtracted twice.
        var area = screen.map { DockReservation.unreservedFrame(of: $0, prefs: prefs) } ?? .zero
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
            case .moveToEmptySpace:
                moveToEmptySpace()
                return
            case _ where action.isMoveToMonitor:
                moveWindows(toMonitor: action.moveMonitorIndex)
                return
            // Fullscreen hides every other window of its workspace, so several windows cannot each
            // be the one on top: the aim stays as it is and nothing happens.
            case .toggleMaximize where model.aimedWindows.count > 1:
                toast?.showCentred(title: "Fullscreen takes one window",
                                   subtitle: "Aim at a single window, or tile the group with Return")
                return
            // Anything that makes sense window by window is applied to every aimed window. (The
            // `where` would only bind to the last pattern, so the count is checked in the body.)
            case .toggleGroup:
                toggleGroup()
                return
            case .toggleGroupLock:
                toggleGroupLock()
                return
            // Showing or hiding the strip is about the strip, not about the aimed window: the mode
            // stays open, with the strip appearing or folding away under the aim.
            case .toggleInvisibleStrip:
                toggleInvisibleStrip()
                return
            // Recording and pictures are of the one window aimed at, never the whole screen.
            case .toggleRecording:
                let window = aimedWindow
                endAiming(commit: false)
                toggleRecording(window)
                return
            case .screenshotWindow:
                let window = aimedWindow
                endAiming(commit: false)
                screenshot(window)
                return
            // A run of aimed windows is decluttered among themselves; a single aim means the lot.
            case .declutter:
                let aimed = model.aimedWindows
                endAiming(commit: false)
                declutter(aimed.count > 1 ? aimed : nil)
                return
            // Both hand the keyboard to something else, so the mode ends first and takes its grab
            // with it — a launcher that cannot be typed into is no launcher.
            case .openLauncher, .openRaycastCommand, .showOverview:
                endAiming(commit: false)
            case .maximizeWindow, .minimizeWindow, .closeWindow, .moveToStart, .moveToEnd:
                if model.aimedWindows.count > 1 {
                    applyToAimedGroup(action)
                    return
                }
                // One window aimed at: the action is about that one, not about whatever happens to
                // be focused, so the aim becomes the selection before the mode ends.
                let aimed = model.aimedWindows.first
                endAiming(commit: false)
                if let aimed { model.select(id: aimed.id, announce: false) }
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
            return
        }

        if action.isMoveToMonitor {
            moveWindows(toMonitor: action.moveMonitorIndex)
            return
        }

        if action.isMonitorAction {
            focusMonitor(action.focusMonitorIndex)
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
        case .declutter:
            declutter(nil)
        case .toggleGroup:
            toggleGroup()
        case .toggleGroupLock:
            toggleGroupLock()
        case .closeWindow:
            closeSelectedWindow()
        case .search:
            search?.toggle()
        case .openLauncher:
            noteLaunch()
            SystemLaunchers.open(store.prefs.launcher)
        case .openRaycastCommand:
            noteLaunch()
            SystemLaunchers.openCommand(store.prefs.raycastCommand, fallback: store.prefs.launcher)
        case .goToEmptySpace:
            goToEmptySpace()
        case .moveToEmptySpace:
            moveToEmptySpace()
        case .showOverview:
            SystemLaunchers.showMissionControl()
        case .toggleInvisibleStrip:
            toggleInvisibleStrip()
        case .toggleRecording:
            toggleRecording(model.selectedWindow)
        case .screenshotWindow:
            screenshot(model.selectedWindow)
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
    /// The monitor `focusMonitor` last sent only the pointer to, and the selection then.
    private var pointerOnlyMonitor: (display: CGDirectDisplayID, selectedID: CGWindowID?)?

    /// Groups the aimed windows, or breaks up the group the selection is in.
    private func toggleGroup() {
        if model.aimingID != nil {
            let aimed = model.aimedWindows
            guard aimed.count > 1 else {
                toast?.showCentred(title: "Aim at two or more windows to group them",
                                   subtitle: "Shift-click or Shift with the arrows")
                return
            }
            endAiming(commit: false)
            guard let group = model.makeGroup(aimed.map(\.id)) else { return }
            model.select(id: aimed[0].id, announce: false)
            announceGroup("Grouped \(aimed.count) windows as group \(group.id)")
            return
        }
        guard let selected = model.selectedID, let group = model.group(of: selected) else {
            toast?.showCentred(title: "Nothing to ungroup",
                               subtitle: "Select a window in a group, or aim at several to make one")
            return
        }
        let count = group.ids.count
        model.ungroup(containing: selected)
        announceGroup("Ungrouped \(count) windows")
    }

    /// Locks cycling to the selected window's group — while aiming, the group the aim is on or in —
    /// or lifts the lock.
    private func toggleGroupLock() {
        if model.lockedGroupID == nil, model.aimingID != nil {
            let group = model.aimedGroup ?? model.aimInsideGroupID.flatMap { id in model.groups.first { $0.id == id } }
                ?? model.aimingID.flatMap { model.group(of: $0) }
            guard let group, let first = model.members(of: group).first else {
                toast?.showCentred(title: "Nothing to lock", subtitle: "Aim at a group to lock cycling to it")
                return
            }
            endAiming(commit: false)
            model.select(id: first.id, announce: false)
        }
        let wasLocked = model.lockedGroupID
        if let group = model.toggleGroupLock() {
            announceGroup("Cycling locked to group \(group.id)")
        } else if let wasLocked {
            announceGroup("Unlocked group \(wasLocked)")
        } else {
            toast?.showCentred(title: "Nothing to lock",
                               subtitle: "Select a window in a group to lock cycling to it")
        }
    }

    /// While a tiled window's icon is dragged along the strip, shows the cell it would take if it
    /// were dropped there: the group is laid out in queue order, so the drop decides the place.
    private func previewTilePlacement(of window: ManagedWindow?, at target: Int) {
        guard let window, let group = model.tiledGroup(of: window.id) else {
            tilePreview.hide()
            return
        }
        // The queue as the drop would leave it.
        var order = model.visibleWindows
        guard let origin = order.firstIndex(where: { $0.id == window.id }) else { return }
        let moved = order.remove(at: origin)
        order.insert(moved, at: min(max(target, 0), order.count))

        let ids = Set(group.ids)
        let members = order.filter { ids.contains($0.id) }
        guard let place = members.firstIndex(where: { $0.id == window.id }),
              let layout = TileLayout.options(for: members.count).first(where: { $0.name == group.layout })
                ?? TileLayout.options(for: members.count).first,
              layout.frames.indices.contains(place)
        else {
            tilePreview.hide()
            return
        }
        let unit = layout.frames[place]
        let area = tilingArea(of: members).insetBy(dx: CGFloat(store.prefs.tileOuterGap), dy: CGFloat(store.prefs.tileOuterGap))
        let gap = CGFloat(store.prefs.tileInnerGap) / 2
        // Layout rects run from the top down; screen coordinates run from the bottom up.
        let cell = NSRect(x: area.minX + unit.minX * area.width,
                          y: area.maxY - (unit.minY + unit.height) * area.height,
                          width: unit.width * area.width,
                          height: unit.height * area.height)
        tilePreview.show(cell.insetBy(dx: gap, dy: gap), animated: store.prefs.animates(.windowOutlines))
    }

    /// Keeps the panel beside the strip in step: the open group, or the one the pointer rests on.
    private func syncGroupPanel() {
        // While aiming, the group the aim is on shows its windows too, so it is plain what stepping
        // into it would offer.
        let aimed = model.aimedGroup ?? model.aimInsideGroupID.flatMap { id in model.groups.first { $0.id == id } }
        // Invisible mode hides the strip outside aiming, and a group's strip on its own — with no
        // strip to carry on from — is not a thing to leave on screen.
        let hiddenUntilAiming = store.prefs.invisibleStrip && model.aimingID == nil
        guard !hiddenUntilAiming, let group = model.openGroup ?? aimed else {
            groupPanel.hide()
            strip?.companionLength = 0
            strip?.isReplacedByGroup = false
            return
        }
        let windows = model.members(of: group)
        let prefs = store.prefs
        let covered: Set<CGWindowID> = prefs.focusMaximizedWindow && prefs.collapseCoveredWindows
            ? Set(windows.filter { model.isCovered($0) }.map(\.id))
            : []
        // The main strip gives up the room first, so both are laid out in their final places.
        // Only the strip the aim is on grows, so this one follows the aim into the group.
        let aiming = model.aimingID != nil && model.aimInsideGroupID == group.id
        // Replacing the main strip is for being inside the group; a group the aim only rests on
        // opens over its entry instead, so the strip the aim is walking stays in view.
        let inside = model.aimingID != nil ? model.aimInsideGroupID == group.id : model.openGroupID == group.id
        let placement: GroupPanelController.Placement
        switch prefs.groupStripPlacement {
        case .automatic, .before, .after: placement = .beside
        case .replace where inside: placement = .replacing
        case .replace, .overGroup: placement = windows.first.map { .over($0.id) } ?? .beside
        }
        let replacing = placement == .replacing && windows.count > 1
        strip?.isReplacedByGroup = replacing
        strip?.companionLength = placement == .beside
            ? groupPanel.length(for: windows, covered: covered, aiming: aiming) : 0
        groupPanel.show(number: group.id, windows: windows, selected: model.selectedID,
                        peek: model.openGroup == nil,
                        aimingID: model.aimingID, aimedIDs: model.aimedIDs, coveredIDs: covered,
                        maximizedID: model.maximizedID,
                        tiledNumbers: tiledNumbers(for: windows),
                        showsTiledNumbers: model.tiledGroups.count > 1,
                        locked: model.lockedGroupID == group.id,
                        aiming: aiming, placement: placement)
    }

    /// The layout each of those windows is held in, for the marks in the group's strip.
    private func tiledNumbers(for windows: [ManagedWindow]) -> [CGWindowID: Int] {
        var out: [CGWindowID: Int] = [:]
        for window in windows {
            if let group = model.tiledGroup(of: window.id) { out[window.id] = group.id }
        }
        return out
    }

    /// Runs an action over every aimed window at once, then leaves aiming mode.
    private func applyToAimedGroup(_ action: HotkeyAction) {
        let group = model.aimedWindows
        guard group.count > 1 else { return }
        // What was selected before aiming: the aim never moved it, and acting on a run of windows
        // is no reason to move it either.
        let selected = model.selectedWindow
        endAiming(commit: false)
        let count = group.count
        switch action {
        case .maximizeWindow:
            // One after another, so an app that snaps its own frame does not fight the next one.
            for window in group { maximize(window, bringUp: false) }
            // The selection stays where it was and comes up on top; bringing up the first aimed
            // window instead would hand it the focus, and the selection would follow.
            if let selected { bringUp(selected) }
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

    /// Moves and, where it has to, shrinks windows so that none of them covers another, leaving
    /// each as close to where and how big it was as it can. With nil, every window on screen right
    /// now is decluttered, each screen on its own; otherwise just these, among themselves.
    private func declutter(_ chosen: [ManagedWindow]?) {
        let onScreen = WindowTiler.onScreenWindowIDs()
        let candidates = (chosen ?? model.windows).filter { !$0.isMinimized && onScreen.contains($0.id) }
        guard candidates.count > 1 else {
            toast?.showCentred(title: "Nothing to declutter", subtitle: "Fewer than two windows on screen")
            return
        }
        withReachableElements(candidates) { [weak self] ready in
            self?.placeDecluttered(ready.filter { $0.element != nil })
        }
    }

    private func placeDecluttered(_ windows: [ManagedWindow]) {
        dropFocusFlash()
        let gaps = WindowTiler.Gaps(prefs: store.prefs)
        var byScreen: [Int: [(window: ManagedWindow, frame: NSRect)]] = [:]
        for window in windows {
            guard let frame = WindowTiler.frame(of: window) ?? WindowTiler.serverFrame(of: window.id),
                  let screen = NSScreen.screens.indices.max(by: {
                      Self.overlapArea(NSScreen.screens[$0].frame, frame) < Self.overlapArea(NSScreen.screens[$1].frame, frame)
                  })
            else { continue }
            byScreen[screen, default: []].append((window, frame))
        }

        var moved: [ManagedWindow] = []
        for (screen, entries) in byScreen {
            let area = tilingArea(on: NSScreen.screens[screen]).insetBy(dx: gaps.outer, dy: gaps.outer)
            let frames = Declutter.arrange(entries.map(\.frame), in: area, gap: max(gaps.inner, 0))
            for (entry, target) in zip(entries, frames) where !WindowTiler.matches(entry.frame, target) {
                // A window given a new place by hand is no longer the fullscreen or maximized one.
                if model.maximizedID == entry.window.id { model.endFocus() }
                framesBeforeMaximize.removeValue(forKey: entry.window.id)
                // Nor part of a layout: the group is freed where it stands, as a move by hand frees it.
                if let group = model.tiledGroup(of: entry.window.id) {
                    model.clearTiled(containing: entry.window.id)
                    tiledOrders[group.id] = nil
                    for member in group.ids { tiledFrames[member] = nil }
                }
                WindowTiler.restore(entry.window, to: target)
                moved.append(entry.window)
            }
        }
        Diagnostics.note("declutter: moved \(moved.count) of \(windows.count) windows")
        if moved.isEmpty {
            toast?.showCentred(title: "Nothing to declutter", subtitle: "Every window is already in view")
        } else {
            announceGroup("Decluttered \(moved.count) of \(windows.count) windows")
        }
    }

    private static func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let common = a.intersection(b)
        return common.isNull ? 0 : common.width * common.height
    }

    /// Fills the screen with the selected window, less the strip's room. Nothing else changes: no
    /// way back through the same shortcut, and the rest of the workspace stays where it is.
    private func maximizeWindow() {
        guard let window = model.selectedWindow else { return }
        maximize(window)
    }

    private func maximize(_ window: ManagedWindow, bringUp: Bool = true) {
        dropFocusFlash()
        var window = window
        window.element = window.element ?? WindowSpaceMover.element(for: window)
        // Its old frame is still worth keeping: the fullscreen shortcut can put it back later.
        if framesBeforeMaximize[window.id] == nil {
            framesBeforeMaximize[window.id] = WindowTiler.frame(of: window)
        }
        WindowTiler.fill(window, in: tilingArea(of: [window]), gaps: WindowTiler.Gaps(prefs: store.prefs))
        if bringUp { self.bringUp(window) }
    }

    /// Puts a window just filled to the screen in front with the keyboard: maximizing or sending
    /// fullscreen something left behind another window would change nothing anyone can see. No
    /// cursor warp or outline — the window now covers the screen, so there is nothing to point out.
    private func bringUp(_ window: ManagedWindow) {
        guard !WindowFocuser.isFocused(window) else { return }
        WindowFocuser.focus(window,
                            workspaceIndex: model.workspaceNumber(of: window),
                            siblingCount: model.windows.count { $0.pid == window.pid })
    }

    /// Fills the screen with the selected window, less the strip's room; again restores it.
    private func toggleMaximize() {
        guard var window = model.selectedWindow else { return }
        dropFocusFlash()
        window.element = window.element ?? WindowSpaceMover.element(for: window)
        let area = tilingArea(of: [window])

        // Fullscreen is a toggle, not a new arrangement: a window in a layout keeps its place in
        // it, goes fullscreen over the top, and comes back to it. Neither step frees the group.
        tilingSettledAt = Date().addingTimeInterval(2)

        let current = WindowTiler.frame(of: window)
        Diagnostics.note("fullscreen \(window.appName) id=\(window.id) element=\(window.element != nil) frame=\(current.map { "\($0)" } ?? "nil") area=\(area) stored=\(framesBeforeMaximize[window.id].map { "\($0)" } ?? "none")")

        if let previous = framesBeforeMaximize[window.id],
           let frame = WindowTiler.frame(of: window), Self.fills(frame, area) {
            framesBeforeMaximize[window.id] = nil
            WindowTiler.restore(window, to: previous)
            model.endFocus()
            return
        }
        framesBeforeMaximize[window.id] = WindowTiler.frame(of: window)
        WindowTiler.fill(window, in: area, gaps: WindowTiler.Gaps(prefs: store.prefs))
        bringUp(window)
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

        Diagnostics.note("close \(window.appName) id=\(window.id) space=\(window.spaceID.map(String.init) ?? "none") "
                         + "current=\(model.currentSpaceID.map(String.init) ?? "none") "
                         + "successor=\(successor.map { "\($0.appName) \($0.id)" } ?? "none")")
        WindowCloser.close(window,
                           workspaceIndex: model.workspaceNumber(of: window),
                           siblingCount: model.windows.count { $0.pid == window.pid })

        if let successor { model.select(id: successor.id, announce: false) }
        // Closing the last window here leaves an empty workspace, and macOS likes to answer that by
        // activating some other application — which, with switching-on-activate off, can carry us
        // somewhere else entirely. The user closed a window; they did not ask to travel.
        if onCurrentSpace, successor == nil, let here = model.currentSpaceID {
            holdSpace = (here, Date().addingTimeInterval(2))
            Diagnostics.note("holding workspace \(here) after closing its last window")
        }
        // Closing the last window of a workspace can make macOS move another one here, and that has
        // to show up in the queue rather than leaving the strip claiming the workspace is empty.
        for delay in [0.4, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enumerator?.refresh()
            }
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
        raiseLayoutOnceFocused(window.id)
        flashFocus(window)
    }

    /// Counts layout raises asked for, so one still waiting for its focus to land stands down when
    /// focus has moved on meanwhile.
    private var layoutRaiseRequest = 0

    /// Brings a whole layout forward when one of its windows is focused: the windows were arranged
    /// to be looked at together, and picking one of them should not leave the rest behind another
    /// app. The focused window is raised last, so it stays the one on top.
    ///
    /// Waits for the focus to actually land — a jump to another workspace, or an app slow to
    /// answer, takes a moment, and windows raised before that are raised on a desktop not in view
    /// or buried again by the focus arriving after them.
    private func raiseLayoutOnceFocused(_ id: CGWindowID?) {
        layoutRaiseRequest &+= 1
        guard let id, model.tiledGroup(of: id) != nil else { return }
        raiseLayout(of: id, attempt: 0, raises: 0, request: layoutRaiseRequest)
    }

    private func raiseLayout(of id: CGWindowID, attempt: Int, raises: Int, request: Int) {
        guard request == layoutRaiseRequest, attempt < 40,
              let window = model.windows.first(where: { $0.id == id }),
              let group = model.tiledGroup(of: id)
        else { return }
        let retry = { [weak self] (delay: TimeInterval, raises: Int) in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                self?.raiseLayout(of: id, attempt: attempt + 1, raises: raises, request: request)
            }
        }
        let spaces = SpacesBridge.shared.allSpaces(forWindow: id)
        let spaceInView = spaces.isEmpty || spaces.contains { SpacesBridge.shared.isShowing($0) }
        guard spaceInView, SpaceSwitcher.destination == nil,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
        else { return retry(0.1, raises) }

        // Only the ones on the workspace in view: raising a window that lives elsewhere would drag
        // its workspace, or the window itself, into what the user is looking at.
        let members = model.tiledWindowsInQueueOrder(group).filter {
            !$0.isMinimized && ($0.id == id || ($0.spaceID != nil && $0.spaceID == window.spaceID))
        }
        guard members.count > 1, !WindowTiler.coveredWindowIDs(among: Set(members.map(\.id)),
                                                                ownPIDs: Set(members.map(\.pid)),
                                                                queued: Set(model.windows.map(\.id))).isEmpty else { return }
        // Some apps order a window forward only on a second ask, or a moment after the first one
        // has been answered: look again shortly, and ask again if the layout is still buried.
        guard raises < 3 else {
            Diagnostics.note("layout of \(id) still covered after \(raises) raises")
            return
        }
        Diagnostics.note("raise layout of \(window.appName) id=\(id) (\(members.count) windows)")
        WindowTiler.raise(members.filter { $0.id != id })
        (window.element ?? WindowSpaceMover.element(for: window))?.perform(kAXRaiseAction)
        retry(0.25, raises + 1)
    }

    /// Outlines the window focus just landed on, so it is plain which one took it — the same mark
    /// aiming uses, in the selection's colour, for a moment.
    private func flashFocus(_ window: ManagedWindow) {
        guard store.prefs.flashFocusedWindow, store.prefs.flashFocusedWindowDuration > 0 else { return }
        // A window already here is marked at once. One on another workspace is marked when the
        // travel is over — the switch animation takes as long as it takes, and an outline drawn
        // while it runs is spent before the window is even on screen. So: wait for the workspace to
        // actually be the one in view, and give up if it never is.
        focusMarkRequest &+= 1
        markFocus(window.id, attempt: 0, request: focusMarkRequest)
    }

    /// Counts focus outlines asked for, so one still waiting for its window's workspace to arrive
    /// stands down when the window is resized — or another outline is asked for — meanwhile.
    private var focusMarkRequest = 0

    /// Drops the focus outline, drawn or still waiting to be: the window's frame is about to change,
    /// and an outline of where it was is an outline of nothing.
    private func dropFocusFlash() {
        focusMarkRequest &+= 1
        aimHighlight.cancelFlash()
    }

    private func markFocus(_ id: CGWindowID, attempt: Int, request: Int) {
        guard request == focusMarkRequest, model.aimingID == nil, let window = model.windows.first(where: { $0.id == id }) else { return }
        // On screen is not enough: the window of the workspace being switched to is listed as on
        // screen from the first frame of the slide, and an outline drawn then stays put while the
        // desktops move underneath it. The workspace only counts as in view once it is the current
        // one, which the WindowServer makes it at the end of the slide.
        let spaces = SpacesBridge.shared.allSpaces(forWindow: id)
        let spaceInView = spaces.isEmpty || spaces.contains { SpacesBridge.shared.isShowing($0) }
        if spaceInView, WindowTiler.onScreenWindowIDs().contains(id) {
            // Arrived after a switch: let the last frame of the slide go by, so the outline lands
            // on the window where it rests rather than on the desktop still sliding in.
            if attempt > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.markFocus(id, attempt: 0, request: request)
                }
                return
            }
            aimHighlight.flash(window, for: store.prefs.flashFocusedWindowDuration,
                               fading: store.prefs.animates(.windowOutlines))
            return
        }
        guard attempt < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.markFocus(id, attempt: attempt + 1, request: request)
        }
    }

    /// Sends the selected window — or every aimed window, while aiming — to a workspace, and takes
    /// the user there with it: the window is what they were working on. The WindowServer moves
    /// what it will; a window it would only move along with the rest of its app, while that app has
    /// windows elsewhere, is held by its title bar while the desktop changes, as a person would.
    private func moveWindows(toWorkspace index: Int) {
        let windows = model.aimingID != nil ? model.aimedWindows : model.selectedWindow.map { [$0] } ?? []
        if model.aimingID != nil { endAiming(commit: false) }
        let spaces = SpacesBridge.shared.userSpaceIDs
        guard !windows.isEmpty, spaces.indices.contains(index - 1), spaceMover.isAvailable,
              !WindowDragMover.isCarrying
        else { return }

        let target = spaces[index - 1]
        let result = spaceMover.move(windows, to: target, queue: model.windows)
        model.relocate(result.arrived.map(\.id), toSpace: target)

        let done = { [weak self] (moved: [ManagedWindow], stayed: [ManagedWindow]) in
            guard let self else { return }
            // Follow the windows: the first of them, as the model now has it, is focused there —
            // which is also what takes the user to the workspace, if the carry has not already.
            let movedIDs = Set(moved.map(\.id))
            if let lead = windows.first(where: { movedIDs.contains($0.id) })
                .flatMap({ lead in self.model.windows.first { $0.id == lead.id } }) {
                self.model.select(id: lead.id, announce: false)
                self.focus(lead)
            }
            if let kept = stayed.first {
                let others = stayed.count > 1 ? " and \(stayed.count - 1) more" : ""
                self.toast?.show(title: "\(kept.appName) stayed where it was\(others)",
                                 subtitle: "It could not be moved to workspace \(index)", beside: kept.id)
            } else if let first = windows.first {
                self.toast?.show(title: windows.count == 1 ? first.displayTitle : "\(windows.count) windows",
                                 subtitle: "Moved to workspace \(index)", beside: first.id)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.enumerator?.refresh()
            }
        }

        guard !result.leftBehind.isEmpty else {
            done(result.arrived, [])
            return
        }
        Diagnostics.note("moving \(result.leftBehind.count) window(s) to workspace \(index) by holding it through the switch")
        WindowDragMover.carry(result.leftBehind, to: target) { [weak self] carried in
            guard let self else { return }
            self.model.relocate(carried.map(\.id), toSpace: target)
            let carriedIDs = Set(carried.map(\.id))
            done(result.arrived + carried, result.leftBehind.filter { !carriedIDs.contains($0.id) })
        }
    }

    /// Sends the selected window — or every aimed window — to monitor `number` (counted left to
    /// right), or with nil to the monitor after the one it is on, going round all of them. Each
    /// keeps its place and size relative to the room the screen has, so a half stays a half and a
    /// maximized window fills the other screen; focus follows it there.
    private func moveWindows(toMonitor number: Int?) {
        let windows = model.aimingID != nil ? model.aimedWindows : model.selectedWindow.map { [$0] } ?? []
        if model.aimingID != nil { endAiming(commit: false) }
        guard store.prefs.multiMonitorMode, !windows.isEmpty, !WindowDragMover.isCarrying else { return }
        let screens = Monitors.orderedScreens
        guard screens.count > 1 else {
            toast?.showCentred(title: "Only one monitor", subtitle: "There is nowhere else to move the window")
            return
        }
        if let number, !screens.indices.contains(number - 1) {
            toast?.showCentred(title: "No monitor \(number)", subtitle: "Monitors are counted left to right; there are \(screens.count)")
            return
        }

        var windowsWithFrames: [(window: ManagedWindow, frame: NSRect, source: NSScreen)] = []
        for var window in windows {
            window.element = window.element ?? WindowSpaceMover.element(for: window)
            guard window.element != nil,
                  let frame = WindowTiler.frame(of: window) ?? WindowTiler.serverFrame(of: window.id),
                  let source = Monitors.screen(containing: frame)
            else { continue }
            windowsWithFrames.append((window, frame, source))
        }
        guard let lead = windowsWithFrames.first else { return }
        let targetIndex: Int
        if let number {
            targetIndex = number - 1
        } else {
            let from = screens.firstIndex(of: lead.source) ?? 0
            targetIndex = (from + 1) % screens.count
        }
        let target = screens[targetIndex]
        let targetArea = tilingArea(on: target)

        var moved: [ManagedWindow] = []
        for (window, frame, source) in windowsWithFrames where source != target {
            relocate(window, frame: frame, from: source, toArea: targetArea)
            moved.append(window)
        }
        Diagnostics.note("moved \(moved.count) window(s) to monitor \(targetIndex + 1)")
        guard let first = moved.first else {
            toast?.showCentred(title: "Already on monitor \(targetIndex + 1)", subtitle: lead.window.displayTitle)
            return
        }
        if Monitors.displayID(of: target) != Monitors.displayID(of: lead.source) { markMonitor(target) }
        model.select(id: first.id, announce: false)
        focus(first)
        toast?.show(title: moved.count == 1 ? first.displayTitle : "\(moved.count) windows",
                    subtitle: "Moved to monitor \(targetIndex + 1)", beside: first.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enumerator?.refresh()
        }
    }

    /// Puts a window at the same place relative to another screen's room; one filling its screen
    /// fills the other.
    private func relocate(_ window: ManagedWindow, frame: NSRect, from source: NSScreen, toArea targetArea: NSRect) {
        let sourceArea = tilingArea(on: source)
        if Self.fills(frame, sourceArea) {
            framesBeforeMaximize[window.id] = nil
            WindowTiler.fill(window, in: targetArea, gaps: WindowTiler.Gaps(prefs: store.prefs))
        } else {
            WindowTiler.restore(window, to: Self.map(frame, from: sourceArea, to: targetArea))
        }
    }

    /// The monitor worked on: the selected window's, as the key screen lags behind (or never
    /// follows) focus that is slow to land — or the one the pointer was last sent to empty-handed.
    private func workedOnDisplay() -> CGDirectDisplayID? {
        if let pointed = pointerOnlyMonitor, pointed.selectedID == model.selectedID { return pointed.display }
        return model.selectedWindow.flatMap(model.monitorID(of:)) ?? NSScreen.main.flatMap(Monitors.displayID(of:))
    }

    // MARK: - Launching onto the monitor worked on

    /// Where a launcher was opened from. macOS puts an app's new window on the screen the app last
    /// used (or the launcher's), so the next window to open is brought to the monitor worked on.
    private var launchTarget: (display: CGDirectDisplayID, at: Date)?

    private func noteLaunch() {
        launchTarget = NSScreen.screens.count > 1 ? workedOnDisplay().map { ($0, Date()) } : nil
    }

    private func placeLaunched(_ arrived: [ManagedWindow], attempt: Int = 0) {
        guard let target = launchTarget else { return }
        guard Date().timeIntervalSince(target.at) < 20 else {
            launchTarget = nil
            return
        }
        guard var window = arrived.first(where: { !$0.isMinimized }) else { return }
        launchTarget = nil
        window.element = window.element ?? WindowSpaceMover.element(for: window)
        guard window.element != nil,
              let frame = WindowTiler.frame(of: window) ?? WindowTiler.serverFrame(of: window.id),
              let source = Monitors.screen(containing: frame),
              let screen = NSScreen.screens.first(where: { Monitors.displayID(of: $0) == target.display })
        else {
            // A window just made may not answer yet; give it a moment once.
            if attempt == 0 {
                launchTarget = target
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    self?.placeLaunched([window], attempt: 1)
                }
            }
            return
        }
        guard source != screen else { return }
        Diagnostics.note("launched \(window.appName) id=\(window.id) opened on \(source.localizedName), "
                         + "moving to \(screen.localizedName)")
        relocate(window, frame: frame, from: source, toArea: tilingArea(on: screen))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enumerator?.refresh()
        }
    }

    /// Goes to monitor `number` (counted left to right), or with nil to the one after the focused
    /// one: focus lands on the window on top there, so that monitor's strip is the one worked on.
    /// A monitor with nothing on show gets the pointer instead.
    private func focusMonitor(_ number: Int?) {
        guard store.prefs.multiMonitorMode else { return }
        let screens = Monitors.orderedScreens
        guard screens.count > 1 else {
            toast?.showCentred(title: "Only one monitor", subtitle: "There is no other monitor to go to")
            return
        }
        if let number, !screens.indices.contains(number - 1) {
            toast?.showCentred(title: "No monitor \(number)", subtitle: "Monitors are counted left to right; there are \(screens.count)")
            return
        }
        // Landing on an empty monitor only moves the pointer, so until the selection changes
        // "next" goes on from there, or it would land there again.
        let selectedID = model.selectedID
        let currentDisplay = workedOnDisplay()
        pointerOnlyMonitor = nil
        let current = screens.firstIndex { Monitors.displayID(of: $0) == currentDisplay } ?? 0
        let targetIndex = number.map { $0 - 1 } ?? (current + 1) % screens.count
        let target = screens[targetIndex]
        guard let display = Monitors.displayID(of: target) else { return }
        if display != currentDisplay { markMonitor(target) }

        let onShow = WindowTiler.onScreenWindowIDs()
        let windows = model.windows.filter {
            !$0.isMinimized && onShow.contains($0.id) && model.monitorID(of: $0) == display
        }
        // Front to back, so the window last on top there is the one landed on.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let topmost = list.lazy
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            .compactMap { id in windows.first { $0.id == id } }
            .first
        if let window = topmost ?? windows.first {
            Diagnostics.note("monitor \(targetIndex + 1): focusing \(window.appName) id=\(window.id)")
            model.select(id: window.id, announce: true)
            focus(window)
            return
        }
        Diagnostics.note("monitor \(targetIndex + 1): nothing on show, pointer to \(target.localizedName)")
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: target.frame.midX, y: primaryHeight - target.frame.midY))
        pointerOnlyMonitor = (display, selectedID)
    }

    /// Lights up the edges of the monitor the work just moved over to.
    private func markMonitor(_ screen: NSScreen) {
        guard store.prefs.flashMonitorOnSwitch, NSScreen.screens.count > 1 else { return }
        Diagnostics.note("monitor frame on \(screen.localizedName)")
        monitorFrame.flash(screen, for: 0.35, fading: store.prefs.animates(.windowOutlines))
    }

    /// A frame at the same place relative to another area, scaled to it and kept inside it.
    static func map(_ frame: NSRect, from source: NSRect, to target: NSRect) -> NSRect {
        let scaleX = source.width > 0 ? target.width / source.width : 1
        let scaleY = source.height > 0 ? target.height / source.height : 1
        var result = NSRect(x: target.minX + (frame.minX - source.minX) * scaleX,
                            y: target.minY + (frame.minY - source.minY) * scaleY,
                            width: min(frame.width * scaleX, target.width),
                            height: min(frame.height * scaleY, target.height))
        result.origin.x = min(max(result.minX, target.minX), target.maxX - result.width)
        result.origin.y = min(max(result.minY, target.minY), target.maxY - result.height)
        return result
    }

    /// Goes to the empty workspace nearest the one in view on this monitor, the way `⌥N` goes to
    /// workspace N. WindowQueue does not make desktops, so with none empty it says so instead.
    private func goToEmptySpace() {
        guard let current = SpacesBridge.shared.currentSpaceID else { return }
        let onThisDisplay = Set(SpacesBridge.shared.spacesSharingDisplay(with: current))
        let candidates = model.spaceOrder.filter { onThisDisplay.contains($0) }
        guard let empty = model.nearestEmptySpace(to: current, among: candidates) else {
            toast?.showCentred(title: "No empty workspace",
                               subtitle: "Every workspace on this monitor has windows; Mission Control adds more")
            return
        }
        guard empty != current, let index = model.workspaceNumber(ofSpace: empty) else {
            toast?.showCentred(title: "This workspace is empty", subtitle: "WindowQueue")
            return
        }
        Diagnostics.note("nearest empty workspace: \(index) (space \(empty))")
        switchToSpace(index)
    }

    /// Sends the selected window — or every aimed window — to the empty workspace nearest the one in
    /// view on this monitor, and goes there with it, as `⌥⇧N` does for workspace N.
    private func moveToEmptySpace() {
        let windows = model.aimingID != nil ? model.aimedWindows : model.selectedWindow.map { [$0] } ?? []
        guard !windows.isEmpty, let current = SpacesBridge.shared.currentSpaceID else { return }
        let onThisDisplay = Set(SpacesBridge.shared.spacesSharingDisplay(with: current))
        let candidates = model.spaceOrder.filter { onThisDisplay.contains($0) }
        // The workspace being left is no destination, even when the windows leaving are all it has.
        guard let empty = model.nearestEmptySpace(to: current, among: candidates,
                                                  ignoring: Set(windows.map(\.id)), includingOrigin: false),
              let index = model.workspaceNumber(ofSpace: empty)
        else {
            if model.aimingID != nil { endAiming(commit: false) }
            toast?.showCentred(title: "No empty workspace",
                               subtitle: "Every other workspace on this monitor has windows; Mission Control adds more")
            return
        }
        Diagnostics.note("moving to the nearest empty workspace: \(index) (space \(empty))")
        moveWindows(toWorkspace: index)
    }

    /// Changes workspace using the configured strategy, falling back through the others.
    private func switchToSpace(_ index: Int) {
        let target = SpacesBridge.shared.userSpaceID(atIndex: index)
        lastSpaceRequest = Date()
        // A newer request, even for the desktop already on show, retires the retries of an older one.
        spaceRequest &+= 1
        // A workspace already on show — on another monitor, each having its own desktops — needs
        // no switch, and none of the ways below does anything visible for it. Going there means
        // moving over to that monitor.
        if let target, SpacesBridge.shared.isShowing(target) {
            goToShownSpace(target, index: index)
            return
        }
        // What the target's own monitor shows: with several, the strip's display says nothing
        // about whether the switch happened.
        let origin = target.flatMap { SpacesBridge.shared.spaceOnShow(onDisplayOf: $0) }
        // Desktops are known and this one is not among them: the system shortcut below would only
        // hand ⌃N to the frontmost app (Mission Control's own shortcuts are off out of the box).
        let known = SpacesBridge.shared.userSpaceIDs.count
        if target == nil, known > 0, store.prefs.spaceSwitchMethod != .systemShortcut {
            toast?.showCentred(title: "No workspace \(index)",
                               subtitle: known == 1 ? "There is 1 workspace" : "There are \(known) workspaces")
            return
        }
        switch store.prefs.spaceSwitchMethod {
        case .focusWindow:
            if focusWindow(onSpaceIndex: index) { break }
            // Nothing to focus there: carry a window of our own over instead, and only fall back to
            // the system shortcut if that is unavailable.
            if let target, SpaceSwitcher.jump(toSpace: target) { break }
            SpaceSwitcher.sendSystemShortcut(index: index)
        case .systemShortcut:
            SpaceSwitcher.sendSystemShortcut(index: index)
        case .privateAPI:
            if let target, SpaceSwitcher.jump(toSpace: target) { break }
            SpaceSwitcher.sendSystemShortcut(index: index)
        }
        // Every one of these can quietly do nothing — an empty workspace has no window to focus,
        // and the WindowServer call is refused often enough that it cannot be taken on trust. The
        // user asked to be somewhere, so check they got there and try the other ways if not.
        guard let target else { return }
        ensureArrived(at: target, from: origin, index: index, request: spaceRequest, attempt: 0)
    }

    /// Checks the workspace switch actually happened, and tries the next way of doing it if not.
    ///
    /// Only while nothing else has happened since: a newer request, or the user having gone
    /// somewhere else in the meantime, ends it — a retry landing then would drag them back.
    /// The retries are the ways the Dock takes part in; the WindowServer-only switch would leave it
    /// believing the old desktop is current.
    private func ensureArrived(at target: UInt64, from origin: UInt64?, index: Int, request: Int,
                               attempt: Int) {
        // The slide between desktops takes about half a second, and the desktop on show only
        // changes once it is over; looking sooner mistakes a switch under way for one refused.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.arrivalCheckDelay) { [weak self] in
            guard let self, request == self.spaceRequest else { return }
            self.enumerator?.refreshSpaceState()
            if SpacesBridge.shared.isShowing(target) { return }
            let current = SpacesBridge.shared.spaceOnShow(onDisplayOf: target)
            guard current == origin else {
                Diagnostics.note("workspace \(index): went to \(current.map(String.init) ?? "none") instead; leaving it")
                return
            }
            guard attempt < 2 else {
                Diagnostics.note("workspace \(index): could not switch")
                return
            }
            Diagnostics.note("workspace \(index): still on \(current.map(String.init) ?? "none"), trying again")
            switch attempt {
            case 0:
                if !SpaceSwitcher.jump(toSpace: target) { SpaceSwitcher.sendSystemShortcut(index: index) }
            default:
                SpaceSwitcher.sendSystemShortcut(index: index)
            }
            self.ensureArrived(at: target, from: origin, index: index, request: request, attempt: attempt + 1)
        }
    }

    private static let arrivalCheckDelay: TimeInterval = 0.8

    /// When the user last asked to change workspace, so a switch macOS makes on its own can be told
    /// from one they asked for.
    private var lastSpaceRequest = Date.distantPast
    /// Counts workspace requests, so a retry left over from an earlier one stands down.
    private var spaceRequest = 0
    /// The workspace to stay on: emptied by closing its last window, and left only when the user
    /// says so.
    private var holdSpace: (id: UInt64, until: Date)?

    /// Moves focus to a workspace that is already on show, on whichever monitor shows it: to the
    /// window on top there, or — with none — the pointer to the middle of that screen.
    private func goToShownSpace(_ space: UInt64, index: Int) {
        let windows = model.windows.filter { $0.spaceID == space && !$0.isMinimized }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let selected = model.selectedWindow, selected.spaceID == space, selected.pid == frontPID {
            Diagnostics.note("workspace \(index): already there")
            return
        }
        if let screen = SpacesBridge.shared.screen(ofSpace: space),
           Monitors.displayID(of: screen) != workedOnDisplay() {
            markMonitor(screen)
        }
        // Front to back, so the window last on top there is the one landed on.
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        let topmost = list.lazy
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            .compactMap { id in windows.first { $0.id == id } }
            .first
        if let window = topmost ?? windows.first {
            Diagnostics.note("workspace \(index): on show, focusing \(window.appName) id=\(window.id)")
            model.select(id: window.id, announce: false)
            focus(window)
            return
        }
        guard let screen = SpacesBridge.shared.screen(ofSpace: space) else { return }
        Diagnostics.note("workspace \(index): on show and empty, pointer to \(screen.localizedName)")
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        CGWarpMouseCursorPosition(CGPoint(x: screen.frame.midX, y: primaryHeight - screen.frame.midY))
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

    /// Takes us back to the workspace emptied by a close, if macOS moved us off it by itself.
    /// Runs whenever the desktop on show changes.
    private func keepHeldWorkspace() {
        guard let hold = holdSpace else { return }
        guard Date() < hold.until else {
            holdSpace = nil
            return
        }
        // A switch the user asked for wins: this is only for the ones nobody asked for. So does one
        // of our own jumps, which is travelling on the user's behalf.
        guard lastSpaceRequest < Date().addingTimeInterval(-0.5), SpaceSwitcher.destination == nil else {
            holdSpace = nil
            return
        }
        let current = SpacesBridge.shared.currentSpaceID
        guard let current, current != hold.id, !SpacesBridge.shared.isShowing(hold.id) else { return }
        holdSpace = nil
        Diagnostics.note("macOS moved us to \(current) after a close; going back to \(hold.id)")
        if !SpaceSwitcher.jump(toSpace: hold.id), let index = model.workspaceNumber(ofSpace: hold.id) {
            SpaceSwitcher.sendSystemShortcut(index: index)
        }
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
        case "tour":
            showTour()
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
        updateItem.target = self
        updateItem.isHidden = true
        menu.addItem(updateItem)
        grantAccessItem.target = self
        grantAccessItem.isHidden = AXIsProcessTrusted()
        menu.addItem(grantAccessItem)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Show the Tour…", action: #selector(showTour), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Sort queue by workspace", action: #selector(sortByWorkspace),
                     keyEquivalent: "s")
            .target = self
        menu.addItem(withTitle: "Refresh windows", action: #selector(refreshWindows), keyEquivalent: "r")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About WindowQueue", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
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
                spacesAvailable: SpacesBridge.shared.isAvailable,
                showTour: { [weak self] in self?.showTour() },
                checkForUpdates: { [weak self] in self?.checkForUpdates() }
            )
        }
        settingsWindow?.present()
        // Our own window is discovered like any other, just not instantly by the poll timer.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enumerator?.refresh()
        }
    }

    /// The welcome tour: a pretend desktop to watch and try everything in, then the few settings
    /// that matter most. Closing it, finished or not, counts as having seen it.
    @objc private func showTour() {
        if tour == nil {
            let tour = TourWindowController(store: store)
            tour.onKeyboardChange = { [weak self] hasKeyboard in
                guard let self else { return }
                self.tourHasKeyboard = hasKeyboard
                if hasKeyboard { self.endAiming(commit: false) }
                self.syncHotkeys()
            }
            tour.onClose = { [weak self] in
                self?.store.prefs.onboardingCompleted = true
            }
            self.tour = tour
        }
        tour?.present()
    }

    /// The standard panel: icon, version and copyright come from Info.plist. Living in the menu bar,
    /// the app has no main menu to hold it, and the panel would open under the app in front.
    @objc private func showAbout() {
        let credits = NSAttributedString(
            string: "A keyboard-driven window queue for macOS.\nFree software under the GNU GPL, version 3.",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }()]
        )
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.windows.filter { $0.isVisible && $0.className.contains("About") }.forEach { $0.orderFrontRegardless() }
    }

    /// The newer release found, with the way to download it.
    @objc private func showUpdate() {
        guard let release = updates.available else { return }
        if updateWindow?.window.isVisible != true {
            updateWindow = UpdateWindowController(release: release)
        }
        updateWindow?.present()
    }

    @objc private func checkForUpdates() {
        updates.check(userAsked: true)
    }

    @objc private func grantAccessibility() {
        Permissions.prompt()
        Permissions.openAccessibilitySettings()
    }

    /// The shortcuts are live only once they can work, and not while the tour is trying them out.
    private func syncHotkeys(_ prefs: Preferences? = nil) {
        hotkeys.isSuspended = !accessGranted || tourHasKeyboard
        hotkeys.apply(prefs ?? store.prefs)
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
