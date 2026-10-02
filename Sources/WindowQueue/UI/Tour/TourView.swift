import AppKit
import Combine
import SwiftUI

/// The welcome tour: a page per idea, each with a pretend desktop that plays a demo and then lets
/// the user try the same keys, ending with the settings that matter most and a page of tips.
struct TourView: View {
    @ObservedObject var model: TourModel
    @ObservedObject var store: PreferencesStore
    @ObservedObject var sim: TourSim
    var close: () -> Void = {}

    static let size = NSSize(width: 980, height: 640)

    init(model: TourModel, close: @escaping () -> Void = {}) {
        self.model = model
        self.store = model.store
        self.sim = model.sim
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch model.page {
                case .welcome: welcome
                case .basics, .aiming, .tiling, .groups: lesson
                case .setup: setup
                case .tips: tips
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Frame

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(TourPage.allCases) { page in
                Button { model.show(page) } label: {
                    HStack(spacing: 5) {
                        Text("\(page.rawValue + 1)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .frame(width: 17, height: 17)
                            .background(Circle().fill(page == model.page ? Color.accentColor : page.rawValue < model.page.rawValue
                                ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.2)))
                            .foregroundStyle(page == model.page ? .white : .primary)
                        Text(page.title)
                            .font(.system(size: 12, weight: page == model.page ? .semibold : .regular))
                            .foregroundStyle(page == model.page ? .primary : .secondary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if page != TourPage.allCases.last {
                    Rectangle().fill(Color.secondary.opacity(0.25)).frame(height: 1).frame(maxWidth: 30)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if model.page != .tips {
                Button("Skip Tour") { close() }
                    .buttonStyle(.link)
            }
            Spacer()
            if model.page != .welcome {
                Button("Back") { model.back() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            if model.page == .tips {
                Button("Start Using WindowQueue") { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            } else {
                Button("Next") { model.next() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    // MARK: - Building blocks

    private func pageTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 24, weight: .bold))
    }

    private func paragraph(_ text: String) -> some View {
        Text(.init(text))
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A shortcut or two on the left — each one cap, joined by "or" / "then" — and what it does.
    private func keyRow(_ combos: [String], _ text: String, joiner: String = "or") -> some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(combos.enumerated()), id: \.offset) { index, combo in
                    if index > 0 {
                        Text(joiner).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    KeyCaps(text: combo, small: true)
                }
            }
            .frame(width: 104, alignment: .leading)
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func callout(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
            Text(.init(text)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
    }

    private func tasks(_ items: [(TourEvent, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR TURN").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let done = model.done.contains(item.0)
                HStack(spacing: 7) {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(done ? Color.green : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                    Text(.init(item.1)).font(.system(size: 12))
                        .strikethrough(done, color: .secondary)
                        .foregroundStyle(done ? .secondary : .primary)
                }
                .animation(.easeOut(duration: 0.2), value: done)
            }
        }
    }

    private var desktop: some View {
        VStack(spacing: 8) {
            SimDesktopView(sim: sim, prefs: store.prefs, onClick: model.page.isInteractive ? { model.click($0) } : nil,
                           onDragStart: model.page.isInteractive ? { model.takeOver() } : nil)
                .overlay(alignment: .topLeading) {
                    if model.demoPlaying {
                        Label(model.page == .tips ? "PREVIEW" : "DEMO", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                            .padding(.top, 22)
                            .padding(.leading, 10)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    if model.demoPlaying {
                        // How far through the demo is, so it reads as a recording that will end.
                        TimelineView(.animation) { context in
                            let progress = min(1, context.date.timeIntervalSince(model.demoStarted) / model.demoLength)
                            GeometryReader { geometry in
                                Capsule().fill(Color.red.opacity(0.85))
                                    .frame(width: geometry.size.width * progress, height: 3)
                            }
                            .frame(height: 3)
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                    }
                }
                .overlay {
                    if model.awaitingUser {
                        turnPrompt.transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: model.demoPlaying)
                .animation(.easeOut(duration: 0.25), value: model.awaitingUser)
            HStack(spacing: 8) {
                Circle().fill(model.demoPlaying ? Color.red : Color.green).frame(width: 7, height: 7)
                Text(model.demoPlaying
                     ? (model.page == .tips ? "Preview — press its keys to try it yourself" : "Demo — press any shortcut or click to try it yourself")
                     : "Your turn — the desktop is pretend, your real windows stay put")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.page == .tips {
                    if model.demoPlaying {
                        Button("Pause Previews") { model.finishDemo() }
                            .controlSize(.small)
                    } else {
                        Button("Play Previews") { model.resumeTips() }
                            .controlSize(.small)
                    }
                } else if model.demoPlaying {
                    Button("Stop Demo") { model.finishDemo() }
                        .controlSize(.small)
                } else if !model.page.demo.isEmpty {
                    Button("Watch Demo") { model.playDemo() }
                        .controlSize(.small)
                }
            }
            .frame(width: SimDesktopView.size.width)
        }
    }

    // MARK: - Pages

    private var welcome: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    pageTitle("Welcome to WindowQueue")
                    paragraph("Every window you open joins a **queue**, shown as a strip of icons at the edge of the screen. Go through it from the keyboard, pick several windows at once, tile them, group them.")
                    paragraph("The next steps each give you a pretend desktop to try one idea on — the keys work there just as they will on your real windows, which stay put.")
                    Divider()
                    Text("PERMISSIONS").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        VStack(alignment: .leading, spacing: 12) {
                            permissionRow(granted: AXIsProcessTrusted(), title: "Accessibility",
                                          detail: "Needed to see, focus and move windows. The shortcuts stay off until it's granted.") {
                                Permissions.prompt()
                                Permissions.openAccessibilitySettings()
                            }
                            permissionRow(granted: ScreenRecordingAccess.isGranted, title: "Screen Recording (optional)",
                                          detail: "Window titles from other workspaces, previews, and pictures or videos of a window.") {
                                ScreenRecordingAccess.request()
                                ScreenRecordingAccess.openSettings()
                            }
                        }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(width: 300)
            desktop
        }
        .padding(24)
    }

    private func permissionRow(granted: Bool, title: String, detail: String, grant: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 16))
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !granted {
                    Button("Grant…", action: grant).controlSize(.small).padding(.top, 2)
                }
            }
        }
    }

    private var lesson: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    lessonText
                }
                .padding(.trailing, 4)
            }
            .frame(width: 300)
            desktop
        }
        .padding(24)
    }

    @ViewBuilder
    private var lessonText: some View {
        let superKey = model.superSymbol
        let along = model.alongArrows
        switch model.page {
        case .basics:
            pageTitle("Focus and move")
            paragraph("The strip lists your windows in queue order; the highlighted one has focus. Walk through it without reaching for the mouse.")
            VStack(alignment: .leading, spacing: 6) {
                keyRow([model.combo(.cycleNext)], "Next window")
                keyRow([model.combo(.cyclePrevious)], "Previous window")
                keyRow([model.combo(.moveLeft), model.combo(.moveRight)], "Move the window earlier or later in the queue", joiner: "/")
            }
            callout("cursorarrow.click", "Click an icon to focus its window, or scroll over the strip to run through the queue. Hovering focuses the window under the pointer — you can turn that off in Setup.")
            tasks(taskList)
        case .aiming:
            pageTitle("Aiming mode")
            paragraph("Tap **\(superKey)** on its own. The screen dims, the strip grows and an orange aim appears — nothing takes focus until you say so.")
            VStack(alignment: .leading, spacing: 6) {
                keyRow([String(along.first!), String(along.last!)], "Move the aim; [ and ] work too", joiner: "/")
                keyRow(["⇧\(String(along.last!))"], "Aim at several windows")
                keyRow(["A"], "Aim at all of them")
                keyRow(["\(superKey)\(String(along.last!))"], "Carry the aimed windows along the queue")
                keyRow(["↩", superKey], "Focus the aimed window; Space works too")
                keyRow(["esc"], "Leave, changing nothing")
            }
            callout("keyboard", "**No \(superKey) needed while aiming:** shortcuts work with their letter alone — \(bareShortcuts).")
            tasks(taskList)
        case .tiling:
            pageTitle("Tiling")
            paragraph("Tiling starts in aiming mode: tap **\(superKey)** on its own first. Aim at two or more windows and a menu of layouts appears beside them. **\(model.intoArrow)** steps into it, **↩** tiles.")
            paragraph("A tiled layout follows the queue: move one of its windows along the queue and the layout reflows. Windows with fixed proportions, like the **iOS Simulator**, keep them — the others share the room that's left.")
            VStack(alignment: .leading, spacing: 6) {
                keyRow([superKey], "Tap on its own to enter aiming mode")
                keyRow(["⇧\(String(along.last!))"], "Aim multiple windows")
                keyRow([model.intoArrow, "↩"], "Open the layouts, then tile", joiner: "then")
                keyRow([String(along.first!), String(along.last!)], "Pick another layout", joiner: "/")
                keyRow(["\(superKey)\(String(along.first!))"], "While aiming: move a window, and the tiles follow")
            }
            tasks(taskList)
        case .groups:
            pageTitle("Groups")
            paragraph("Windows that belong together can be grouped: they share one place in the strip, and open in a strip of their own beside it. Grouping starts in aiming mode: tap **\(superKey)** on its own first.")
            VStack(alignment: .leading, spacing: 6) {
                keyRow([superKey], "Tap on its own to enter aiming mode")
                keyRow(["⇧\(String(along.last!))", "G"], "Aim at several, then group them", joiner: "then")
                keyRow([model.intoArrow], "While aiming at a group: step into it")
                keyRow([model.combo(.toggleGroup)], "Ungroup the selected window's group")
                keyRow([model.combo(.toggleGroupLock)], "Lock cycling to the group, and unlock it")
            }
            callout("lock.fill", "While locked, \(model.combo(.cyclePrevious)) and \(model.combo(.cycleNext)) only go round the group, and its strip shows a padlock.")
            tasks(taskList)
        default:
            EmptyView()
        }
    }

    /// The page's "Your turn" checklist.
    private var taskList: [(TourEvent, String)] {
        let superKey = model.superSymbol
        let along = model.alongArrows
        switch model.page {
        case .basics: return [(.cycled, "Go to the next window — \(model.combo(.cycleNext))"), (.moved, "Move a window along the queue — \(model.combo(.moveLeft))"),
                   (.clicked, "Click an icon in the strip")]
        case .aiming: return [(.aimed, "Tap \(superKey) on its own"), (.aimedThree, "Aim at three windows with ⇧\(String(along.last!))"),
                   (.confirmed, "Focus one with ↩ or another \(superKey) tap")]
        case .tiling: return [(.tiled, "Tile windows — tap \(superKey), ⇧\(String(along.last!)), then \(model.intoArrow) and ↩"), (.reorderedTiles, "Reorder the tiles — tap \(superKey), aim, then \(superKey)\(String(along.first!))"),
                   (.secondLayout, "Try a second layout")]
        case .groups: return [(.grouped, "Group two windows — tap \(superKey), ⇧\(String(along.last!)), then G"), (.locked, "Lock cycling to the group — \(model.combo(.toggleGroupLock))"),
                   (.cycledLocked, "Cycle while it's locked — \(model.combo(.cycleNext))")]
        default: return []
        }
    }

    /// What the desktop shows once the demo hands over: it's the user's turn now, and where to start.
    private var turnPrompt: some View {
        let next = model.currentTip?.hint ?? taskList.first { !model.done.contains($0.0) }?.1
        return VStack(spacing: 6) {
            Label("Your turn", systemImage: "hand.point.up.left.fill")
                .font(.system(size: 15, weight: .bold))
            Text("This desktop is yours to try — it follows your keys and clicks.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if let next {
                Text(.init("Try: **\(next)**")).font(.system(size: 12)).padding(.top, 2)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .allowsHitTesting(false)
    }

    /// The shortcuts that answer to their letter alone in aiming mode, the useful ones first.
    private var bareShortcuts: String {
        let wanted: [(HotkeyAction, String)] = [(.maximizeWindow, "maximize"), (.toggleMaximize, "fullscreen"),
                                                (.toggleGroup, "group"), (.closeWindow, "close")]
        let prefs = store.prefs
        return wanted.compactMap { action, word in
            let combo = prefs.combo(for: action)
            guard combo.modifiers == prefs.superModifier.carbonMask else { return nil }
            return "**\(KeyCombo.keyName(for: combo.keyCode))** \(word)"
        }.joined(separator: ", ")
    }

    // MARK: - Setup

    private var setup: some View {
        HStack(alignment: .top, spacing: 24) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pageTitle("Make it yours")
                    paragraph("The settings that matter most. Everything else is in Settings, from the menu bar icon.")
                    setting("Super key", "Held for every shortcut; tapped alone, it opens aiming mode.") {
                        Picker("", selection: Binding(get: { store.prefs.superModifier },
                                                      set: { store.setSuperModifier($0) })) {
                            ForEach(SuperModifier.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    setting("Queue", "Which windows each strip shows.") {
                        VStack(alignment: .leading, spacing: 6) {
                            scopeChoice(.global, "rectangle.stack", "All windows", "One queue of everything, everywhere.")
                            scopeChoice(.monitor, "display.2", "Each monitor", "Every monitor's strip lists its own windows.")
                            scopeChoice(.currentSpace, "square.on.square", "Each workspace", "Only the desktop on show.")
                        }
                    }
                    setting("Strip", "Where the strip sits.") {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("", selection: $store.prefs.stripSide) {
                                ForEach(StripSide.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            Picker("", selection: $store.prefs.stripAlignment) {
                                ForEach(StripAlignment.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented).labelsHidden()
                            Toggle("Hide it until aiming mode opens", isOn: $store.prefs.invisibleStrip)
                        }
                    }
                    setting("Pointer", "") {
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Focus the window under the pointer", isOn: $store.prefs.focusFollowsMouse)
                            Toggle("Move the pointer to windows focused from the keyboard", isOn: $store.prefs.warpCursorToWindow)
                        }
                    }
                    setting("Launcher", "Opened by \(model.combo(.openLauncher)), and by a double tap of \(model.superSymbol).") {
                        Picker("", selection: $store.prefs.launcher) {
                            ForEach(LauncherApp.allCases) { launcher in
                                Text(launcher.isAvailable ? launcher.title : "\(launcher.title) (not installed)").tag(launcher)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    setting("Startup", "") {
                        VStack(alignment: .leading, spacing: 3) {
                            Toggle("Launch at login", isOn: $store.prefs.launchAtLogin)
                                .disabled(!LoginItem.isInstalled)
                            if !LoginItem.isInstalled {
                                Text("Available once WindowQueue is in the Applications folder.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(.trailing, 8)
            }
            .frame(width: 330)
            VStack(spacing: 8) {
                SimDesktopView(sim: sim, prefs: store.prefs)
                Text("Preview — the strip follows your choices")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: store.prefs)
    }

    private func setting<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private func scopeChoice(_ scope: QueueScope, _ symbol: String, _ title: String, _ detail: String) -> some View {
        let chosen = store.prefs.scope == scope
        return Button {
            store.prefs.scope = scope
            if scope == .monitor { store.prefs.multiMonitorMode = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 16)).frame(width: 24)
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .medium))
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(chosen ? Color.accentColor : .secondary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(chosen ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(chosen ? Color.accentColor.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tips

    /// The tips in a list that moves on by itself, each previewed on the desktop beside it; pressing
    /// a tip's keys stops the previews and lets the user try it there.
    private var tips: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                pageTitle("A few more things")
                paragraph("Each one previews on the desktop in turn. Press its keys to try it yourself, or pick one from the list.")
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(model.tips.enumerated()), id: \.element.id) { index, tip in
                                tipRow(tip, index: index).id(index)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: model.tipIndex) { _, index in
                        withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
                Text("Reopen this tour any time from Settings › General or the menu bar icon.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 300)
            desktop
        }
        .padding(24)
    }

    private func tipRow(_ tip: TourTip, index: Int) -> some View {
        let current = index == model.tipIndex
        return Button { model.pickTip(index) } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: tip.symbol)
                        .font(.system(size: 13))
                        .frame(width: 20)
                        .foregroundStyle(current ? Color.accentColor : .secondary)
                    Text(tip.title).font(.system(size: 13, weight: current ? .semibold : .regular))
                    Spacer(minLength: 4)
                    if !current, let first = tip.keys.first { KeyCaps(text: first, small: true) }
                }
                if current {
                    if !tip.keys.isEmpty {
                        HStack(spacing: 5) {
                            ForEach(Array(tip.keys.enumerated()), id: \.offset) { KeyCaps(text: $0.element, small: true) }
                        }
                    }
                    Text(tip.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.demoPlaying {
                        TimelineView(.animation) { context in
                            let progress = min(1, context.date.timeIntervalSince(model.demoStarted) / model.demoLength)
                            GeometryReader { geometry in
                                Capsule().fill(Color.accentColor.opacity(0.25))
                                Capsule().fill(Color.accentColor).frame(width: geometry.size.width * progress)
                            }
                            .frame(height: 3)
                        }
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(current ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(current ? Color.accentColor.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.3), value: current)
    }
}

/// Hosts the tour in a normal window. While it has the keyboard, the keys and the super key tap go
/// to its pretend desktop, and `onKeyboardChange` lets the app stand its own shortcuts down.
final class TourWindowController: NSWindowController, NSWindowDelegate {
    var onKeyboardChange: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let model: TourModel
    private let taps = ModifierTapMonitor()
    private var keyMonitor: Any?
    private var superKeyWatch: AnyCancellable?

    init(store: PreferencesStore) {
        model = TourModel(store: store)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: TourView.size),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Welcome to WindowQueue"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: TourView(model: model) { [weak window] in window?.performClose(nil) })
        window.center()
        window.delegate = self
        taps.onTap = { [weak self] in self?.model.superTap() }
        // The super key can change on the Setup page; the pages before it then answer to the new one.
        superKeyWatch = store.$prefs.map(\.superModifier).removeDuplicates()
            .sink { [weak self] modifier in self?.taps.modifiers = modifier.eventFlags }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    func present() {
        if window?.isVisible != true { model.show(.welcome) }
        showWindow(nil)
        if let window { OwnWindows.present(window) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        taps.modifiers = model.prefs.superModifier.eventFlags
        taps.start(includingOtherApps: false)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            // Holding the super key for a shortcut is not a tap of it.
            self.taps.cancel()
            return self.model.handleKey(keyCode: Int(event.keyCode), flags: event.modifierFlags,
                                        characters: event.charactersIgnoringModifiers) ? nil : event
        }
        onKeyboardChange?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        taps.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onKeyboardChange?(false)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose?()
    }

    /// Draws every page — and the demo's states along the way — into PNGs without putting anything
    /// on screen, for checking the tour's look. Debug command `tour-render <dir>`.
    static func render(store: PreferencesStore, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = TourModel(store: store)
        model.sim.animated = false
        let host = NSHostingView(rootView: TourView(model: model))
        host.frame = NSRect(origin: .zero, size: TourView.size)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: TourView.size.width, height: TourView.size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // Under ARC, a window released on close would be released twice.
        window.isReleasedWhenClosed = false
        window.contentView = host
        func snap(_ name: String) {
            // Let transitions and springs finish, as they would on screen.
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        for page in TourPage.allCases {
            // The demo step by step, without its timers, then the hand-over to the user.
            model.show(page, scheduled: false)
            snap("\(page.rawValue)-\(page.title)-0")
            var shot = 1
            for step in page.demo {
                if case .wait = step { continue }
                model.run(step)
                snap("\(page.rawValue)-\(page.title)-\(shot)")
                shot += 1
            }
            model.finishDemo()
            snap("\(page.rawValue)-\(page.title)-turn")
        }
        // Every tip's preview, step by step.
        model.show(.tips, scheduled: false)
        for (index, tip) in model.tips.enumerated() {
            model.showTip(index, scheduled: false)
            snap("tip\(index)-\(tip.id)-0")
            var shot = 1
            for step in tip.preview {
                if case .wait = step { continue }
                model.run(step)
                snap("tip\(index)-\(tip.id)-\(shot)")
                shot += 1
            }
        }
        window.close()
    }
}
