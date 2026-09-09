import AppKit
import SwiftUI

/// The always-on-top vertical strip: current-workspace badge on top, then window icons in queue
/// order, each carrying the number of the workspace it lives on.
///
/// Icons can be dragged to reorder the queue. While a drag is in progress the dragged icon is drawn
/// on top at the cursor and its row is left empty, and the other icons slide around that gap to show
/// where it will land. Drawing it outside the flow is what makes it track the pointer exactly: an
/// icon that is both positioned by the layout and offset by the drag fights itself every time the
/// two disagree. Its row keeps its place in the list all the same — replacing it with a separate
/// placeholder would make the icon re-appear from nothing on drop instead of settling into its
/// slot. The queue itself is only reordered when the icon is dropped.
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
    /// Where the dragged icon started, captured once: headers come and go as the preview reorders,
    /// so recomputing this mid-drag would shift the icon out from under the cursor.
    @State private var dragOriginTop: CGFloat = 0

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
            ForEach(previewLayout.elements) { element in
                switch element {
                case .badge:
                    spaceBadge
                case .header(let workspace):
                    header(workspace)
                case .window(let window):
                    row(for: window)
                        // Kept in the layout, just not drawn: the floating copy stands in for it.
                        .opacity(window.id == draggingID ? 0 : 1)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.4).combined(with: .opacity),
                            removal: .scale(scale: 0.6).combined(with: .opacity)
                        ))
                }
            }
        }
        .animation(StripMetrics.layoutAnimation, value: previewLayout.elements.map(\.id))
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
        // row moves, cancelling the drag halfway through.
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

    // MARK: - Layout

    private func layout(of windows: [ManagedWindow]) -> StripLayout {
        StripLayout(windows: windows, prefs: prefs) { model.workspaceNumber(of: $0) }
    }

    /// Geometry of the committed queue. Drag targeting measures against this rather than the preview
    /// so that the answer cannot oscillate as the preview rearranges itself underneath the cursor.
    private var committedLayout: StripLayout { layout(of: model.visibleWindows) }

    private var previewLayout: StripLayout { layout(of: orderedWindows) }

    /// The queue as the strip currently shows it: the committed order, with a drag in progress
    /// previewed by moving the dragged window to the slot it would land in.
    private var orderedWindows: [ManagedWindow] {
        var windows = model.visibleWindows
        guard let draggingID,
              let origin = windows.firstIndex(where: { $0.id == draggingID })
        else { return windows }

        let window = windows.remove(at: origin)
        windows.insert(window, at: min(max(dragTargetIndex, 0), windows.count))
        return windows
    }

    private var draggedWindow: ManagedWindow? {
        guard let draggingID else { return nil }
        return model.visibleWindows.first { $0.id == draggingID }
    }

    // MARK: - Rows

    @ViewBuilder
    private var floatingRow: some View {
        if let window = draggedWindow {
            row(for: window)
                .scaleEffect(1.12)
                .shadow(color: .black.opacity(0.3), radius: 6)
                .offset(y: dragOriginTop + dragTranslation)
        }
    }

    private func header(_ workspace: Int) -> some View {
        let height = StripMetrics.headerHeight(prefs: prefs)
        return Text("\(workspace)")
            .font(.system(size: height * 0.72, weight: .bold, design: .rounded))
            .foregroundStyle(Color.primary.opacity(0.7))
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(Capsule().fill(Color.primary.opacity(0.13)))
            .help("Workspace \(workspace)")
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

            // Redundant once the icons are grouped under a workspace header.
            if prefs.showWorkspaceNumbers, !prefs.groupByWorkspace,
               let workspace = model.workspaceNumber(of: window) {
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

    private func dragChanged(start: CGFloat, offset: CGFloat) {
        let layout = committedLayout

        if draggingID == nil {
            guard let origin = layout.windowIndex(atOffsetFromTop: start),
                  model.visibleWindows.indices.contains(origin)
            else { return }
            draggingID = model.visibleWindows[origin].id
            dragOriginIndex = origin
            dragTargetIndex = origin
            dragOriginTop = layout.topOffset(ofWindowAt: origin)
            onHold(model.visibleWindows[origin], 0)
        }
        dragTranslation = offset

        guard let target = layout.nearestWindowIndex(toOffsetFromTop: start + offset) else { return }
        dragTargetIndex = target
        if let window = draggedWindow { onHold(window, offset) }
    }

    private func dragEnded(offset: CGFloat) {
        guard let window = draggedWindow else {
            endDrag()
            return
        }

        if abs(offset) < 4, dragTargetIndex == dragOriginIndex {
            onSelect(window)
            endDrag()
            return
        }

        model.move(id: window.id, toVisiblePosition: dragTargetIndex)

        // Let the floating icon travel from the cursor to the slot it was dropped on, then hand
        // over to the row underneath, which has been holding that place all along. The destination
        // is read from the layout the move has just produced, headers included.
        let destination = committedLayout.topOffset(ofWindowAt: dragTargetIndex)
        withAnimation(Self.settleAnimation) {
            dragTranslation = destination - dragOriginTop
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) {
            endDrag()
        }
    }

    private static let settleAnimation: Animation = .spring(response: 0.22, dampingFraction: 0.9)
    private static let settleDuration: TimeInterval = 0.22

    private func endDrag() {
        draggingID = nil
        dragTranslation = 0
        dragOriginTop = 0
        onHold(nil, 0)
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

    /// Height of a workspace group header.
    static func headerHeight(prefs: Preferences) -> CGFloat { max(15, prefs.iconSize * 0.52) }

}
