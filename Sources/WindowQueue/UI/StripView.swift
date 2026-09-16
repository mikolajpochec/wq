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
    @ObservedObject var screen: StripScreenState
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
    /// Ties the empty-workspace marker to the window that fills it, so the window grows out of it.
    @Namespace private var slotNamespace

    private var prefs: Preferences { store.prefs }

    private var side: StripSide { prefs.stripSide }

    var body: some View {
        // The panel spans the whole edge and never resizes while the queue changes. The strip is
        // placed inside it by alignment, and the empty rest stays transparent to clicks. The panel
        // is also thicker than the strip, leaving room for aiming mode to grow into, so the strip
        // is pinned to the screen edge it lives on.
        strip
            .padding(side.isVertical ? .vertical : .horizontal, prefs.stripMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.placement(of: prefs))
    }

    /// Where the strip sits in its panel: against the screen edge, and along it by alignment.
    static func placement(of prefs: Preferences) -> Alignment {
        let along: CGFloat = prefs.stripAlignment.fraction
        switch prefs.stripSide {
        case .left: return Alignment(horizontal: .leading, vertical: along == 0 ? .top : along == 1 ? .bottom : .center)
        case .right: return Alignment(horizontal: .trailing, vertical: along == 0 ? .top : along == 1 ? .bottom : .center)
        case .top: return Alignment(horizontal: along == 0 ? .leading : along == 1 ? .trailing : .center, vertical: .top)
        case .bottom: return Alignment(horizontal: along == 0 ? .leading : along == 1 ? .trailing : .center, vertical: .bottom)
        }
    }

    /// The point aiming mode grows the strip from: its screen edge, at the end it is aligned to.
    private var scaleAnchor: UnitPoint {
        let along = prefs.stripAlignment.fraction
        switch side {
        case .left: return UnitPoint(x: 0, y: along)
        case .right: return UnitPoint(x: 1, y: along)
        case .top: return UnitPoint(x: along, y: 0)
        case .bottom: return UnitPoint(x: along, y: 1)
        }
    }

    private var stack: AnyLayout {
        side.isVertical
            ? AnyLayout(VStackLayout(spacing: StripMetrics.spacing))
            : AnyLayout(HStackLayout(spacing: StripMetrics.spacing))
    }

    private var strip: some View {
        stack {
            ForEach(previewLayout.elements) { element in
                switch element {
                case .badge:
                    spaceBadge
                case .emptySlot:
                    emptySlotMarker
                        .matchedGeometryEffect(id: "empty-slot", in: slotNamespace)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                case .window(let window) where window.id == model.slotFilledID:
                    row(for: window)
                        .matchedGeometryEffect(id: "empty-slot", in: slotNamespace)
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
        .frame(width: side.isVertical ? prefs.stripWidth : nil,
               height: side.isVertical ? nil : prefs.stripWidth)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.corner, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(prefs.stripOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        // On a monitor that is not the selected one the strip stays readable but steps back.
        .saturation(screen.isActive ? 1 : 0)
        .opacity(screen.isActive ? 1 : prefs.inactiveStripOpacity)
        .animation(.easeOut(duration: 0.2), value: screen.isActive)
        .overlay(alignment: side.isVertical ? .top : .leading) { floatingRow }
        .coordinateSpace(name: Self.dragSpace)
        // One gesture for the whole strip: a per-row recogniser would be destroyed the moment its
        // row moves, cancelling the drag halfway through.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
                .onChanged { value in
                    let start = side.isVertical ? value.startLocation.y : value.startLocation.x
                    let now = side.isVertical ? value.location.y : value.location.x
                    dragChanged(start: start, offset: now - start)
                }
                .onEnded { value in
                    let start = side.isVertical ? value.startLocation.y : value.startLocation.x
                    let now = side.isVertical ? value.location.y : value.location.x
                    dragEnded(offset: now - start)
                }
        )
        // Applied last so the background and border grow with the icons, and outside the named
        // coordinate space so drag positions keep arriving in unscaled units. Growth is anchored to
        // the screen edge, so the strip expands inwards instead of off the side of its panel.
        .scaleEffect(model.aimingID == nil ? 1 : prefs.aimingScale, anchor: scaleAnchor)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: model.aimingID == nil)
    }

    // MARK: - Layout

    private func layout(of windows: [ManagedWindow]) -> StripLayout {
        StripLayout(windows: windows, prefs: prefs, slot: model.slotPlacement)
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
                .offset(x: side.isVertical ? 0 : dragOriginTop + dragTranslation,
                        y: side.isVertical ? dragOriginTop + dragTranslation : 0)
        }
    }

    private var spaceBadge: some View {
        Text((screen.spaceIndex ?? model.currentSpaceIndex).map(String.init) ?? "–")
            .font(.system(size: prefs.iconSize * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(badgeForeground)
            .frame(width: prefs.iconSize, height: prefs.iconSize)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(badgeFill)
            )
            .animation(.easeOut(duration: 0.25), value: screen.backdropIsLight)
            .help("Current workspace")
    }

    /// A dashed, hatched outline the size of an icon: a place a window could go.
    private var emptySlotMarker: some View {
        let long = prefs.iconSize
        let short = StripMetrics.slotThickness(prefs: prefs)
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return DiagonalStripes(spacing: 5)
            .stroke(Color.accentColor.opacity(0.45), lineWidth: 1.2)
            .clipShape(shape)
            .overlay(
                shape.strokeBorder(Color.accentColor.opacity(0.85),
                                   style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            )
            .frame(width: side.isVertical ? long : short, height: side.isVertical ? short : long)
            .padding(4)
            .help("Empty workspace")
    }

    /// The number follows what is behind the strip: dark over a light screen, light over a dark
    /// one. Until that is known it keeps the accent colour.
    private var badgeForeground: Color {
        switch screen.backdropIsLight {
        case .some(true): return Color.black.opacity(0.85)
        case .some(false): return .white
        case .none: return .accentColor
        }
    }

    private var badgeFill: Color {
        switch screen.backdropIsLight {
        case .some(true): return Color.white.opacity(0.55)
        case .some(false): return Color.black.opacity(0.35)
        case .none: return Color.accentColor.opacity(0.16)
        }
    }

    private func row(for window: ManagedWindow) -> some View {
        let isSelected = window.id == model.selectedID
        // Aiming borrows the highlight and marks it in a different colour, so it is never mistaken
        // for the window that actually has focus.
        // A run of aimed windows is all marked; the end the aim is moving has the heavier border.
        let isAimCursor = window.id == model.aimingID
        let isAimed = isAimCursor || (model.aimAnchorID != nil && model.aimedIDs.contains(window.id))
        let highlight: Color? = isAimed ? .orange : (isSelected ? .accentColor : nil)
        return ZStack(alignment: .bottomTrailing) {
            icon(for: window)
                .frame(width: prefs.iconSize, height: prefs.iconSize)
                .opacity(window.isMinimized ? 0.45 : 1)

        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(highlight?.opacity(0.28) ?? .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(highlight ?? .clear, lineWidth: isAimCursor ? 2.5 : 1.5)
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
    /// Shared timing so the panel resize and the SwiftUI content move together.
    static let layoutAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.82)
    static let layoutDuration: TimeInterval = 0.32

    /// Height of one window row: the icon plus the row's own padding.
    static func rowHeight(prefs: Preferences) -> CGFloat { prefs.iconSize + 8 }

    /// Length of the empty-workspace marker along the strip: the size of an icon, so it takes a
    /// window's place; the dashes and hatching are what tell it apart.
    static func slotThickness(prefs: Preferences) -> CGFloat { prefs.iconSize }
    static func slotLength(prefs: Preferences) -> CGFloat { slotThickness(prefs: prefs) + 8 }


}

/// Parallel lines at 45°, filling their rect, for hatching.
private struct DiagonalStripes: Shape {
    let spacing: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Lines running up to the right; start far enough left that the whole rect is covered.
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}
