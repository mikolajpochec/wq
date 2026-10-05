import AppKit
import SwiftUI

/// One thing aiming mode can do, offered as a tile to click.
struct AimAction: Identifiable, Equatable {
    enum Kind: Equatable {
        /// One of WindowQueue's own actions, run exactly as its shortcut would run it.
        case shortcut(HotkeyAction)
        /// Aim at everything within reach, which `A` does from the keyboard.
        case selectAll
        /// Focus what is aimed at and leave the mode, which Return does.
        case confirm
        /// Leave the mode with the queue as it was.
        case cancel
    }

    let kind: Kind
    let title: String
    let symbol: String

    var id: String {
        switch kind {
        case .shortcut(let action): return action.rawValue
        case .selectAll: return "select-all"
        case .confirm: return "confirm"
        case .cancel: return "cancel"
        }
    }
}

final class ActionPanelState: ObservableObject {
    @Published var actions: [AimAction] = []
    @Published var hoveredID: String?
}

/// The tiles beside the strip while aiming mode is driven by the mouse: everything the mode's keys
/// do, as something to click, since a user who opened the mode with the pointer has no reason to
/// know the keys.
struct ActionPanelView: View {
    @ObservedObject var state: ActionPanelState
    @ObservedObject var store: PreferencesStore
    var pick: (AimAction) -> Void

    private var prefs: Preferences { store.prefs }

    /// Tiles run across the strip's own direction: beside a side strip they stack downwards, under
    /// a top or bottom strip they run along it.
    private var stack: AnyLayout {
        prefs.stripSide.isVertical
            ? AnyLayout(VStackLayout(spacing: 4))
            : AnyLayout(HStackLayout(spacing: 4))
    }

    var body: some View {
        stack {
            ForEach(state.actions) { action in
                tile(action)
            }
        }
        .padding(6)
        .glassBackground(RoundedRectangle(cornerRadius: 12, style: .continuous), opacity: prefs.stripOpacity)
    }

    private func tile(_ action: AimAction) -> some View {
        let hovered = state.hoveredID == action.id
        return VStack(spacing: 2) {
            Image(systemName: action.symbol)
                .font(.system(size: 15, weight: .medium))
            Text(action.title)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: 58, height: 42)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07))
        )
        .contentShape(Rectangle())
        // The panel is never key, so a zero-distance drag is what registers a click in it.
        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in pick(action) })
    }
}

/// Hosting view that reports the pointer, since the panel is never key.
private final class ActionHostingView: NSHostingView<ActionPanelView> {
    var onPointerMoved: ((NSPoint?) -> Void)?

    private var tracking: NSTrackingArea?

    required init(rootView: ActionPanelView) {
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
}

/// Owns the tile panel that sits beside the strip while aiming with the mouse.
final class ActionPanelController {
    let state = ActionPanelState()
    private let store: PreferencesStore
    private var panel: OverlayPanel?
    private var hosting: ActionHostingView?

    /// Screen rect of the strip's content and the edge it lives on, so the tiles sit beside it.
    var stripFrameProvider: (() -> (frame: NSRect, side: StripSide)?)?
    var onPick: ((AimAction) -> Void)?

    init(store: PreferencesStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ actions: [AimAction]) {
        guard !actions.isEmpty else {
            hide()
            return
        }
        state.actions = actions

        let view = ActionPanelView(state: state, store: store) { [weak self] action in
            self?.onPick?(action)
        }
        let hosting = self.hosting ?? ActionHostingView(rootView: view)
        hosting.rootView = view
        if self.hosting == nil {
            hosting.onPointerMoved = { [weak self] point in self?.pointerMoved(to: point) }
        }
        self.hosting = hosting

        let panel = self.panel ?? {
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
            panel.acceptsMouseMovedEvents = true
            panel.contentView = hosting
            return panel
        }()
        self.panel = panel
        // The tile count changes with what is aimed at, so the size is taken fresh each time. The
        // layout is plain enough that `fittingSize` is right immediately, unlike the group's strip.
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = store.prefs.instantAiming || !store.prefs.animates(.aimingMode) ? 1 : 0
            panel.orderFrontRegardless()
            OverlaySpace.shared.adopt(panel)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = store.prefs.instantAiming ? 0 : store.prefs.duration(.aimingMode, 0.1)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        panel?.orderOut(nil)
        state.hoveredID = nil
    }

    private func pointerMoved(to point: NSPoint?) {
        guard let point, let hosting else {
            if state.hoveredID != nil { state.hoveredID = nil }
            return
        }
        let inset: CGFloat = 6
        let along = store.prefs.stripSide.isVertical
            ? (hosting.isFlipped ? point.y : hosting.bounds.height - point.y) - inset
            : point.x - inset
        let step: CGFloat = (store.prefs.stripSide.isVertical ? 42 : 58) + 4
        let index = Int(along / step)
        let id = state.actions.indices.contains(index) && along >= 0 ? state.actions[index].id : nil
        if state.hoveredID != id { state.hoveredID = id }
    }

    /// Beside the strip, towards the middle of the screen, level with the strip's content.
    private func origin(for size: NSSize) -> NSPoint {
        let gap: CGFloat = 10
        guard let strip = stripFrameProvider?() else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(strip.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        switch strip.side {
        case .left, .right:
            let x = strip.side == .left ? strip.frame.maxX + gap : strip.frame.minX - gap - size.width
            let y = min(max(strip.frame.midY - size.height / 2, visible.minY + gap),
                        visible.maxY - size.height - gap)
            return NSPoint(x: min(max(x, visible.minX + gap), visible.maxX - size.width - gap), y: y)
        case .top, .bottom:
            let y = strip.side == .top ? strip.frame.minY - gap - size.height : strip.frame.maxY + gap
            let x = min(max(strip.frame.midX - size.width / 2, visible.minX + gap),
                        visible.maxX - size.width - gap)
            return NSPoint(x: x, y: min(max(y, visible.minY + gap), visible.maxY - size.height - gap))
        }
    }
}
