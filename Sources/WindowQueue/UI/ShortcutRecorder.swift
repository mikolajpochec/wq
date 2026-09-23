import AppKit
import SwiftUI

/// Click-to-record view for a single shortcut. Captures the next key press with modifiers.
struct ShortcutRecorder: NSViewRepresentable {
    let combo: KeyCombo?
    /// Aiming mode has the keyboard to itself, so its own keys are bare ones; a global shortcut
    /// cannot be, and there a bare key is refused.
    var allowsBareKey = false
    let onChange: (KeyCombo) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.combo = combo
        view.allowsBareKey = allowsBareKey
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = onChange
        view.combo = combo
        view.allowsBareKey = allowsBareKey
    }

    final class RecorderView: NSView {
        var onChange: ((KeyCombo) -> Void)?
        var combo: KeyCombo? { didSet { needsDisplay = true } }
        var allowsBareKey = false
        private var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 130, height: 24) }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            isRecording = true
        }

        override func resignFirstResponder() -> Bool {
            isRecording = false
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { // Escape cancels
                isRecording = false
                window?.makeFirstResponder(nil)
                return
            }
            guard let recorded = KeyCombo(event: event)
                ?? (allowsBareKey ? KeyCombo(keyCode: UInt32(event.keyCode), modifiers: 0) : nil)
            else {
                NSSound.beep() // bare keys cannot be global shortcuts
                return
            }
            combo = recorded
            onChange?(recorded)
            isRecording = false
            window?.makeFirstResponder(nil)
        }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                         : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()

            let text = isRecording ? "Press keys…" : (combo?.displayString ?? "Unset")
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: isRecording ? NSColor.controlAccentColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            let origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2)
            (text as NSString).draw(at: origin, withAttributes: attributes)
        }
    }
}
