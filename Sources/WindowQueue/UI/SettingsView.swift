import AppKit
import SwiftUI

/// The settings' tabs, shown as the window's toolbar the way macOS settings windows are.
enum SettingsTab: String, CaseIterable {
    case general, focus, shortcuts, strip, animations

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .focus: return "cursorarrow.rays"
        case .shortcuts: return "keyboard"
        case .strip: return "sidebar.left"
        case .animations: return "wand.and.stars"
        }
    }
}

/// One tab of the settings.
struct SettingsView: View {
    @ObservedObject var store: PreferencesStore
    let tab: SettingsTab
    let hotkeyFailures: [HotkeyAction]
    let spacesAvailable: Bool
    var showTour: () -> Void = {}
    var checkForUpdates: () -> Void = {}

    @State private var rectangleStatus = ""
    @State private var newAimAction: HotkeyAction = .toggleRecording

    var body: some View {
        Group {
            switch tab {
            case .general: general
            case .focus: focus
            case .shortcuts: shortcuts
            case .strip: strip
            case .animations: animations
            }
        }
        .frame(width: SettingsWindowController.size.width, height: SettingsWindowController.size.height)
    }

    // MARK: - Building blocks

    /// Every slider is the same length with its value in a fixed column, so they line up down the
    /// page whatever their labels say.
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double, format: @escaping (Double) -> String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Slider(value: value, in: range, step: step)
                    .labelsHidden()
                    .frame(width: 200)
                Text(format(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
    private static func points(_ value: Double) -> String { "\(Int(value)) pt" }
    private static func seconds(_ value: Double) -> String { String(format: "%.2g s", value) }

    // MARK: - General

    private var general: some View {
        Form {
            Section("Getting started") {
                // Polled: the grant happens in System Settings, which tells nobody.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if AXIsProcessTrusted() {
                        Label("Accessibility access is granted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("WindowQueue needs Accessibility access to see and move windows; its shortcuts stay off until then.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Grant Access…") {
                                Permissions.prompt()
                                Permissions.openAccessibilitySettings()
                            }
                        }
                    }
                }
                HStack {
                    caption("A short tour of focusing, aiming, tiling and groups, with a pretend desktop to try them in.")
                    Spacer()
                    Button("Show the Tour") { showTour() }
                }
            }

            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $store.prefs.checkForUpdates)
                HStack {
                    caption("Version \(UpdateChecker.currentVersion). WindowQueue looks for a new release on GitHub once a day and tells you; it never installs anything itself.")
                    Spacer()
                    Button("Check Now") { checkForUpdates() }
                }
            }

            Section("Queue") {
                Picker("Queue scope", selection: $store.prefs.scope) {
                    ForEach(QueueScope.allCases.filter { $0 != .monitor || store.prefs.multiMonitorMode }) {
                        Text($0.title).tag($0)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Multi-monitor mode", isOn: $store.prefs.multiMonitorMode)
                    caption("Every monitor's strip shows its own queue: with the per-monitor scope the windows on that monitor, with the per-workspace one the desktop it has on show. Cycling works on the monitor you are on. Also takes the shortcuts that go to monitor N (counted left to right) or on to the next monitor, and — with Shift — take the window there with you.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Wrap around at the ends of the queue", isOn: $store.prefs.cycleWrapsAround)
                    caption("Going past the last window comes back to the first, and the other way round, when cycling and when moving the aim. Off, the steps stop at the ends.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Keep the queue sorted by workspace", isOn: $store.prefs.autoSortByWorkspace)
                    caption("New windows join their workspace's group automatically. Reordering the queue by hand turns this off; the sort shortcut turns it back on.")
                }
            }

            Section("Workspaces") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Workspace switching", selection: $store.prefs.spaceSwitchMethod) {
                        ForEach(SpaceSwitchMethod.allCases) { Text($0.title).tag($0) }
                    }
                    caption(store.prefs.spaceSwitchMethod.explanation)
                }
                if !spacesAvailable {
                    Text("Workspace support is unavailable on this macOS version: the private Spaces API could not be loaded. Workspace switching and per-workspace scope are disabled.")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Tiling") {
                sliderRow("Screen gap", value: $store.prefs.tileOuterGap, in: 0...40, step: 1, format: Self.points)
                sliderRow("Gap between windows", value: $store.prefs.tileInnerGap, in: 0...40, step: 1, format: Self.points)
                caption("Room left around windows that WindowQueue places: tiled from aiming mode, maximized, or sent fullscreen.")
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Tile on a separate workspace", isOn: $store.prefs.tileOnSeparateWorkspace)
                    caption("When other windows share the workspace, the tiled windows move to one holding nothing else. Off, they are gathered on the first aimed window's workspace.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Respect window size limits", isOn: $store.prefs.respectWindowSizeLimits)
                    caption("Windows with a minimum or maximum size, a fixed size or a fixed aspect ratio, like the iOS Simulator, are sized to fit and centred in their place, and the other windows take the room they leave. A window's limits are learnt the first time it refuses a size, which makes it flicker once.")
                }
            }

            Section("Fullscreen windows") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Focus on the fullscreen window", isOn: $store.prefs.focusMaximizedWindow)
                    caption("Sending a window fullscreen moves it to the front of its workspace in the queue. Cycling then stays on it until it is restored, which puts the queue back as it was. Plain maximizing leaves the queue alone.")
                }
                if store.prefs.focusMaximizedWindow {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Collapse the windows it covers", isOn: $store.prefs.collapseCoveredWindows)
                        caption("The windows the fullscreen one covers fold into one tile beside it, showing the first few icons and how many there are. Off, they keep a row each and are tinted instead.")
                    }
                }
            }

            Section("Strip labels") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show window titles under the icons", isOn: $store.prefs.showWindowLabels)
                    caption("Tells apart several windows of the same application. The icon shrinks to make room, so the strip stays the same size.")
                }
            }

            Section("Window titles") {
                caption(titlesExplanation)
                if !ScreenRecordingAccess.isGranted {
                    Button("Grant Screen Recording…") {
                        ScreenRecordingAccess.request()
                        ScreenRecordingAccess.openSettings()
                    }
                }
            }

            Section("Startup") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Launch at login", isOn: $store.prefs.launchAtLogin)
                        .disabled(!LoginItem.isInstalled)
                    if let note = loginItemNote {
                        HStack(spacing: 8) {
                            caption(note)
                            if LoginItem.state == .needsApproval {
                                Button("Open Login Items") { LoginItem.openSystemSettings() }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Focus

    private var focus: some View {
        Form {
            Section("Pointer") {
                Toggle("Move the pointer to windows focused from the keyboard", isOn: $store.prefs.warpCursorToWindow)
                Toggle("Focus the window under the pointer", isOn: $store.prefs.focusFollowsMouse)
                sliderRow("Hover delay", value: $store.prefs.focusFollowsMouseDelay, in: 0...1.0, step: 0.05,
                          format: Self.seconds)
                    .disabled(!store.prefs.focusFollowsMouse)
                Toggle("Bring the hovered window to the front", isOn: $store.prefs.focusFollowsMouseRaises)
                    .disabled(!store.prefs.focusFollowsMouse)
            }

            Section("Aiming mode") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Aiming mode", isOn: $store.prefs.aimingEnabled)
                    caption("Tap the super key on its own to pick a window without focusing it. The strip grows, the screens dim behind it, the aimed icon turns orange, and [ / ] or the arrows move the aim. Tapping the super key again focuses the window; so do Return and Space. Escape leaves everything as it was.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Double tap of the super key", selection: $store.prefs.superDoubleTapAction) {
                        Text("Confirm the aim").tag(HotkeyAction?.none)
                        ForEach(HotkeyAction.doubleTapActions) { action in
                            Text(action.title).tag(HotkeyAction?.some(action))
                        }
                    }
                    caption("Two taps of the super key in quick succession. Confirming focuses the aimed window, which is what the second tap does on its own; any other choice leaves aiming mode and runs that action instead.")
                }
                .disabled(!store.prefs.aimingEnabled)
                sliderRow("Dim the screens", value: $store.prefs.aimingDimOpacity, in: 0...0.85, step: 0.05) {
                    $0 == 0 ? "off" : Self.percent($0)
                }
                .disabled(!store.prefs.aimingEnabled)
            }

            Section("Focus") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Outline the window focus lands on", isOn: $store.prefs.flashFocusedWindow)
                    caption("A brief outline around the window that just took focus, in the selection colour — the same mark aiming mode draws around what it is pointing at. It appears at once, holds, then fades over half a second.")
                }
                sliderRow("Outline holds for", value: $store.prefs.flashFocusedWindowDuration,
                          in: 0.05...1, step: 0.05, format: Self.seconds)
                    .disabled(!store.prefs.flashFocusedWindow)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Frame the monitor switched to", isOn: $store.prefs.flashMonitorOnSwitch)
                    caption("When a monitor shortcut, or a workspace shortcut for a desktop on show on another display, takes you to another monitor, its edges light up for a moment in the selection colour.")
                }
            }

            Section("Launcher") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Open with", selection: $store.prefs.launcher) {
                        ForEach(LauncherApp.allCases) { launcher in
                            Text(launcher.isAvailable ? launcher.title : "\(launcher.title) (not installed)")
                                .tag(launcher)
                        }
                    }
                    caption("What the launcher shortcut opens, in aiming mode as well as outside it. Spotlight has no way in other than its own ⌘Space, which is sent as a key press; the others are opened as applications. A launcher that is not installed falls back to Spotlight.")
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Launcher command", text: $store.prefs.raycastCommand, prompt: Text("Opens the launcher above"))
                    caption("The URL \"Run a launcher command\" opens — bind it to a shortcut or the double tap of the super key. Any link an installed app handles works: a Raycast deeplink (Copy Deeplink, ⌘⇧C on a command), an Alfred trigger (alfred://runtrigger/…), a Shortcut (shortcuts://run-shortcut?name=…). Left empty, or on a Mac without the app it needs, it opens the launcher chosen above.")
                }
            }

            Section("Name popup") {
                Toggle("Show the window name after a change", isOn: $store.prefs.toastEnabled)
                sliderRow("Popup duration", value: $store.prefs.toastDuration, in: 0.5...10, step: 0.5,
                          format: Self.seconds)
                    .disabled(!store.prefs.toastEnabled)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show a picture of the window", isOn: $store.prefs.showWindowPreview)
                        .disabled(!store.prefs.toastEnabled)
                    caption("Needs Screen Recording access, and only windows on the workspace in view can be pictured.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var loginItemNote: String? {
        switch LoginItem.state {
        case .notInstalled:
            return "Available once WindowQueue is in the Applications folder (make install)."
        case .needsApproval:
            return "Waiting for approval in the system's login item settings."
        case .enabled, .disabled:
            return nil
        }
    }

    private var titlesExplanation: String {
        if ScreenRecordingAccess.isGranted {
            return "Screen Recording access is granted, so window titles are shown for every workspace."
        }
        return "Windows on other workspaces show only their app name. macOS hides window titles from apps without Screen Recording access; granting it fills them in. Everything else works without it."
    }

    // MARK: - Shortcuts

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Super key", selection: Binding(
                    get: { store.prefs.superModifier },
                    set: { store.setSuperModifier($0) }
                )) {
                    ForEach(SuperModifier.allCases) { Text($0.title).tag($0) }
                }
                .frame(width: 300)
                Spacer()
                Button("Reset all") { store.resetBindingsToDefaults() }
            }
            Text("Changing the super key regenerates every shortcut from the defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !hotkeyFailures.isEmpty {
                Text("Could not register: \(hotkeyFailures.map(\.title).joined(separator: ", ")). Another app probably owns those shortcuts.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    section("Queue", actions: HotkeyAction.queueActions)
                    section("Workspaces", actions: HotkeyAction.spaceActions)
                    section("Move to workspace", actions: HotkeyAction.moveToSpaceActions)
                    if store.prefs.multiMonitorMode {
                        section("Monitors", actions: HotkeyAction.monitorActions)
                    }
                    aimBindings
                }
            }
        }
        .padding()
    }

    /// Keys that mean something only while aiming mode is open, on top of the shortcuts it already
    /// answers to without their super key.
    private var aimBindings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Aiming mode only").font(.headline).padding(.top, 12)
            Text("While aiming, every shortcut above works without its super key. These keys work there and nowhere else, and come first when both would answer.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(store.prefs.aimBindings.sorted { $0.key < $1.key }, id: \.key) { entry in
                HStack {
                    Text(KeyCombo(keyCode: Int(entry.key) ?? 0, modifiers: 0).displayString)
                        .frame(width: 60, alignment: .leading)
                        .font(.system(.body, design: .monospaced))
                    Picker("", selection: Binding(
                        get: { store.prefs.aimBindings[entry.key] ?? entry.value },
                        set: { store.prefs.aimBindings[entry.key] = $0 }
                    )) {
                        ForEach(HotkeyAction.queueActions) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .labelsHidden()
                    Button(role: .destructive) {
                        store.prefs.aimBindings.removeValue(forKey: entry.key)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack {
                Text("Add a key")
                ShortcutRecorder(combo: nil, allowsBareKey: true) { combo in
                    // Only the key matters here: aiming mode has the keyboard to itself, so its own
                    // keys are bare ones.
                    store.prefs.aimBindings["\(combo.keyCode)"] = newAimAction
                }
                .frame(width: 130, height: 24)
                Picker("", selection: $newAimAction) {
                    ForEach(HotkeyAction.queueActions) { action in
                        Text(action.title).tag(action)
                    }
                }
                .labelsHidden()
            }
            .padding(.top, 4)
        }
    }

    private func section(_ title: String, actions: [HotkeyAction]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).padding(.top, 8)
            ForEach(actions) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    ShortcutRecorder(combo: store.prefs.combo(for: action)) { combo in
                        store.setCombo(combo, for: action)
                    }
                    .frame(width: 130, height: 24)
                }
            }
        }
    }

    private var groupStripPlacementExplanation: String {
        let (before, after) = store.prefs.stripSide.isVertical ? ("above", "below") : ("left of", "right of")
        switch store.prefs.groupStripPlacement {
        case .automatic:
            return "A group's windows open in a second strip \(before) the main one when it is aligned to the end, and \(after) it otherwise."
        case .before: return "A group's windows open in a second strip \(before) the main one."
        case .after: return "A group's windows open in a second strip \(after) the main one."
        case .replace: return "While you are inside a group, its windows take the main strip's place; the main strip comes back when you leave it."
        case .overGroup: return "A group's windows open in a strip laid over the main one, centred on the group's own entry."
        }
    }

    private var reservationExplanation: String {
        let gap = RectangleIntegration.reservedWidth(for: store.prefs)
        let base = "While the Dock hides itself, WindowQueue lends the strip the Dock's reserved area on the menu bar screen, so zoom, Fill and tiling leave \(gap) pt free — in apps opened after WindowQueue started. Everywhere else, windows laid against the strip's edge are trimmed after the fact."
        guard RectangleIntegration.isInstalled else { return base }
        return base + " It also sets Rectangle's \(store.prefs.stripSide.rawValue) screen-edge gap, which Rectangle reads at launch, so restart it after changing this."
    }

    // MARK: - Strip

    private var animations: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Animate the interface", isOn: $store.prefs.animationsEnabled)
                    caption("Off, the strip, aiming mode, outlines and popups change at once. Animations macOS runs itself, like switching workspaces, are not WindowQueue's to turn off.")
                }
            }

            Section("Strip") {
                animationToggle(.stripLayout)
                animationToggle(.groupStrip)
            }

            Section("Aiming mode") {
                animationToggle(.aimingMode)
                animationToggle(.aimCursor)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Show aiming mode instantly", isOn: $store.prefs.instantAiming)
                    caption("The mode appears the moment the super key is tapped: the screens dim, the strip grows and — in invisible mode — opens without animating, and nothing waits to see whether a double tap is coming. With a double-tap action set, the mode shows for an instant before the second tap replaces it. Leaving the mode still animates.")
                }
            }

            Section("Windows and popups") {
                animationToggle(.windowOutlines)
                animationToggle(.namePopup)
            }
        }
        .formStyle(.grouped)
    }

    /// One animation's own switch, greyed out while the main switch is off.
    private func animationToggle(_ kind: AnimationKind) -> some View {
        Toggle(kind.title, isOn: animationBinding(kind))
            .disabled(!store.prefs.animationsEnabled)
    }

    /// On while the animation is not switched off on its own; the main switch is shown separately.
    private func animationBinding(_ kind: AnimationKind) -> Binding<Bool> {
        Binding(
            get: { !store.prefs.disabledAnimations.contains(kind) },
            set: { on in
                if on {
                    store.prefs.disabledAnimations.remove(kind)
                } else {
                    store.prefs.disabledAnimations.insert(kind)
                }
            }
        )
    }

    private var strip: some View {
        Form {
            Section("Visibility") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Invisible mode", isOn: $store.prefs.invisibleStrip)
                    caption("The strip is drawn only while aiming mode is open. The queue works as it always does; outside aiming, a change is announced by the name popup alone, and no screen space is reserved.")
                }
                Picker("Show strip", selection: $store.prefs.stripDisplay) {
                    ForEach(StripDisplayMode.allCases) { Text($0.title).tag($0) }
                }
                sliderRow("Inactive monitors", value: $store.prefs.inactiveStripOpacity, in: 0.1...1.0, step: 0.05,
                          format: Self.percent)
                    .disabled(store.prefs.stripDisplay != .highlightActiveScreen)
                Toggle("Hide over fullscreen windows", isOn: $store.prefs.hideInFullscreen)
            }

            Section("Position") {
                Picker("Side", selection: $store.prefs.stripSide) {
                    ForEach(StripSide.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Alignment", selection: $store.prefs.stripAlignment) {
                    ForEach(StripAlignment.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                sliderRow("Margin", value: $store.prefs.stripMargin, in: 0...40, step: 1, format: Self.points)
                Picker("Group strip", selection: $store.prefs.groupStripPlacement) {
                    ForEach(GroupStripPlacement.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                caption(groupStripPlacementExplanation)
            }

            Section("Appearance") {
                sliderRow("Icon size", value: $store.prefs.iconSize, in: 16...48, step: 2, format: Self.points)
                sliderRow("Opacity", value: $store.prefs.stripOpacity, in: 0.2...1.0, step: 0.05, format: Self.percent)
                Toggle("Show workspace number", isOn: $store.prefs.showSpaceBadge)
            }

            Section("Scrolling") {
                sliderRow("Focus after scrolling", value: $store.prefs.scrollFocusDelay, in: 0.1...2.0, step: 0.1,
                          format: Self.seconds)
            }

            Section("Reserve screen space") {
                Toggle("Keep windows clear of the strip", isOn: $store.prefs.reserveScreenSpace)
                Toggle("Trim windows on other screens and in older apps", isOn: $store.prefs.trimWindowsOutsideReservation)
                    .disabled(!store.prefs.reserveScreenSpace)
                caption(reservationExplanation)
                if RectangleIntegration.isInstalled {
                    HStack {
                        Button("Restart Rectangle to apply") {
                            rectangleStatus = "Restarting…"
                            RectangleIntegration.apply(prefs: store.prefs)
                            RectangleIntegration.restart { success in
                                rectangleStatus = success ? "Rectangle restarted." : "Could not restart Rectangle."
                            }
                        }
                        Text(rectangleStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Hosts `SettingsView` in a normal window; the app is an accessory, so it activates on demand.
final class SettingsWindowController: NSWindowController {
    static let size = NSSize(width: 600, height: 560)

    private let store: PreferencesStore
    private let tabs: NSTabViewController

    /// A tab view controller in toolbar style: the tabs are the window's toolbar, and its title
    /// follows the tab — the standard macOS settings window, which a SwiftUI `TabView` in a plain
    /// window is not (on macOS 26 that draws as a blank segmented bar).
    init(store: PreferencesStore, failures: @escaping () -> [HotkeyAction], spacesAvailable: Bool,
         showTour: @escaping () -> Void, checkForUpdates: @escaping () -> Void = {}) {
        self.store = store
        tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for tab in SettingsTab.allCases {
            let view = SettingsView(store: store, tab: tab, hotkeyFailures: failures(),
                                    spacesAvailable: spacesAvailable, showTour: showTour,
                                    checkForUpdates: checkForUpdates)
            let hosting = NSHostingController(rootView: view)
            // The window takes its title from the tab on show.
            hosting.title = tab.title
            let item = NSTabViewItem(viewController: hosting)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.toolbarStyle = .preference
        window.setContentSize(Self.size)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// Draws every tab of the settings window, title bar and toolbar included, into PNGs without
    /// putting it on screen. Run as `WindowQueue --render settings <dir>`.
    static func render(store: PreferencesStore, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let controller = SettingsWindowController(store: store, failures: { [] }, spacesAvailable: true, showTour: {})
        guard let window = controller.window else { return }
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderBack(nil)
        for (index, tab) in SettingsTab.allCases.enumerated() {
            controller.tabs.selectedTabViewItemIndex = index
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            guard let frame = window.contentView?.superview else { continue }
            if let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
                frame.cacheDisplay(in: frame.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("settings-\(index)-\(tab.rawValue).png"))
            }
        }
        window.orderOut(nil)
    }

    func present() {
        showWindow(nil)
        if let window { OwnWindows.present(window) }
    }
}
