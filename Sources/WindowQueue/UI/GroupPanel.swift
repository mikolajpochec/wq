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
    /// The fullscreen window, which is drawn as one thing with the tile of what it covers.
    @Published var maximizedID: CGWindowID?
    /// Aiming mode grows the strip; this one grows with it.
    @Published var scale: CGFloat = 1
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
        // Behind the icons but above the panel's background, exactly as on the main strip.
        .background(alignment: side.isVertical ? .top : .leading) { aimedRunHighlight }
        .background(alignment: side.isVertical ? .top : .leading) { maximizedGroupBackground }
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
        // Grown from the screen edge, the way the main strip grows while aiming.
        .scaleEffect(state.scale, anchor: scaleAnchor)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: state.scale)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// The edge the strip is pinned to, which is where it grows from and sits against.
    private var alignment: Alignment {
        switch side {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    private var scaleAnchor: UnitPoint {
        switch side {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        }
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

    /// The stretch the fullscreen window and the tile of what it covers take together, so the two
    /// are drawn — and selected — as one thing, the way the main strip draws them.
    private var maximizedGroupSpan: (start: CGFloat, end: CGFloat)? {
        guard !state.coveredIDs.isEmpty, let maximized = state.maximizedID else { return nil }
        let places = entries
        guard let window = places.firstIndex(where: {
            if case .window(let one) = $0 { return one.id == maximized }
            return false
        }), let cascade = places.firstIndex(where: {
            if case .cascade = $0 { return true }
            return false
        }) else { return nil }
        let row = StripMetrics.rowHeight(prefs: prefs)
        let step = row + StripMetrics.spacing
        let first = min(window, cascade)
        let last = max(window, cascade)
        return (StripMetrics.padding + CGFloat(first) * step,
                StripMetrics.padding + CGFloat(last) * step + row)
    }

    /// The fullscreen window and the windows it covers are one thing, so one selection covers both.
    private var isMaximizedGroupSelected: Bool {
        state.maximizedID != nil && state.selectedID == state.maximizedID && !state.coveredIDs.isEmpty
    }

    /// The shape tying the fullscreen window to the tile of what it covers.
    @ViewBuilder
    private var maximizedGroupBackground: some View {
        if let span = maximizedGroupSpan {
            let selected = isMaximizedGroupSelected
            let thickness = StripMetrics.rowHeight(prefs: prefs) + 4
            RoundedRectangle(cornerRadius: StripMetrics.groupCorner(prefs: prefs), style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: StripMetrics.groupCorner(prefs: prefs), style: .continuous)
                        .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                )
                .frame(width: side.isVertical ? thickness : span.end - span.start,
                       height: side.isVertical ? span.end - span.start : thickness)
                .offset(x: side.isVertical ? 0 : span.start, y: side.isVertical ? span.start : 0)
                .animation(StripMetrics.layoutAnimation, value: state.coveredIDs)
                .animation(.easeOut(duration: 0.16), value: selected)
        }
    }

    /// The windows that get a row of their own here: the covered ones share the cascade tile.
    private var rows: [ManagedWindow] {
        state.windows.filter { !state.coveredIDs.contains($0.id) }
    }

    /// Several windows are aimed at, which the group's strip shows as runs rather than a cursor.
    private var isAimingRun: Bool { state.aimedIDs.count > 1 }

    /// Positions of the aimed windows grouped into runs of neighbours, each drawn as one highlight.
    private var aimedRuns: [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for (index, window) in rows.enumerated() where state.aimedIDs.contains(window.id) {
            if let last = out.last, last.upperBound == index - 1 {
                out[out.count - 1] = last.lowerBound...index
            } else {
                out.append(index...index)
            }
        }
        return out
    }

    /// One continuous highlight for each run of aimed windows, so a group's windows join up under
    /// the aim the way the main strip's do instead of each carrying its own box.
    @ViewBuilder
    private var aimedRunHighlight: some View {
        if isAimingRun {
            let thickness = StripMetrics.rowHeight(prefs: prefs)
            let step = thickness + StripMetrics.spacing
            ZStack(alignment: side.isVertical ? .top : .leading) {
                ForEach(aimedRuns, id: \.lowerBound) { run in
                    let start = StripMetrics.padding + CGFloat(run.lowerBound) * step
                    let length = CGFloat(run.count) * thickness + CGFloat(run.count - 1) * StripMetrics.spacing
                    RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                        .fill(Color.orange.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                                .strokeBorder(Color.orange, lineWidth: 2.5)
                        )
                        .frame(width: side.isVertical ? thickness : length,
                               height: side.isVertical ? length : thickness)
                        .offset(x: side.isVertical ? 0 : start, y: side.isVertical ? start : 0)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side.isVertical ? .top : .leading)
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: state.aimedIDs)
        }
    }

    private func row(for window: ManagedWindow) -> some View {
        // A run of several aimed windows is drawn as one highlight behind them all, so its rows
        // carry none of their own.
        let aimed = window.id == state.aimingID && !isAimingRun
        // The fullscreen window is highlighted together with its cascade, not as a row of its own.
        let selected = window.id == state.selectedID && !aimed && !isAimingRun
            && !(isMaximizedGroupSelected && window.id == state.maximizedID)
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
    /// The panel is fading away; a show in the meantime catches it and brings it back.
    private var isHiding = false

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
              coveredIDs: Set<CGWindowID> = [], maximizedID: CGWindowID? = nil,
              aiming: Bool = false) {
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
        state.maximizedID = maximizedID
        state.scale = aiming ? max(1, store.prefs.aimingScale) : 1

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
            panel.acceptsMouseMovedEvents = true
            panel.contentView = hosting
            return panel
        }()
        self.panel = panel
        // Room for the grown strip: the panel cannot resize mid-animation without clipping it.
        // The size is worked out from the rows rather than read off the hosting view: SwiftUI lays
        // the new contents out on a later turn, so `fittingSize` here still describes the old ones
        // and the panel would keep the wrong size and place until the next change.
        let scale = max(1, store.prefs.aimingScale)
        let thickness = StripMetrics.thickness(prefs: store.prefs)
        let along = contentLength(rows: rowCount(of: windows, covered: coveredIDs))
        let size = store.prefs.stripSide.isVertical
            ? NSSize(width: thickness * scale, height: along * state.scale)
            : NSSize(width: along * state.scale, height: thickness * scale)
        let target = NSRect(origin: origin(for: size), size: size)

        if panel.isVisible {
            // A fade on the way out was under way, or the group changed size: either way the panel
            // travels to its new place rather than jumping there, in step with the main strip.
            isHiding = false
            guard panel.frame != target || panel.alphaValue < 1 else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StripMetrics.layoutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
            return
        }

        // Opening: the strip unfolds out of the end of the main one, so the two read as one bar
        // growing rather than a second one appearing on top of the windows.
        isHiding = false
        panel.alphaValue = 0
        panel.setFrame(folded(target), display: false)
        panel.orderFrontRegardless()
        OverlaySpace.shared.adopt(panel)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StripMetrics.layoutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    /// The panel as it starts and ends its life: folded away against the main strip.
    private func folded(_ target: NSRect) -> NSRect {
        let share: CGFloat = 0.25
        if store.prefs.stripSide.isVertical {
            let height = target.height * share
            // Aligned to the end, the group's strip sits above the main one and folds downwards.
            let y = isBeforeStrip ? target.minY : target.maxY - height
            return NSRect(x: target.minX, y: y, width: target.width, height: height)
        }
        let width = target.width * share
        let x = isBeforeStrip ? target.maxX - width : target.minX
        return NSRect(x: x, y: target.minY, width: width, height: target.height)
    }

    /// The group's strip goes in front of the main one when the strip is aligned to the end.
    private var isBeforeStrip: Bool { store.prefs.stripAlignment == .end }

    func hide() {
        guard let panel, panel.isVisible, !isHiding else {
            clearHover()
            state.windows = []
            return
        }
        isHiding = true
        clearHover()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = StripMetrics.layoutDuration * 0.6
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(folded(panel.frame), display: true)
        } completionHandler: { [weak self] in
            guard let self, self.isHiding else { return }
            self.isHiding = false
            panel.orderOut(nil)
            panel.alphaValue = 1
            self.state.windows = []
        }
    }

    private func clearHover() {
        guard hoveredID != nil else { return }
        hoveredID = nil
        onHover?(nil)
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
    /// - Parameter aiming: while aiming the strip is drawn larger, and takes more room with it.
    func length(for windows: [ManagedWindow], covered: Set<CGWindowID> = [], aiming: Bool = false) -> CGFloat {
        guard windows.count > 1 else { return 0 }
        let content = contentLength(rows: rowCount(of: windows, covered: covered))
        return content * (aiming ? max(1, store.prefs.aimingScale) : 1) + Self.gap
    }

    /// Rows the group's strip draws: covered windows share the cascade tile, so they count as one.
    private func rowCount(of windows: [ManagedWindow], covered: Set<CGWindowID>) -> Int {
        let hidden = windows.count { covered.contains($0.id) }
        return windows.count - hidden + (hidden > 0 ? 1 : 0)
    }

    /// How long that many rows are, padding included, before aiming scales them.
    private func contentLength(rows: Int) -> CGFloat {
        let count = CGFloat(rows)
        return StripMetrics.padding * 2 + count * StripMetrics.rowHeight(prefs: store.prefs)
            + max(0, count - 1) * StripMetrics.spacing
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

        // The panel carries spare room for aiming to grow into, and the strip inside it sits against
        // the screen edge; line that edge up with the main strip's rather than the panel's middle,
        // or the group's strip stands off the edge by half the spare room.
        switch strip.side {
        case .left, .right:
            let x = strip.side == .left ? strip.frame.minX : strip.frame.maxX - size.width
            // "After" the strip runs downwards, the way the queue does.
            let after = strip.frame.minY - gap - size.height
            let ahead = strip.frame.maxY + gap
            var y = before ? ahead : after
            if y < visible.minY || y + size.height > visible.maxY { y = before ? after : ahead }
            return NSPoint(x: x, y: min(max(y, visible.minY), visible.maxY - size.height))
        case .top, .bottom:
            let y = strip.side == .bottom ? strip.frame.minY : strip.frame.maxY - size.height
            let after = strip.frame.maxX + gap
            let ahead = strip.frame.minX - gap - size.width
            var x = before ? ahead : after
            if x < visible.minX || x + size.width > visible.maxX { x = before ? after : ahead }
            return NSPoint(x: min(max(x, visible.minX), visible.maxX - size.width), y: y)
        }
    }
}
