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
            shortcuts.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            strip.tabItem { Label("Strip", systemImage: "sidebar.left") }
        }
        .frame(width: 520, height: 460)
    }

    // MARK: - General

    private var general: some View {
        Form {
            Picker("Queue scope", selection: $store.prefs.scope) {
                ForEach(QueueScope.allCases) { Text($0.title).tag($0) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Picker("Workspace switching", selection: $store.prefs.spaceSwitchMethod) {
                    ForEach(SpaceSwitchMethod.allCases) { Text($0.title).tag($0) }
                }
                Text(store.prefs.spaceSwitchMethod.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Keep the queue sorted by workspace", isOn: $store.prefs.autoSortByWorkspace)
                Text("New windows join their workspace's group automatically. Reordering the queue by hand turns this off; the sort shortcut turns it back on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Aiming mode", isOn: $store.prefs.aimingEnabled)
                Text("Tap the super key on its own to pick a window without focusing it. The strip grows, the screens dim behind it, the aimed icon turns orange, and [ / ] or the arrows move the aim. Tapping the super key again focuses the window; so do Return and Space. Escape leaves everything as it was.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Dim the screens")
                    Slider(value: $store.prefs.aimingDimOpacity, in: 0...0.85, step: 0.05)
                    Text(store.prefs.aimingDimOpacity == 0
                         ? "off"
                         : String(format: "%.0f%%", store.prefs.aimingDimOpacity * 100))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!store.prefs.aimingEnabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch at login", isOn: $store.prefs.launchAtLogin)
                    .disabled(!LoginItem.isInstalled)
                if let note = loginItemNote {
                    HStack(spacing: 8) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if LoginItem.state == .needsApproval {
                            Button("Open Login Items") { LoginItem.openSystemSettings() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            Toggle("Move the pointer to the focused window", isOn: $store.prefs.warpCursorToWindow)
            Toggle("Show window name popup", isOn: $store.prefs.toastEnabled)
            HStack {
                Text("Popup duration")
                Slider(value: $store.prefs.toastDuration, in: 0.5...10, step: 0.5)
                Text(String(format: "%.1f s", store.prefs.toastDuration))
                    .monospacedDigit()
                    .frame(width: 50, alignment: .trailing)
            }
            .disabled(!store.prefs.toastEnabled)

            Section("Window titles") {
                Text(titlesExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !ScreenRecordingAccess.isGranted {
                    HStack {
                        Button("Grant Screen Recording…") {
                            ScreenRecordingAccess.request()
                            ScreenRecordingAccess.openSettings()
                        }
                        Spacer()
                    }
                }
            }

            if !spacesAvailable {
                Text("Workspace support is unavailable on this macOS version: the private Spaces API could not be loaded. Workspace switching and per-workspace scope are disabled.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .formStyle(.grouped)
        .padding()
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
        guard RectangleIntegration.isInstalled else {
            return "Only the Dock and menu bar can shrink the usable screen area on macOS. WindowQueue can instead set Rectangle's screen-edge gap, but Rectangle is not installed."
        }
        let gap = RectangleIntegration.reservedWidth(for: store.prefs)
        return "macOS lets only the Dock and menu bar shrink the usable screen area, so WindowQueue sets Rectangle's \(store.prefs.stripSide == .left ? "left" : "right") screen-edge gap to \(gap) pt instead. Rectangle reads that value at launch, so restart it after changing this."
    }

    // MARK: - Strip

    private var strip: some View {
        Form {
            Toggle("Show strip", isOn: $store.prefs.stripEnabled)
            Picker("Side", selection: $store.prefs.stripSide) {
                ForEach(StripSide.allCases) { Text($0.title).tag($0) }
            }
            Toggle("Hide over fullscreen windows", isOn: $store.prefs.hideInFullscreen)
            Toggle("Show workspace number", isOn: $store.prefs.showSpaceBadge)
            HStack {
                Text("Icon size")
                Slider(value: $store.prefs.iconSize, in: 16...48, step: 2)
                Text("\(Int(store.prefs.iconSize))").monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text("Strip width")
                Slider(value: $store.prefs.stripWidth, in: 30...90, step: 2)
                Text("\(Int(store.prefs.stripWidth))").monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            HStack {
                Text("Focus after scrolling")
                Slider(value: $store.prefs.scrollFocusDelay, in: 0.1...2.0, step: 0.1)
                Text(String(format: "%.1f s", store.prefs.scrollFocusDelay))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            HStack {
                Text("Opacity")
                Slider(value: $store.prefs.stripOpacity, in: 0.2...1.0, step: 0.05)
                Text(String(format: "%.0f%%", store.prefs.stripOpacity * 100))
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
            }

            Section("Reserve screen space") {
                Toggle("Keep tiled windows clear of the strip", isOn: $store.prefs.reserveScreenSpace)
                    .disabled(!RectangleIntegration.isInstalled)
                Text(reservationExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .padding()
    }
}

/// Hosts `SettingsView` in a normal window; the app is an accessory, so it activates on demand.
final class SettingsWindowController: NSWindowController {
    private let store: PreferencesStore

    init(store: PreferencesStore, failures: @escaping () -> [HotkeyAction], spacesAvailable: Bool) {
        self.store = store
        let view = SettingsView(store: store, hotkeyFailures: failures(), spacesAvailable: spacesAvailable)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
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
