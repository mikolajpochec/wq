import AppKit
import Combine
import SwiftUI

/// What the panel beside the strip is showing: the windows of one group.
final class GroupPanelState: ObservableObject {
    @Published var number = 0
    @Published var windows: [ManagedWindow] = []
    @Published var selectedID: CGWindowID?
    /// The group is only being peeked at from the pointer, not stepped into.
    @Published var isPeek = false
}

/// The contents of a group, beside the strip: one row per window, with its title.
struct GroupPanelView: View {
    @ObservedObject var state: GroupPanelState
    let iconSize: CGFloat
    var pick: (ManagedWindow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Group \(state.number)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.bottom, 2)
            ForEach(state.windows) { window in
                row(for: window)
            }
        }
        .padding(6)
        .frame(width: 260, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(state.isPeek ? Color.primary.opacity(0.15) : Color.accentColor.opacity(0.5),
                              lineWidth: state.isPeek ? 1 : 1.5)
        )
    }

    private func row(for window: ManagedWindow) -> some View {
        let selected = window.id == state.selectedID
        return HStack(spacing: 8) {
            if let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: iconSize * 0.8, height: iconSize * 0.8)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(window.displayTitle).lineLimit(1)
                Text(window.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.3) : .clear)
        )
        .contentShape(Rectangle())
        // The panel is never key, so a zero-distance drag is what registers a click in it.
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in pick(window) })
    }
}

/// Owns the panel that shows a group's windows beside the strip.
final class GroupPanelController {
    let state = GroupPanelState()
    private let store: PreferencesStore
    private var panel: OverlayPanel?
    private var hosting: NSHostingView<GroupPanelView>?

    /// Screen rect of the group's entry in the strip, and the strip's side, to place the panel.
    var anchorProvider: ((CGWindowID) -> (frame: NSRect, side: StripSide)?)?
    /// A window in the panel was clicked.
    var onPick: ((ManagedWindow) -> Void)?

    init(store: PreferencesStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(number: Int, windows: [ManagedWindow], selected: CGWindowID?, peek: Bool) {
        guard windows.count > 1, let anchorID = windows.first?.id else {
            hide()
            return
        }
        state.number = number
        state.windows = windows
        state.selectedID = selected
        state.isPeek = peek

        let view = GroupPanelView(state: state, iconSize: store.prefs.iconSize) { [weak self] window in
            self?.onPick?(window)
        }
        let hosting = self.hosting ?? NSHostingView(rootView: view)
        hosting.rootView = view
        self.hosting = hosting

        let panel = self.panel ?? {
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
            panel.contentView = hosting
            return panel
        }()
        self.panel = panel
        let size = hosting.fittingSize
        panel.setFrame(NSRect(origin: origin(for: size, anchorID: anchorID), size: size), display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            OverlaySpace.shared.adopt(panel)
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func origin(for size: NSSize, anchorID: CGWindowID) -> NSPoint {
        let margin: CGFloat = 10
        guard let anchor = anchorProvider?(anchorID) else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        // Beside the entry, kept on screen: a group near the end of the strip still shows in full.
        let clampedY = min(max(anchor.frame.midY - size.height / 2, visible.minY + margin),
                           visible.maxY - size.height - margin)
        let clampedX = min(max(anchor.frame.midX - size.width / 2, visible.minX + margin),
                           visible.maxX - size.width - margin)
        switch anchor.side {
        case .left: return NSPoint(x: anchor.frame.maxX + margin, y: clampedY)
        case .right: return NSPoint(x: anchor.frame.minX - size.width - margin, y: clampedY)
        case .top: return NSPoint(x: clampedX, y: anchor.frame.minY - size.height - margin)
        case .bottom: return NSPoint(x: clampedX, y: anchor.frame.maxY + margin)
        }
    }
}
