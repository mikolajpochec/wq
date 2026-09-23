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

/// The contents of a group, drawn as a second strip beside the first one: the same icons, the same
/// material, the same size — it reads as a continuation of the strip rather than a menu.
struct GroupPanelView: View {
    @ObservedObject var state: GroupPanelState
    @ObservedObject var store: PreferencesStore
    var pick: (ManagedWindow) -> Void

    private var prefs: Preferences { store.prefs }
    private var side: StripSide { prefs.stripSide }

    private var stack: AnyLayout {
        side.isVertical
            ? AnyLayout(VStackLayout(spacing: StripMetrics.spacing))
            : AnyLayout(HStackLayout(spacing: StripMetrics.spacing))
    }

    var body: some View {
        stack {
            ForEach(state.windows) { window in
                row(for: window)
            }
        }
        .padding(StripMetrics.padding)
        .frame(width: side.isVertical ? StripMetrics.thickness(prefs: prefs) : nil,
               height: side.isVertical ? nil : StripMetrics.thickness(prefs: prefs))
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.corner(prefs: prefs), style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(prefs.stripOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.corner(prefs: prefs), style: .continuous)
                .strokeBorder(state.isPeek ? Color.primary.opacity(0.12) : Color.accentColor.opacity(0.55),
                              lineWidth: state.isPeek ? 1 : 1.5)
        )
        .padding(4)
    }

    private func row(for window: ManagedWindow) -> some View {
        let selected = window.id == state.selectedID
        return Group {
            if let icon = window.icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: StripMetrics.iconCorner(prefs: prefs))
                    .fill(Color.secondary.opacity(0.3))
            }
        }
        .frame(width: prefs.iconSize, height: prefs.iconSize)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .help(window.displayTitle)
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

        let view = GroupPanelView(state: state, store: store) { [weak self] window in
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
        // The second strip runs alongside the first, starting level with the group's own entry, and
        // is nudged back on screen when the group sits near the end of the strip.
        let alignedY = min(max(anchor.frame.maxY - size.height, visible.minY + margin),
                           visible.maxY - size.height - margin)
        let alignedX = min(max(anchor.frame.minX, visible.minX + margin),
                           visible.maxX - size.width - margin)
        switch anchor.side {
        case .left: return NSPoint(x: anchor.frame.maxX, y: alignedY)
        case .right: return NSPoint(x: anchor.frame.minX - size.width, y: alignedY)
        case .top: return NSPoint(x: alignedX, y: anchor.frame.minY - size.height)
        case .bottom: return NSPoint(x: alignedX, y: anchor.frame.maxY)
        }
    }
}
