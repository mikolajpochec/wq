import AppKit
import Combine
import SwiftUI

/// A colour a window or a group can be marked with. The window gets a border of it on screen and
/// its tile on the strip a ring of it, so similar windows can be told apart at a glance.
enum WindowTint: String, CaseIterable, Codable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink, gray

    var id: String { rawValue }

    var title: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .gray: return .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    /// A filled dot for menu items.
    var swatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }
}

/// Names and colours the user gives windows and groups. Like groups themselves, they last for the
/// session: window ids are handed out per session and titles change too often to key them on.
///
/// A window's own colour wins over its group's, so one window of a coloured group can still stand
/// out.
final class WindowMarks: ObservableObject {
    static let shared = WindowMarks()

    @Published private(set) var names: [CGWindowID: String] = [:]
    @Published private(set) var windowTints: [CGWindowID: WindowTint] = [:]
    @Published private(set) var groupTints: [Int: WindowTint] = [:]
    /// Which group each grouped window is in, mirrored from the model so the colour of a window can
    /// be worked out here alone.
    @Published private(set) var groupOfWindow: [CGWindowID: Int] = [:]

    init() {}

    func name(for id: CGWindowID) -> String? { names[id] }

    func setName(_ name: String?, for id: CGWindowID) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[id] = trimmed.isEmpty ? nil : trimmed
    }

    func setTint(_ tint: WindowTint?, for id: CGWindowID) {
        windowTints[id] = tint
    }

    func setTint(_ tint: WindowTint?, forGroup group: Int) {
        groupTints[group] = tint
    }

    func groupTint(_ group: Int) -> WindowTint? { groupTints[group] }

    /// The colour the window is shown in: its own, else its group's.
    func tint(for id: CGWindowID) -> WindowTint? {
        if let own = windowTints[id] { return own }
        return groupOfWindow[id].flatMap { groupTints[$0] }
    }

    /// Every window that has a colour, own or through its group.
    var tintedWindowIDs: Set<CGWindowID> {
        var ids = Set(windowTints.keys)
        for (window, group) in groupOfWindow where groupTints[group] != nil { ids.insert(window) }
        return ids
    }

    /// Keeps the group mirror in step with the model; a group that has gone loses its colour, so a
    /// later group given the same number starts uncoloured.
    func syncGroups(_ groups: [WindowQueueModel.WindowGroup]) {
        var map: [CGWindowID: Int] = [:]
        for group in groups { for id in group.ids { map[id] = group.id } }
        if map != groupOfWindow { groupOfWindow = map }
        let live = Set(groups.map(\.id))
        let stale = groupTints.keys.filter { !live.contains($0) }
        for id in stale { groupTints[id] = nil }
    }

    /// Forgets windows that have closed.
    func prune(keeping live: Set<CGWindowID>) {
        let deadNames = names.keys.filter { !live.contains($0) }
        let deadTints = windowTints.keys.filter { !live.contains($0) }
        for id in deadNames { names[id] = nil }
        for id in deadTints { windowTints[id] = nil }
    }
}
