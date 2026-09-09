import AppKit
import CoreGraphics

/// Optional Screen Recording access.
///
/// Not needed to find or focus windows. It is only what makes `kCGWindowName` readable, which is
/// the one way to show a title for a window sitting on a Space we have not visited yet — the
/// Accessibility API cannot see those.
enum ScreenRecordingAccess {
    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt. macOS only shows it once per app identity; afterwards the user
    /// has to flip the switch in System Settings themselves.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
