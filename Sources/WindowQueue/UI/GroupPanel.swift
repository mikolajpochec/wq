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
    /// Aiming mode's cursor and run, so the group's strip highlights them like the main one.
    @Published var aimingID: CGWindowID?
    @Published var aimedIDs: Set<CGWindowID> = []
    /// Windows a fullscreen window in this group is covering, folded into one tile here.
    @Published var coveredIDs: Set<CGWindowID> = []
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

    /// What the group's strip shows: its windows, with the ones a fullscreen window covers folded
    /// into a single cascade — the same thing the main strip does, in the place they live.
    private var entries: [Entry] {
        var out: [Entry] = []
        var covered: [ManagedWindow] = []
        for window in state.windows {
            if state.coveredIDs.contains(window.id) {
                covered.append(window)
            } else {
                out.append(.window(window))
            }
        }
        if !covered.isEmpty { out.append(.cascade(covered)) }
        return out
    }

    private enum Entry: Identifiable {
        case window(ManagedWindow)
        case cascade([ManagedWindow])

        var id: String {
            switch self {
            case .window(let window): return "w\(window.id)"
            case .cascade: return "cascade"
            }
        }
    }

    var body: some View {
        stack {
            ForEach(entries) { entry in
                switch entry {
                case .window(let window): row(for: window)
                case .cascade(let windows): cascade(windows)
                }
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
    }

    /// The covered windows as one tile: the first few icons behind each other, and how many.
    private func cascade(_ windows: [ManagedWindow]) -> some View {
        let peek = Array(windows.prefix(StripMetrics.stackPeek))
        let middle = CGFloat(peek.count - 1) / 2
        return ZStack {
            ForEach(Array(peek.enumerated().reversed()), id: \.element.id) { depth, window in
                let back = CGFloat(depth)
                let lean = (back - middle) * StripMetrics.stackStep
                icon(for: window)
                    .frame(width: prefs.iconSize, height: prefs.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: StripMetrics.iconCorner(prefs: prefs), style: .continuous))
                    .saturation(1 - back * 0.35)
                    .opacity(1 - back * 0.28)
                    .scaleEffect(1 - back * 0.1)
                    .offset(x: side.isVertical ? 0 : lean, y: side.isVertical ? lean : 0)
            }
        }
        .frame(width: prefs.iconSize, height: prefs.iconSize)
        .overlay(alignment: .bottomTrailing) {
            Text("+\(windows.count)")
                .font(.system(size: max(8, prefs.iconSize * 0.3), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.95)))
                .offset(x: 3, y: 3)
        }
        .padding(4)
        .help("\(windows.count) window\(windows.count == 1 ? "" : "s") behind the fullscreen one")
    }

    @ViewBuilder
    private func icon(for window: ManagedWindow) -> some View {
        if let image = window.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: StripMetrics.iconCorner(prefs: prefs))
                .fill(Color.secondary.opacity(0.3))
        }
    }

    private func row(for window: ManagedWindow) -> some View {
        let aimed = state.aimedIDs.contains(window.id)
        let selected = window.id == state.selectedID && !aimed
        let highlight: Color? = aimed ? .orange : (selected ? .accentColor : nil)
        return icon(for: window)
            .frame(width: prefs.iconSize, height: prefs.iconSize)
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .fill(highlight?.opacity(0.28) ?? .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .strokeBorder(highlight ?? .clear,
                              lineWidth: window.id == state.aimingID ? 2.5 : 1.5)
        )
        .contentShape(Rectangle())
        .help(window.displayTitle)
        // The panel is never key, so a zero-distance drag is what registers a click in it.
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in pick(window) })
    }
}

/// Hosting view that reports the pointer, since the panel is never key and SwiftUI's own hover
/// tracking would never fire in it — the same reason the main strip has one of these.
private final class GroupHostingView: NSHostingView<GroupPanelView> {
    var onPointerMoved: ((NSPoint?) -> Void)?
    var onMiddleClick: ((NSPoint) -> Void)?

    private var tracking: NSTrackingArea?

    required init(rootView: GroupPanelView) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("unsupported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointerMoved?(nil)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return super.otherMouseDown(with: event) }
        onMiddleClick?(convert(event.locationInWindow, from: nil))
    }
}

/// Owns the panel that shows a group's windows beside the strip.
final class GroupPanelController {
    let state = GroupPanelState()
    private let store: PreferencesStore
    private var panel: OverlayPanel?
    private var hosting: GroupHostingView?
    private var hoveredID: CGWindowID?

    /// Screen rect of the strip's content and the edge it lives on, so the group's strip can carry
    /// on in the same line rather than sitting beside it.
    var stripFrameProvider: (() -> (frame: NSRect, side: StripSide)?)?
    /// A window in the panel was clicked.
    var onPick: ((ManagedWindow) -> Void)?
    /// The pointer came to rest on a window in the panel, or left it.
    var onHover: ((ManagedWindow?) -> Void)?
    /// A window in the panel was middle-clicked, which closes it as it does in the strip.
    var onClose: ((ManagedWindow) -> Void)?

    init(store: PreferencesStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(number: Int, windows: [ManagedWindow], selected: CGWindowID?, peek: Bool,
              aimingID: CGWindowID? = nil, aimedIDs: Set<CGWindowID> = [],
              coveredIDs: Set<CGWindowID> = []) {
        guard windows.count > 1 else {
            hide()
            return
        }
        state.number = number
        state.windows = windows
        state.selectedID = selected
        state.isPeek = peek
        state.aimingID = aimingID
        state.aimedIDs = aimedIDs
        state.coveredIDs = coveredIDs

        let view = GroupPanelView(state: state, store: store) { [weak self] window in
            self?.onPick?(window)
        }
        let hosting = self.hosting ?? GroupHostingView(rootView: view)
        hosting.rootView = view
        if self.hosting == nil {
            hosting.onPointerMoved = { [weak self] point in self?.pointerMoved(to: point) }
            hosting.onMiddleClick = { [weak self] point in
                guard let self, let window = self.window(at: point) else { return }
                self.onClose?(window)
            }
        }
        self.hosting = hosting

        let panel = self.panel ?? {
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
            panel.acceptsMouseMovedEvents = true
            panel.contentView = hosting
            return panel
        }()
        self.panel = panel
        let size = hosting.fittingSize
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            OverlaySpace.shared.adopt(panel)
        }
    }

    func hide() {
        panel?.orderOut(nil)
        state.windows = []
        if hoveredID != nil {
            hoveredID = nil
            onHover?(nil)
        }
    }

    /// Names the window under the pointer, the way hovering the main strip does.
    private func pointerMoved(to point: NSPoint?) {
        let hovered = point.flatMap { window(at: $0) }
        guard hovered?.id != hoveredID else { return }
        hoveredID = hovered?.id
        onHover?(hovered)
    }

    /// The window whose row a point in the panel falls on.
    private func window(at point: NSPoint) -> ManagedWindow? {
        guard let hosting else { return nil }
        let prefs = store.prefs
        let row = StripMetrics.rowHeight(prefs: prefs)
        let along: CGFloat
        if prefs.stripSide.isVertical {
            along = hosting.isFlipped ? point.y : hosting.bounds.height - point.y
        } else {
            along = point.x
        }
        let offset = along - StripMetrics.padding
        guard offset >= 0 else { return nil }
        let index = Int(offset / (row + StripMetrics.spacing))
        // Windows folded into the cascade are not rows of their own.
        let rows = state.windows.filter { !state.coveredIDs.contains($0.id) }
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// How much room the group's strip takes along the strip's own direction, gap included, so the
    /// main strip can make space for it and the pair can be centred as one.
    func length(for windows: [ManagedWindow], covered: Set<CGWindowID> = []) -> CGFloat {
        guard windows.count > 1 else { return 0 }
        let prefs = store.prefs
        // Covered windows share one tile, so they take the room of a single row.
        let hidden = windows.count { covered.contains($0.id) }
        let rows = CGFloat(windows.count - hidden + (hidden > 0 ? 1 : 0))
        let content = StripMetrics.padding * 2 + rows * StripMetrics.rowHeight(prefs: prefs)
            + max(0, rows - 1) * StripMetrics.spacing
        return content + Self.gap
    }

    /// Screen rect of one window's row in the group's strip, so the name popup points at the icon
    /// the user is actually looking at rather than at the group's entry in the main strip.
    func rowFrame(for id: CGWindowID) -> (frame: NSRect, side: StripSide)? {
        let rows = state.windows.filter { !state.coveredIDs.contains($0.id) }
        guard let panel, panel.isVisible,
              let index = rows.firstIndex(where: { $0.id == id })
        else { return nil }
        let prefs = store.prefs
        let row = StripMetrics.rowHeight(prefs: prefs)
        let offset = StripMetrics.padding + CGFloat(index) * (row + StripMetrics.spacing)
        let frame = panel.frame
        switch prefs.stripSide {
        case .left, .right:
            return (NSRect(x: frame.minX, y: frame.maxY - offset - row, width: frame.width, height: row),
                    prefs.stripSide)
        case .top, .bottom:
            return (NSRect(x: frame.minX + offset, y: frame.minY, width: row, height: frame.height),
                    prefs.stripSide)
        }
    }

    /// Room left between the two strips.
    static let gap: CGFloat = 8

    /// Carries on where the strip ends, in the same line and the same lane: below it on a side
    /// strip, after it on a top or bottom one. There is room there, and a bar hanging off the side
    /// of the strip would cover the windows instead.
    private func origin(for size: NSSize) -> NSPoint {
        let gap = Self.gap
        // Aligned to the end of the strip, the group goes in front of it; otherwise after it. Either
        // way the two read as one strip broken by a gap.
        let before = store.prefs.stripAlignment == .end
        guard let strip = stripFrameProvider?() else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(strip.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero

        switch strip.side {
        case .left, .right:
            let x = strip.frame.midX - size.width / 2
            // "After" the strip runs downwards, the way the queue does.
            let after = strip.frame.minY - gap - size.height
            let ahead = strip.frame.maxY + gap
            var y = before ? ahead : after
            if y < visible.minY || y + size.height > visible.maxY { y = before ? after : ahead }
            return NSPoint(x: x, y: min(max(y, visible.minY), visible.maxY - size.height))
        case .top, .bottom:
            let y = strip.frame.midY - size.height / 2
            let after = strip.frame.maxX + gap
            let ahead = strip.frame.minX - gap - size.width
            var x = before ? ahead : after
            if x < visible.minX || x + size.width > visible.maxX { x = before ? after : ahead }
            return NSPoint(x: min(max(x, visible.minX), visible.maxX - size.width), y: y)
        }
    }
}
