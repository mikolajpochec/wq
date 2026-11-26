import AppKit
import CoreGraphics

/// Takes the keyboard for a modal moment, without taking focus.
///
/// The obvious alternatives both fail here. An `NSEvent` monitor observes but cannot consume, so
/// Return and the arrows would still reach whatever app is in front; and an accessory application
/// that is not active cannot make even a `.nonactivatingPanel` key, so a panel receives nothing —
/// and activating the app to fix that would move focus, which these modes exist to avoid.
///
/// A session-level event tap can return nil to swallow an event, needs no focus, and lives only as
/// long as the mode does.
///
/// The tap runs on a thread of its own (`EventTapThread`), not the main run loop. An active tap
/// holds up every key press on the system until its callback returns, so on the main thread any
/// stall there (a slow accessibility call, a busy refresh) froze typing in every application for
/// as long as aiming or a prompt was up. `onKeyDown` is therefore called on that thread: it must
/// only read the event and hand real work to the main queue.
final class KeyboardGrabber {
    /// Return true to swallow the key press, false to let it through. Called on the tap thread.
    var onKeyDown: ((CGEvent) -> Bool)?
    /// The tap could not be created, or nothing happened for a long time.
    var onDismiss: (() -> Void)?

    /// The tap swallows key presses, so a mode left open by mistake would lock the keyboard out of
    /// every other application. It closes itself if nothing happens.
    var idleTimeout: TimeInterval = 15

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var idleTimer: Timer?

    var isActive: Bool { tap != nil }

    func begin() {
        guard tap == nil else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let grabber = Unmanaged<KeyboardGrabber>.fromOpaque(refcon).takeUnretainedValue()
            return grabber.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
            onDismiss?()
            return
        }

        let loop = EventTapThread.shared.runLoop
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopWakeUp(loop)

        self.tap = tap
        self.source = source
        restartIdleTimer()
    }

    func end() {
        idleTimer?.invalidate()
        idleTimer = nil

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source {
            CFRunLoopRemoveSource(EventTapThread.shared.runLoop, source, .commonModes)
        }
        if let tap {
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
    }

    private func restartIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: idleTimeout, repeats: false) {
            [weak self] _ in
            self?.onDismiss?()
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long or that the user interrupted; re-arming it
        // is the documented recovery.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        DispatchQueue.main.async { [weak self] in
            // Not for a grab that has ended meanwhile: its timer would dismiss whatever comes next.
            guard let self, self.isActive else { return }
            self.restartIdleTimer()
        }
        let swallow = onKeyDown?(event) ?? false
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}

/// The thread every `KeyboardGrabber` tap runs on: started once, its run loop kept alive for good.
final class EventTapThread {
    static let shared = EventTapThread()

    let runLoop: CFRunLoop

    private init() {
        var loop: CFRunLoop?
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread {
            loop = CFRunLoopGetCurrent()
            // A run loop with no sources returns at once; a port nobody sends to keeps it going.
            RunLoop.current.add(Port(), forMode: .default)
            ready.signal()
            while true { CFRunLoopRun() }
        }
        thread.name = "WindowQueue.keyboardTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = loop!
    }
}

extension CGEvent {
    var keyCode: Int {
        Int(getIntegerValueField(.keyboardEventKeycode))
    }

    /// The characters this key press would type, ignoring modifiers we do not care about.
    var typedCharacters: String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        keyboardGetUnicodeString(maxStringLength: buffer.count,
                                 actualStringLength: &length,
                                 unicodeString: &buffer)
        guard length > 0 else { return "" }
        return String(utf16CodeUnits: buffer, count: length)
    }
}
