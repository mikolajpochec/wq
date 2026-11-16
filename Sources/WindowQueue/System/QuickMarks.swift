import AppKit
import Carbon.HIToolbox

/// A window or an app put on a key, vim-marks style but in two strokes and with no letters to
/// learn: the bind shortcut, then any key, binds; the jump shortcut, then that key, goes back.
struct QuickMark: Codable, Equatable {
    enum Kind: String, Codable {
        /// This very window.
        case window
        /// Whichever window of the app; pressed again from inside the app, its next window.
        case app
    }

    var kind: Kind
    /// The window, while it lives (window marks only).
    var windowID: CGWindowID?
    /// The window's `orderKey`, to find it again after the app or WindowQueue restarted.
    var orderKey: String?
    var bundleID: String?
    var appName: String
    /// What the window was called when it was bound, for the popup.
    var title: String

    init(kind: Kind, window: ManagedWindow) {
        self.kind = kind
        windowID = kind == .window ? window.id : nil
        orderKey = kind == .window ? window.orderKey : nil
        bundleID = window.bundleID
        appName = window.appName
        title = kind == .window ? window.displayTitle : window.appName
    }

    func belongs(_ window: ManagedWindow) -> Bool {
        if let bundleID, let other = window.bundleID { return bundleID == other }
        return appName == window.appName
    }

    enum Target: Equatable {
        case window(CGWindowID)
        /// Nothing of the app is open: start it.
        case launch(bundleID: String)
        case gone
    }

    /// Where pressing this mark goes.
    ///
    /// - Parameters:
    ///   - windows: the queue, in order.
    ///   - recent: window ids, most recently focused first.
    ///   - current: the window focused now.
    func target(in windows: [ManagedWindow], recent: [CGWindowID], current: CGWindowID?) -> Target {
        switch kind {
        case .window:
            if let windowID, windows.contains(where: { $0.id == windowID }) { return .window(windowID) }
            if let orderKey, let match = windows.first(where: { $0.orderKey == orderKey }) {
                return .window(match.id)
            }
            // The exact window is gone; its app is the next best thing.
            let ofApp = windows.filter(belongs)
            if let any = Self.mostRecent(ofApp, recent: recent) { return .window(any.id) }
            return bundleID.map { .launch(bundleID: $0) } ?? .gone
        case .app:
            let ofApp = windows.filter(belongs)
            guard !ofApp.isEmpty else { return bundleID.map { .launch(bundleID: $0) } ?? .gone }
            // Already in the app: walk on through its windows in queue order.
            if let current, let index = ofApp.firstIndex(where: { $0.id == current }) {
                return .window(ofApp[(index + 1) % ofApp.count].id)
            }
            return .window(Self.mostRecent(ofApp, recent: recent)!.id)
        }
    }

    private static func mostRecent(_ windows: [ManagedWindow], recent: [CGWindowID]) -> ManagedWindow? {
        for id in recent {
            if let window = windows.first(where: { $0.id == id }) { return window }
        }
        return windows.first
    }
}

/// The marks, keyed by virtual key code, kept in their own defaults entry so the preferences file
/// stays about preferences.
final class QuickMarkStore {
    private static let key = "quickMarks.v1"
    private let defaults: UserDefaults

    private(set) var marks: [Int: QuickMark] = [:]
    /// Window ids, most recently focused first, for app marks to land where the user last was.
    private(set) var recent: [CGWindowID] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode([String: QuickMark].self, from: data) {
            marks = Dictionary(uniqueKeysWithValues: stored.compactMap { key, mark in
                Int(key).map { ($0, mark) }
            })
        }
    }

    func set(_ mark: QuickMark?, keyCode: Int) {
        marks[keyCode] = mark
        save()
    }

    func noteFocus(_ id: CGWindowID) {
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        if recent.count > 200 { recent.removeLast(recent.count - 200) }
    }

    /// The window's own marks, and its app's, for the popup to say what is already bound.
    func keys(for window: ManagedWindow) -> [Int] {
        marks.filter { _, mark in
            mark.kind == .window ? mark.windowID == window.id : mark.belongs(window)
        }.keys.sorted()
    }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: marks.map { ("\($0.key)", $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.key) }
    }

    static let escapeKeyCode = kVK_Escape

    /// Keys that cannot be a mark: Escape cancels and the rest are better left alone.
    static func isMarkable(keyCode: Int) -> Bool {
        ![kVK_Escape, kVK_Return, kVK_Tab, kVK_Command, kVK_Shift, kVK_Option, kVK_Control,
          kVK_RightCommand, kVK_RightShift, kVK_RightOption, kVK_RightControl, kVK_Function,
          kVK_CapsLock].contains(keyCode)
    }
}
