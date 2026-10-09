import AppKit
import SwiftUI

/// Stands in for a tiled window too big for its place: one with a minimum or a fixed size that its
/// neighbours could not make room for, even at their smallest.
///
/// The window itself sits centred under its place, behind its neighbours, and a placeholder fills
/// the place: the app, the window's title and why it is not shown. Focusing the window — from the
/// strip, or by clicking the placeholder — brings it out over the layout; focusing one of the others
/// puts the placeholder back in front of it.
///
/// A placeholder is an ordinary-level panel, so other apps' windows go over it as over any window.
/// It is ordered in once its window is on screen, so it joins the window's workspace, and goes when
/// the window closes or leaves the layout.
final class TilePlaceholders {
    static let shared = TilePlaceholders()

    /// The panels' title, by which the window enumerator tells them from windows to queue.
    static let title = "WindowQueue tile placeholder"

    /// The window was clicked through its placeholder: focus it.
    var onReveal: ((CGWindowID) -> Void)?
    /// Whether the window is still held in a layout.
    var isTiled: (CGWindowID) -> Bool = { _ in true }
    /// Whether the window has the focus, so it is out in front and no placeholder belongs over it.
    var isFocused: (CGWindowID) -> Bool = { _ in false }

    private struct Slot {
        /// The window's place, in Cocoa screen coordinates.
        var room: NSRect
        let panel: NSPanel
        var orderedIn = false
    }

    private var slots: [CGWindowID: Slot] = [:]
    private var timer: Timer?

    /// The ids of the windows a placeholder stands in for.
    var heldIDs: Set<CGWindowID> { Set(slots.keys) }

    /// Gives these windows a placeholder at the room passed, or takes theirs away for a nil room.
    func set(_ entries: [(window: ManagedWindow, limits: SizeLimits, room: NSRect?)]) {
        for entry in entries {
            let id = entry.window.id
            guard let room = entry.room else {
                remove(id)
                continue
            }
            let panel = slots[id]?.panel ?? make(for: id)
            panel.setFrame(room, display: false)
            (panel.contentView as? NSHostingView<PlaceholderView>)?.rootView = PlaceholderView(
                icon: NSRunningApplication(processIdentifier: entry.window.pid)?.icon,
                appName: entry.window.appName, title: entry.window.title,
                reason: Self.reason(entry.limits, room: room.size))
            slots[id] = Slot(room: room, panel: panel, orderedIn: slots[id]?.orderedIn ?? false)
        }
        // After the windows have been raised and focused, which follows the tiling.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.cover(entries.map(\.window.id))
        }
        if !slots.isEmpty, timer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.update() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    /// Puts these windows' placeholders back in front of them, unless the window has the focus.
    func cover(_ ids: [CGWindowID]) {
        for id in ids {
            guard var slot = slots[id], !isFocused(id), onScreen(id) else { continue }
            if !slot.orderedIn { Diagnostics.note("placeholder over window \(id) at \(slot.room)") }
            slot.panel.order(.above, relativeTo: Int(id))
            slot.panel.alphaValue = 1
            slot.orderedIn = true
            slots[id] = slot
        }
    }

    func remove(_ id: CGWindowID) {
        slots.removeValue(forKey: id)?.panel.orderOut(nil)
        if slots.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }

    private func onScreen(_ id: CGWindowID) -> Bool {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
        return info?[kCGWindowIsOnscreen as String] as? Bool ?? false
    }

    private func update() {
        for (id, slot) in slots {
            guard isTiled(id),
                  let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first
            else {
                remove(id)
                continue
            }
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !slot.orderedIn {
                if onScreen { cover([id]) }
            } else if slot.panel.isOnActiveSpace {
                // Minimised, or its app hidden: nothing to stand in for until it is back.
                slot.panel.alphaValue = onScreen ? 1 : 0
            }
        }
    }

    static func reason(_ limits: SizeLimits, room: CGSize) -> String {
        func text(_ size: CGSize) -> String { "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))" }
        let place = "its place here is \(text(room))"
        if limits.isFixed {
            return "Its size is fixed at \(text(limits.min)); \(place)."
        }
        return "It does not go smaller than \(text(limits.fitted(in: room))); \(place)."
    }

    private func make(for id: CGWindowID) -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = Self.title
        panel.level = .normal
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let host = ClickHostingView(rootView: PlaceholderView(icon: nil, appName: "", title: "", reason: ""))
        host.onClick = { [weak self] in
            Diagnostics.note("placeholder clicked: showing window \(id)")
            self?.onReveal?(id)
        }
        panel.contentView = host
        return panel
    }

    private final class ClickHostingView: NSHostingView<PlaceholderView> {
        var onClick: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            onClick?()
        }
    }

    struct PlaceholderView: View {
        let icon: NSImage?
        let appName: String
        let title: String
        let reason: String

        var body: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.background.opacity(0.92))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                VStack(spacing: 8) {
                    if let icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }
                    Text(appName)
                        .font(.headline)
                    if !title.isEmpty {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text("Too big for this place")
                        .font(.callout.weight(.medium))
                        .padding(.top, 6)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Click to show it")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.center)
                .padding(20)
            }
        }
    }
}
