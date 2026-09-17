import AppKit

/// A way to drive WindowQueue from a script, for testing features without synthesizing keystrokes
/// that would land in whatever app is in front.
///
/// Off unless `defaults write com.mpochec.windowqueue debugCommands -bool true`. Commands arrive as
/// distributed notifications named `com.mpochec.windowqueue.command`, the command line as the object:
///
///     action cycleNext            any `HotkeyAction` raw value
///     aim                         tap the super key (open aiming mode, or confirm it)
///     aimkey forward [shift] [move]
///     dump                        write the queue state to ~/Library/Logs/WindowQueue/state.txt
final class DebugCommands {
    static let notificationName = Notification.Name("com.mpochec.windowqueue.command")
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "debugCommands") }

    private let handler: ([String]) -> Void
    private var observer: NSObjectProtocol?

    init(handler: @escaping ([String]) -> Void) {
        self.handler = handler
    }

    func start() {
        guard Self.isEnabled, observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName, object: nil, queue: .main
        ) { [weak self] note in
            guard let line = note.object as? String else { return }
            self?.handler(line.split(separator: " ").map(String.init))
        }
    }

    static func writeState(_ model: WindowQueueModel) {
        var lines: [String] = []
        lines.append("time \(Date().timeIntervalSince1970)")
        lines.append("currentSpace \(model.currentSpaceID.map(String.init) ?? "nil") index \(model.currentSpaceIndex.map(String.init) ?? "nil")")
        lines.append("spaceOrder \(model.spaceOrder.map(String.init).joined(separator: ","))")
        lines.append("selected \(model.selectedID.map(String.init) ?? "nil")")
        lines.append("aiming \(model.aimingID.map(String.init) ?? "nil") anchor \(model.aimAnchorID.map(String.init) ?? "nil")")
        lines.append("emptySlot \(model.emptySlot.map { "space=\($0.spaceID) before=\($0.beforeID.map(String.init) ?? "end")" } ?? "nil")")
        lines.append("autoSort \(model.autoSortByWorkspace)")
        let front = NSWorkspace.shared.frontmostApplication
        let focused = front.flatMap {
            AXPrivate.application($0.processIdentifier).attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
        }.flatMap(AXPrivate.windowID(of:))
        lines.append("frontmost \(front?.localizedName ?? "nil") pid \(front?.processIdentifier ?? -1) focusedWindow \(focused.map(String.init) ?? "nil")")
        lines.append("pointer \(NSEvent.mouseLocation)")
        let serverSpaces = SpacesBridge.shared.spaces(forWindows: model.windows.map(\.id))
        for window in model.windows {
            let workspace = model.workspaceNumber(of: window).map(String.init) ?? "-"
            let actual = serverSpaces[window.id].map(String.init) ?? "nil"
            lines.append("win \(window.id) ws=\(workspace) space=\(window.spaceID.map(String.init) ?? "nil") server=\(actual) min=\(window.isMinimized) el=\(window.element != nil) pid=\(window.pid) \(window.appName) | \(window.title)")
        }
        let url = Diagnostics.logURL.deletingLastPathComponent().appendingPathComponent("state.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
