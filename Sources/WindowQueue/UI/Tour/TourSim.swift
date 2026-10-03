import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A window on the tour's pretend desktop: a pictogram standing in for a real app's window.
struct SimWindow: Identifiable, Equatable {
    let id: Int
    let name: String
    let symbol: String
    let tint: Color
    /// Where the window sits when nothing has placed it, as a unit rect of the desktop's free area.
    var home: CGRect
    /// Width over height for a window that keeps its proportions, like the iOS Simulator.
    var aspect: CGFloat?

    var isPhone: Bool { aspect != nil }

    static let safari = SimWindow(id: 1, name: "Safari", symbol: "safari", tint: .blue,
                                  home: CGRect(x: 0.04, y: 0.05, width: 0.58, height: 0.6))
    static let notes = SimWindow(id: 2, name: "Notes", symbol: "note.text", tint: .orange,
                                 home: CGRect(x: 0.3, y: 0.14, width: 0.46, height: 0.56))
    static let terminal = SimWindow(id: 3, name: "Terminal", symbol: "terminal", tint: .gray,
                                    home: CGRect(x: 0.46, y: 0.36, width: 0.5, height: 0.56))
    static let mail = SimWindow(id: 4, name: "Mail", symbol: "envelope", tint: .cyan,
                                home: CGRect(x: 0.12, y: 0.4, width: 0.48, height: 0.54))
    static let xcode = SimWindow(id: 5, name: "Xcode", symbol: "hammer", tint: .indigo,
                                 home: CGRect(x: 0.03, y: 0.04, width: 0.66, height: 0.82))
    static let simulator = SimWindow(id: 6, name: "iOS Simulator", symbol: "iphone", tint: .pink,
                                     home: CGRect(x: 0.72, y: 0.06, width: 0.24, height: 0.88), aspect: 0.48)
    static let music = SimWindow(id: 7, name: "Music", symbol: "music.note", tint: .red,
                                 home: CGRect(x: 0.36, y: 0.08, width: 0.44, height: 0.5))
}

/// Things the user did in the pretend desktop, which tick off a page's tasks.
enum TourEvent: Hashable {
    case cycled, moved, clicked
    case aimed, aimedSeveral, aimedThree, confirmed, cancelled
    case tiled, reorderedTiles, secondLayout
    case grouped, enteredGroup, locked, cycledLocked
    case switchedSpace, movedToSpace, wentToEmptySpace
    case switchedMonitor, movedToMonitor
    case searched, launched, doubleTapped, maximized, fullscreened, restored, decluttered
    case pictured, recorded, videoSaved, hidStrip, stripBack, peekedStrip, dragged, dropped
    case closed, closedWhileAiming
}

/// Where the pretend desktop starts: which windows, and on which workspace and monitor each is.
struct SimSetup {
    var windows: [SimWindow]
    var selected: Int?
    /// Workspace per window id (1-based); unlisted windows are on workspace 1.
    var spaces: [Int: Int] = [:]
    /// Monitor per window id (0-based); unlisted windows are on the first.
    var monitors: [Int: Int] = [:]
    var spaceCount = 1
    var monitorCount = 1
}

/// The tour's pretend desktop: a queue of pictogram windows that answers the same keys WindowQueue
/// does — cycling, aiming, tiling, groups, workspaces, monitors and the rest — without touching a
/// real window. Kept to what the tour shows; tiling goes through the real `TileSolver`, so the iOS
/// Simulator keeps its proportions the way it does for real.
final class TourSim: ObservableObject {
    struct Group: Equatable {
        let id: Int
        var ids: [Int]
    }

    /// An entry of the strip: a window on its own, or a group standing in one place for its members.
    enum Entry: Hashable {
        case window(Int)
        case group(Int)
    }

    struct Flash: Equatable {
        let id: Int
        let text: String
    }

    /// Something marked on one window or monitor for a moment: the picture's shutter, a monitor frame.
    struct Mark: Equatable {
        let id: Int
        let target: Int
    }

    @Published private(set) var windows: [SimWindow] = []
    @Published private(set) var queue: [Int] = []
    @Published private(set) var selected: Int?
    /// Back to front.
    @Published private(set) var zOrder: [Int] = []
    @Published private(set) var aiming = false
    @Published private(set) var aimAnchor = 0
    @Published private(set) var aimCursor = 0
    @Published private(set) var insideGroup: Int?
    @Published private(set) var menuFocused = false
    @Published private(set) var menuIndex = 0
    @Published private(set) var tiled: [Int] = []
    @Published private(set) var tiledLayout: String?
    /// Maximized windows stay so until sent fullscreen and back; the fullscreen one is `fullscreen`.
    @Published private(set) var maximized: Set<Int> = []
    @Published private(set) var fullscreen: Int?
    @Published private(set) var groups: [Group] = []
    @Published private(set) var lockedGroup: Int?

    @Published private(set) var spaceOf: [Int: Int] = [:]
    @Published private(set) var monitorOf: [Int: Int] = [:]
    @Published private(set) var spaceCount = 1
    @Published private(set) var monitorCount = 1
    /// The workspace each monitor has on show.
    @Published private(set) var shownSpace: [Int] = [1]
    /// Which way the last workspace switch went, for the slide.
    @Published private(set) var spaceDirection = 1
    /// The monitor worked on when no window there is selected.
    @Published private(set) var activeMonitor = 0

    @Published private(set) var searchOpen = false
    @Published private(set) var query = ""
    @Published private(set) var launcher: Flash?
    @Published private(set) var shutter: Mark?
    @Published private(set) var monitorFrame: Mark?
    @Published private(set) var recording: Int?
    @Published private(set) var stripHidden = false
    @Published private(set) var decluttered = false
    @Published private(set) var closed: Set<Int> = []
    /// The icon being dragged along the strip, and the icon the pretend pointer rests on.
    @Published private(set) var lifted: Int?
    @Published private(set) var pointer: Int?

    /// The keys just pressed, shown as keycaps over the desktop.
    @Published private(set) var keys: Flash?
    /// A word from the app, the way it shows a toast.
    @Published private(set) var note: Flash?
    @Published private(set) var done: Set<TourEvent> = []

    private var layoutsUsed: Set<String> = []
    private var nextGroupID = 1
    private var flashCount = 0
    private var aimingOpenedAt = Date.distantPast
    private var dragStart = 0
    private var launcherName = "Spotlight"
    var animated = true

    static let doubleTapInterval: TimeInterval = 0.4

    // MARK: - Setting up

    func reset(_ windows: [SimWindow], selected: Int? = nil) {
        reset(SimSetup(windows: windows, selected: selected))
    }

    func reset(_ setup: SimSetup) {
        change {
            windows = setup.windows
            queue = windows.map(\.id)
            zOrder = queue.reversed()
            spaceOf = Dictionary(uniqueKeysWithValues: queue.map { ($0, setup.spaces[$0] ?? 1) })
            monitorOf = Dictionary(uniqueKeysWithValues: queue.map { ($0, setup.monitors[$0] ?? 0) })
            spaceCount = setup.spaceCount
            monitorCount = setup.monitorCount
            shownSpace = Array(repeating: 1, count: setup.monitorCount)
            activeMonitor = 0
            selected = setup.selected ?? queue.first
            if let s = selected { raise(s) }
            aiming = false
            insideGroup = nil
            menuFocused = false
            tiled = []
            tiledLayout = nil
            maximized = []
            fullscreen = nil
            groups = []
            lockedGroup = nil
            searchOpen = false
            query = ""
            launcher = nil
            shutter = nil
            monitorFrame = nil
            recording = nil
            stripHidden = false
            decluttered = false
            closed = []
            lifted = nil
            pointer = nil
            keys = nil
            note = nil
            layoutsUsed = []
        }
    }

    /// Forgets which tasks were done, for a page started afresh.
    func clearDone() { done = [] }

    func window(_ id: Int) -> SimWindow? { windows.first { $0.id == id } }

    // MARK: - Workspaces and monitors

    /// The monitor being worked on: the selected window's, else the one last gone to.
    var focusedMonitor: Int { selected.flatMap { monitorOf[$0] } ?? activeMonitor }

    func monitor(of id: Int) -> Int { monitorOf[id] ?? 0 }

    func space(of id: Int) -> Int { spaceOf[id] ?? 1 }

    /// On the workspace its monitor has on show, and not closed.
    func isOnShow(_ id: Int) -> Bool {
        !closed.contains(id) && space(of: id) == shownSpace[safe: monitor(of: id)]
    }

    /// The queue of one monitor's strip: its windows on every workspace, in queue order.
    func queue(onMonitor monitor: Int) -> [Int] {
        queue.filter { self.monitor(of: $0) == monitor && !closed.contains($0) }
    }

    // MARK: - Strip

    /// The focused monitor's strip, which aiming and cycling work on.
    var entries: [Entry] { entries(onMonitor: focusedMonitor) }

    func entries(onMonitor monitor: Int) -> [Entry] {
        var out: [Entry] = []
        var seen = Set<Int>()
        for id in queue(onMonitor: monitor) {
            if let group = group(of: id) {
                if seen.insert(group.id).inserted { out.append(.group(group.id)) }
            } else {
                out.append(.window(id))
            }
        }
        return out
    }

    func group(of id: Int) -> Group? { groups.first { $0.ids.contains(id) } }

    /// A group's members in queue order.
    func members(_ groupID: Int) -> [Int] {
        guard let group = groups.first(where: { $0.id == groupID }) else { return [] }
        return queue.filter(group.ids.contains)
    }

    func ids(of entry: Entry) -> [Int] {
        switch entry {
        case .window(let id): return [id]
        case .group(let id): return members(id)
        }
    }

    /// What the aim moves over: the strip's entries, or a group's members once stepped into it.
    var aimEntries: [Entry] {
        if let insideGroup { return members(insideGroup).map(Entry.window) }
        return entries
    }

    var aimedEntries: [Entry] {
        let list = aimEntries
        guard aiming, !list.isEmpty else { return [] }
        let low = max(0, min(aimAnchor, aimCursor)), high = min(list.count - 1, max(aimAnchor, aimCursor))
        guard low <= high else { return [] }
        return Array(list[low...high])
    }

    var aimedIDs: [Int] { aimedEntries.flatMap(ids(of:)) }

    /// The aim rests on one group as a whole.
    var aimedGroup: Int? {
        guard aimedEntries.count == 1, case .group(let id) = aimedEntries[0] else { return nil }
        return id
    }

    var canTile: Bool { aimedIDs.count >= 2 && aimedGroup == nil }

    var layoutOptions: [TileLayout] { TileLayout.options(for: aimedIDs.count) }

    /// The group whose own strip is out: the one aimed into, else the selected window's.
    var shownGroup: Int? {
        if let insideGroup { return insideGroup }
        if aiming, let aimedGroup { return aimedGroup }
        return selected.flatMap { group(of: $0)?.id }
    }

    /// The strip is out of sight in invisible mode, except while aiming.
    var stripShown: Bool { !stripHidden || aiming }

    var searchMatches: [Int] {
        let needle = query.lowercased()
        return queue.filter { id in
            !closed.contains(id) && (needle.isEmpty || window(id)?.name.lowercased().contains(needle) == true)
        }
    }

    // MARK: - Frames

    /// The frame of each window on show on `monitor`, inside that monitor's `area`, origin top left.
    func frames(in area: CGRect, monitor: Int = 0) -> [Int: CGRect] {
        let here = queue.filter { self.monitor(of: $0) == monitor && isOnShow($0) }
        var out: [Int: CGRect] = [:]
        for id in here {
            guard let window = window(id) else { continue }
            let home = CGRect(x: area.minX + window.home.minX * area.width,
                              y: area.minY + window.home.minY * area.height,
                              width: window.home.width * area.width, height: window.home.height * area.height)
            out[id] = fit(window, in: home)
        }
        if decluttered, here.count >= 2 {
            // Every window in view at once, none on top of another.
            let options = TileLayout.options(for: here.count)
            if let layout = options.first(where: { $0.kind == "Grid" }) ?? options.first(where: { $0.kind == "Columns" }) {
                let limits = here.map { id in window(id)?.aspect.map { SizeLimits(aspect: $0) } ?? .none }
                let frames = TileSolver.frames(units: layout.frames, limits: limits, in: area, inset: 6)
                for (id, frame) in zip(here, frames) { out[id] = frame }
            }
        }
        let order = here.filter(tiled.contains)
        if order.count >= 2 {
            let options = TileLayout.options(for: order.count)
            let layout = options.first { $0.name == tiledLayout }
                ?? options.first { $0.kind == TileLayout.kind(of: tiledLayout) } ?? options.first
            if let layout {
                let limits = order.map { id in window(id)?.aspect.map { SizeLimits(aspect: $0) } ?? .none }
                let frames = TileSolver.frames(units: layout.frames, limits: limits, in: area, inset: 3)
                for (id, frame) in zip(order, frames) { out[id] = frame }
            }
        }
        for id in here where maximized.contains(id) || fullscreen == id {
            if let window = window(id) { out[id] = fit(window, in: area.insetBy(dx: 3, dy: 3)) }
        }
        return out
    }

    private func fit(_ window: SimWindow, in box: CGRect) -> CGRect {
        guard let aspect = window.aspect else { return box }
        let size = SizeLimits(aspect: aspect).fitted(in: box.size)
        return CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: - Keys

    /// Takes a key press the way WindowQueue would. Returns whether it meant something here.
    @discardableResult
    func press(keyCode: Int, flags rawFlags: NSEvent.ModifierFlags, prefs: Preferences, characters: String? = nil) -> Bool {
        launcherName = prefs.launcher.title
        let flags = rawFlags.intersection([.command, .option, .control, .shift])
        let cgFlags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if searchOpen {
            searchKey(keyCode, flags: flags, characters: characters)
            return true
        }
        if aiming {
            if menuFocused {
                guard let key = Self.aimKey(keyCode) else { return true }
                showKeys(flags, keyCode)
                menuKey(key, side: prefs.stripSide)
                return true
            }
            if let key = Self.aimKey(keyCode) {
                showKeys(flags, keyCode)
                let moves = !flags.intersection([.option, .command, .control]).isEmpty
                aimKey(key, extends: flags.contains(.shift), moves: moves, side: prefs.stripSide)
                return true
            }
            // The mode has the keyboard to itself: a shortcut works with or without its super key.
            let bare = flags.isEmpty
            let action = HotkeyAction.allCases.first { prefs.combo(for: $0).matches(keyCode: keyCode, flags: cgFlags) }
                ?? (bare ? HotkeyAction.allCases.first { action in
                    let combo = prefs.combo(for: action)
                    return combo.keyCode == UInt32(keyCode) && combo.modifiers == prefs.superModifier.carbonMask
                } : nil)
            showKeys(flags, keyCode)
            if let action { perform(action) }
            return true
        }
        guard let action = HotkeyAction.allCases.first(where: { prefs.combo(for: $0).matches(keyCode: keyCode, flags: cgFlags) })
        else { return false }
        showKeys(flags, keyCode)
        perform(action)
        return true
    }

    /// A tap of the super key on its own: opens aiming mode, or focuses what it is aimed at. A
    /// second tap straight after the first runs `doubleTap`, as the real one does.
    func superTap(symbol: String, doubleTap: HotkeyAction? = nil) {
        flash(.keys, symbol)
        guard aiming else {
            if searchOpen { change { searchOpen = false } }
            beginAiming()
            return
        }
        if Date().timeIntervalSince(aimingOpenedAt) < Self.doubleTapInterval {
            done.insert(.doubleTapped)
            if let doubleTap {
                // What the double tap runs counts as the double tap, not as that action's own key.
                let before = done
                change { endAiming() }
                perform(doubleTap)
                done = before.union([.doubleTapped])
                return
            }
        }
        confirm()
    }

    func click(_ id: Int) {
        change {
            if aiming { endAiming() }
            searchOpen = false
            select(id)
            done.insert(.clicked)
        }
    }

    /// Types into the search panel, as the demo does.
    func type(_ text: String) {
        guard searchOpen else { return }
        change { query += text }
    }

    enum AimKey { case up, down, left, right, back, forward, enter, space, all, cancel }

    static func aimKey(_ keyCode: Int) -> AimKey? {
        switch keyCode {
        case kVK_UpArrow: return .up
        case kVK_DownArrow: return .down
        case kVK_LeftArrow: return .left
        case kVK_RightArrow: return .right
        case kVK_ANSI_LeftBracket: return .back
        case kVK_ANSI_RightBracket: return .forward
        case kVK_Return, kVK_ANSI_KeypadEnter: return .enter
        case kVK_Space: return .space
        case kVK_ANSI_A: return .all
        case kVK_Escape: return .cancel
        default: return nil
        }
    }

    private func searchKey(_ keyCode: Int, flags: NSEvent.ModifierFlags, characters: String?) {
        change {
            switch keyCode {
            case kVK_Escape:
                showKeys(flags, keyCode)
                searchOpen = false
            case kVK_Return, kVK_ANSI_KeypadEnter:
                showKeys(flags, keyCode)
                searchOpen = false
                if let first = searchMatches.first {
                    select(first)
                    done.insert(.searched)
                }
            case kVK_Delete:
                if !query.isEmpty { query.removeLast() }
            default:
                guard flags.isDisjoint(with: [.command, .control, .option]),
                      let typed = characters?.filter({ $0.isLetter || $0.isNumber || $0 == " " }), !typed.isEmpty
                else { return }
                query += typed
            }
        }
    }

    private static func intoScreen(_ side: StripSide) -> AimKey {
        switch side {
        case .left: return .right
        case .right: return .left
        case .top: return .down
        case .bottom: return .up
        }
    }

    private static func awayFromScreen(_ side: StripSide) -> AimKey {
        switch side {
        case .left: return .left
        case .right: return .right
        case .top: return .up
        case .bottom: return .down
        }
    }

    private func aimKey(_ key: AimKey, extends: Bool, moves: Bool, side: StripSide) {
        if let step = step(for: key, side: side) {
            if moves { moveAimed(by: step) } else if extends { extendAim(by: step) } else { moveAim(by: step) }
            return
        }
        change {
            switch key {
            case Self.intoScreen(side) where aimedGroup != nil, .enter where aimedGroup != nil:
                insideGroup = aimedGroup
                aimAnchor = 0
                aimCursor = 0
                done.insert(.enteredGroup)
            case Self.awayFromScreen(side) where insideGroup != nil:
                let group = insideGroup
                insideGroup = nil
                let index = entries.firstIndex { $0 == .group(group ?? -1) } ?? 0
                aimAnchor = index
                aimCursor = index
            case .enter where canTile, Self.intoScreen(side) where canTile:
                menuFocused = true
                menuIndex = 0
            case .all:
                aimAnchor = 0
                aimCursor = max(0, aimEntries.count - 1)
                noteAim()
            case .enter, .space:
                confirm()
            case .cancel:
                endAiming()
                done.insert(.cancelled)
            default:
                break
            }
        }
    }

    private func step(for key: AimKey, side: StripSide) -> Int? {
        switch key {
        case .back: return -1
        case .forward: return 1
        case .up, .down, .left, .right:
            let previous: AimKey = side.isVertical ? .up : .left
            let next: AimKey = side.isVertical ? .down : .right
            if key == previous { return -1 }
            if key == next { return 1 }
            // Across the strip the arrows lead into the menu or a group when there is one.
            if canTile || aimedGroup != nil || insideGroup != nil { return nil }
            return key == .left || key == .up ? -1 : 1
        default:
            return nil
        }
    }

    private func menuKey(_ key: AimKey, side: StripSide) {
        change {
            let count = layoutOptions.count
            switch key {
            case .up, .back: menuIndex = (menuIndex - 1 + count) % max(count, 1)
            case .down, .forward: menuIndex = (menuIndex + 1) % max(count, 1)
            case .left where !side.isVertical: menuIndex = (menuIndex - 1 + count) % max(count, 1)
            case .right where !side.isVertical: menuIndex = (menuIndex + 1) % max(count, 1)
            case .enter, .space: tile()
            default: menuFocused = false
            }
        }
    }

    // MARK: - Actions

    func perform(_ action: HotkeyAction) {
        change {
            switch action {
            case .cycleNext: aiming ? moveAim(by: 1) : cycle(by: 1)
            case .cyclePrevious: aiming ? moveAim(by: -1) : cycle(by: -1)
            case .moveRight: aiming ? moveAimed(by: 1) : moveSelected(by: 1)
            case .moveLeft: aiming ? moveAimed(by: -1) : moveSelected(by: -1)
            case .toggleGroup: toggleGroup()
            case .toggleGroupLock: toggleLock()
            case .maximizeWindow: maximize()
            case .toggleMaximize: toggleFullscreen()
            case .goToEmptySpace: goToEmptySpace(carrying: false)
            case .moveToEmptySpace: goToEmptySpace(carrying: true)
            case .focusNextMonitor: focusMonitor((focusedMonitor + 1) % max(monitorCount, 1))
            case .moveToNextMonitor: moveTarget(toMonitor: (focusedMonitor + 1) % max(monitorCount, 1))
            case .search: openSearch()
            case .openLauncher, .openRaycastCommand: openLauncher()
            case .declutter: declutter()
            case .screenshotWindow: takePicture()
            case .toggleRecording: toggleRecording()
            case .toggleInvisibleStrip: toggleStrip()
            case .closeWindow: closeTarget()
            default:
                if let index = action.spaceIndex {
                    goToSpace(index)
                } else if let index = action.moveSpaceIndex {
                    moveTarget(toSpace: index)
                } else if let index = action.focusMonitorIndex {
                    focusMonitor(index - 1)
                } else if let index = action.moveMonitorIndex {
                    moveTarget(toMonitor: index - 1)
                } else {
                    flash(.note, "\(action.title) — try it on your real windows after the tour")
                }
            }
        }
    }

    func beginAiming() {
        change {
            fullscreen = nil
            aiming = true
            aimingOpenedAt = Date()
            insideGroup = nil
            menuFocused = false
            let index = selected.flatMap { id in entries.firstIndex { ids(of: $0).contains(id) } } ?? 0
            aimAnchor = index
            aimCursor = index
            done.insert(.aimed)
            if stripHidden { done.insert(.peekedStrip) }
        }
    }

    private func endAiming() {
        aiming = false
        menuFocused = false
        insideGroup = nil
    }

    private func confirm() {
        change {
            let target = aimEntries.indices.contains(aimCursor) ? ids(of: aimEntries[aimCursor]).first : nil
            endAiming()
            if let target { select(target) }
            done.insert(.confirmed)
        }
    }

    private func moveAim(by step: Int) {
        change {
            aimCursor = min(max(aimCursor + step, 0), max(aimEntries.count - 1, 0))
            aimAnchor = aimCursor
            menuFocused = false
        }
    }

    private func extendAim(by step: Int) {
        change {
            aimCursor = min(max(aimCursor + step, 0), max(aimEntries.count - 1, 0))
            noteAim()
        }
    }

    private func noteAim() {
        let count = aimedIDs.count
        if count >= 2 { done.insert(.aimedSeveral) }
        if count >= 3 { done.insert(.aimedThree) }
    }

    /// Carries the aimed run one entry along the queue.
    private func moveAimed(by step: Int) {
        change {
            var list = aimEntries
            let low = min(aimAnchor, aimCursor), high = max(aimAnchor, aimCursor)
            guard low >= 0, high < list.count else { return }
            if step < 0, low > 0 {
                let before = list.remove(at: low - 1)
                list.insert(before, at: high)
            } else if step > 0, high < list.count - 1 {
                let after = list.remove(at: high + 1)
                list.insert(after, at: low)
            } else {
                return
            }
            let before = queue.filter(tiled.contains)
            reorder(as: list)
            aimAnchor += step
            aimCursor += step
            noteMove(tiledBefore: before)
        }
    }

    /// Puts the queue in the order of these entries, which cover either one monitor's strip or one
    /// group's members. Everything else keeps its place.
    private func reorder(as list: [Entry]) {
        let ordered = list.flatMap(ids(of:))
        var slots = queue.indices.filter { ordered.contains(queue[$0]) }.makeIterator()
        for id in ordered { if let slot = slots.next() { queue[slot] = id } }
    }

    private func moveSelected(by step: Int) {
        guard let selected else { return }
        let mine = queue(onMonitor: monitor(of: selected))
        guard let index = mine.firstIndex(of: selected), mine.indices.contains(index + step),
              let from = queue.firstIndex(of: selected), let to = queue.firstIndex(of: mine[index + step])
        else { return }
        let before = queue.filter(tiled.contains)
        queue.swapAt(from, to)
        noteMove(tiledBefore: before)
    }

    /// A tiled layout follows the queue: when its windows' order changed, it has just reflowed.
    private func noteMove(tiledBefore: [Int]) {
        done.insert(.moved)
        if tiled.count >= 2, queue.filter(tiled.contains) != tiledBefore {
            done.insert(.reorderedTiles)
            raiseTiled()
        }
    }

    private func cycle(by step: Int) {
        let pool = lockedGroup.map(members) ?? queue(onMonitor: focusedMonitor)
        guard !pool.isEmpty else { return }
        let index = selected.flatMap(pool.firstIndex(of:)) ?? (step > 0 ? -1 : pool.count)
        let next = pool[(index + step + pool.count) % pool.count]
        select(next)
        done.insert(.cycled)
        if lockedGroup != nil { done.insert(.cycledLocked) }
    }

    /// Focuses a window, going over to its workspace first if another one is on show.
    private func select(_ id: Int) {
        let monitor = monitor(of: id)
        if shownSpace.indices.contains(monitor), shownSpace[monitor] != space(of: id) {
            spaceDirection = space(of: id) > shownSpace[monitor] ? 1 : -1
            shownSpace[monitor] = space(of: id)
        }
        selected = id
        activeMonitor = monitor
        if fullscreen != id { fullscreen = nil }
        if tiled.contains(id) { raiseTiled() }
        raise(id)
    }

    private func raise(_ id: Int) {
        zOrder.removeAll { $0 == id }
        zOrder.append(id)
    }

    private func raiseTiled() {
        for id in queue where tiled.contains(id) { raise(id) }
        if let selected, tiled.contains(selected) { raise(selected) }
    }

    private func tile() {
        let ids = queue.filter(aimedIDs.contains)
        let options = layoutOptions
        guard ids.count >= 2, options.indices.contains(menuIndex) else { return }
        let layout = options[menuIndex]
        endAiming()
        tiled = ids
        tiledLayout = layout.name
        decluttered = false
        maximized.subtract(ids)
        fullscreen = nil
        raiseTiled()
        select(ids[0])
        done.insert(.tiled)
        layoutsUsed.insert(layout.kind)
        if layoutsUsed.count >= 2 { done.insert(.secondLayout) }
    }

    private func toggleGroup() {
        if aiming {
            let ids = queue.filter(aimedIDs.contains)
            guard ids.count > 1 else {
                flash(.note, "Aim at two or more windows to group them")
                return
            }
            endAiming()
            for index in groups.indices { groups[index].ids.removeAll(where: ids.contains) }
            groups.removeAll { $0.ids.count < 2 }
            groups.append(Group(id: nextGroupID, ids: ids))
            nextGroupID += 1
            dropStaleLock()
            select(ids[0])
            done.insert(.grouped)
            flash(.note, "Grouped \(ids.count) windows")
            return
        }
        guard let selected, let group = group(of: selected) else {
            flash(.note, "Nothing to ungroup — aim at several windows to make a group")
            return
        }
        groups.removeAll { $0.id == group.id }
        dropStaleLock()
        flash(.note, "Ungrouped \(group.ids.count) windows")
    }

    private func toggleLock() {
        if lockedGroup != nil {
            lockedGroup = nil
            flash(.note, "Cycling unlocked")
            return
        }
        let group = aiming
            ? (aimedGroup ?? insideGroup ?? aimedIDs.first.flatMap { self.group(of: $0)?.id })
            : selected.flatMap { self.group(of: $0)?.id }
        guard let group else {
            flash(.note, "Select a window in a group to lock cycling to it")
            return
        }
        if aiming { endAiming() }
        lockedGroup = group
        if let selected, members(group).contains(selected) {} else if let first = members(group).first { select(first) }
        done.insert(.locked)
        flash(.note, "Cycling locked to this group")
    }

    private func dropStaleLock() {
        if let lockedGroup, !groups.contains(where: { $0.id == lockedGroup }) { self.lockedGroup = nil }
    }

    /// The window an action is about: the aimed one while aiming (which ends the mode), else the
    /// selected one.
    private func takeTarget() -> Int? {
        let target = aiming ? aimedIDs.first : selected
        if aiming { endAiming() }
        return target
    }

    private func maximize() {
        guard let target = takeTarget() else { return }
        // As in the app: maximizing takes the window out of its layout, which frees the rest.
        if tiled.contains(target) { tiled = [] }
        select(target)
        maximized.insert(target)
        decluttered = false
        done.insert(.maximized)
    }

    /// Fullscreen, and fullscreen again to put the window back as it was before either.
    private func toggleFullscreen() {
        guard let target = takeTarget() else { return }
        if fullscreen == target {
            fullscreen = nil
            maximized.remove(target)
            done.insert(.restored)
        } else {
            select(target)
            fullscreen = target
            done.insert(.fullscreened)
        }
    }

    private func goToSpace(_ index: Int) {
        if aiming { endAiming() }
        guard index <= spaceCount else {
            flash(.note, spaceCount == 1 ? "No workspace \(index) — there is only one" : "No workspace \(index) — there are \(spaceCount)")
            return
        }
        let monitor = focusedMonitor
        guard shownSpace[monitor] != index else { return }
        spaceDirection = index > shownSpace[monitor] ? 1 : -1
        shownSpace[monitor] = index
        activeMonitor = monitor
        // Focus lands on the window on top there, if there is one.
        selected = zOrder.last { self.monitor(of: $0) == monitor && isOnShow($0) }
        done.insert(.switchedSpace)
    }

    private func moveTarget(toSpace index: Int) {
        guard let target = takeTarget() else { return }
        guard index <= spaceCount else {
            flash(.note, "No workspace \(index)")
            return
        }
        guard space(of: target) != index else { return }
        spaceOf[target] = index
        maximized.remove(target)
        tiled.removeAll { $0 == target }
        select(target)
        done.insert(.movedToSpace)
        flash(.note, "\(window(target)?.name ?? "Window") moved to workspace \(index)")
    }

    private func goToEmptySpace(carrying: Bool) {
        let monitor = focusedMonitor
        let empty = (1...max(spaceCount, 1)).first { space in
            space != shownSpace[monitor] && !queue(onMonitor: monitor).contains { self.space(of: $0) == space }
        }
        // With every workspace in use, a new one is added at the end, so the shortcut always
        // has somewhere to go and the tip can always be done.
        let target = empty ?? spaceCount + 1
        if empty == nil {
            spaceCount += 1
            flash(.note, "Added workspace \(target)")
        }
        // Its own shortcut, not the numbered ones: only that one is ticked off.
        let before = done
        if carrying { moveTarget(toSpace: target) } else { goToSpace(target) }
        done = before.union([.wentToEmptySpace])
    }

    private func focusMonitor(_ index: Int) {
        if aiming { endAiming() }
        guard monitorCount > 1 else {
            flash(.note, "Only one monitor — there is no other to go to")
            return
        }
        guard index < monitorCount else {
            flash(.note, "No monitor \(index + 1)")
            return
        }
        activeMonitor = index
        if let top = zOrder.last(where: { monitor(of: $0) == index && isOnShow($0) }) {
            select(top)
        } else {
            selected = nil
        }
        flashMonitor(index)
        done.insert(.switchedMonitor)
    }

    private func moveTarget(toMonitor index: Int) {
        guard monitorCount > 1 else {
            flash(.note, "Only one monitor — there is nowhere else to move the window")
            return
        }
        guard let target = takeTarget(), index < monitorCount, monitor(of: target) != index else { return }
        monitorOf[target] = index
        spaceOf[target] = shownSpace[index]
        tiled.removeAll { $0 == target }
        select(target)
        flashMonitor(index)
        done.insert(.movedToMonitor)
    }

    private func openSearch() {
        if aiming { endAiming() }
        searchOpen.toggle()
        query = ""
        // Opening it is the lesson; picking a window from it is up to the user.
        if searchOpen { done.insert(.searched) }
    }

    private func openLauncher() {
        if aiming { endAiming() }
        flashCount += 1
        let id = flashCount
        launcher = Flash(id: id, text: launcherName)
        done.insert(.launched)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.launcher?.id == id else { return }
            self.change { self.launcher = nil }
        }
    }

    private func declutter() {
        if aiming { endAiming() }
        decluttered = true
        tiled = []
        maximized = []
        fullscreen = nil
        done.insert(.decluttered)
        flash(.note, "Every window in view, none on top of another")
    }

    private func takePicture() {
        guard let target = takeTarget() else { return }
        flashCount += 1
        let id = flashCount
        shutter = Mark(id: id, target: target)
        done.insert(.pictured)
        flash(.note, "Picture of the \(window(target)?.name ?? "") window saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.shutter?.id == id else { return }
            self.change { self.shutter = nil }
        }
    }

    private func toggleRecording() {
        if let recording {
            self.recording = nil
            if aiming { endAiming() }
            flash(.note, "Video of the \(window(recording)?.name ?? "") window saved")
            done.insert(.videoSaved)
            return
        }
        guard let target = takeTarget() else { return }
        recording = target
        done.insert(.recorded)
        flash(.note, "Recording the \(window(target)?.name ?? "") window")
    }

    private func toggleStrip() {
        stripHidden.toggle()
        done.insert(stripHidden ? .hidStrip : .stripBack)
        flash(.note, stripHidden ? "Strip hidden — it comes back while aiming" : "Strip shown")
    }

    private func closeTarget() {
        let wasAiming = aiming
        guard let target = takeTarget() else { return }
        done.insert(wasAiming ? .closedWhileAiming : .closed)
        closed.insert(target)
        tiled.removeAll { $0 == target }
        if selected == target {
            selected = zOrder.last { $0 != target && monitor(of: $0) == monitor(of: target) && isOnShow($0) }
        }
        flash(.note, "\(window(target)?.name ?? "Window") closed")
    }

    // MARK: - Dragging icons

    /// The pretend pointer, resting on an icon of the strip (nil hides it).
    func point(at id: Int?) {
        change { pointer = id }
    }

    func beginDrag(_ id: Int) {
        let list = entries(onMonitor: monitor(of: id))
        change {
            lifted = id
            dragStart = list.firstIndex { ids(of: $0).contains(id) } ?? 0
        }
    }

    /// Puts the lifted icon `offset` entries from where the drag began.
    func drag(to offset: Int) {
        guard let lifted else { return }
        var list = entries(onMonitor: monitor(of: lifted))
        guard let from = list.firstIndex(where: { ids(of: $0).contains(lifted) }) else { return }
        let to = min(max(dragStart + offset, 0), list.count - 1)
        guard to != from else { return }
        change {
            let entry = list.remove(at: from)
            list.insert(entry, at: to)
            reorder(as: list)
            done.insert(.dragged)
        }
    }

    /// Moves the lifted icon one more entry along, as the demo does.
    func drag(by step: Int) {
        guard let lifted else { return }
        let list = entries(onMonitor: monitor(of: lifted))
        guard let index = list.firstIndex(where: { ids(of: $0).contains(lifted) }) else { return }
        drag(to: index + step - dragStart)
    }

    func endDrag() {
        change {
            if lifted != nil, done.contains(.dragged) { done.insert(.dropped) }
            lifted = nil
        }
    }

    // MARK: - Flashes

    private func flashMonitor(_ index: Int) {
        flashCount += 1
        let id = flashCount
        monitorFrame = Mark(id: id, target: index)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.monitorFrame?.id == id else { return }
            self.change { self.monitorFrame = nil }
        }
    }

    private func showKeys(_ flags: NSEvent.ModifierFlags, _ keyCode: Int) {
        let modifiers = KeyCombo(keyCode: UInt32(keyCode), modifiers: KeyCombo.carbonModifiers(from: flags))
        let name: String
        switch Self.aimKey(keyCode) {
        case .enter: name = "↩"
        case .cancel: name = "esc"
        case .space: name = "Space"
        default: name = KeyCombo.keyName(for: UInt32(keyCode))
        }
        flash(.keys, modifiers.modifierSymbols + name)
    }

    private enum FlashSlot { case keys, note }

    private func flash(_ slot: FlashSlot, _ text: String) {
        flashCount += 1
        let id = flashCount
        let flash = Flash(id: id, text: text)
        switch slot {
        case .keys: keys = flash
        case .note: note = flash
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (slot == .keys ? 1.1 : 2.6)) { [weak self] in
            guard let self else { return }
            self.change {
                if self.keys?.id == id { self.keys = nil }
                if self.note?.id == id { self.note = nil }
            }
        }
    }

    private func change(_ body: () -> Void) {
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { body() }
        } else {
            body()
        }
    }
}

extension TileLayout {
    /// The kind of the layout with this name, whatever the count it was made for.
    static func kind(of name: String?) -> String? {
        guard let name else { return nil }
        return TileLayout(name: name, frames: []).kind
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
