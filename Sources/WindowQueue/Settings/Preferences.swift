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
    case left, right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }
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
    case space1, space2, space3, space4, space5, space6, space7, space8, space9

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cyclePrevious: return "Select previous window"
        case .cycleNext: return "Select next window"
        case .moveLeft: return "Move window earlier in queue"
        case .moveRight: return "Move window later in queue"
        case .moveToStart: return "Move window to start of queue"
        case .moveToEnd: return "Move window to end of queue"
        default: return "Switch to workspace \(spaceIndex ?? 0)"
        }
    }

    /// 1-based workspace index for the `spaceN` cases, nil for every other action.
    var spaceIndex: Int? {
        guard rawValue.hasPrefix("space") else { return nil }
        return Int(rawValue.dropFirst("space".count))
    }

    static var queueActions: [HotkeyAction] {
        [.cyclePrevious, .cycleNext, .moveLeft, .moveRight, .moveToStart, .moveToEnd]
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
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
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
    var reserveScreenSpace: Bool = false
    var bindings: [String: KeyCombo] = [:]

    var toastEnabled: Bool = true
    var toastDuration: Double = 2.0

    var stripEnabled: Bool = true
    var stripSide: StripSide = .left
    var stripWidth: Double = 46
    var iconSize: Double = 28
    var showIndexNumbers: Bool = true
    var showSpaceBadge: Bool = true
    var stripOpacity: Double = 0.9

    /// Windows the user has minimised are still queue members but drawn dimmed.
    var includeMinimized: Bool = true

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
