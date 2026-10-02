import AppKit
import ApplicationServices

/// Optional troubleshooting dump, enabled with:
/// `defaults write com.mpochec.windowqueue diagnostics -bool true`
///
/// Writes what the Accessibility enumeration found next to what the WindowServer reports, which is
/// the quickest way to tell whether a missing window is a discovery problem or a filtering one.
enum Diagnostics {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "diagnostics") }

    private static var directory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/WindowQueue", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Snapshot of the current state, rewritten on every refresh.
    static var logURL: URL { directory.appendingPathComponent("diagnostics.txt") }
    /// Append-only breadcrumbs, kept separate so a snapshot never overwrites them.
    static var eventsURL: URL { directory.appendingPathComponent("events.log") }

    /// Always-on breadcrumb so a launch that stalls on permissions leaves a trace.
    static func note(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        let url = eventsURL
        rotateIfLarge(url)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static let maxEventsSize = 5_000_000
    private static var notesSinceSizeCheck = 0

    /// Keeps the log from growing for ever: past a few megabytes it becomes `events.1.log`,
    /// replacing the one before. The size is looked at every few hundred notes, not every one.
    private static func rotateIfLarge(_ url: URL) {
        notesSinceSizeCheck += 1
        guard notesSinceSizeCheck >= 200 else { return }
        notesSinceSizeCheck = 0
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > maxEventsSize else { return }
        let old = url.deletingLastPathComponent().appendingPathComponent("events.1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }

    /// The WindowServer and accessibility halves of a dump ask every application about every
    /// window, each question allowed to block; on the main thread that stalls the strip right after
    /// every refresh — a Space switch included. They run here instead, one dump at a time.
    private static let dumpQueue = DispatchQueue(label: "WindowQueue.diagnostics", qos: .utility)
    private static var isDumping = false

    /// Call on the main thread: the model is read here, the slow part runs on `dumpQueue`.
    static func dump(model: WindowQueueModel) {
        // A dump still in flight is about to write a snapshot just as fresh.
        guard !isDumping else { return }
        isDumping = true
        var lines: [String] = []
        lines.append("=== WindowQueue diagnostics \(Date()) ===")
        lines.append("AX trusted: \(AXIsProcessTrusted())  window numbers: \(AXPrivate.supportsWindowNumbers)")
        lines.append("Spaces API: \(SpacesBridge.shared.isAvailable)  desktops: \(SpacesBridge.shared.spaceCount)")
        lines.append("current space id: \(model.currentSpaceID.map(String.init) ?? "nil") index: \(model.currentSpaceIndex.map(String.init) ?? "nil")")
        lines.append("scope: \(model.scope.rawValue)  queued: \(model.windows.count)  visible: \(model.visibleWindows.count)")

        lines.append("--- queue ---")
        for (index, window) in model.windows.enumerated() {
            lines.append(String(format: "%2d  id=%-8u space=%-22@ pid=%-6d min=%@ %@ — %@",
                                index + 1, window.id,
                                (window.spaceID.map(String.init) ?? "nil") as NSString,
                                window.pid, window.isMinimized ? "y" : "n",
                                window.appName, window.title))
        }

        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
            .map { (pid: $0.processIdentifier, name: $0.localizedName ?? "?") }
        let url = logURL
        dumpQueue.async {
            lines.append("--- WindowServer real windows (all spaces) ---")
            lines.append(contentsOf: windowServerList())
            lines.append("--- accessibility, per application ---")
            lines.append(contentsOf: accessibilityList(apps: apps))

            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { isDumping = false }
        }
    }

    private static func windowServerList() -> [String] {
        let options: CGWindowListOption = [.excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ["<unavailable>"]
        }
        let candidates = raw.compactMap { info -> (CGWindowID, String, Int, Int)? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any]
            else { return nil }
            let width = Int((bounds["Width"] as? Double) ?? 0)
            let height = Int((bounds["Height"] as? Double) ?? 0)
            // Skip the toolbar/shadow helper windows every app keeps around.
            guard width >= 200, height >= 200 else { return nil }
            let owner = (info[kCGWindowOwnerName as String] as? String) ?? "?"
            return (id, owner, width, height)
        }
        let spaces = SpacesBridge.shared.spaces(forWindows: candidates.map(\.0))
        return candidates.map { id, owner, width, height in
            let ordered = SpacesBridge.shared.isOrderedIn(id).map { $0 ? "yes" : "no" } ?? "?"
            return "id=\(id) \(width)x\(height) space=\(spaces[id].map(String.init) ?? "nil") ordered=\(ordered) \(owner)"
        }
    }

    private static func accessibilityList(apps: [(pid: pid_t, name: String)]) -> [String] {
        var lines: [String] = []

        // Per-pid window counts straight from the WindowServer, to compare against what AX reports.
        var serverCounts: [pid_t: Int] = [:]
        let raw = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in raw where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            serverCounts[pid, default: 0] += 1
        }

        for app in apps {
            let element = AXPrivate.application(app.pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
            let windows = value as? [AXUIElement]

            var count: CFIndex = -1
            AXUIElementGetAttributeValueCount(element, kAXWindowsAttribute as CFString, &count)

            var ranged: CFArray?
            let rangedError = AXUIElementCopyAttributeValues(element, kAXWindowsAttribute as CFString, 0, 50, &ranged)
            let rangedCount = (ranged as? [AXUIElement])?.count ?? -1

            let name = app.name
            let server = serverCounts[app.pid] ?? 0
            let hidden = element.boolAttribute(kAXHiddenAttribute) ?? false
            let focusedID = element.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self)
                .flatMap { AXPrivate.windowID(of: $0) }
                .map(String.init) ?? "nil"
            lines.append("\(name) pid=\(app.pid) axError=\(error.rawValue) ax=\(windows?.count ?? -1) count=\(count) ranged=\(rangedCount)/\(rangedError.rawValue) server=\(server) hidden=\(hidden) focusedWindow=\(focusedID)")
            guard let windows else { continue }
            for window in windows {
                let id = AXPrivate.windowID(of: window).map(String.init) ?? "nil"
                let role = window.attribute(kAXRoleAttribute, as: String.self) ?? "?"
                let subrole = window.attribute(kAXSubroleAttribute, as: String.self) ?? "?"
                let title = window.attribute(kAXTitleAttribute, as: String.self) ?? ""
                lines.append("    id=\(id) role=\(role) subrole=\(subrole) — \(title)")
            }
        }
        return lines
    }
}
