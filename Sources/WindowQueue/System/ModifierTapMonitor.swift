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
    /// The super key is currently held on its own, having been pressed from nothing.
    private var armed = false
    /// Something during this press ruled it out as a tap. Cleared only by releasing everything.
    private var invalidated = false

    /// With `includingOtherApps` off only WindowQueue's own windows are watched — what the tour
    /// needs, and all that works before Accessibility is granted.
    func start(includingOtherApps: Bool = true) {
        let flags: NSEvent.EventTypeMask = [.flagsChanged]
        let interruptions: NSEvent.EventTypeMask = [
            .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]

        // Global monitors see other apps' events; local ones see our own panels', which matters
        // once the aiming panel has taken key focus.
        if includingOtherApps, let monitor = NSEvent.addGlobalMonitorForEvents(matching: flags, handler: { [weak self] in
            self?.handle($0)
        }) { monitors.append(monitor) }

        if includingOtherApps, let monitor = NSEvent.addGlobalMonitorForEvents(matching: interruptions, handler: { [weak self] _ in
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
        invalidated = true
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags.isEmpty {
            let held = pressedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            let wasTap = armed && !invalidated && held <= Self.maxHold
            armed = false
            invalidated = false
            pressedAt = nil
            if wasTap { onTap?() }
            return
        }

        // Arming happens only on the way up from nothing. Letting a return to the bare super key
        // re-arm would turn the tail of every combination into a tap: releasing Shift while Option
        // is still down for `⌥⇧]` leaves exactly the super key held, and the release that follows
        // would look identical to a deliberate tap.
        if flags == modifiers, !armed {
            armed = true
            invalidated = false
            pressedAt = Date()
            return
        }

        if flags != modifiers {
            // Another modifier joined in: this is a combination, not a tap.
            invalidated = true
        }
    }
}
