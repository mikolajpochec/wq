import AppKit
import Carbon.HIToolbox

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
    var isInteractive: Bool {
        switch self {
        case .welcome, .basics, .aiming, .tiling, .groups: return true
        case .setup, .tips: return false
        }
    }

    var windows: [SimWindow] {
        switch self {
        case .tiling: return [.xcode, .simulator, .safari, .terminal]
        case .aiming, .groups: return [.safari, .notes, .terminal, .mail, .music]
        default: return [.safari, .notes, .terminal, .mail]
        }
    }

    /// What the demo does, the keys shown as it presses them. Loops until the user takes over.
    var demo: [TourModel.DemoStep] {
        switch self {
        case .welcome:
            return [.wait(1), .action(.cycleNext), .wait(1), .action(.cycleNext), .wait(1.2), .superTap,
                    .wait(0.8), .key(.next), .wait(0.6), .key(.next, extend: true), .wait(1.2), .key(.cancel),
                    .wait(1), .action(.cycleNext), .wait(1.5)]
        case .basics:
            return [.wait(1), .action(.cycleNext), .wait(1), .action(.cycleNext), .wait(1.3), .action(.moveLeft),
                    .wait(1), .action(.moveLeft), .wait(1.3), .click(SimWindow.mail.id), .wait(1.3),
                    .action(.cyclePrevious), .wait(1.6)]
        case .aiming:
            return [.wait(0.8), .superTap, .wait(1), .key(.next), .wait(0.7), .key(.next), .wait(1),
                    .key(.next, extend: true), .wait(0.7), .key(.next, extend: true), .wait(1.4), .key(.cancel),
                    .wait(1), .superTap, .wait(0.8), .key(.next), .wait(0.8), .key(.enter), .wait(1.6)]
        case .tiling:
            return [.wait(0.8), .superTap, .wait(0.8), .key(.next, extend: true), .wait(0.6),
                    .key(.next, extend: true), .wait(1), .key(.into), .wait(1), .key(.enter), .wait(1.8),
                    // Moving the Simulator to the front makes it the main window: the layout reflows,
                    // and the phone keeps its proportions while the others share what is left.
                    .superTap, .wait(0.7), .key(.next), .wait(0.8), .key(.previous, carry: true), .wait(1.8),
                    .key(.cancel), .wait(0.8), .superTap, .wait(0.6), .key(.previous), .wait(0.5),
                    .key(.next, extend: true), .wait(0.5),
                    .key(.next, extend: true), .wait(0.8), .key(.into), .wait(0.8), .key(.next), .wait(0.8),
                    .key(.enter), .wait(2)]
        case .groups:
            return [.wait(0.8), .superTap, .wait(0.7), .key(.next), .wait(0.6), .key(.next, extend: true),
                    .wait(1), .bareAction(.toggleGroup), .wait(1.5), .action(.toggleGroupLock), .wait(1.3),
                    .action(.cycleNext), .wait(1), .action(.cycleNext), .wait(1), .action(.toggleGroupLock),
                    .wait(1.2), .action(.cycleNext), .wait(1.6)]
        case .setup, .tips:
            return []
        }
    }
}

/// Drives the tour: which page is up, the demo playing on it, and the keys the user tries.
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
        case wait(TimeInterval)
    }

    @Published private(set) var page: TourPage = .welcome
    @Published private(set) var demoPlaying = false
    let sim = TourSim()
    let store: PreferencesStore
    private var demoWork: [DispatchWorkItem] = []

    init(store: PreferencesStore) {
        self.store = store
        sim.reset(TourPage.welcome.windows)
    }

    var prefs: Preferences { store.prefs }

    func show(_ page: TourPage) {
        stopDemo()
        self.page = page
        sim.reset(page.windows)
        sim.clearDone()
        if !page.demo.isEmpty { playDemo() }
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

    // MARK: - Demo

    func playDemo() {
        stopDemo()
        sim.reset(page.windows)
        demoPlaying = true
        var at: TimeInterval = 0
        for step in page.demo {
            if case .wait(let seconds) = step {
                at += seconds
                continue
            }
            let work = DispatchWorkItem { [weak self] in self?.run(step) }
            demoWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + at, execute: work)
        }
        let again = DispatchWorkItem { [weak self] in self?.playDemo() }
        demoWork.append(again)
        DispatchQueue.main.asyncAfter(deadline: .now() + at + 1, execute: again)
    }

    private func stopDemo() {
        demoWork.forEach { $0.cancel() }
        demoWork = []
        demoPlaying = false
    }

    /// The user pressed a key or clicked: the demo makes way, and the desktop starts afresh.
    private func takeOver() {
        guard demoPlaying else { return }
        stopDemo()
        sim.reset(page.windows)
        sim.clearDone()
    }

    func run(_ step: DemoStep) {
        let prefs = self.prefs
        switch step {
        case .action(let action):
            let combo = prefs.combo(for: action)
            sim.press(keyCode: Int(combo.keyCode), flags: Self.flags(combo.modifiers), prefs: prefs)
        case .bareAction(let action):
            sim.press(keyCode: Int(prefs.combo(for: action).keyCode), flags: [], prefs: prefs)
        case .key(let key, let extend, let carry):
            var flags: NSEvent.ModifierFlags = []
            if extend { flags.insert(.shift) }
            if carry { flags.formUnion(prefs.superModifier.eventFlags) }
            sim.press(keyCode: keyCode(key), flags: flags, prefs: prefs)
        case .superTap:
            sim.superTap(symbol: prefs.superModifier.symbol)
        case .click(let id):
            sim.click(id)
        case .wait:
            break
        }
    }

    private func keyCode(_ key: DemoKey) -> Int {
        let vertical = prefs.stripSide.isVertical
        switch key {
        case .next: return vertical ? kVK_DownArrow : kVK_RightArrow
        case .previous: return vertical ? kVK_UpArrow : kVK_LeftArrow
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

    func handleKey(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard page.isInteractive else { return false }
        if demoPlaying {
            // Only a key the desktop answers takes the demo away; ⌘W and the like pass through.
            let probe = TourSim()
            probe.animated = false
            probe.reset(page.windows)
            guard probe.press(keyCode: keyCode, flags: flags, prefs: prefs) else { return false }
            takeOver()
        }
        return sim.press(keyCode: keyCode, flags: flags, prefs: prefs)
    }

    func superTap() {
        guard page.isInteractive else { return }
        takeOver()
        sim.superTap(symbol: prefs.superModifier.symbol)
    }

    func click(_ id: Int) {
        takeOver()
        sim.click(id)
    }

    // MARK: - Words

    func combo(_ action: HotkeyAction) -> String { prefs.combo(for: action).displayString }

    var superSymbol: String { prefs.superModifier.symbol }

    /// The arrows that run along the strip.
    var alongArrows: String { prefs.stripSide.isVertical ? "↑↓" : "←→" }

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
