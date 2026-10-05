import AppKit
import Combine
import SwiftUI

/// A borderless, non-activating panel that floats above everything on every Space.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        // Liquid Glass draws its own soft shadow; the window's, traced from the content's alpha,
        // only adds a dark rim around it.
        if #available(macOS 26, *) { hasShadow = false } else { hasShadow = true }
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
    }
}

/// Hosting view that reports the pointer position.
///
/// SwiftUI's `onHover` is driven by tracking areas that are only active in the key window, and the
/// strip's panel is deliberately never key. Tracking the pointer here, with `.activeAlways`, is what
/// makes hovering work at all.
private final class HoverHostingView<Content: View>: NSHostingView<Content> {
    /// Pointer position in this view's coordinates, or nil once it leaves.
    var onPointerMoved: ((NSPoint?) -> Void)?
    /// Wheel travel, positive downwards, and whether it came in points (a trackpad or a smooth
    /// wheel) rather than whole notches.
    var onScroll: ((CGFloat, Bool) -> Void)?
    /// Middle click at a position in this view's coordinates.
    var onMiddleClick: ((NSPoint) -> Void)?

    private var pointerTracking: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("unsupported")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved,
                                            .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        pointerTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMoved?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointerMoved?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        // A wheel notch pushes content up, so invert it: scrolling down walks down the queue. A
        // sideways swipe counts too, which suits a strip that runs across the screen.
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX : event.scrollingDeltaY
        onScroll?(-delta, event.hasPreciseScrollingDeltas)
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        onMiddleClick?(convert(event.locationInWindow, from: nil))
    }
}

/// Per-screen facts the strip view draws from, beyond the shared queue.
final class StripScreenState: ObservableObject {
    /// False on a screen that is not the selected one, where the strip is drawn greyed out.
    @Published var isActive = true
    /// Desktop number showing on this screen.
    @Published var spaceIndex: Int?
    /// 1-based monitor number (left to right, as the monitor shortcuts count), nil with one screen.
    @Published var monitorIndex: Int?
    /// The display the strip is on, whose queue it shows in multi-monitor mode.
    @Published var monitorID: CGDirectDisplayID?
    /// Whether the screen behind the workspace number is light, or nil while unknown.
    @Published var backdropIsLight: Bool?
    /// The last sample's verdict, which has to be repeated before the number changes colour.
    var pendingBackdropIsLight: Bool?
    /// Room a second strip — a group's — takes beside this one, so the two can be centred together.
    @Published var companionLength: CGFloat = 0
    /// A group's strip has taken this one's place while the user is inside the group.
    @Published var isReplacedByGroup = false
    /// In invisible mode the strip is folded flat against the screen edge and swings open when
    /// aiming asks for it, the way a page opens. True while it is open.
    @Published var isUnfolded = true
}

/// Owns the strip panels, one per screen that should show the strip, and keeps them positioned.
final class StripController {
    private final class ScreenStrip {
        let panel: OverlayPanel
        let hosting: NSView
        let state: StripScreenState
        var screen: NSScreen

        init(panel: OverlayPanel, hosting: NSView, state: StripScreenState, screen: NSScreen) {
            self.panel = panel
            self.hosting = hosting
            self.state = state
            self.screen = screen
        }
    }

    private let model: WindowQueueModel
    private let store: PreferencesStore
    private let onSelect: (ManagedWindow) -> Void
    private let onHold: (ManagedWindow?) -> Void
    private let onClose: (ManagedWindow) -> Void
    /// Steps the selection by whole rows as the wheel turns.
    private let onScroll: (Int) -> Void
    /// The pointer is over the tile the covered windows are collapsed into, with how many there are,
    /// or over it no longer.
    var onHiddenStackHold: (([ManagedWindow]) -> Void)?
    /// The pointer is over a group's entry, with the group and the window whose row it is, or over
    /// it no longer.
    var onGroupHover: (((group: WindowQueueModel.WindowGroup, row: ManagedWindow)?) -> Void)?
    /// The window being dragged along the strip and where it would land, or nil once dropped.
    var onDragTarget: ((ManagedWindow?, Int) -> Void)?
    /// The current-workspace badge was clicked.
    var onBadgeTap: (() -> Void)?

    /// Keyed by display id. Panels are kept while hidden so coming back is instant and nothing is
    /// rebuilt when a screen switches to a fullscreen space and back.
    private var strips: [CGDirectDisplayID: ScreenStrip] = [:]
    /// The strip the pointer is over, which the popup should point from; nil means the selected
    /// screen's strip.
    private weak var pointerStrip: ScreenStrip?
    private var cancellables = Set<AnyCancellable>()
    private let backdrop = BackdropSampler()
    private var backdropTimer: Timer?
    private var backdropQuietUntil = Date.distantPast
    /// Live position of an icon being dragged, which the queue order does not yet reflect.
    private var dragOffset: (id: CGWindowID, y: CGFloat)?
    private var hoveredID: CGWindowID?
    /// Wheel travel not yet worth a whole step.
    private var scrollTravel: CGFloat = 0
    /// Room taken by the group's strip, so the two are centred and placed as one.
    var companionLength: CGFloat = 0 {
        didSet {
            guard companionLength != oldValue else { return }
            // The view draws itself from its screen's state; the controller only measures.
            for strip in strips.values where strip.state.companionLength != companionLength {
                strip.state.companionLength = companionLength
            }
            sync()
        }
    }
    /// A group's strip stands in for this one, which steps out of sight and out of the pointer's way.
    var isReplacedByGroup = false {
        didSet {
            guard isReplacedByGroup != oldValue else { return }
            for strip in strips.values { strip.state.isReplacedByGroup = isReplacedByGroup }
            if isReplacedByGroup { pointerStrip.map { pointerMoved(to: nil, in: $0) } }
        }
    }

    init(model: WindowQueueModel,
         store: PreferencesStore,
         onSelect: @escaping (ManagedWindow) -> Void,
         onHold: @escaping (ManagedWindow?) -> Void,
         onClose: @escaping (ManagedWindow) -> Void,
         onScroll: @escaping (Int) -> Void) {
        self.model = model
        self.store = store
        self.onSelect = onSelect
        self.onHold = onHold
        self.onClose = onClose
        self.onScroll = onScroll
    }

    func start() {
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)
        // The selected screen follows focus, which can move without the queue changing.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .merge(with: workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sync()
                // A Space switch slides windows past the strip for a while; samples taken then
                // describe the animation, not the screen it settles on.
                self?.backdropQuietUntil = Date().addingTimeInterval(1.2)
            }
            .store(in: &cancellables)

        // What is behind the strip changes with every window moved over or away from it; there is
        // no notification for that, so look now and then.
        backdropTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.sampleBackdrops()
        }
        sync()
        sampleBackdrops()
    }

    /// Reads how light the screen is behind each strip's workspace number, so the number can
    /// switch between dark and light to stay readable.
    private func sampleBackdrops() {
        guard store.prefs.showSpaceBadge, Date() >= backdropQuietUntil else { return }
        for strip in strips.values where strip.panel.isVisible {
            guard let rect = badgeFrame(of: strip) else { continue }
            backdrop.luminance(behind: rect, on: strip.screen) { [weak self, weak strip] luminance in
                guard let self else { return }
                guard let strip, let luminance, Date() >= self.backdropQuietUntil else { return }
                // A little hysteresis, so a backdrop near the middle does not flicker between the two.
                let current = strip.state.backdropIsLight
                let isLight = current == true ? luminance > 0.45 : luminance > 0.55
                // Only a verdict that holds for two samples in a row changes the colour, so a window
                // passing under the strip does not make the number blink.
                defer { strip.state.pendingBackdropIsLight = isLight }
                guard current != isLight else { return }
                if current == nil || strip.state.pendingBackdropIsLight == isLight {
                    strip.state.backdropIsLight = isLight
                }
            }
        }
    }

    /// Screen rect of the workspace number, which is the first element of the strip.
    private func badgeFrame(of strip: ScreenStrip) -> NSRect? {
        let panel = strip.panel.frame
        let prefs = store.prefs
        // The badge is drawn inside a row-sized element, inset by the row's own padding.
        let start = contentStart(inPanelLength: mainLength(of: panel), on: strip) + StripMetrics.padding + 4
        let size = prefs.iconSize
        let thickness = StripMetrics.thickness(prefs: prefs)
        let crossInset = (thickness - size) / 2
        switch prefs.stripSide {
        case .left:
            return NSRect(x: panel.minX + crossInset, y: panel.maxY - start - size, width: size, height: size)
        case .right:
            return NSRect(x: panel.maxX - thickness + crossInset, y: panel.maxY - start - size, width: size, height: size)
        case .top:
            return NSRect(x: panel.minX + start, y: panel.maxY - thickness + crossInset, width: size, height: size)
        case .bottom:
            return NSRect(x: panel.minX + start, y: panel.minY + crossInset, width: size, height: size)
        }
    }

    /// Closes the strip like a page and takes the panel away once it is flat.
    private func fold(_ strip: ScreenStrip) {
        guard strip.state.isUnfolded else { return }
        strip.state.isUnfolded = false
        let panel = strip.panel
        let delay = store.prefs.duration(.aimingMode, StripMetrics.foldDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak strip] in
            guard let strip, strip.state.isUnfolded == false else { return }
            guard self?.store.prefs.invisibleStrip == true, self?.model.aimingID == nil else { return }
            panel.orderOut(nil)
        }
    }

    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    private func sync() {
        let prefs = store.prefs
        guard prefs.stripDisplay != .hidden else {
            strips.values.forEach { $0.panel.orderOut(nil) }
            strips = [:]
            return
        }

        let screens = NSScreen.screens
        let active = NSScreen.main ?? screens.first
        let spaces = SpacesBridge.shared.screenSpaces()
        var present = Set<CGDirectDisplayID>()

        for screen in screens {
            guard let id = Self.displayID(of: screen) else { continue }
            present.insert(id)

            let isActive = screen == active
            // Without separate Spaces per display there is one entry, and it covers every screen.
            let space = SpacesBridge.displayUUID(of: screen).flatMap { spaces[$0] }
                ?? (spaces.count == 1 ? spaces.values.first : nil)
            // A fullscreen window is the one case where floating above everything is unwelcome.
            let hiddenByFullscreen = prefs.hideInFullscreen && (space?.isFullscreen ?? false)
            // Invisible mode keeps the queue out of sight until aiming mode asks for it.
            let hiddenUntilAiming = prefs.invisibleStrip && model.aimingID == nil
            let wanted = (isActive || prefs.stripDisplay == .highlightActiveScreen) && !hiddenByFullscreen

            guard wanted, !hiddenUntilAiming else {
                // Folding away is an animation, so the panel stays until the page has closed.
                if let strip = strips[id], strip.panel.isVisible, wanted, prefs.invisibleStrip {
                    fold(strip)
                } else {
                    strips[id]?.panel.orderOut(nil)
                }
                continue
            }

            let strip = strips[id] ?? build(on: screen)
            strips[id] = strip
            strip.screen = screen
            if strip.state.monitorID != id { strip.state.monitorID = id }
            // Aiming picks among every window, wherever it is, so no strip is greyed out meanwhile.
            let drawActive = isActive || prefs.stripDisplay == .activeScreenOnly || model.aimingID != nil
            if strip.state.isActive != drawActive { strip.state.isActive = drawActive }
            let index = space?.index ?? (isActive ? model.currentSpaceIndex : nil)
            if strip.state.spaceIndex != index { strip.state.spaceIndex = index }
            let monitor = screens.count > 1 ? Monitors.orderedScreens.firstIndex(of: screen).map { $0 + 1 } : nil
            if strip.state.monitorIndex != monitor { strip.state.monitorIndex = monitor }
            layout(strip)
            if !strip.panel.isVisible {
                // In invisible mode the strip starts folded flat and opens on the next turn of the
                // run loop, which is what gives SwiftUI a state to animate away from.
                strip.state.isUnfolded = !prefs.invisibleStrip || prefs.instantAiming || !prefs.animates(.aimingMode)
                strip.panel.orderFrontRegardless()
                OverlaySpace.shared.adopt(strip.panel)
            }
            if !strip.state.isUnfolded {
                DispatchQueue.main.async { strip.state.isUnfolded = true }
            }
        }

        for (id, strip) in strips where !present.contains(id) {
            strip.panel.orderOut(nil)
            strips[id] = nil
        }
    }

    private func build(on screen: NSScreen) -> ScreenStrip {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0,
                                                     width: StripMetrics.thickness(prefs: store.prefs),
                                                     height: 100))
        let state = StripScreenState()
        state.isReplacedByGroup = isReplacedByGroup
        var view = StripView(model: model, store: store, screen: state, onSelect: onSelect) { [weak self, weak panel] window, offset in
            guard let self else { return }
            if window != nil { self.pointerStrip = self.strips.values.first { $0.panel === panel } }
            self.dragOffset = window.map { ($0.id, offset) }
            // Carrying the icon, the name is beside the point: the user picked the window and is
            // watching where it will land. The drag itself is still tracked, so hovering stays shut
            // off until the icon is dropped.
            self.onHold(abs(offset) >= 4 ? nil : window)
        }
        view.onDragTarget = { [weak self] window, target in self?.onDragTarget?(window, target) }
        view.onBadgeTap = { [weak self] in self?.onBadgeTap?() }
        let hosting = HoverHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        let strip = ScreenStrip(panel: panel, hosting: hosting, state: state, screen: screen)

        hosting.onPointerMoved = { [weak self, weak strip] point in
            guard let self, let strip else { return }
            self.pointerMoved(to: point, in: strip)
        }
        hosting.onScroll = { [weak self] delta, precise in self?.scrolled(by: delta, precise: precise) }
        hosting.onMiddleClick = { [weak self, weak strip] point in
            guard let self, let strip, let window = self.window(at: point, in: strip) else { return }
            self.onClose(window)
        }
        return strip
    }

    /// The panel spans the full height of the screen and never resizes; the content centres itself
    /// inside it, so adding or removing a window is a pure SwiftUI animation with no window resize.
    /// Empty areas of an `NSHostingView` do not hit-test, so clicks there fall through to the app
    /// underneath.
    private func layout(_ strip: ScreenStrip) {
        let prefs = store.prefs
        let visible = DockReservation.unreservedFrame(of: strip.screen, prefs: prefs)
        let margin = store.prefs.stripMargin
        // Room for aiming mode to grow into: resizing the panel mid-animation would clip the
        // strip, so it is always as thick as the strip can ever get.
        let thickness = StripMetrics.thickness(prefs: prefs) * max(1, prefs.aimingScale)
        let target: NSRect
        switch prefs.stripSide {
        case .left:
            target = NSRect(x: visible.minX + margin, y: visible.minY, width: thickness, height: visible.height)
        case .right:
            target = NSRect(x: visible.maxX - thickness - margin, y: visible.minY,
                            width: thickness, height: visible.height)
        case .top:
            target = NSRect(x: visible.minX, y: visible.maxY - thickness - margin,
                            width: visible.width, height: thickness)
        case .bottom:
            target = NSRect(x: visible.minX, y: visible.minY + margin, width: visible.width, height: thickness)
        }
        guard target != strip.panel.frame else { return }
        strip.panel.setFrame(target, display: true)
    }

    /// The layout of one strip's content — in multi-monitor mode each monitor's queue is its own.
    private func contentLayout(of strip: ScreenStrip?) -> StripLayout {
        var groups: [CGWindowID: Int] = [:]
        for group in model.groups {
            for id in group.ids { groups[id] = group.id }
        }
        let monitor = strip?.state.monitorID
        return StripLayout(windows: model.stripWindows(onMonitor: monitor), prefs: store.prefs,
                           slot: model.slotPlacement(onMonitor: monitor),
                           collapsed: collapsedIDs(on: monitor), groups: groups)
    }

    /// Windows drawn as one collapsed tile, which has to match what `StripView` draws.
    private func collapsedIDs(on monitor: CGDirectDisplayID?) -> Set<CGWindowID> {
        let prefs = store.prefs
        guard prefs.focusMaximizedWindow, prefs.collapseCoveredWindows, let maximized = model.maximizedID
        else { return [] }
        var ids = Set(model.stripWindows(onMonitor: monitor).filter { model.isCovered($0) }.map(\.id))
        // The maximized window is drawn at the front of that tile, so it is part of it here too.
        guard !ids.isEmpty else { return [] }
        ids.insert(maximized)
        return ids
    }

    /// The strip the popup points from: the one under the pointer, else the selected screen's.
    private var anchorStrip: ScreenStrip? {
        if let pointerStrip, pointerStrip.panel.isVisible { return pointerStrip }
        let visible = strips.values.filter { $0.panel.isVisible }
        return visible.first { $0.state.isActive && $0.screen == NSScreen.main }
            ?? visible.first { $0.state.isActive }
            ?? visible.first
    }

    /// Distance from the start of the panel — its top for a vertical strip, its left for a
    /// horizontal one — to the start of the strip content, which alignment places along the edge.
    private func contentStart(inPanelLength length: CGFloat, on strip: ScreenStrip?) -> CGFloat {
        let alignment = store.prefs.stripAlignment
        // Flush with the end it is aligned to; the margin only keeps the other end off the edge.
        let leading = alignment == .start ? 0 : store.prefs.stripMargin
        let trailing = alignment == .end ? 0 : store.prefs.stripMargin
        let free = max(0, length - leading - trailing - contentLayout(of: strip).totalHeight)
        // The pair keeps the alignment as one: centred it shares the middle, at either end it grows
        // inwards, so this strip moves out of the way of the group's strip where that is needed.
        let shift = store.prefs.stripShift(forCompanion: companionLength)
        return leading + free * alignment.fraction - shift
    }

    private func mainLength(of rect: NSRect) -> CGFloat {
        side.isVertical ? rect.height : rect.width
    }

    /// Shows the window's name as soon as its icon is hovered, and drops it on the way out.
    private func pointerMoved(to point: NSPoint?, in strip: ScreenStrip) {
        if point != nil {
            pointerStrip = strip
        } else if dragOffset == nil, pointerStrip === strip {
            pointerStrip = nil
        }
        // A drag already owns the popup, and aiming is keyboard-driven and drawn scaled, so the
        // unscaled hit-test would land on the wrong icon. A strip a group's has replaced is not
        // there to hover.
        guard dragOffset == nil, model.aimingID == nil, point == nil || !isReplacedByGroup else { return }

        // The collapsed tile is not one window, so it gets its own popup rather than the name of
        // whichever window happens to be first inside it.
        if let point, isHiddenStack(at: point, in: strip) {
            let hidden = contentLayout(of: strip).hiddenWindows
            guard hoveredID != Self.stackHoverID else { return }
            hoveredID = Self.stackHoverID
            onHiddenStackHold?(hidden)
            return
        }

        let hovered = point.flatMap { window(at: $0, in: strip) }
        // A group's entry stands for several windows, so it is named as a group rather than with
        // whichever window's title happens to be first inside it.
        if let hovered, let group = model.group(of: hovered.id) {
            guard hoveredID != hovered.id else { return }
            hoveredID = hovered.id
            onGroupHover?((group, hovered))
            return
        }
        onGroupHover?(nil)

        guard hovered?.id != hoveredID else { return }
        hoveredID = hovered?.id
        if hovered == nil, hoveredID == nil { onHiddenStackHold?([]) }
        onHold(hovered)
    }

    /// Turns wheel travel into whole steps through the queue: one icon per row of movement, so the
    /// selection keeps pace with what the strip actually looks like.
    private func scrolled(by delta: CGFloat, precise: Bool) {
        // A notched wheel reports a line or so per notch, far short of a row: one notch, one step.
        guard precise else {
            scrollTravel = 0
            if delta != 0 { onScroll(delta > 0 ? 1 : -1) }
            return
        }
        let step = StripMetrics.rowHeight(prefs: store.prefs)
        scrollTravel += delta
        let steps = Int(scrollTravel / step)
        guard steps != 0 else { return }
        scrollTravel -= CGFloat(steps) * step
        onScroll(steps)
    }

    /// Stands in for the collapsed tile in `hoveredID`, which otherwise holds a window id.
    private static let stackHoverID = CGWindowID.max

    private func isHiddenStack(at point: NSPoint, in strip: ScreenStrip) -> Bool {
        contentLayout(of: strip).isHiddenStack(atOffsetFromTop: offsetAlongContent(of: point, in: strip))
    }

    /// How far along the strip's content a point lies.
    private func offsetAlongContent(of point: NSPoint, in strip: ScreenStrip) -> CGFloat {
        let view = strip.hosting
        let along: CGFloat
        if side.isVertical {
            along = view.isFlipped ? point.y : view.bounds.height - point.y
        } else {
            along = point.x
        }
        return along - contentStart(inPanelLength: mainLength(of: view.bounds), on: strip)
    }

    /// The window under a point in the hosting view, which spans the whole edge while the strip
    /// content sits inside it wherever alignment puts it.
    private func window(at point: NSPoint, in strip: ScreenStrip) -> ManagedWindow? {
        contentLayout(of: strip).windowIndex(atOffsetFromTop: offsetAlongContent(of: point, in: strip))
            .map { model.stripWindows(onMonitor: strip.state.monitorID)[$0] }
    }

    /// Screen rect of the strip's content — the bar itself, not the panel it floats in — so another
    /// strip can be placed in line with it.
    func contentFrame() -> (frame: NSRect, side: StripSide)? {
        guard let strip = anchorStrip else { return nil }
        let panel = strip.panel.frame
        let prefs = store.prefs
        let start = contentStart(inPanelLength: mainLength(of: panel), on: strip)
        let length = contentLayout(of: strip).totalHeight
        let thickness = StripMetrics.thickness(prefs: prefs)
        switch prefs.stripSide {
        case .left:
            return (NSRect(x: panel.minX, y: panel.maxY - start - length, width: thickness, height: length), .left)
        case .right:
            return (NSRect(x: panel.maxX - thickness, y: panel.maxY - start - length,
                           width: thickness, height: length), .right)
        case .top:
            return (NSRect(x: panel.minX + start, y: panel.maxY - thickness, width: length, height: thickness), .top)
        case .bottom:
            return (NSRect(x: panel.minX + start, y: panel.minY, width: length, height: thickness), .bottom)
        }
    }

    /// Screen-space rect of one window's row, so the toast can point at that icon.
    func rowFrame(for id: CGWindowID) -> NSRect? {
        guard let strip = anchorStrip else { return nil }
        return rowFrame(for: id, in: strip)
    }

    /// The window's row on every strip on screen, the popup's own strip first.
    func rowFramesOnEveryStrip(for id: CGWindowID) -> [NSRect] {
        let anchor = anchorStrip
        let others = strips.values.filter { $0.panel.isVisible && $0 !== anchor }
            .sorted { $0.screen.frame.minX < $1.screen.frame.minX }
        return ([anchor].compactMap { $0 } + others).compactMap { rowFrame(for: id, in: $0) }
    }

    private func rowFrame(for id: CGWindowID, in strip: ScreenStrip) -> NSRect? {
        guard let index = model.stripWindows(onMonitor: strip.state.monitorID).firstIndex(where: { $0.id == id })
        else { return nil }
        let panel = strip.panel.frame
        let prefs = store.prefs
        let layout = contentLayout(of: strip)
        let start = contentStart(inPanelLength: mainLength(of: panel), on: strip)
        // A dragged icon is drawn at the cursor while the queue order still has it in its old slot,
        // so shift the anchor by the drag.
        let drag = dragOffset.flatMap { $0.id == id ? $0.y : nil } ?? 0
        var along = start + layout.centreOffset(ofWindowAt: index) + drag
        var rowLength = StripMetrics.rowHeight(prefs: prefs)

        // While aiming, the strip is drawn scaled about the end it is aligned to; the layout is
        // not, so the anchor follows the same transform or the popup drifts from its icon.
        if model.aimingID != nil, model.aimInsideGroupID == nil {
            let anchor = start + layout.totalHeight * prefs.stripAlignment.fraction
            along = anchor + (along - anchor) * prefs.aimingScale
            rowLength *= prefs.aimingScale
        }

        if side.isVertical {
            // Screen coordinates run upwards, offsets along the strip downwards.
            let centreY = panel.maxY - along
            return NSRect(x: panel.minX, y: centreY - rowLength / 2, width: panel.width, height: rowLength)
        }
        let centreX = panel.minX + along
        return NSRect(x: centreX - rowLength / 2, y: panel.minY, width: rowLength, height: panel.height)
    }

    /// An icon is being carried along the strip.
    var isDragging: Bool { dragOffset != nil }

    var side: StripSide { store.prefs.stripSide }
}
