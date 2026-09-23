import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: PreferencesStore
    let hotkeyFailures: [HotkeyAction]
    let spacesAvailable: Bool

    @State private var rectangleStatus = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            focus.tabItem { Label("Focus", systemImage: "cursorarrow.rays") }
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            strip.tabItem { Label("Strip", systemImage: "sidebar.left") }
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
            Section("Queue") {
                Picker("Queue scope", selection: $store.prefs.scope) {
                    ForEach(QueueScope.allCases) { Text($0.title).tag($0) }
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
                sliderRow("Dim the screens", value: $store.prefs.aimingDimOpacity, in: 0...0.85, step: 0.05) {
                    $0 == 0 ? "off" : Self.percent($0)
                }
                .disabled(!store.prefs.aimingEnabled)
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
                }
            }
        }
        .padding()
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

    private var reservationExplanation: String {
        let gap = RectangleIntegration.reservedWidth(for: store.prefs)
        let base = "While the Dock hides itself, WindowQueue lends the strip the Dock's reserved area on the menu bar screen, so zoom, Fill and tiling leave \(gap) pt free — in apps opened after WindowQueue started. Everywhere else, windows laid against the strip's edge are trimmed after the fact."
        guard RectangleIntegration.isInstalled else { return base }
        return base + " It also sets Rectangle's \(store.prefs.stripSide.rawValue) screen-edge gap, which Rectangle reads at launch, so restart it after changing this."
    }

    // MARK: - Strip

    private var strip: some View {
        Form {
            Section("Visibility") {
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

    init(store: PreferencesStore, failures: @escaping () -> [HotkeyAction], spacesAvailable: Bool) {
        self.store = store
        let view = SettingsView(store: store, hotkeyFailures: failures(), spacesAvailable: spacesAvailable)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "WindowQueue Settings"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func present() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
