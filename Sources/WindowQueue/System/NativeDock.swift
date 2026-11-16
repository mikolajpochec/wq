import AppKit

/// The macOS Dock's "Automatically hide and show the Dock" setting, read and changed the way
/// System Settings does it (private `CoreDock` calls, applied live without restarting the Dock).
enum NativeDock {
    private typealias GetFn = @convention(c) () -> Bool
    private typealias SetFn = @convention(c) (Bool) -> Void

    private static let services = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let getAutoHide: GetFn? = services.flatMap { dlsym($0, "CoreDockGetAutoHideEnabled") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setAutoHide: SetFn? = services.flatMap { dlsym($0, "CoreDockSetAutoHideEnabled") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    /// Whether the Dock hides itself until the pointer reaches its edge.
    static var isAutoHidden: Bool {
        if let getAutoHide { return getAutoHide() }
        return UserDefaults(suiteName: "com.apple.dock")?.bool(forKey: "autohide") ?? false
    }

    /// Turns the Dock's auto-hide on or off.
    static func setAutoHidden(_ hidden: Bool) {
        if let setAutoHide {
            setAutoHide(hidden)
        } else {
            // Fallback: write the preference and restart the Dock so it picks it up.
            let script = "defaults write com.apple.dock autohide -bool \(hidden) && killall Dock"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            try? process.run()
        }
        Diagnostics.note("native dock auto-hide \(hidden ? "on" : "off")")
        // The strip's own room is only reserved while the Dock hides itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { DockReservation.shared?.update() }
    }
}
