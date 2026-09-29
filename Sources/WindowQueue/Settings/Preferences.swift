import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

enum QueueScope: String, Codable, CaseIterable, Identifiable {
    case global
    case currentSpace

    var id: String { rawValue }
    var title: String {
        switch self {
        case .global: return "All windows (global)"
        case .currentSpace: return "Current workspace only"
        }
    }
}

enum StripSide: String, Codable, CaseIterable, Identifiable {
    case left, right, top, bottom
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Left and right strips run down the screen; top and bottom ones across it.
    var isVertical: Bool { self == .left || self == .right }
}

/// Where the strip sits along its edge, like `justify-content` in a flex container.
enum StripAlignment: String, Codable, CaseIterable, Identifiable {
    case start, center, end
    var id: String { rawValue }
    var title: String {
        switch self {
        case .start: return "Start"
        case .center: return "Center"
        case .end: return "End"
        }
    }

    /// The same position as a fraction of the edge's length.
    var fraction: CGFloat {
        switch self {
        case .start: return 0
        case .center: return 0.5
        case .end: return 1
        }
    }
}

/// Where a group's own strip goes relative to the main one.
enum GroupStripPlacement: String, Codable, CaseIterable, Identifiable {
    /// In front of the main strip when it is aligned to the end, after it otherwise.
    case automatic
    case before
    case after
    /// Takes the main strip's place for as long as the user is inside the group.
    case replace
    /// Lies over the main strip, centred on the group's own entry in it.
    case overGroup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .before: return "Before"
        case .after: return "After"
        case .replace: return "Replace"
        case .overGroup: return "Over group"
        }
    }
    /// The group's strip sits beside the main one, which moves to make room for it.
    var isBeside: Bool {
        switch self {
        case .automatic, .before, .after: return true
        case .replace, .overGroup: return false
        }
    }
}

/// The animations that can be switched off one by one, each covering one part of the interface.
enum AnimationKind: String, Codable, CaseIterable, Identifiable {
    /// Windows arriving, leaving and moving in the strip, the selection, and a dropped icon settling.
    case stripLayout
    /// Aiming mode coming and going: the dimming, the strip growing and the invisible strip unfolding.
    case aimingMode
    /// The aim stepping from window to window, on the strip and around the windows themselves.
    case aimCursor
    /// A group's own strip folding out of the main one and back.
    case groupStrip
    /// The outline that marks where focus landed, and the preview of where a dragged window will go.
    case windowOutlines
    /// The name popup fading in and out.
    case namePopup

    var id: String { rawValue }
    var title: String {
        switch self {
        case .stripLayout: return "Windows arriving, leaving and moving"
        case .aimingMode: return "Entering and leaving"
        case .aimCursor: return "Aim moving"
        case .groupStrip: return "Group strip folding out"
        case .windowOutlines: return "Window outlines"
        case .namePopup: return "Name popup"
        }
    }
}

/// Which screens the strip is drawn on.
enum StripDisplayMode: String, Codable, CaseIterable, Identifiable {
    /// Only on the screen holding the focused window; nothing on the others.
    case activeScreenOnly
    /// On every screen, with the strips on inactive screens greyed out and faded.
    case highlightActiveScreen
    case hidden

    var id: String { rawValue }
    var title: String {
        switch self {
        case .activeScreenOnly: return "Selected monitor only"
        case .highlightActiveScreen: return "All monitors, highlight selected"
        case .hidden: return "Hidden"
        }
    }
}

enum SuperModifier: String, Codable, CaseIterable, Identifiable {
    case option, control, command, controlOption, commandOption

    var id: String { rawValue }

    var carbonMask: UInt32 {
        switch self {
        case .option: return UInt32(optionKey)
        case .control: return UInt32(controlKey)
        case .command: return UInt32(cmdKey)
        case .controlOption: return UInt32(controlKey) | UInt32(optionKey)
        case .commandOption: return UInt32(cmdKey) | UInt32(optionKey)
        }
    }

    /// The same combination as `NSEvent` reports it, for detecting a bare tap of the super key.
    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .option: return [.option]
        case .control: return [.control]
        case .command: return [.command]
        case .controlOption: return [.control, .option]
        case .commandOption: return [.command, .option]
        }
    }

    var title: String {
        switch self {
        case .option: return "⌥ Option"
        case .control: return "⌃ Control"
        case .command: return "⌘ Command"
        case .controlOption: return "⌃⌥ Control+Option"
        case .commandOption: return "⌘⌥ Command+Option"
        }
    }
}

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case cyclePrevious, cycleNext
    case moveLeft, moveRight
    case moveToStart, moveToEnd
    case sortByWorkspace
    case closeWindow
    case toggleMaximize
    case maximizeWindow
    case minimizeWindow
    case declutter
    case toggleGroup
    case search
    case openLauncher
    case showOverview
    case toggleInvisibleStrip
    case toggleRecording
    case screenshotWindow
    case goToEmptySpace
    case moveToEmptySpace
    case space1, space2, space3, space4, space5, space6, space7, space8, space9
    case moveToSpace1, moveToSpace2, moveToSpace3, moveToSpace4, moveToSpace5
    case moveToSpace6, moveToSpace7, moveToSpace8, moveToSpace9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cyclePrevious: return "Select previous window"
        case .cycleNext: return "Select next window"
        case .moveLeft: return "Move window earlier in queue"
        case .moveRight: return "Move window later in queue"
        case .moveToStart: return "Move window to start of queue"
        case .moveToEnd: return "Move window to end of queue"
        case .sortByWorkspace: return "Sort queue by workspace"
        case .closeWindow: return "Close selected window"
        case .toggleMaximize: return "Fullscreen window (again to restore)"
        case .maximizeWindow: return "Maximize window"
        case .minimizeWindow: return "Minimize window"
        case .declutter: return "Declutter windows (show every one, resizing as little as possible)"
        case .toggleGroup: return "Group or ungroup windows"
        case .search: return "Search windows"
        case .openLauncher: return "Open the launcher"
        case .showOverview: return "Show Mission Control"
        case .toggleInvisibleStrip: return "Hide or show the strip (invisible mode)"
        case .toggleRecording: return "Start or stop recording the screen"
        case .screenshotWindow: return "Take a picture of the window"
        case .goToEmptySpace: return "Go to the nearest empty workspace"
        case .moveToEmptySpace: return "Move window to the nearest empty workspace"
        default:
            if let index = moveSpaceIndex { return "Move window to workspace \(index)" }
            return "Switch to workspace \(spaceIndex ?? 0)"
        }
    }

    /// 1-based workspace index for the `spaceN` cases, nil for every other action.
    var spaceIndex: Int? {
        guard rawValue.hasPrefix("space") else { return nil }
        return Int(rawValue.dropFirst("space".count))
    }

    /// 1-based workspace index for the `moveToSpaceN` cases, nil for every other action.
    var moveSpaceIndex: Int? {
        guard rawValue.hasPrefix("moveToSpace") else { return nil }
        return Int(rawValue.dropFirst("moveToSpace".count))
    }

    static var moveToSpaceActions: [HotkeyAction] {
        allCases.filter { $0.moveSpaceIndex != nil }
    }

    static var queueActions: [HotkeyAction] {
        [.cyclePrevious, .cycleNext, .moveLeft, .moveRight, .moveToStart, .moveToEnd, .sortByWorkspace,
         .toggleMaximize, .maximizeWindow, .minimizeWindow, .declutter, .toggleGroup, .closeWindow, .search,
         .openLauncher, .showOverview, .toggleInvisibleStrip, .toggleRecording, .screenshotWindow,
         .goToEmptySpace, .moveToEmptySpace]
    }

    /// What a double tap of the super key can be bound to: anything that makes sense with no window
    /// picked out first.
    static var doubleTapActions: [HotkeyAction] {
        [.openLauncher, .showOverview, .search, .goToEmptySpace, .toggleInvisibleStrip, .toggleRecording,
         .screenshotWindow, .toggleMaximize,
         .maximizeWindow, .minimizeWindow, .declutter, .toggleGroup, .closeWindow, .sortByWorkspace,
         .moveToStart, .moveToEnd]
    }

    static var spaceActions: [HotkeyAction] {
        allCases.filter { $0.spaceIndex != nil }
    }

    /// Default combo for this action given the chosen "super" modifier.
    ///
    /// No default takes a letter that Option turns into a Polish one on the Polish Pro layout —
    /// A, C, E, L, N, O, S, X, Z — so with Option as the super key, ą ć ę ł ń ó ś ź ż still type.
    func defaultCombo(superMask: UInt32) -> KeyCombo {
        let shift = UInt32(shiftKey)
        switch self {
        case .cyclePrevious: return KeyCombo(keyCode: kVK_ANSI_LeftBracket, modifiers: superMask)
        case .cycleNext: return KeyCombo(keyCode: kVK_ANSI_RightBracket, modifiers: superMask)
        case .moveLeft: return KeyCombo(keyCode: kVK_ANSI_LeftBracket, modifiers: superMask | shift)
        case .moveRight: return KeyCombo(keyCode: kVK_ANSI_RightBracket, modifiers: superMask | shift)
        case .moveToStart: return KeyCombo(keyCode: kVK_Home, modifiers: superMask | shift)
        case .moveToEnd: return KeyCombo(keyCode: kVK_End, modifiers: superMask | shift)
        case .sortByWorkspace: return KeyCombo(keyCode: kVK_ANSI_W, modifiers: superMask | shift)
        case .closeWindow: return KeyCombo(keyCode: kVK_ANSI_Q, modifiers: superMask)
        case .toggleMaximize: return KeyCombo(keyCode: kVK_ANSI_F, modifiers: superMask)
        case .maximizeWindow: return KeyCombo(keyCode: kVK_ANSI_M, modifiers: superMask)
        case .minimizeWindow: return KeyCombo(keyCode: kVK_ANSI_H, modifiers: superMask)
        case .declutter: return KeyCombo(keyCode: kVK_ANSI_D, modifiers: superMask)
        case .toggleGroup: return KeyCombo(keyCode: kVK_ANSI_G, modifiers: superMask)
        case .search: return KeyCombo(keyCode: kVK_Space, modifiers: superMask)
        case .openLauncher: return KeyCombo(keyCode: kVK_ANSI_R, modifiers: superMask)
        case .showOverview: return KeyCombo(keyCode: kVK_ANSI_W, modifiers: superMask)
        case .toggleInvisibleStrip: return KeyCombo(keyCode: kVK_ANSI_I, modifiers: superMask)
        case .toggleRecording: return KeyCombo(keyCode: kVK_ANSI_V, modifiers: superMask)
        case .screenshotWindow: return KeyCombo(keyCode: kVK_ANSI_P, modifiers: superMask)
        // Next to the numbered workspaces: the one with nothing on it.
        case .goToEmptySpace: return KeyCombo(keyCode: kVK_ANSI_0, modifiers: superMask)
        case .moveToEmptySpace: return KeyCombo(keyCode: kVK_ANSI_0, modifiers: superMask | shift)
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            if let move = moveSpaceIndex {
                return KeyCombo(keyCode: digits[move - 1], modifiers: superMask | shift)
            }
            let index = (spaceIndex ?? 1) - 1
            return KeyCombo(keyCode: digits[index], modifiers: superMask)
        }
    }
}

struct Preferences: Codable, Equatable {
    var scope: QueueScope = .global
    var superModifier: SuperModifier = .option
    var spaceSwitchMethod: SpaceSwitchMethod = .privateAPI
    /// Ask Rectangle to keep its tiled windows clear of the strip.
    var reserveScreenSpace: Bool = true
    var bindings: [String: KeyCombo] = [:]

    var toastEnabled: Bool = true
    var toastDuration: Double = 1.0

    var stripDisplay: StripDisplayMode = .highlightActiveScreen
    /// Opacity of the greyed-out strips on inactive screens.
    var inactiveStripOpacity: Double = 0.55
    var stripSide: StripSide = .left
    var stripAlignment: StripAlignment = .center
    /// Where a group's strip goes: before the main strip (above or left of it) or after it.
    var groupStripPlacement: GroupStripPlacement = .automatic
    /// Gap between the strip and the screen edges around it.
    var stripMargin: Double = 4
    /// No longer set by hand: the strip is as thick as an icon row needs. Kept so an old stored
    /// blob still decodes.
    var stripWidth: Double = 36
    var iconSize: Double = 34
    var showSpaceBadge: Bool = true
    /// Keep the queue grouped by workspace without having to sort it by hand.
    var autoSortByWorkspace: Bool = true
    var stripOpacity: Double = 1.0
    /// Get out of the way of a fullscreen window, where an always-on-top strip is an intrusion.
    var hideInFullscreen: Bool = true

    /// Tapping the super key on its own opens aiming mode: pick a window without focusing it, then
    /// confirm with Return or Space.
    var aimingEnabled: Bool = true
    /// How much the strip grows while aiming, so it is obvious the mode is on.
    var aimingScale: Double = 1.2
    /// How far the screens are dimmed behind the strip while aiming. Zero turns dimming off.
    var aimingDimOpacity: Double = 0.45
    /// How long scrolling over the strip has to stop before the selected window is focused, so
    /// running through the queue does not focus everything on the way past.
    var scrollFocusDelay: Double = 0.3
    /// Move the pointer to the middle of a window when it is focused, so the cursor follows the
    /// keyboard instead of being left behind on another screen.
    var warpCursorToWindow: Bool = true
    /// Focus the window under the pointer once the pointer rests on it.
    var focusFollowsMouse: Bool = true
    /// How long the pointer has to rest before the window under it is focused.
    var focusFollowsMouseDelay: Double = 0.05
    /// Bring the hovered window to the front as well. Off, it takes keyboard focus where it lies.
    var focusFollowsMouseRaises: Bool = false
    /// Trim windows that zoom or tile under the strip after the fact, where the Dock reservation does
    /// not reach: other screens, and apps started before WindowQueue.
    var trimWindowsOutsideReservation: Bool = true
    /// Start automatically at login. Only takes effect for the copy in the Applications folder.
    var launchAtLogin: Bool = true

    /// Show a picture of the window in the name popup. Needs Screen Recording access, like titles.
    var showWindowPreview: Bool = true

    /// Gap left around a tiled or maximized window, at the edge of the screen and between windows.
    var tileOuterGap: Double = 0
    var tileInnerGap: Double = 4
    /// Tiling from aiming mode gives the layout a workspace of its own when others share the
    /// windows'. Off, the layout goes to the first aimed window's workspace, whoever else is there.
    var tileOnSeparateWorkspace: Bool = false
    /// Tiling and maximizing fit each window to the sizes it accepts — its minimum and maximum, a
    /// fixed size or aspect ratio (the iOS Simulator) — and share the rest out among the others.
    var respectWindowSizeLimits: Bool = true

    /// Windows the user has minimised are still queue members but drawn dimmed.
    var includeMinimized: Bool = true

    /// Sending a window fullscreen (`toggleMaximize`) puts it first on its workspace and takes the
    /// rest of that workspace out of the way until it is restored. Plain maximizing does not.
    var focusMaximizedWindow: Bool = true
    /// Draw the covered windows as one cascading tile with their number, rather than leaving a row
    /// for each of them.
    var collapseCoveredWindows: Bool = true

    /// A line of the window's title under its icon in the strip, for telling apart several windows
    /// of the same application. The row keeps its size; the icon gives up the room.
    var showWindowLabels: Bool = true

    /// Which finder the launcher shortcut opens — its key in aiming mode, or its own shortcut.
    var launcher: LauncherApp = .spotlight

    /// Outline a window for a moment when focus lands on it, the way aiming outlines what it is on.
    var flashFocusedWindow: Bool = true
    /// How long that outline stays up.
    var flashFocusedWindowDuration: Double = 0.15

    /// Aiming mode appears at once: no dimming fading in, no strip growing or unfolding, and no
    /// wait to see whether a second tap of the super key is coming.
    var instantAiming: Bool = false

    /// Off, nothing in WindowQueue animates; everything changes at once.
    var animationsEnabled: Bool = true
    /// Animations switched off on their own while the rest keep running.
    var disabledAnimations: Set<AnimationKind> = []

    /// The strip is only on screen while aiming mode is open; the rest of the time the queue is
    /// there but out of sight, and a change is announced by the popup alone.
    var invisibleStrip: Bool = false

    /// Extra keys that only mean something in aiming mode, on top of the shortcuts it already
    /// answers to without their super key. Keyed by virtual key code.
    var aimBindings: [String: HotkeyAction] = [:]

    /// What a second tap of the super key does, straight after the first one opened aiming mode.
    /// Nil keeps the plain behaviour: the second tap confirms the aim and focuses the window.
    var superDoubleTapAction: HotkeyAction? = .search

    /// Decoded field by field so that adding a setting never invalidates a stored blob.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
        }
        let defaults = Preferences()
        scope = value(.scope, defaults.scope)
        superModifier = value(.superModifier, defaults.superModifier)
        spaceSwitchMethod = value(.spaceSwitchMethod, defaults.spaceSwitchMethod)
        reserveScreenSpace = value(.reserveScreenSpace, defaults.reserveScreenSpace)
        bindings = value(.bindings, defaults.bindings)
        toastEnabled = value(.toastEnabled, defaults.toastEnabled)
        toastDuration = value(.toastDuration, defaults.toastDuration)
        // Older builds stored a plain on/off switch; an explicit "off" carries over as hidden.
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        let legacyEnabled = (try? legacy?.decodeIfPresent(Bool.self, forKey: .stripEnabled)) ?? nil
        stripDisplay = value(.stripDisplay, legacyEnabled == false ? .hidden : defaults.stripDisplay)
        inactiveStripOpacity = value(.inactiveStripOpacity, defaults.inactiveStripOpacity)
        stripSide = value(.stripSide, defaults.stripSide)
        stripAlignment = value(.stripAlignment, defaults.stripAlignment)
        groupStripPlacement = value(.groupStripPlacement, defaults.groupStripPlacement)
        stripMargin = value(.stripMargin, defaults.stripMargin)
        stripWidth = value(.stripWidth, defaults.stripWidth)
        iconSize = value(.iconSize, defaults.iconSize)
        showSpaceBadge = value(.showSpaceBadge, defaults.showSpaceBadge)
        autoSortByWorkspace = value(.autoSortByWorkspace, defaults.autoSortByWorkspace)
        stripOpacity = value(.stripOpacity, defaults.stripOpacity)
        hideInFullscreen = value(.hideInFullscreen, defaults.hideInFullscreen)
        aimingEnabled = value(.aimingEnabled, defaults.aimingEnabled)
        aimingScale = value(.aimingScale, defaults.aimingScale)
        aimingDimOpacity = value(.aimingDimOpacity, defaults.aimingDimOpacity)
        scrollFocusDelay = value(.scrollFocusDelay, defaults.scrollFocusDelay)
        warpCursorToWindow = value(.warpCursorToWindow, defaults.warpCursorToWindow)
        focusFollowsMouse = value(.focusFollowsMouse, defaults.focusFollowsMouse)
        focusFollowsMouseDelay = value(.focusFollowsMouseDelay, defaults.focusFollowsMouseDelay)
        focusFollowsMouseRaises = value(.focusFollowsMouseRaises, defaults.focusFollowsMouseRaises)
        trimWindowsOutsideReservation = value(.trimWindowsOutsideReservation, defaults.trimWindowsOutsideReservation)
        launchAtLogin = value(.launchAtLogin, defaults.launchAtLogin)
        showWindowPreview = value(.showWindowPreview, defaults.showWindowPreview)
        tileOuterGap = value(.tileOuterGap, defaults.tileOuterGap)
        tileInnerGap = value(.tileInnerGap, defaults.tileInnerGap)
        tileOnSeparateWorkspace = value(.tileOnSeparateWorkspace, defaults.tileOnSeparateWorkspace)
        respectWindowSizeLimits = value(.respectWindowSizeLimits, defaults.respectWindowSizeLimits)
        includeMinimized = value(.includeMinimized, defaults.includeMinimized)
        focusMaximizedWindow = value(.focusMaximizedWindow, defaults.focusMaximizedWindow)
        collapseCoveredWindows = value(.collapseCoveredWindows, defaults.collapseCoveredWindows)
        showWindowLabels = value(.showWindowLabels, defaults.showWindowLabels)
        launcher = value(.launcher, defaults.launcher)
        invisibleStrip = value(.invisibleStrip, defaults.invisibleStrip)
        aimBindings = value(.aimBindings, defaults.aimBindings)
        flashFocusedWindow = value(.flashFocusedWindow, defaults.flashFocusedWindow)
        flashFocusedWindowDuration = value(.flashFocusedWindowDuration, defaults.flashFocusedWindowDuration)
        instantAiming = value(.instantAiming, defaults.instantAiming)
        animationsEnabled = value(.animationsEnabled, defaults.animationsEnabled)
        disabledAnimations = value(.disabledAnimations, defaults.disabledAnimations)
        superDoubleTapAction = (try? container.decodeIfPresent(HotkeyAction.self, forKey: .superDoubleTapAction)) ?? nil
    }

    init() {}

    private enum LegacyKeys: String, CodingKey {
        case stripEnabled
    }

    static func defaultBindings(superMask: UInt32) -> [String: KeyCombo] {
        var out: [String: KeyCombo] = [:]
        for action in HotkeyAction.allCases {
            out[action.rawValue] = action.defaultCombo(superMask: superMask)
        }
        return out
    }

    /// The keys these actions had by default before the defaults gave the Polish letters back.
    private static let formerDefaultKeys: [HotkeyAction: Int] = [
        .sortByWorkspace: kVK_ANSI_S, .openLauncher: kVK_ANSI_S, .showOverview: kVK_ANSI_O,
        .toggleRecording: kVK_ANSI_C, .screenshotWindow: kVK_ANSI_X,
    ]

    /// Moves every binding still on its former default to the current one. A binding the user
    /// chose themselves is left alone.
    /// - Returns: whether anything changed.
    mutating func moveOffFormerDefaults() -> Bool {
        var changed = false
        for (action, key) in Self.formerDefaultKeys {
            let current = action.defaultCombo(superMask: superModifier.carbonMask)
            let former = KeyCombo(keyCode: UInt32(key), modifiers: current.modifiers)
            guard bindings[action.rawValue] == former else { continue }
            bindings[action.rawValue] = current
            changed = true
        }
        return changed
    }

    /// A group's strip goes in front of the main one — above it on a side strip, left of it on a
    /// top or bottom one — rather than after it.
    var groupStripIsBefore: Bool {
        switch groupStripPlacement {
        case .automatic, .replace, .overGroup: return stripAlignment == .end
        case .before: return true
        case .after: return false
        }
    }

    /// How far the main strip moves towards its start to make room for a group's strip that takes
    /// `length`, so the pair keeps the strip's alignment as one: centred, it shares the middle; at
    /// either end it grows inwards. Negative moves it towards its end.
    func stripShift(forCompanion length: CGFloat) -> CGFloat {
        // Replacing the strip or lying over it, the group's strip takes no room beside it.
        guard groupStripPlacement.isBeside else { return 0 }
        let before = groupStripIsBefore
        switch stripAlignment {
        case .center: return before ? -length / 2 : length / 2
        case .start: return before ? -length : 0
        case .end: return before ? 0 : length
        }
    }

    func animates(_ kind: AnimationKind) -> Bool {
        animationsEnabled && !disabledAnimations.contains(kind)
    }

    /// The animation to use for this part of the interface, or nil when it is switched off.
    func animation(_ kind: AnimationKind, _ animation: Animation?) -> Animation? {
        animates(kind) ? animation : nil
    }

    /// An AppKit fade's length for this part of the interface: none when it is switched off.
    func duration(_ kind: AnimationKind, _ duration: TimeInterval) -> TimeInterval {
        animates(kind) ? duration : 0
    }

    func combo(for action: HotkeyAction) -> KeyCombo {
        bindings[action.rawValue] ?? action.defaultCombo(superMask: superModifier.carbonMask)
    }
}

/// Single source of truth for settings; persists to `UserDefaults` on every change.
final class PreferencesStore: ObservableObject {
    private static let key = "preferences.v1"

    @Published var prefs: Preferences {
        didSet {
            guard prefs != oldValue else { return }
            save()
        }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           var decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
            // Once only: a binding put back on one of those keys later on is the user's choice.
            let migration = "bindings.polishLettersFree.v1"
            if !UserDefaults.standard.bool(forKey: migration) {
                UserDefaults.standard.set(true, forKey: migration)
                if decoded.moveOffFormerDefaults() {
                    if let data = try? JSONEncoder().encode(decoded) {
                        UserDefaults.standard.set(data, forKey: Self.key)
                    }
                }
            }
            prefs = decoded
        } else {
            var fresh = Preferences()
            fresh.bindings = Preferences.defaultBindings(superMask: fresh.superModifier.carbonMask)
            prefs = fresh
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prefs) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Regenerates every binding from the defaults for the current super modifier.
    func resetBindingsToDefaults() {
        prefs.bindings = Preferences.defaultBindings(superMask: prefs.superModifier.carbonMask)
    }

    func setSuperModifier(_ modifier: SuperModifier) {
        prefs.superModifier = modifier
        prefs.bindings = Preferences.defaultBindings(superMask: modifier.carbonMask)
    }

    func setCombo(_ combo: KeyCombo, for action: HotkeyAction) {
        prefs.bindings[action.rawValue] = combo
    }
}
