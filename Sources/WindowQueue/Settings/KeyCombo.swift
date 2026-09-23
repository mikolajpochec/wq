import AppKit
import Carbon.HIToolbox

/// A registerable global shortcut: a virtual key code plus a Carbon modifier mask.
struct KeyCombo: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`).
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: Int, modifiers: UInt32) {
        self.init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// Builds a combo from a recorded key event. Returns nil when no modifier is held,
    /// because a bare key cannot be registered as a system-wide hotkey.
    init?(event: NSEvent) {
        let mods = KeyCombo.carbonModifiers(from: event.modifierFlags)
        guard mods != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    /// Whether a key event matches this combo. Aiming mode swallows every key press, so the
    /// shortcuts have to be recognised from the raw event rather than through Carbon.
    func matches(keyCode: Int, flags: CGEventFlags) -> Bool {
        guard UInt32(keyCode) == self.keyCode else { return false }
        var held: UInt32 = 0
        if flags.contains(.maskCommand) { held |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { held |= UInt32(optionKey) }
        if flags.contains(.maskControl) { held |= UInt32(controlKey) }
        if flags.contains(.maskShift) { held |= UInt32(shiftKey) }
        return held == modifiers
    }

    var modifierSymbols: String {
        var out = ""
        if modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { out += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { out += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { out += "⌘" }
        return out
    }

    var displayString: String { modifierSymbols + KeyCombo.keyName(for: keyCode) }

    // MARK: - Key names

    private static let specialNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3",
        kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Layout-aware label for a virtual key code, e.g. `30` -> `]` on a US layout.
    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialNames[Int(keyCode)] { return special }
        if let translated = translate(keyCode: keyCode), !translated.isEmpty {
            return translated.uppercased()
        }
        return "#\(keyCode)"
    }

    private static func translate(keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress else { return nil }
            let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState, chars.count, &length, &chars
            )
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}
