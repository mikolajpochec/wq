import AppKit
import SwiftUI

/// The always-on-top vertical strip: workspace badge on top, then window icons in queue order.
///
/// Icons can be dragged to reorder the queue. While a drag is in progress the dragged icon leaves
/// the layout and is drawn on top at the cursor, and a gap slides between the remaining icons to
/// show where it will land. Keeping it out of the flow is what makes it track the pointer exactly:
/// an icon that is both positioned by the layout and offset by the drag fights itself every time
/// the two disagree. The queue itself is only reordered when the icon is dropped.
struct StripView: View {
    @ObservedObject var model: WindowQueueModel
    @ObservedObject var store: PreferencesStore
    var onSelect: (ManagedWindow) -> Void
    /// Called with the window being held and how far it has been dragged, and with nil when the
    /// hold ends, so the popup can stay up and follow the icon.
    var onHold: (ManagedWindow?, CGFloat) -> Void

    /// Drags are measured in this space rather than against a row, because a row moves while it is
    /// being dragged and a translation measured against a moving view lags behind the cursor.
    private static let dragSpace = "WindowQueueStrip"

    @State private var draggingID: CGWindowID?
    @State private var dragOriginIndex = 0
    @State private var dragTargetIndex = 0
    @State private var dragTranslation: CGFloat = 0

    private var prefs: Preferences { store.prefs }

    var body: some View {
        // The panel keeps a fixed, full-height frame so nothing resizes while the queue changes;
        // the spacers centre the strip and stay transparent to clicks.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            strip
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var strip: some View {
        VStack(spacing: StripMetrics.spacing) {
            if prefs.showSpaceBadge {
                spaceBadge
            }
            ForEach(slots) { slot in
                if let window = slot.window {
                    row(for: window)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4).combined(with: .opacity),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        ))
                } else {
                    Color.clear.frame(height: StripMetrics.rowHeight(prefs: prefs))
                }
            }
        }
        .animation(StripMetrics.layoutAnimation, value: slots.map(\.id))
        .animation(.easeOut(duration: 0.16), value: model.selectedID)
        .padding(StripMetrics.padding)
        .frame(width: prefs.stripWidth)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.corner, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(prefs.stripOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .overlay(alignment: .top) { floatingRow }
        .coordinateSpace(name: Self.dragSpace)
        // One gesture for the whole strip: a per-row recogniser would be destroyed the moment its
        // row is replaced by the gap, cancelling the drag halfway through.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
                .onChanged { value in
                    dragChanged(start: value.startLocation.y,
                                offset: value.location.y - value.startLocation.y)
                }
                .onEnded { value in
                    dragEnded(offset: value.location.y - value.startLocation.y)
                }
        )
    }

    // MARK: - Layout model

    /// One position in the strip: either a window, or the gap left by the icon being dragged.
    private struct Slot: Identifiable {
        let id: String
        let window: ManagedWindow?
    }

    private var slots: [Slot] {
        let windows = model.visibleWindows
        guard let draggingID,
              let origin = windows.firstIndex(where: { $0.id == draggingID })
        else {
            return windows.map { Slot(id: "window-\($0.id)", window: $0) }
        }

        var remaining = windows.map { Slot(id: "window-\($0.id)", window: $0) }
        remaining.remove(at: origin)
        remaining.insert(Slot(id: "gap", window: nil),
                         at: min(max(dragTargetIndex, 0), remaining.count))
        return remaining
    }

    private var draggedWindow: ManagedWindow? {
        guard let draggingID else { return nil }
        return model.visibleWindows.first { $0.id == draggingID }
    }

    private var slotHeight: CGFloat {
        StripMetrics.rowHeight(prefs: prefs) + StripMetrics.spacing
    }

    /// Distance from the top of the strip to the top edge of the row at `index`.
    private func topOffset(of index: Int) -> CGFloat {
        var offset = StripMetrics.padding
        if prefs.showSpaceBadge { offset += prefs.iconSize + StripMetrics.spacing }
        return offset + CGFloat(index) * slotHeight
    }

    // MARK: - Rows

    @ViewBuilder
    private var floatingRow: some View {
        if let window = draggedWindow {
            row(for: window)
                .scaleEffect(1.12)
                .shadow(color: .black.opacity(0.3), radius: 6)
                .offset(y: topOffset(of: dragOriginIndex) + dragTranslation)
        }
    }

    private var spaceBadge: some View {
        Text(model.currentSpaceIndex.map(String.init) ?? "–")
            .font(.system(size: prefs.iconSize * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.accentColor)
            .frame(width: prefs.iconSize, height: prefs.iconSize)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            )
            .help("Current workspace")
    }

    private func row(for window: ManagedWindow) -> some View {
        let isSelected = window.id == model.selectedID
        return ZStack(alignment: .bottomTrailing) {
            icon(for: window)
                .frame(width: prefs.iconSize, height: prefs.iconSize)
                .opacity(window.isMinimized ? 0.45 : 1)

            if prefs.showWorkspaceNumbers, let workspace = model.workspaceNumber(of: window) {
                Text("\(workspace)")
                    .font(.system(size: max(8, prefs.iconSize * 0.32), weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.black.opacity(0.65)))
                    .offset(x: 4, y: 3)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .help(window.displayTitle)
    }

    @ViewBuilder
    private func icon(for window: ManagedWindow) -> some View {
        if let image = window.icon {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.3))
        }
    }

    // MARK: - Dragging

    /// Which row a point in strip coordinates falls on.
    private func index(at y: CGFloat) -> Int? {
        let position = Int(floor((y - topOffset(of: 0)) / slotHeight))
        return model.visibleWindows.indices.contains(position) ? position : nil
    }

    private func dragChanged(start: CGFloat, offset: CGFloat) {
        if draggingID == nil {
            guard let origin = index(at: start) else { return }
            draggingID = model.visibleWindows[origin].id
            dragOriginIndex = origin
            dragTargetIndex = origin
        }
        dragTranslation = offset
        dragTargetIndex = min(max(dragOriginIndex + Int((offset / slotHeight).rounded()), 0),
                              model.visibleWindows.count - 1)
        if let window = draggedWindow { onHold(window, offset) }
    }

    private func dragEnded(offset: CGFloat) {
        defer {
            draggingID = nil
            dragTranslation = 0
            onHold(nil, 0)
        }
        guard let window = draggedWindow else { return }

        if abs(offset) < 4, dragTargetIndex == dragOriginIndex {
            onSelect(window)
        } else {
            model.move(id: window.id, toVisiblePosition: dragTargetIndex)
        }
    }
}

enum StripMetrics {
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 6
    static let corner: CGFloat = 12
    /// Gap between the strip and the screen edge.
    static let screenMargin: CGFloat = 8
    /// Shared timing so the panel resize and the SwiftUI content move together.
    static let layoutAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.82)
    static let layoutDuration: TimeInterval = 0.32

    /// Height of one window row: the icon plus the row's own padding.
    static func rowHeight(prefs: Preferences) -> CGFloat { prefs.iconSize + 8 }

    /// Height the strip needs for the given content, mirroring `StripView`'s layout.
    static func height(itemCount: Int, prefs: Preferences) -> CGFloat {
        let rows = itemCount + (prefs.showSpaceBadge ? 1 : 0)
        guard rows > 0 else { return padding * 2 }
        let itemsHeight = CGFloat(itemCount) * rowHeight(prefs: prefs)
            + (prefs.showSpaceBadge ? prefs.iconSize : 0)
        return itemsHeight + CGFloat(rows - 1) * spacing + padding * 2
    }

    /// Distance from the top of the strip to the centre of the row at `index`.
    static func rowCentreOffset(index: Int, prefs: Preferences) -> CGFloat {
        var offset = padding
        if prefs.showSpaceBadge { offset += prefs.iconSize + spacing }
        offset += CGFloat(index) * (rowHeight(prefs: prefs) + spacing)
        return offset + rowHeight(prefs: prefs) / 2
    }
}
