import AppKit
import ApplicationServices

/// Gates startup on the Accessibility (TCC) permission, which every AX call here needs.
final class Permissions {
    private var timer: Timer?

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once (unless `prompt` is off — the tour asks in its own words instead), then polls
    /// until the user grants access, calling `onGranted` on the main thread.
    func requestAndWait(prompt: Bool = true, onGranted: @escaping () -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            onGranted()
            return
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.timer = nil
            onGranted()
        }
    }

    /// Shows the system's own request, which offers to open the settings at the right switch.
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
