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
    @ObservedObject var capture = ScreenCapture.shared
    var onSelect: (ManagedWindow) -> Void
    /// Called with the window being held and how far it has been dragged, and with nil when the
    /// hold ends, so the popup can stay up and follow the icon.
    var onHold: (ManagedWindow?, CGFloat) -> Void
    /// The window being dragged and the queue position it would land in, or nil once it is dropped.
    var onDragTarget: (ManagedWindow?, Int) -> Void = { _, _ in }
    /// The current-workspace badge was clicked.
    var onBadgeTap: () -> Void = {}

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
    /// Where the press started, so a click that lands on no icon can still be placed.
    @State private var dragStart: CGFloat = 0
    /// The collapsed tile is being dragged, which moves every window inside it as one.
    @State private var draggingStack = false
    /// A group's tile is being dragged, which likewise moves all of its windows.
    @State private var draggingGroupID: Int?
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
            // The strip shifts to leave room for a group's strip beside it, so the two keep the
            // strip's alignment as one; see `StripController.contentStart`.
            .offset(x: side.isVertical ? 0 : -companionShift, y: side.isVertical ? -companionShift : 0)
            // Making room for a group's strip is a slide, not a jump; the group's own panel moves
            // on the same timing.
            .animation(prefs.animation(.groupStrip, .easeOut(duration: StripMetrics.layoutDuration)), value: screen.companionLength)
            // The margin is a gap from the screen edge, not from the end of the strip: aligned to
            // the start or the end, the strip lines up with the windows beside it.
            .padding(side.isVertical ? .top : .leading, prefs.stripAlignment == .start ? 0 : prefs.stripMargin)
            .padding(side.isVertical ? .bottom : .trailing, prefs.stripAlignment == .end ? 0 : prefs.stripMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.placement(of: prefs))
            // A group's strip stands in its place while the user is inside the group.
            .opacity(screen.isReplacedByGroup ? 0 : 1)
            .allowsHitTesting(!screen.isReplacedByGroup)
            .animation(prefs.animation(.groupStrip, .easeOut(duration: 0.13)), value: screen.isReplacedByGroup)
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
    /// Which way the folded page leans while it is shut.
    ///
    /// Hinged on the screen edge and lying over the screen, so opening sweeps it out of the middle
    /// and down onto its edge — a page being turned, rather than a panel unfolding off the side.
    static func foldedAngle(for side: StripSide) -> Double {
        switch side {
        case .left, .top: return 100
        case .right, .bottom: return -100
        }
    }

    /// The aim is walking this strip, rather than a group's strip below it.
    private var isAimTarget: Bool {
        model.aimingID != nil && model.aimInsideGroupID == nil
    }

    /// How far this strip moves to make room for a group's strip beside it.
    private var companionShift: CGFloat {
        prefs.stripShift(forCompanion: screen.companionLength)
    }

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
                case .group(let id, let windows):
                    groupTile(id: id, windows: windows)
                        .opacity(draggingGroupID == id ? 0 : 1)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
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
        .animation(prefs.animation(.stripLayout, StripMetrics.layoutAnimation), value: previewLayout.elements.map(\.id))
        .animation(prefs.animation(.stripLayout, .easeOut(duration: 0.11)), value: model.selectedID)
        .animation(prefs.animation(.stripLayout, .easeOut(duration: 0.14)), value: model.maximizedID)
        .animation(prefs.animation(.stripLayout, StripMetrics.layoutAnimation), value: collapsedIDs)
        .padding(StripMetrics.padding)
        .frame(width: side.isVertical ? StripMetrics.thickness(prefs: prefs) : nil,
               height: side.isVertical ? nil : StripMetrics.thickness(prefs: prefs))
        // Behind the icons but above the strip's own background.
        .background(alignment: side.isVertical ? .top : .leading) { aimedRunHighlight }
        // On a monitor that is not the selected one the strip stays readable but steps back, and
        // so does the whole strip while the user is working inside a group. Only the content loses
        // its colour: a colour filter over the glass flattens it into a dull grey slab.
        .saturation(screen.isActive ? 1 : 0)
        .dockGlassBackground(cornerRadius: StripMetrics.corner(prefs: prefs), opacity: prefs.stripOpacity)
        .opacity(screen.isActive ? (model.openGroupID == nil ? 1 : 0.55) : prefs.inactiveStripOpacity)
        .animation(prefs.animation(.groupStrip, .easeOut(duration: 0.13)), value: model.openGroupID)
        .animation(prefs.animation(.stripLayout, .easeOut(duration: 0.14)), value: screen.isActive)
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
        // Invisible mode: the strip is a page hinged on the screen edge, flat against it until
        // aiming opens it. The perspective is what makes it read as opening rather than squashing.
        .rotation3DEffect(.degrees(screen.isUnfolded ? 0 : Self.foldedAngle(for: side)),
                          axis: side.isVertical ? (x: 0, y: 1, z: 0) : (x: 1, y: 0, z: 0),
                          anchor: scaleAnchor, perspective: 0.9)
        // Past ninety degrees the page is face down over the screen, so it fades out rather than
        // showing its back, and the last of the turn is what brings it into view.
        .opacity(screen.isUnfolded ? 1 : 0)
        // Opening can be told to happen at once; folding away always animates.
        .animation(prefs.instantAiming && screen.isUnfolded
                   ? nil : prefs.animation(.aimingMode, .spring(response: StripMetrics.foldDuration, dampingFraction: 0.78)),
                   value: screen.isUnfolded)
        // Only the strip the aim is actually on grows: stepped into a group, the aim walks the
        // group's own strip, and growing this one too would just push the pair around.
        .scaleEffect(isAimTarget ? prefs.aimingScale : 1, anchor: scaleAnchor)
        .animation(prefs.instantAiming && isAimTarget
                   ? nil : prefs.animation(.aimingMode, .spring(response: 0.18, dampingFraction: 0.82)),
                   value: isAimTarget)
    }

    // MARK: - Layout

    /// This monitor's queue: its own in multi-monitor mode, the focused monitor's otherwise.
    private var visibleWindows: [ManagedWindow] {
        model.stripWindows(onMonitor: screen.monitorID)
    }

    private func layout(of windows: [ManagedWindow]) -> StripLayout {
        StripLayout(windows: windows, prefs: prefs, slot: model.slotPlacement(onMonitor: screen.monitorID),
                    collapsed: collapsedIDs, groups: groupNumbers)
    }

    /// Which group each window belongs to, for the layout to fold them into one entry.
    private var groupNumbers: [CGWindowID: Int] {
        var numbers: [CGWindowID: Int] = [:]
        for group in model.groups {
            for id in group.ids { numbers[id] = group.id }
        }
        return numbers
    }

    /// Windows the maximized one covers, while they are meant to collapse into one tile.
    private var collapsedIDs: Set<CGWindowID> {
        // A drag of one icon expands the tile so it can be dropped anywhere among the rows; a drag
        // of the tile itself keeps it collapsed, because that is the thing being moved. A press that
        // has not travelled is a click, and must not shuffle the strip under the pointer.
        guard prefs.focusMaximizedWindow, prefs.collapseCoveredWindows, model.maximizedID != nil,
              draggingID == nil || draggingStack || !dragMoved
        else { return [] }
        var ids = Set(visibleWindows.filter { model.isCovered($0) }.map(\.id))
        // The maximized window goes in the tile too, at the front: one entry on the strip holds the
        // window on top and the windows under it, rather than two entries tied together by a shape.
        guard !ids.isEmpty, let maximized = model.maximizedID else { return [] }
        ids.insert(maximized)
        return ids
    }

    /// Geometry of the committed queue. Drag targeting measures against this rather than the preview
    /// so that the answer cannot oscillate as the preview rearranges itself underneath the cursor.
    private var committedLayout: StripLayout { layout(of: visibleWindows) }

    private var previewLayout: StripLayout { layout(of: orderedWindows) }

    /// The queue as the strip currently shows it: the committed order, with a drag in progress
    /// previewed by moving the dragged window to the slot it would land in.
    private var orderedWindows: [ManagedWindow] {
        var windows = visibleWindows
        guard let draggingID else { return windows }

        if let moving = draggingBlockIDs {
            let block = windows.filter { moving.contains($0.id) }
            let destination = blockDestination(of: moving, in: windows)
            windows.removeAll { moving.contains($0.id) }
            windows.insert(contentsOf: block, at: min(destination, windows.count))
            return windows
        }

        guard let origin = windows.firstIndex(where: { $0.id == draggingID }) else { return windows }
        let window = windows.remove(at: origin)
        windows.insert(window, at: min(max(dragTargetIndex, 0), windows.count))
        return windows
    }

    /// The windows a tile being dragged holds — the collapsed stack's, or a group's — which move
    /// through the queue as one. Nil while a single window is carried.
    private var draggingBlockIDs: Set<CGWindowID>? {
        if draggingStack { return collapsedIDs }
        guard let draggingGroupID, let group = model.groups.first(where: { $0.id == draggingGroupID })
        else { return nil }
        return Set(group.ids)
    }

    /// Where a block lands among the windows left once it is taken out: in front of the window it
    /// is dropped on when carried up the strip, behind it when carried down — as a single window
    /// lands — so the far end can be reached either way.
    private func blockDestination(of moving: Set<CGWindowID>, in windows: [ManagedWindow]) -> Int {
        let ahead = windows.prefix(dragTargetIndex).count { moving.contains($0.id) }
        let past = dragTargetIndex > dragOriginIndex ? 1 : 0
        return max(dragTargetIndex - ahead + past, 0)
    }

    private var draggedWindow: ManagedWindow? {
        guard let draggingID else { return nil }
        return visibleWindows.first { $0.id == draggingID }
    }

    // MARK: - Rows

    @ViewBuilder
    private var floatingRow: some View {
        if draggingStack {
            hiddenStackTile(for: visibleWindows.filter { collapsedIDs.contains($0.id) })
                .scaleEffect(1.12)
                .shadow(color: .black.opacity(0.3), radius: 6)
                .offset(x: side.isVertical ? 0 : dragOriginTop + dragTranslation,
                        y: side.isVertical ? dragOriginTop + dragTranslation : 0)
        } else if let id = draggingGroupID, let members = draggingBlockIDs {
            groupTile(id: id, windows: visibleWindows.filter { members.contains($0.id) })
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

    @ViewBuilder
    private var spaceBadge: some View {
        // While a window is being recorded the badge says so instead: it is the one thing more
        // worth knowing at a glance than which workspace this is.
        if capture.isRecording {
            Image(systemName: "record.circle.fill")
                .font(.system(size: prefs.iconSize * 0.6, weight: .semibold))
                .foregroundStyle(Color.red)
                .symbolEffect(.pulse)
                .frame(width: prefs.iconSize, height: prefs.iconSize)
                .background(
                    RoundedRectangle(cornerRadius: StripMetrics.badgeCorner(prefs: prefs), style: .continuous)
                        .fill(Color.red.opacity(0.16))
                )
                .padding(4)
                .help("Recording a window")
        } else {
            workspaceBadge
        }
    }

    private var workspaceBadge: some View {
        // The controller works out each screen's own number, falling back to the model's for the
        // screen the strip belongs to; another screen's desktop is not this one's number.
        Text(screen.spaceIndex.map(String.init) ?? "–")
            .font(.system(size: prefs.iconSize * 0.55, weight: .semibold, design: .rounded))
            .foregroundStyle(badgeForeground)
            .frame(width: prefs.iconSize, height: prefs.iconSize)
            .background(
                RoundedRectangle(cornerRadius: StripMetrics.badgeCorner(prefs: prefs), style: .continuous)
                    .fill(badgeFill)
            )
            // With several monitors a small corner number says which one this is; the workspace
            // number stays the main thing.
            .overlay(alignment: .bottomTrailing) {
                if let monitor = screen.monitorIndex {
                    Text(String(monitor))
                        .font(.system(size: prefs.iconSize * 0.24, weight: .bold, design: .rounded))
                        .foregroundStyle(badgeForeground.opacity(0.65))
                        .padding(.trailing, prefs.iconSize * 0.1)
                        .padding(.bottom, prefs.iconSize * 0.04)
                }
            }
            .animation(prefs.animation(.stripLayout, .easeOut(duration: 0.25)), value: screen.backdropIsLight)
            // The same inset every row has, so the badge sits the same distance from the end of the
            // strip as the icons do from its sides.
            .padding(4)
            .help(screen.monitorIndex.map { "Current workspace (monitor \($0))" } ?? "Current workspace")
    }

    /// Several windows are aimed at, which the strip shows as runs rather than a single cursor.
    private var isAimingRun: Bool {
        model.aimedWindows.count > 1
    }

    /// Where the aimed windows sit, merged into one stretch for each run of neighbouring entries.
    /// Measured by the strip's entries, not queue positions: a group's windows need not be next to
    /// each other in the queue, yet share one tile, and tiles are not all a row long.
    private var aimedSpans: [(start: CGFloat, length: CGFloat)] {
        let aimed = model.aimedIDs
        let positions = visibleWindows.indices.filter { aimed.contains(visibleWindows[$0].id) }
        return committedLayout.spans(ofWindowsAt: positions)
    }

    /// One continuous highlight for each run of aimed windows.
    @ViewBuilder
    private var aimedRunHighlight: some View {
        if isAimingRun {
            let thickness = StripMetrics.rowHeight(prefs: prefs)
            ZStack(alignment: side.isVertical ? .top : .leading) {
                ForEach(aimedSpans, id: \.start) { span in
                    let start = span.start
                    let length = span.length
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
            .animation(prefs.animation(.aimCursor, .spring(response: 0.16, dampingFraction: 0.87)), value: model.aimedIDs)
        }
    }

    /// A group as the strip shows it: the members' icons stacked, their number, and a mark that it
    /// is open — its windows are listed in the panel beside the strip.
    private func groupTile(id: Int, windows: [ManagedWindow]) -> some View {
        let isOpen = model.openGroupID == id
        let holdsSelection = windows.contains { $0.id == model.selectedID }
        return ZStack {
            ForEach(Array(windows.prefix(StripMetrics.stackPeek).enumerated().reversed()), id: \.element.id) { depth, window in
                let back = CGFloat(depth)
                let lean = (back - CGFloat(min(windows.count, StripMetrics.stackPeek) - 1) / 2) * StripMetrics.stackStep
                icon(for: window)
                    .frame(width: prefs.iconSize, height: prefs.iconSize)
                    .clipShape(RoundedRectangle(cornerRadius: StripMetrics.iconCorner(prefs: prefs), style: .continuous))
                    .saturation(1 - back * 0.25)
                    .opacity(1 - back * 0.2)
                    .scaleEffect(1 - back * 0.08)
                    .offset(x: side.isVertical ? 0 : lean, y: side.isVertical ? lean : 0)
            }
        }
        .frame(width: prefs.iconSize, height: prefs.iconSize)
        .overlay(alignment: .bottomTrailing) {
            Text("\(windows.count)")
                .font(.system(size: max(8, prefs.iconSize * 0.3), weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .background(Capsule().fill(Color.accentColor.opacity(0.95)))
                .offset(x: 3, y: 3)
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .fill(holdsSelection ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .strokeBorder(holdsSelection ? Color.accentColor : Color.primary.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1.5, dash: isOpen ? [] : [4, 3]))
        )
        .contentShape(Rectangle())
        .help("Group of \(windows.count) windows")
    }

    /// Marks a window still held in a layout. Any resize or move of it frees the whole group, so
    /// the mark is also a reminder that the arrangement is only there until the window is touched.
    private func tiledMark(_ group: WindowQueueModel.TiledGroup) -> some View {
        let size = max(7, prefs.iconSize * 0.3)
        return HStack(spacing: 1) {
            Image(systemName: "square.grid.2x2.fill")
            // Several layouts at once are told apart by number; one on its own needs none.
            if model.tiledGroups.count > 1 { Text("\(group.id)") }
        }
        .font(.system(size: size, weight: .bold))
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.black.opacity(0.55)))
        .offset(x: -1, y: -1)
        .help("Tiled group \(group.id) — moving or resizing a window frees it")
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
        // The maximized window is the card on top, whatever its place in the queue; the rest fall
        // away behind it in queue order.
        let ordered = windows.filter { $0.id == model.maximizedID } + windows.filter { $0.id != model.maximizedID }
        let covered = max(ordered.count - 1, 0)
        let selected = ordered.contains { $0.id == model.selectedID }
        let peek = Array(ordered.prefix(StripMetrics.stackPeek))
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
        .overlay(alignment: .bottomTrailing) { hiddenCountBadge(covered) }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: StripMetrics.rowCorner(prefs: prefs), style: .continuous)
                .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .animation(prefs.animation(.stripLayout, .easeOut(duration: 0.11)), value: selected)
        .contentShape(Rectangle())
        .help("\(covered) window\(covered == 1 ? "" : "s") behind the maximized one")
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

    private func row(for window: ManagedWindow) -> some View {
        // While a run of windows is aimed, that run is the only highlight on the strip; and a
        // maximized window with a stack beside it is highlighted as one group, not as a row.
        let isSelected = window.id == model.selectedID && !isAimingRun
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
        .overlay(alignment: .topLeading) {
            if let group = model.tiledGroup(of: window.id) { tiledMark(group) }
        }
        .contentShape(Rectangle())
        .help(window.displayTitle)
    }

    /// The icon, and under it a line of the window's title when labels are on. The pair is drawn
    /// inside the room one icon had, so turning labels on does not make the strip any longer.
    private func iconWithLabel(for window: ManagedWindow) -> some View {
        icon(for: window)
            .frame(width: prefs.iconSize, height: prefs.iconSize)
            .windowLabel(window, prefs: prefs)
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
        dragStart = start

        if draggingID == nil {
            guard let origin = layout.windowIndex(atOffsetFromTop: start),
                  visibleWindows.indices.contains(origin)
            else { return }
            // Taking hold of the collapsed tile takes hold of every window inside it.
            // So does taking hold of a group's tile.
            draggingStack = layout.isHiddenStack(atOffsetFromTop: start)
            draggingGroupID = draggingStack ? nil : layout.group(atOffsetFromTop: start)
            draggingID = visibleWindows[origin].id
            dragOriginIndex = origin
            dragTargetIndex = origin
            dragOriginTop = layout.topOffset(ofWindowAt: origin)
            if draggingBlockIDs == nil { onHold(visibleWindows[origin], 0) }
        }
        dragTranslation = offset
        if abs(offset) >= Self.dragThreshold { dragMoved = true }

        guard let target = layout.nearestWindowIndex(toOffsetFromTop: start + offset) else { return }
        dragTargetIndex = target
        if draggingBlockIDs == nil, let window = draggedWindow {
            // The window is still reported while it is carried — the strip needs to know a drag is
            // under way — and the popup is dropped separately, by the controller.
            onHold(window, offset)
            // Where a window would land is worth showing once the icon is actually being carried;
            // a press that has not moved is a click, and a cell lighting up under it is noise.
            onDragTarget(dragMoved ? window : nil, target)
        }
    }

    private func dragEnded(offset: CGFloat) {
        if let moving = draggingBlockIDs {
            if abs(offset) < Self.dragThreshold, dragTargetIndex == dragOriginIndex {
                // A click on the collapsed tile is a click on the card on top of it: the maximized
                // window, which is the one the tile shows and the one the user can actually see. A
                // click on a group's tile steps into the group at its first window.
                let maximized = draggingStack
                    ? model.maximizedID.flatMap { id in model.windows.first { $0.id == id } } : nil
                if let window = maximized ?? draggedWindow { onSelect(window) }
                endDrag()
                return
            }
            let visible = visibleWindows
            let ids = visible.filter { moving.contains($0.id) }.map(\.id)
            model.onMonitor(screen.monitorID) {
                model.move(ids: ids, toVisiblePosition: blockDestination(of: moving, in: visible))
            }
            endDrag()
            return
        }
        guard let window = draggedWindow else {
            // A click on the badge is a click on the workspace itself, which opens aiming mode.
            if abs(offset) < Self.dragThreshold, committedLayout.isBadge(atOffsetFromTop: dragStart) {
                onBadgeTap()
            }
            endDrag()
            return
        }

        if abs(offset) < Self.dragThreshold, dragTargetIndex == dragOriginIndex {
            onSelect(window)
            endDrag()
            return
        }

        // Dropped on a group, the window goes beside the group — past all of it when carried down
        // the strip — never between its windows.
        var target = dragTargetIndex
        let visible = visibleWindows
        if visible.indices.contains(target),
           model.group(of: window.id)?.id != model.group(of: visible[target].id)?.id,
           let span = model.onMonitor(screen.monitorID, { model.groupSpan(of: visible[target].id) }) {
            target = target > dragOriginIndex ? span.upperBound : span.lowerBound
        }
        model.onMonitor(screen.monitorID) { model.move(id: window.id, toVisiblePosition: target) }

        // Let the floating icon travel from the cursor to the slot it was dropped on, then hand
        // over to the row underneath, which has been holding that place all along. The destination
        // is read from the layout the move has just produced, headers included.
        let destination = committedLayout.topOffset(ofWindowAt: target)
        withAnimation(prefs.animation(.stripLayout, Self.settleAnimation)) {
            dragTranslation = destination - dragOriginTop
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDuration) {
            endDrag()
        }
    }

    /// How far the pointer has to travel before a press counts as a drag.
    private static let dragThreshold: CGFloat = 4

    private static let settleAnimation: Animation = .spring(response: 0.16, dampingFraction: 0.9)
    private static let settleDuration: TimeInterval = 0.16

    private func endDrag() {
        onDragTarget(nil, 0)
        draggingID = nil
        draggingStack = false
        draggingGroupID = nil
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
    /// A row's highlight is concentric with the strip: its radius is the strip's less the padding
    /// between them, as Liquid Glass nests shapes.
    static func corner(prefs: Preferences) -> CGFloat { thickness(prefs: prefs) * 0.34 }
    static func rowCorner(prefs: Preferences) -> CGFloat { max(corner(prefs: prefs) - padding, 4) }
    static func badgeCorner(prefs: Preferences) -> CGFloat { prefs.iconSize * 0.27 }
    static func iconCorner(prefs: Preferences) -> CGFloat { prefs.iconSize * 0.23 }
    static func groupCorner(prefs: Preferences) -> CGFloat { (rowHeight(prefs: prefs) + 4) * 0.3 }
    /// Shared timing so the panel resize and the SwiftUI content move together.
    static let layoutAnimation: Animation = .spring(response: 0.22, dampingFraction: 0.85)
    static let layoutDuration: TimeInterval = 0.22
    /// How long the page takes to swing open or shut in invisible mode.
    static let foldDuration: TimeInterval = 0.24

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
    static func stackLength(prefs: Preferences, cards: Int = stackPeek) -> CGFloat {
        rowHeight(prefs: prefs) + stackStep * CGFloat(max(min(cards, stackPeek) - 1, 0))
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

extension View {
    /// A line of the window's title across the foot of an icon, when labels are on — shared by the
    /// main strip and the group's strip so both show the same thing.
    @ViewBuilder
    func windowLabel(_ window: ManagedWindow, prefs: Preferences) -> some View {
        if prefs.showWindowLabels {
            // Across the foot of the icon, not under it: the icon keeps its size and the row keeps
            // its place, and the title is legible over whatever the icon happens to be.
            ZStack(alignment: .bottom) {
                self
                Text(WindowLabel.text(for: window))
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
            self
        }
    }
}

enum WindowLabel {
    /// What the label says: the window's own title, which is what tells two windows of the same
    /// application apart, falling back to the application's name.
    static func text(for window: ManagedWindow) -> String {
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return window.appName }
        // Titles often start with a marker or a bullet the app draws itself; it says nothing here.
        return String(title.drop { !$0.isLetter && !$0.isNumber })
    }
}
