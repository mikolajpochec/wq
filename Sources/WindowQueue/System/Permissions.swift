import AppKit
import ApplicationServices

/// Gates startup on the Accessibility (TCC) permission, which every AX call here needs.
final class Permissions {
    private var timer: Timer?

    var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts once, then polls until the user grants access, calling `onGranted` on the main thread.
    func requestAndWait(onGranted: @escaping () -> Void) {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
