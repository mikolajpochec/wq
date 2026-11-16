import AppKit
import CoreGraphics

/// Lets a menu WindowQueue pops up be walked with the app's own keys: while it is open, `[` and `]`
/// (with any modifiers, as aiming takes them) and whatever the cycle shortcuts are bound to step the
/// highlight up and down, and Space picks like Return. Each such press is swallowed and replayed as
/// the arrow or Return key the menu understands; every other key goes through untouched.
final class MenuKeyMapper {
    private let grabber = KeyboardGrabber()
    private let upCodes: Set<Int>
    private let downCodes: Set<Int>

    init(prefs: Preferences) {
        upCodes = [33, Int(prefs.combo(for: .cyclePrevious).keyCode)]
        downCodes = [30, Int(prefs.combo(for: .cycleNext).keyCode)]
        grabber.idleTimeout = 120
        grabber.onDismiss = { [weak self] in self?.end() }
        grabber.onKeyDown = { [weak self] event in self?.handle(event) ?? false }
    }

    /// Runs `body` (the blocking `popUp`) with the keys mapped.
    func whileOpen(_ body: () -> Void) {
        grabber.begin()
        body()
        end()
    }

    func end() {
        grabber.end()
    }

    private static let upArrow: CGKeyCode = 126
    private static let downArrow: CGKeyCode = 125
    private static let returnKey: CGKeyCode = 36

    private func handle(_ event: CGEvent) -> Bool {
        let code = event.keyCode
        let replacement: CGKeyCode
        // Up wins when both shortcuts share a key (they differ only by modifiers in some setups).
        if upCodes.contains(code) {
            replacement = Self.upArrow
        } else if downCodes.contains(code) {
            replacement = Self.downArrow
        } else if code == 49 {
            replacement = Self.returnKey
        } else {
            return false
        }
        for down in [true, false] {
            guard let synthetic = CGEvent(keyboardEventSource: nil, virtualKey: replacement, keyDown: down) else { continue }
            // Bare arrows: with the super key still held, an arrow would mean something else.
            synthetic.flags = []
            synthetic.post(tap: .cgSessionEventTap)
        }
        return true
    }
}
