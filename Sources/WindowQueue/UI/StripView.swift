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
    /// The collapsed tile is being dragged, which moves every window inside it as one.
    @State private var draggingStack = false
    /// The pointer has actually travelled: a press on its own is a click, not a drag.
    @State private var dragMoved = false
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
            // The margin is a gap from the screen edge, not from the end of the strip: aligned to
            // the start or the end, the strip lines up with the windows beside it.
            .padding(side.isVertical ? .top : .leading, prefs.stripAlignment == .start ? 0 : prefs.stripMargin)
            .padding(side.isVertical ? .bottom : .trailing, prefs.stripAlignment == .end ? 0 : prefs.stripMargin)
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
                case .hiddenStack(let windows):
                    hiddenStackTile(for: windows)
                        // Kept in the layout while it is dragged; the floating copy stands in.
                        .opacity(draggingStack ? 0 : 1)
                        // The icons fly in from their rows; the tile itself only needs to fade.
                        .transition(.opacity)
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
        .animation(.easeOut(duration: 0.2), value: model.maximizedID)
        .animation(StripMetrics.layoutAnimation, value: collapsedIDs)
        .padding(StripMetrics.padding)
        .frame(width: side.isVertical ? StripMetrics.thickness(prefs: prefs) : nil,
               height: side.isVertical ? nil : StripMetrics.thickness(prefs: prefs))
        // Behind the icons but above the strip's own background.
        .background(alignment: side.isVertical ? .top : .leading) { aimedRunHighlight }
        .background(alignment: side.isVertical ? .top : .leading) { maximizedGroupBackground }
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.corner(prefs: prefs), style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(prefs.stripOpacity)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.corner(prefs: prefs), style: .continuous)
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
        StripLayout(windows: windows, prefs: prefs, slot: model.slotPlacement, collapsed: collapsedIDs)
    }

    /// Windows the maximized one covers, while they are meant to collapse into one tile.
    private var collapsedIDs: Set<CGWindowID> {
        // A drag of one icon expands the tile so it can be dropped anywhere among the rows; a drag
        // of the tile itself keeps it collapsed, because that is the thing being moved. A press that
        // has not travelled is a click, and must not shuffle the strip under the pointer.
        guard prefs.focusMaximizedWindow, prefs.collapseCoveredWindows, model.maximizedID != nil,
              draggingID == nil || draggingStack || !dragMoved
        else { return [] }
        return Set(model.visibleWindows.filter { model.isCovered($0) }.map(\.id))
    }

    /// Geometry of the committed queue. Drag targeting measures against this rather than the preview
    /// so that the answer cannot oscillate as the preview rearranges itself underneath the cursor.
    private var committedLayout: StripLayout { layout(of: model.visibleWindows) }

    private var previewLayout: StripLayout { layout(of: orderedWindows) }

    /// The queue as the strip currently shows it: the committed order, with a drag in progress
    /// previewed by moving the dragged window to the slot it would land in.
    private var orderedWindows: [ManagedWindow] {
        var windows = model.visibleWindows
        guard let draggingID else { return windows }

        if draggingStack {
            let moving = collapsedIDs
            let group = windows.filter { moving.contains($0.id) }
            let ahead = windows.prefix(dragTargetIndex).count { moving.contains($0.id) }
            windows.removeAll { moving.contains($0.id) }
            windows.insert(contentsOf: group, at: min(max(dragTargetIndex - ahead, 0), windows.count))
            return windows
        }

        guard let origin = windows.firstIndex(where: { $0.id == draggingID }) else { return windows }
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
        if draggingStack {
            hiddenStackTile(for: model.visibleWindows.filter { collapsedIDs.contains($0.id) })
                .scaleEffect(1.12)
                .shadow(color: .black.opacity(0.3), radius: 6)
                .offset(x: side.isVertical ? 0 : dragOriginTop + dragTranslation,
                        y: side.isVertical ? dragOriginTop + dragTranslation : 0)
        } else if let window = draggedWindow {
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
                RoundedRectangle(cornerRadius: StripMetrics.badgeCorner(prefs: prefs), style: .continuous)
                    .fill(badgeFill)
            )
            .animation(.easeOut(duration: 0.25), value: screen.backdropIsLight)
            // The same inset every row has, so the badge sits the same distance from the end of the
            // strip as the icons do from its sides.
            .padding(4)
            .help("Current workspace")
    }

    /// Several windows are aimed at, which the strip shows as runs rather than a single cursor.
    private var isAimingRun: Bool {
        model.aimedWindows.count > 1
    }

    /// Positions of the aimed windows grouped into runs of neighbours, each drawn as one highlight.
    private var aimedRuns: [ClosedRange<Int>] {
        let aimed = model.aimedIDs
        var runs: [ClosedRange<Int>] = []
        for (index, window) in model.visibleWindows.enumerated() where aimed.contains(window.id) {
            if let last = runs.last, last.upperBound == index - 1 {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        return runs
    }

    /// One continuous highlight for each run of aimed windows.
    @ViewBuilder
    private var aimedRunHighlight: some View {
        if isAimingRun {
            let layout = committedLayout
            let thickness = StripMetrics.rowHeight(prefs: prefs)
            ZStack(alignment: side.isVertical ? .top : .leading) {
                ForEach(aimedRuns, id: \.lowerBound) { run in
                    let start = layout.topOffset(ofWindowAt: run.lowerBound)
                    let length = layout.topOffset(ofWindowAt: run.upperBound) + thickness - start
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
            .animation(.spring(response: 0.22, dampingFraction: 0.85), value: model.aimedIDs)
        }
    }

    /// Marks a window still held in a layout. Any resize or move of it frees the whole group, so
    /// the mark is also a reminder that the arrangement is only there until the window is touched.
    private var tiledMark: some View {
        Image(systemName: "square.grid.2x2.fill")
            .font(.system(size: max(7, prefs.iconSize * 0.3), weight: .bold))
            .foregroundStyle(Color.accentColor)
            .padding(1)
            .background(Circle().fill(Color.black.opacity(0.5)))
            .offset(x: 1, y: -1)
            .help("Tiled — moving or resizing it frees the group")
    }

    /// A dashed, hatched outline the size of an icon: a place a window could go.
    private var emptySlotMarker: some View {
        let long = prefs.iconSize
        let short = StripMetrics.slotThickness(prefs: prefs)
        let shape = RoundedRectangle(cornerRadius: StripMetrics.iconCorner(prefs: prefs), style: .continuous)
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

    /// A window the maximized one is covering and which is still drawn as its own row: only when
    /// the windows are not being collapsed into the stack tile.
    private func isCovered(_ window: ManagedWindow) -> Bool {
        prefs.focusMaximizedWindow && collapsedIDs.isEmpty && model.isCovered(window)
    }

    /// The covered windows as one tile: the first few icons cascading behind each other, fading as
    /// they go back, with the number of windows hidden.
    private func hiddenStackTile(for windows: [ManagedWindow]) -> some View {
        let peek = Array(windows.prefix(StripMetrics.stackPeek))
        let step = StripMetrics.stackStep
        let size = prefs.iconSize
        // The cascade leans both ways from the middle, so the tile sits on the strip's centre line
        // like every other icon rather than hanging off one end.
        let middle = CGFloat(peek.count - 1) / 2
        return ZStack {
            // Drawn back to front, so the nearest card is the one on top.
            ForEach(Array(peek.enumerated().reversed()), id: \.element.id) { depth, window in
                let back = CGFloat(depth)
                let lean = (back - middle) * step
                icon(for: window)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: StripMetrics.iconCorner(prefs: prefs), style: .continuous))
                    // Paired with the window's own row, so collapsing flies the icon into the
                    // cascade and expanding flies it back out to its place in the queue.
                    .matchedGeometryEffect(id: "covered-\(window.id)", in: slotNamespace)
                    .saturation(1 - back * 0.35)
                    .opacity(1 - back * 0.28)
                    .scaleEffect(1 - back * 0.1, anchor: .center)
                    .offset(x: side.isVertical ? 0 : lean, y: side.isVertical ? lean : 0)
            }
        }
        .frame(width: side.isVertical ? size : size + step * CGFloat(max(peek.count - 1, 0)),
               height: side.isVertical ? size + step * CGFloat(max(peek.count - 1, 0)) : size)
        .overlay(alignment: .bottomTrailing) { hiddenCountBadge(windows.count) }
        .padding(4)
        .contentShape(Rectangle())
        .help("\(windows.count) window\(windows.count == 1 ? "" : "s") behind the maximized one")
    }

    private func hiddenCountBadge(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: prefs.iconSize * 0.34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.95)))
            .offset(x: 3, y: 3)
    }

    /// Where the maximized window and the tile of what it covers sit together, as offsets along the
    /// strip, or nil when nothing is collapsed.
    private var maximizedGroupSpan: (start: CGFloat, end: CGFloat)? {
        let visible = model.visibleWindows
        // While the tile is being carried around, the shape joining it to the maximized window
        // would stretch across the whole strip; it comes back when the tile is dropped.
        guard !draggingStack, !collapsedIDs.isEmpty,
              let maximized = visible.firstIndex(where: { $0.id == model.maximizedID }),
              let firstHidden = visible.firstIndex(where: { collapsedIDs.contains($0.id) })
        else { return nil }
        let layout = previewLayout
        let first = min(maximized, firstHidden)
        let last = max(maximized, firstHidden)
        let tail = last == firstHidden
            ? StripMetrics.stackLength(prefs: prefs)
            : StripMetrics.rowHeight(prefs: prefs)
        return (layout.topOffset(ofWindowAt: first), layout.topOffset(ofWindowAt: last) + tail)
    }

    /// The maximized window and the windows it covers are one thing, so one selection covers both.
    private var isMaximizedGroupSelected: Bool {
        model.maximizedID != nil && model.selectedID == model.maximizedID && !collapsedIDs.isEmpty
    }

    /// The shape tying the maximized window to the tile of what it covers, so it is plain which
    /// window the hidden ones are behind. Plain on purpose: an accent-coloured outline here reads as
    /// a selection, which is a different thing — unless the group really is the selected one.
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
                .animation(StripMetrics.layoutAnimation, value: collapsedIDs)
                .animation(.easeOut(duration: 0.16), value: selected)
        }
    }

    private func row(for window: ManagedWindow) -> some View {
        // While a run of windows is aimed, that run is the only highlight on the strip; and a
        // maximized window with a stack beside it is highlighted as one group, not as a row.
        let isSelected = window.id == model.selectedID && !isAimingRun
            && !(isMaximizedGroupSelected && window.id == model.maximizedID)
        // Aiming borrows the highlight and marks it in a different colour, so it is never mistaken
        // for the window that actually has focus.
        // A run of several aimed windows is drawn as one highlight behind them all, so its rows
        // carry none of their own.
        let isAimCursor = window.id == model.aimingID && !isAimingRun
        let isAimed = isAimCursor
        let highlight: Color? = isAimed ? .orange : (isSelected ? .accentColor : nil)
        let covered = isCovered(window)
        return ZStack(alignment: .bottomTrailing) {
            iconWithLabel(for: window)
                .matchedGeometryEffect(id: "covered-\(window.id)", in: slotNamespace)
                .frame(width: prefs.iconSize, height: prefs.iconSize)
                .opacity(window.isMinimized ? 0.45 : covered ? 0.5 : 1)
                // Behind the maximized window, and out of the way until it is restored.
                .saturation(covered ? 0.2 : 1)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .fill(highlight?.opacity(0.28) ?? (covered ? Color.blue.opacity(0.22) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .strokeBorder(highlight ?? .clear, lineWidth: isAimCursor ? 2.5 : 1.5)
        )
        .overlay(alignment: side.isVertical ? .bottomLeading : .topTrailing) {
            if model.isTiled(window) { tiledMark }
        }
        .contentShape(Rectangle())
        .help(window.displayTitle)
    }

    /// The icon, and under it a line of the window's title when labels are on. The pair is drawn
    /// inside the room one icon had, so turning labels on does not make the strip any longer.
    @ViewBuilder
    private func iconWithLabel(for window: ManagedWindow) -> some View {
        if prefs.showWindowLabels {
            // Across the foot of the icon, not under it: the icon keeps its size and the row keeps
            // its place, and the title is legible over whatever the icon happens to be.
            ZStack(alignment: .bottom) {
                icon(for: window)
                    .frame(width: prefs.iconSize, height: prefs.iconSize)
                Text(label(for: window))
                    // A fixed, readable size rather than a fraction of the icon: a bigger icon is
                    // room for more of the title, not for bigger letters.
                    .font(.system(size: StripMetrics.labelSize, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 2)
                    .frame(maxWidth: prefs.iconSize)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.black.opacity(0.62))
                    )
            }
        } else {
            icon(for: window)
        }
    }

    /// What the label says: the window's own title, which is what tells two windows of the same
    /// application apart, falling back to the application's name.
    private func label(for window: ManagedWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return window.appName }
        // Titles often start with a marker or a bullet the app draws itself; it says nothing here.
        return String(title.drop { !$0.isLetter && !$0.isNumber })
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

    // MARK: - Dragging

    private func dragChanged(start: CGFloat, offset: CGFloat) {
        let layout = committedLayout

        if draggingID == nil {
            guard let origin = layout.windowIndex(atOffsetFromTop: start),
                  model.visibleWindows.indices.contains(origin)
            else { return }
            // Taking hold of the collapsed tile takes hold of every window inside it.
            draggingStack = layout.isHiddenStack(atOffsetFromTop: start)
            draggingID = model.visibleWindows[origin].id
            dragOriginIndex = origin
            dragTargetIndex = origin
            dragOriginTop = layout.topOffset(ofWindowAt: origin)
            if !draggingStack { onHold(model.visibleWindows[origin], 0) }
        }
        dragTranslation = offset
        if abs(offset) >= Self.dragThreshold { dragMoved = true }

        guard let target = layout.nearestWindowIndex(toOffsetFromTop: start + offset) else { return }
        dragTargetIndex = target
        if !draggingStack, let window = draggedWindow { onHold(window, offset) }
    }

    private func dragEnded(offset: CGFloat) {
        if draggingStack {
            let moving = collapsedIDs
            let ids = model.visibleWindows.filter { moving.contains($0.id) }.map(\.id)
            let ahead = model.visibleWindows.prefix(dragTargetIndex).count { moving.contains($0.id) }
            if abs(offset) >= Self.dragThreshold || dragTargetIndex != dragOriginIndex {
                model.move(ids: ids, toVisiblePosition: max(dragTargetIndex - ahead, 0))
            }
            endDrag()
            return
        }
        guard let window = draggedWindow else {
            endDrag()
            return
        }

        if abs(offset) < Self.dragThreshold, dragTargetIndex == dragOriginIndex {
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

    /// How far the pointer has to travel before a press counts as a drag.
    private static let dragThreshold: CGFloat = 4

    private static let settleAnimation: Animation = .spring(response: 0.22, dampingFraction: 0.9)
    private static let settleDuration: TimeInterval = 0.22

    private func endDrag() {
        draggingID = nil
        draggingStack = false
        dragMoved = false
        dragTranslation = 0
        dragOriginTop = 0
        onHold(nil, 0)
    }
}

enum StripMetrics {
    static let spacing: CGFloat = 6
    static let padding: CGFloat = 6
    /// Corners follow the size of what they round: the strip's own, a row's highlight, the
    /// workspace badge, the empty slot. A fixed radius looks wrong the moment the icons change size.
    static func corner(prefs: Preferences) -> CGFloat { thickness(prefs: prefs) * 0.28 }
    static func rowCorner(prefs: Preferences) -> CGFloat { rowHeight(prefs: prefs) * 0.24 }
    static func badgeCorner(prefs: Preferences) -> CGFloat { prefs.iconSize * 0.27 }
    static func iconCorner(prefs: Preferences) -> CGFloat { prefs.iconSize * 0.23 }
    static func groupCorner(prefs: Preferences) -> CGFloat { (rowHeight(prefs: prefs) + 4) * 0.3 }
    /// Shared timing so the panel resize and the SwiftUI content move together.
    static let layoutAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.82)
    static let layoutDuration: TimeInterval = 0.32

    /// Height of one window row: the icon plus the row's own padding.
    static func rowHeight(prefs: Preferences) -> CGFloat { prefs.iconSize + 8 }

    /// Length of the empty-workspace marker along the strip: the size of an icon, so it takes a
    /// window's place; the dashes and hatching are what tell it apart.
    static func slotThickness(prefs: Preferences) -> CGFloat { prefs.iconSize }
    static func slotLength(prefs: Preferences) -> CGFloat { slotThickness(prefs: prefs) + 8 }

    /// How thick the strip is: a row, plus the padding around the content. It follows the icon
    /// size rather than being set on its own — a strip narrower than its icons only clipped them.
    static func thickness(prefs: Preferences) -> CGFloat {
        rowHeight(prefs: prefs) + padding * 2
    }

    /// Point size of the title drawn across an icon. Small, and the same whatever the icon size.
    static let labelSize: CGFloat = 10

    /// How far the cascade of hidden windows leans out from the icon under it.
    static let stackStep: CGFloat = 5
    /// Icons drawn in the cascade, however many windows are hidden.
    static let stackPeek = 3

    /// The hidden stack takes a row plus the lean of the cards behind it.
    static func stackLength(prefs: Preferences) -> CGFloat {
        rowHeight(prefs: prefs) + stackStep * CGFloat(stackPeek - 1)
    }


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
