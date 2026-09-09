import AppKit

/// Detects a clean tap of the super modifier: pressed and released on its own, quickly, with
/// nothing else in between.
///
/// Carbon hotkeys cannot express a modifier-only shortcut, so this watches `flagsChanged` events
/// instead. A tap only counts when no key, click or scroll happened while the modifier was down,
/// and when it was not held for long — otherwise every `⌥]` and every pause mid-typing would open
/// aiming mode. Carbon consumes the key events of our own shortcuts before a monitor sees them, so
/// the hotkey dispatcher calls `cancel()` as well.
final class ModifierTapMonitor {
    var onTap: (() -> Void)?
    /// The modifier combination that counts as the super key.
    var modifiers: NSEvent.ModifierFlags = .option

    private static let maxHold: TimeInterval = 0.4

    private var monitors: [Any] = []
    private var pressedAt: Date?

    func start() {
        let flags: NSEvent.EventTypeMask = [.flagsChanged]
        let interruptions: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]

        // Global monitors see other apps' events; local ones see our own panels', which matters
        // once the aiming panel has taken key focus.
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: flags, handler: { [weak self] in
            self?.handle($0)
        }) { monitors.append(monitor) }

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: interruptions, handler: { [weak self] _ in
            self?.cancel()
        }) { monitors.append(monitor) }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: flags, handler: { [weak self] event in
            self?.handle(event)
            return event
        }) { monitors.append(monitor) }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: interruptions, handler: { [weak self] event in
            self?.cancel()
            return event
        }) { monitors.append(monitor) }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Abandons a tap in progress. Called when a shortcut fires, because Carbon swallows the key
    /// event that would otherwise have interrupted it.
    func cancel() {
        pressedAt = nil
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == modifiers {
            pressedAt = Date()
            return
        }

        guard flags.isEmpty, let pressedAt else {
            // Another modifier joined in, so this is the start of a combination, not a tap.
            self.pressedAt = nil
            return
        }

        self.pressedAt = nil
        if Date().timeIntervalSince(pressedAt) <= Self.maxHold {
            onTap?()
        }
    }
}
