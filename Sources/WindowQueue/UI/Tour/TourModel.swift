import AppKit
import Carbon.HIToolbox
import Combine

/// The tour's pages, in order.
enum TourPage: Int, CaseIterable, Identifiable {
    case welcome, basics, aiming, tiling, groups, setup, tips

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .basics: return "Focus"
        case .aiming: return "Aiming"
        case .tiling: return "Tiling"
        case .groups: return "Groups"
        case .setup: return "Setup"
        case .tips: return "Tips"
        }
    }

    /// The pretend desktop answers the keys on these pages.
    var isInteractive: Bool { self != .setup }

    var windows: [SimWindow] {
        switch self {
        case .tiling: return [.xcode, .simulator, .safari, .terminal]
        case .aiming, .groups: return [.safari, .notes, .terminal, .mail, .music]
        default: return [.safari, .notes, .terminal, .mail]
        }
    }

    /// The Welcome page's demo, the keys shown as it presses them. It loops until the user does
    /// anything; the lesson pages have none — they are the user's to try from the start, and a
    /// desktop moving on its own there read as canned rather than responsive. (The tips preview
    /// each tip in turn instead; see `TourTip`.)
    var demo: [TourModel.DemoStep] {
        guard self == .welcome else { return [] }
        return [.wait(1), .action(.cycleNext), .wait(1), .action(.cycleNext), .wait(1.2), .superTap,
                .wait(0.8), .key(.previous), .wait(0.6), .key(.previous), .wait(0.6), .key(.next, extend: true),
                .wait(0.6), .key(.next, extend: true), .wait(1), .key(.into), .wait(0.9), .key(.enter), .wait(1.8),
                .superTap, .wait(0.7), .key(.cancel), .wait(1), .action(.cycleNext), .wait(1.5)]
    }
}

/// One of the tips on the last page: what it does, its keys, and a preview on the pretend desktop
/// that plays before the next tip comes up — or that the user can take over and try.
struct TourTip: Identifiable {
    /// One of a tip's shortcuts, and what the pretend desktop records once it has been used.
    struct Goal {
        let keys: String
        let event: TourEvent
    }

    let id: String
    let symbol: String
    let title: String
    let goals: [Goal]
    let text: String
    /// What to try, for the "Your turn" card.
    let hint: String
    let setup: SimSetup
    let preview: [TourModel.DemoStep]

    var keys: [String] { goals.map(\.keys) }

    func used(_ goal: Goal, in done: Set<TourEvent>) -> Bool { done.contains(goal.event) }

    /// Every one of the tip's shortcuts has been used, so the next tip can come up.
    func isDone(_ done: Set<TourEvent>) -> Bool { goals.allSatisfy { done.contains($0.event) } }
}

/// Drives the tour: which page is up, the demo or preview playing on it, and the keys the user tries.
final class TourModel: ObservableObject {
    enum DemoKey { case next, previous, into, enter, cancel, all }

    enum DemoStep {
        /// A shortcut pressed with its full combo.
        case action(HotkeyAction)
        /// A shortcut's key alone, as aiming mode takes it.
        case bareAction(HotkeyAction)
        case key(DemoKey, extend: Bool = false, carry: Bool = false)
        case superTap
        case click(Int)
        /// Typed into the search panel.
        case type(String)
        /// The pretend pointer goes to an icon of the strip (nil hides it).
        case pointer(Int?)
        case lift(Int)
        case dragStep(Int)
        case drop
        case wait(TimeInterval)
    }

    @Published private(set) var page: TourPage = .welcome
    @Published private(set) var demoPlaying = false
    /// When the demo started and how long it runs, for its progress bar.
    @Published private(set) var demoStarted = Date.distantPast
    @Published private(set) var demoLength: TimeInterval = 1
    /// The desktop is the user's and they haven't done anything yet: it says it's their turn, so it
    /// is not mistaken for something predefined.
    @Published private(set) var awaitingUser = false
    /// The tip on show, and whether the tips go on to the next by themselves.
    @Published private(set) var tipIndex = 0
    @Published private(set) var tipsPlaying = true
    let sim = TourSim()
    let store: PreferencesStore
    private var demoWork: [DispatchWorkItem] = []
    private var simWatch: AnyCancellable?
    /// A finished tip is about to hand on to the next.
    private var advancing = false

    init(store: PreferencesStore) {
        self.store = store
        sim.reset(TourPage.welcome.windows)
        // `objectWillChange` fires before the change lands; look on the next turn.
        simWatch = sim.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.advanceIfTipDone() }
        }
    }

    var prefs: Preferences { store.prefs }

    /// - Parameter scheduled: off, the demo is only marked as playing and its steps are left for
    ///   the caller to `run` — for rendering the tour without timers.
    func show(_ page: TourPage, scheduled: Bool = true) {
        stopDemo()
        awaitingUser = false
        self.page = page
        sim.clearDone()
        if page == .tips {
            tipsPlaying = true
            showTip(0, scheduled: scheduled)
            return
        }
        resetDesktop()
        if page.demo.isEmpty {
            awaitingUser = page.isInteractive
        } else {
            playDemo(scheduled: scheduled)
        }
    }

    func next() {
        if let next = TourPage(rawValue: page.rawValue + 1) { show(next) }
    }

    func back() {
        if let previous = TourPage(rawValue: page.rawValue - 1) { show(previous) }
    }

    func stop() { stopDemo() }

    /// What the user has done on this page; the demo's own doings don't count.
    var done: Set<TourEvent> { demoPlaying ? [] : sim.done }

    // MARK: - Tips

    var currentTip: TourTip? { page == .tips ? tips[safe: tipIndex] : nil }

    /// Previews a tip; with the tips playing, the next one follows when it ends.
    func showTip(_ index: Int, scheduled: Bool = true) {
        guard tips.indices.contains(index) else { return }
        tipIndex = index
        playDemo(scheduled: scheduled)
    }

    /// The user picked a tip from the list: its preview plays, and the tips go on from there.
    func pickTip(_ index: Int) {
        tipsPlaying = true
        showTip(index)
    }

    func resumeTips() {
        tipsPlaying = true
        showTip(tipIndex)
    }

    /// The user has used every one of the tip's shortcuts: a second to see the last one happen,
    /// then on to the next tip.
    private func advanceIfTipDone() {
        guard page == .tips, !demoPlaying, !advancing, let tip = currentTip, tip.isDone(sim.done) else { return }
        advancing = true
        let index = tipIndex
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.advancing = false
            guard self.page == .tips, self.tipIndex == index, !self.demoPlaying else { return }
            self.tipsPlaying = true
            self.showTip((index + 1) % max(self.tips.count, 1))
        }
    }

    var tips: [TourTip] {
        let superKey = superSymbol
        let launcher = prefs.launcher.title
        var tips = [
            TourTip(id: "workspaces", symbol: "square.grid.3x3", title: "Workspaces",
                    goals: [.init(keys: "\(combo(.space1))…9", event: .switchedSpace), .init(keys: "\(combo(.moveToSpace1))…9", event: .movedToSpace),
                            .init(keys: combo(.goToEmptySpace), event: .wentToEmptySpace)],
                    text: "\(combo(.space1))…9 go to workspace N; \(combo(.moveToSpace1))…9 take the window along. \(combo(.goToEmptySpace)) finds an empty one.",
                    hint: "\(combo(.space2)), \(combo(.moveToSpace1)) and \(combo(.goToEmptySpace))",
                    setup: SimSetup(windows: [.safari, .notes, .terminal, .mail], spaces: [3: 2, 4: 2], spaceCount: 3),
                    preview: [.wait(0.8), .action(.space2), .wait(1.3), .action(.space1), .wait(1.1), .action(.cycleNext),
                              .wait(0.9), .action(.moveToSpace2), .wait(1.5), .action(.goToEmptySpace), .wait(1.4),
                              .action(.space1), .wait(1.2)]),
            TourTip(id: "search", symbol: "magnifyingglass", title: "Search",
                    goals: [.init(keys: combo(.search), event: .searched)],
                    text: "Find any window by typing part of its name; ↩ goes there.",
                    hint: "\(combo(.search)), type part of a name, ↩",
                    setup: SimSetup(windows: [.safari, .notes, .terminal, .mail, .music]),
                    preview: [.wait(0.8), .action(.search), .wait(0.8), .type("t"), .wait(0.35), .type("e"), .wait(0.35),
                              .type("r"), .wait(1.1), .key(.enter), .wait(1.6)]),
            TourTip(id: "launcher", symbol: "sparkle.magnifyingglass", title: "Launcher",
                    goals: [.init(keys: combo(.openLauncher), event: .launched), .init(keys: "\(superKey) \(superKey)", event: .doubleTapped)],
                    text: "\(combo(.openLauncher)) opens \(launcher). Two quick taps of \(superKey): \(prefs.superDoubleTapAction?.title.lowercased() ?? "focus the aimed window").",
                    hint: "\(combo(.openLauncher)), then tap \(superKey) twice",
                    setup: SimSetup(windows: [.safari, .notes, .terminal]),
                    preview: [.wait(0.8), .action(.openLauncher), .wait(2.3), .superTap, .wait(0.15), .superTap, .wait(2.3)]),
            TourTip(id: "maximize", symbol: "arrow.up.left.and.arrow.down.right", title: "Maximize and fullscreen",
                    goals: [.init(keys: combo(.maximizeWindow), event: .maximized), .init(keys: combo(.toggleMaximize), event: .fullscreened)],
                    text: "\(combo(.maximizeWindow)) fills the screen beside the strip. \(combo(.toggleMaximize)) goes fullscreen; again, and the window is back.",
                    hint: "\(combo(.maximizeWindow)), then \(combo(.toggleMaximize))",
                    setup: SimSetup(windows: [.safari, .notes, .terminal, .mail]),
                    preview: [.wait(0.8), .action(.maximizeWindow), .wait(1.4), .action(.cycleNext), .wait(1), .action(.toggleMaximize),
                              .wait(1.4), .action(.toggleMaximize), .wait(1.3)]),
            TourTip(id: "declutter", symbol: "rectangle.3.group", title: "Declutter",
                    goals: [.init(keys: combo(.declutter), event: .decluttered)],
                    text: "Every window in view at once, none on top of another, resized as little as possible.",
                    hint: combo(.declutter),
                    setup: SimSetup(windows: [.safari, .notes, .terminal, .mail]),
                    preview: [.wait(1), .action(.declutter), .wait(2.6)]),
            TourTip(id: "capture", symbol: "camera.viewfinder", title: "Picture or video",
                    goals: [.init(keys: combo(.screenshotWindow), event: .pictured), .init(keys: combo(.toggleRecording), event: .videoSaved)],
                    text: "\(combo(.screenshotWindow)) takes a picture, \(combo(.toggleRecording)) starts and stops a video — of the one window, not the screen.",
                    hint: "\(combo(.screenshotWindow)), then \(combo(.toggleRecording)) to start and stop",
                    setup: SimSetup(windows: [.safari, .notes, .terminal]),
                    preview: [.wait(0.8), .action(.screenshotWindow), .wait(1.5), .action(.toggleRecording), .wait(2.4),
                              .action(.toggleRecording), .wait(1.5)]),
            TourTip(id: "invisible", symbol: "eye.slash", title: "Invisible strip",
                    goals: [.init(keys: combo(.toggleInvisibleStrip), event: .hidStrip), .init(keys: superKey, event: .peekedStrip)],
                    text: "Hide the strip and get its room back; it shows up again whenever aiming mode opens.",
                    hint: "\(combo(.toggleInvisibleStrip)), then tap \(superKey) to see the strip",
                    setup: SimSetup(windows: [.safari, .notes, .terminal]),
                    preview: [.wait(0.8), .action(.toggleInvisibleStrip), .wait(1.4), .superTap, .wait(1.3), .key(.cancel),
                              .wait(1), .action(.toggleInvisibleStrip), .wait(1.3)]),
            TourTip(id: "drag", symbol: "hand.draw", title: "Drag and drop",
                    goals: [.init(keys: "Drag an icon", event: .dropped)],
                    text: "Drag an icon along the strip to reorder the queue.",
                    hint: "Drag an icon along the strip",
                    setup: SimSetup(windows: [.safari, .notes, .terminal, .mail]),
                    preview: [.wait(0.6), .pointer(SimWindow.mail.id), .wait(0.8), .lift(SimWindow.mail.id), .wait(0.4),
                              .dragStep(-1), .wait(0.45), .dragStep(-1), .wait(0.45), .dragStep(-1), .wait(0.6), .drop,
                              .wait(0.8), .pointer(nil), .wait(1)]),
        ]
        if prefs.multiMonitorMode {
            tips.insert(TourTip(id: "monitors", symbol: "display.2", title: "Monitors",
                                goals: [.init(keys: combo(.focusNextMonitor), event: .switchedMonitor), .init(keys: combo(.moveToNextMonitor), event: .movedToMonitor)],
                                text: "Each monitor has its own strip. \(combo(.focusNextMonitor)) goes to the next monitor, \(combo(.moveToNextMonitor)) takes the window along; \(combo(.focusMonitor1))…4 go to monitor N.",
                                hint: "\(combo(.focusNextMonitor)), then \(combo(.moveToNextMonitor))",
                                setup: SimSetup(windows: [.safari, .notes, .terminal, .mail], monitors: [3: 1, 4: 1], monitorCount: 2),
                                preview: [.wait(0.9), .action(.focusNextMonitor), .wait(1.4), .action(.focusNextMonitor), .wait(1.3),
                                          .action(.moveToNextMonitor), .wait(1.6), .action(.focusNextMonitor), .wait(1.3)]),
                        at: 1)
        }
        return tips
    }

    // MARK: - Demo

    private var demoSteps: [DemoStep] { currentTip?.preview ?? page.demo }

    private func resetDesktop() {
        if let tip = currentTip {
            sim.reset(tip.setup)
        } else {
            sim.reset(page.windows)
        }
    }

    /// Plays the demo (or the tip's preview) from the start.
    func playDemo(scheduled: Bool = true) {
        stopDemo()
        resetDesktop()
        awaitingUser = false
        demoPlaying = true
        guard scheduled else { return }
        var at: TimeInterval = 0
        var lastStep: TimeInterval = 0
        for step in demoSteps {
            if case .wait(let seconds) = step {
                at += seconds
                continue
            }
            let work = DispatchWorkItem { [weak self] in self?.run(step) }
            demoWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: work)
            lastStep = at
        }
        demoStarted = Date()
        // A tip hands on to the next as soon as its last step has had a moment to show.
        demoLength = page == .tips ? lastStep + 1.2 : at + 0.6
        let end = DispatchWorkItem { [weak self] in self?.demoEnded() }
        demoWork.append(end)
        DispatchQueue.main.asyncAfter(deadline: .now() + demoLength, execute: end)
    }

    /// The Welcome demo loops; a tip's preview hands on to the next tip, or to the user once the
    /// tips are paused.
    private func demoEnded() {
        guard page == .tips else {
            playDemo()
            return
        }
        if tipsPlaying {
            showTip((tipIndex + 1) % max(tips.count, 1))
        } else {
            finishDemo()
        }
    }

    /// Ends the demo and gives the desktop, back as it started, to the user.
    func finishDemo() {
        stopDemo()
        if page == .tips { tipsPlaying = false }
        resetDesktop()
        sim.clearDone()
        awaitingUser = page.isInteractive
    }

    private func stopDemo() {
        demoWork.forEach { $0.cancel() }
        demoWork = []
        demoPlaying = false
    }

    /// The user pressed a key, clicked or dragged: the demo makes way at once, the desktop starts
    /// afresh, and the tips stay on this one.
    func takeOver() {
        awaitingUser = false
        guard demoPlaying else { return }
        stopDemo()
        if page == .tips { tipsPlaying = false }
        resetDesktop()
        sim.clearDone()
    }

    func run(_ step: DemoStep) {
        Self.perform(step, on: sim, prefs: prefs)
    }

    /// Plays one step on a pretend desktop, with the keys the given settings bind.
    static func perform(_ step: DemoStep, on sim: TourSim, prefs: Preferences) {
        switch step {
        case .action(let action):
            let combo = prefs.combo(for: action)
            sim.press(keyCode: Int(combo.keyCode), flags: flags(combo.modifiers), prefs: prefs)
        case .bareAction(let action):
            sim.press(keyCode: Int(prefs.combo(for: action).keyCode), flags: [], prefs: prefs)
        case .key(let key, let extend, let carry):
            var flags: NSEvent.ModifierFlags = []
            if extend { flags.insert(.shift) }
            if carry { flags.formUnion(prefs.superModifier.eventFlags) }
            sim.press(keyCode: keyCode(key, prefs: prefs), flags: flags, prefs: prefs)
        case .superTap:
            sim.superTap(symbol: prefs.superModifier.symbol, doubleTap: prefs.superDoubleTapAction)
        case .click(let id):
            sim.click(id)
        case .type(let text):
            sim.type(text)
        case .pointer(let id):
            sim.point(at: id)
        case .lift(let id):
            sim.beginDrag(id)
        case .dragStep(let step):
            sim.drag(by: step)
        case .drop:
            sim.endDrag()
        case .wait:
            break
        }
    }

    private static func keyCode(_ key: DemoKey, prefs: Preferences) -> Int {
        switch key {
        // [ and ] move along the queue whichever side the strip is on; the arrows work too.
        case .next: return kVK_ANSI_RightBracket
        case .previous: return kVK_ANSI_LeftBracket
        case .into:
            switch prefs.stripSide {
            case .left: return kVK_RightArrow
            case .right: return kVK_LeftArrow
            case .top: return kVK_DownArrow
            case .bottom: return kVK_UpArrow
            }
        case .enter: return kVK_Return
        case .cancel: return kVK_Escape
        case .all: return kVK_ANSI_A
        }
    }

    private static func flags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    // MARK: - The user's turn

    func handleKey(keyCode: Int, flags: NSEvent.ModifierFlags, characters: String? = nil) -> Bool {
        guard page.isInteractive else { return false }
        // The user is trying it: whatever the key, the demo stops at once.
        takeOver()
        return sim.press(keyCode: keyCode, flags: flags, prefs: prefs, characters: characters)
    }

    func superTap() {
        guard page.isInteractive else { return }
        takeOver()
        sim.superTap(symbol: prefs.superModifier.symbol, doubleTap: prefs.superDoubleTapAction)
    }

    func click(_ id: Int) {
        takeOver()
        sim.click(id)
    }

    // MARK: - Words

    func combo(_ action: HotkeyAction) -> String { prefs.combo(for: action).displayString }

    var superSymbol: String { prefs.superModifier.symbol }

    /// The arrow pointing from the strip into the screen.
    var intoArrow: String {
        switch prefs.stripSide {
        case .left: return "→"
        case .right: return "←"
        case .top: return "↓"
        case .bottom: return "↑"
        }
    }
}
