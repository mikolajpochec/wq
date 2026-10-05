import AppKit
import SwiftUI

/// What the tiling menu shows: the layouts for the aimed windows and which one is picked.
final class TilingMenuState: ObservableObject {
    @Published var count = 0
    @Published var layouts: [TileLayout] = []
    @Published var highlighted = 0
    /// The keyboard is in the menu rather than on the strip.
    @Published var isFocused = false
}

struct TilingMenuView: View {
    @ObservedObject var state: TilingMenuState
    let side: StripSide
    /// A layout clicked with the mouse, by position in the list.
    var pick: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(state.count) windows")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            ForEach(Array(state.layouts.enumerated()), id: \.element.id) { index, layout in
                HStack(spacing: 10) {
                    preview(of: layout)
                        .frame(width: 34, height: 22)
                    Text(layout.name)
                        .font(.system(size: 13))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlight(for: index))
                )
                .contentShape(Rectangle())
                // Like the strip, the panel is never key; a zero-distance drag is what reliably
                // registers a click in it.
                .gesture(DragGesture(minimumDistance: 0).onEnded { _ in pick(index) })
            }
            Text(hint)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 2)
        }
        .padding(8)
        .frame(width: 220)
        .glassBackground(RoundedRectangle(cornerRadius: 14, style: .continuous),
                         border: state.isFocused ? Color.orange : nil,
                         borderWidth: state.isFocused ? 2 : 1)
    }

    private func highlight(for index: Int) -> Color {
        guard index == state.highlighted else { return .clear }
        return state.isFocused ? Color.orange.opacity(0.35) : Color.primary.opacity(0.08)
    }

    private var hint: String {
        if state.isFocused { return "Return or click to tile · Esc to go back" }
        let arrow: String
        switch side {
        case .left: arrow = "→"
        case .right: arrow = "←"
        case .top: arrow = "↓"
        case .bottom: arrow = "↑"
        }
        return "\(arrow), Return or click to choose a layout"
    }

    private func preview(of layout: TileLayout) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.frames.enumerated()), id: \.offset) { _, unit in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: max(0, unit.width * geometry.size.width - 2),
                               height: max(0, unit.height * geometry.size.height - 2))
                        .offset(x: unit.minX * geometry.size.width + 1,
                                y: unit.minY * geometry.size.height + 1)
                }
            }
        }
    }
}

/// The panel beside the strip offering ways to tile the aimed windows.
final class TilingMenuController {
    let state = TilingMenuState()
    private let store: PreferencesStore
    private var panel: OverlayPanel?
    private var hosting: NSHostingView<TilingMenuView>?

    /// A layout was clicked; the highlight is already on it.
    var onPick: (() -> Void)?

    /// Screen rect covering the aimed icons, and the strip's side, to place the menu beside them.
    var anchorProvider: (([CGWindowID]) -> (frame: NSRect, side: StripSide)?)?

    init(store: PreferencesStore) {
        self.store = store
    }

    var isVisible: Bool { panel?.isVisible == true }

    var selectedLayout: TileLayout? {
        state.layouts.indices.contains(state.highlighted) ? state.layouts[state.highlighted] : nil
    }

    /// Shows or refreshes the menu for these windows; hides it when there are too few to tile.
    func update(for windows: [ManagedWindow]) {
        let layouts = TileLayout.options(for: windows.count)
        guard !layouts.isEmpty else {
            hide()
            return
        }
        if state.layouts.map(\.name) != layouts.map(\.name) {
            state.layouts = layouts
            state.highlighted = 0
        }
        state.count = windows.count

        let side = store.prefs.stripSide
        let view = TilingMenuView(state: state, side: side) { [weak self] index in
            guard let self, self.state.layouts.indices.contains(index) else { return }
            self.state.highlighted = index
            self.onPick?()
        }
        let hosting = self.hosting ?? NSHostingView(rootView: view)
        hosting.rootView = view
        self.hosting = hosting
        let size = hosting.fittingSize

        let panel = self.panel ?? {
            let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size))
            panel.contentView = hosting
            return panel
        }()
        self.panel = panel
        panel.setFrame(NSRect(origin: origin(for: size, ids: windows.map(\.id)), size: size), display: true)
        if !panel.isVisible {
            panel.orderFrontRegardless()
            OverlaySpace.shared.adopt(panel)
        }
    }

    func hide() {
        state.isFocused = false
        panel?.orderOut(nil)
    }

    func moveHighlight(by delta: Int) {
        let count = state.layouts.count
        guard count > 0 else { return }
        state.highlighted = ((state.highlighted + delta) % count + count) % count
    }

    private func origin(for size: NSSize, ids: [CGWindowID]) -> NSPoint {
        let margin: CGFloat = 10
        guard let anchor = anchorProvider?(ids) else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        }
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor.frame) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
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
