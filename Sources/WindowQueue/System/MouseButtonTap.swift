import AppKit
import CoreGraphics

/// Turns the mouse's side buttons into WindowQueue actions.
///
/// A monitor could only watch the clicks, and the app under the pointer would still go back or
/// forward. A session event tap can swallow them, so a button bound to an action does only that;
/// one left on "do nothing" passes straight through. The release is swallowed along with the
/// press, so no app sees half a click.
final class MouseButtonTap {
    /// `kCGMouseEventButtonNumber` of the side buttons.
    private static let backButton: Int64 = 3
    private static let forwardButton: Int64 = 4

    private let store: PreferencesStore
    var onAction: ((HotkeyAction) -> Void)?

    private var tap: CFMachPort?

    init(store: PreferencesStore) {
        self.store = store
    }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MouseButtonTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        else {
            Diagnostics.note("mouse buttons: could not create event tap")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
    }

    private func action(forButton button: Int64) -> MouseButtonAction {
        switch button {
        case Self.backButton: return store.prefs.mouseBackButton
        case Self.forwardButton: return store.prefs.mouseForwardButton
        default: return .passThrough
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        guard let action = action(forButton: button).hotkeyAction else {
            return Unmanaged.passUnretained(event)
        }
        if type == .otherMouseDown {
            // Acting inside the callback would hold up every mouse event behind it.
            DispatchQueue.main.async { [weak self] in
                Diagnostics.note("mouse button \(button): \(action.rawValue)")
                self?.onAction?(action)
            }
        }
        return nil
    }
}
