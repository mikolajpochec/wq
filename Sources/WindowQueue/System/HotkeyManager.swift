import AppKit
import Carbon.HIToolbox

/// Registers the global shortcuts with Carbon's hotkey API.
///
/// Carbon hotkeys need no event tap, so the app requires no permission beyond Accessibility.
final class HotkeyManager {
    struct RegistrationFailure: Identifiable {
        let id: String
        let action: HotkeyAction
        let combo: KeyCombo
    }

    private var handlerRef: EventHandlerRef?
    private var hotkeyRefs: [EventHotKeyRef?] = []
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private var nextHotkeyID: UInt32 = 1

    private(set) var failures: [RegistrationFailure] = []

    /// Invoked on the main thread when a registered shortcut fires.
    var onAction: ((HotkeyAction) -> Void)?

    /// Nothing is registered while set: before Accessibility is granted, when the shortcuts could
    /// only swallow keys and do nothing, and while the tour has the keyboard to try them in.
    var isSuspended = false

    private static let signature: OSType = 0x5751_4B45 // 'WQKE'

    init() {
        installHandler()
    }

    deinit {
        unregisterAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotkeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.dispatch(hotkeyID.id)
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    private func dispatch(_ id: UInt32) -> OSStatus {
        guard let action = actionsByID[id] else { return OSStatus(eventNotHandledErr) }
        if Diagnostics.isEnabled { Diagnostics.note("hotkey \(action.rawValue)") }
        DispatchQueue.main.async { [weak self] in self?.onAction?(action) }
        return noErr
    }

    // MARK: - Registration

    /// Every setting passes through here, not just the shortcuts, and registering afresh leaves a
    /// moment with nothing registered — a key pressed then reaches the app in front as the
    /// character it types, ś for ⌥S. So nothing is touched unless a shortcut actually changed.
    func apply(_ prefs: Preferences) {
        // Without multi-monitor mode the monitor shortcuts leave their keys to other apps.
        guard !isSuspended else {
            if appliedBindings != nil {
                unregisterAll()
                appliedBindings = nil
                Diagnostics.note("hotkeys suspended")
            }
            return
        }
        let actions = HotkeyAction.allCases.filter { prefs.multiMonitorMode || !$0.isMonitorAction }
        var wanted = actions.map { Binding(action: $0, combo: prefs.combo(for: $0), isExtra: false) }
        if prefs.altTabCycles {
            // A shortcut the user set to the same keys keeps them.
            let taken = Set(wanted.map(\.combo))
            wanted += Self.altTabBindings.filter { !taken.contains($0.combo) }
        }
        guard wanted != appliedBindings else { return }
        appliedBindings = wanted
        unregisterAll()
        failures = []

        for binding in wanted {
            let (action, combo) = (binding.action, binding.combo)
            let id = nextHotkeyID
            nextHotkeyID += 1

            var ref: EventHotKeyRef?
            let hotkeyID = EventHotKeyID(signature: Self.signature, id: id)
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, hotkeyID,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotkeyRefs.append(ref)
                actionsByID[id] = action
            } else {
                // An extra binding failing says nothing about the action's own shortcut.
                if !binding.isExtra {
                    failures.append(RegistrationFailure(id: action.rawValue, action: action, combo: combo))
                }
                Diagnostics.note("hotkey \(action.rawValue) \(combo.displayString) not registered: \(status)")
            }
        }
        Diagnostics.note("hotkeys registered: \(hotkeyRefs.count) of \(wanted.count)")
    }

    /// One registration: an action's own shortcut, or an extra one a setting adds.
    struct Binding: Equatable {
        let action: HotkeyAction
        let combo: KeyCombo
        let isExtra: Bool
    }

    /// ⌥Tab and ⌥⇧Tab cycling, with `Preferences.altTabCycles`.
    static let altTabBindings = [
        Binding(action: .cycleNext, combo: KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey)), isExtra: true),
        Binding(action: .cyclePrevious, combo: KeyCombo(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey | shiftKey)), isExtra: true),
    ]

    private var appliedBindings: [Binding]?

    private func unregisterAll() {
        for ref in hotkeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        hotkeyRefs = []
        actionsByID = [:]
    }
}
