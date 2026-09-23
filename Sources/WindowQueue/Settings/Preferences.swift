import AppKit
import Carbon.HIToolbox
import Combine

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
    case search
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
        case .search: return "Search windows"
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
         .toggleMaximize, .maximizeWindow, .closeWindow, .search]
    }

    static var spaceActions: [HotkeyAction] {
        allCases.filter { $0.spaceIndex != nil }
    }

    /// Default combo for this action given the chosen "super" modifier.
    func defaultCombo(superMask: UInt32) -> KeyCombo {
        let shift = UInt32(shiftKey)
        switch self {
        case .cyclePrevious: return KeyCombo(keyCode: kVK_ANSI_LeftBracket, modifiers: superMask)
        case .cycleNext: return KeyCombo(keyCode: kVK_ANSI_RightBracket, modifiers: superMask)
        case .moveLeft: return KeyCombo(keyCode: kVK_ANSI_LeftBracket, modifiers: superMask | shift)
        case .moveRight: return KeyCombo(keyCode: kVK_ANSI_RightBracket, modifiers: superMask | shift)
        case .moveToStart: return KeyCombo(keyCode: kVK_Home, modifiers: superMask | shift)
        case .moveToEnd: return KeyCombo(keyCode: kVK_End, modifiers: superMask | shift)
        case .sortByWorkspace: return KeyCombo(keyCode: kVK_ANSI_S, modifiers: superMask | shift)
        case .closeWindow: return KeyCombo(keyCode: kVK_ANSI_Q, modifiers: superMask)
        case .toggleMaximize: return KeyCombo(keyCode: kVK_ANSI_F, modifiers: superMask)
        case .maximizeWindow: return KeyCombo(keyCode: kVK_ANSI_M, modifiers: superMask)
        case .search: return KeyCombo(keyCode: kVK_Space, modifiers: superMask)
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
    var spaceSwitchMethod: SpaceSwitchMethod = .focusWindow
    /// Ask Rectangle to keep its tiled windows clear of the strip.
    var reserveScreenSpace: Bool = true
    var bindings: [String: KeyCombo] = [:]

    var toastEnabled: Bool = true
    var toastDuration: Double = 2.0

    var stripDisplay: StripDisplayMode = .highlightActiveScreen
    /// Opacity of the greyed-out strips on inactive screens.
    var inactiveStripOpacity: Double = 0.65
    var stripSide: StripSide = .left
    var stripAlignment: StripAlignment = .center
    /// Gap between the strip and the screen edges around it.
    var stripMargin: Double = 8
    var stripWidth: Double = 36
    var iconSize: Double = 26
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
    var scrollFocusDelay: Double = 0.5
    /// Move the pointer to the middle of a window when it is focused, so the cursor follows the
    /// keyboard instead of being left behind on another screen.
    var warpCursorToWindow: Bool = true
    /// Focus the window under the pointer once the pointer rests on it.
    var focusFollowsMouse: Bool = true
    /// How long the pointer has to rest before the window under it is focused.
    var focusFollowsMouseDelay: Double = 0.2
    /// Bring the hovered window to the front as well. Off, it takes keyboard focus where it lies.
    var focusFollowsMouseRaises: Bool = false
    /// Trim windows that zoom or tile under the strip after the fact, where the Dock reservation does
    /// not reach: other screens, and apps started before WindowQueue.
    var trimWindowsOutsideReservation: Bool = true
    /// Start automatically at login. Only takes effect for the copy in the Applications folder.
    var launchAtLogin: Bool = true

    /// Windows the user has minimised are still queue members but drawn dimmed.
    var includeMinimized: Bool = true

    /// Maximizing a window puts it first on its workspace and dims the rest of that workspace in the
    /// strip, which cycling then skips until the window is restored.
    var focusMaximizedWindow: Bool = true
    /// Draw the covered windows as one cascading tile with their number, rather than leaving a row
    /// for each of them.
    var collapseCoveredWindows: Bool = true

    /// A line of the window's title under its icon in the strip, for telling apart several windows
    /// of the same application. The row keeps its size; the icon gives up the room.
    var showWindowLabels: Bool = false

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
        includeMinimized = value(.includeMinimized, defaults.includeMinimized)
        focusMaximizedWindow = value(.focusMaximizedWindow, defaults.focusMaximizedWindow)
        collapseCoveredWindows = value(.collapseCoveredWindows, defaults.collapseCoveredWindows)
        showWindowLabels = value(.showWindowLabels, defaults.showWindowLabels)
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
           let decoded = try? JSONDecoder().decode(Preferences.self, from: data) {
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
