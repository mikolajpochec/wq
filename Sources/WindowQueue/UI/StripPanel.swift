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
        hasShadow = true
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
    /// Raw wheel travel, positive downwards.
    var onScroll: ((CGFloat) -> Void)?
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
        // A wheel notch pushes content up, so invert it: scrolling down walks down the queue.
        onScroll?(-event.scrollingDeltaY)
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

    /// Keyed by display id. Panels are kept while hidden so coming back is instant and nothing is
    /// rebuilt when a screen switches to a fullscreen space and back.
    private var strips: [CGDirectDisplayID: ScreenStrip] = [:]
    /// The strip the pointer is over, which the popup should point from; nil means the selected
    /// screen's strip.
    private weak var pointerStrip: ScreenStrip?
    private var cancellables = Set<AnyCancellable>()
    /// Live position of an icon being dragged, which the queue order does not yet reflect.
    private var dragOffset: (id: CGWindowID, y: CGFloat)?
    private var hoveredID: CGWindowID?
    /// Wheel travel not yet worth a whole step.
    private var scrollTravel: CGFloat = 0

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
            .sink { [weak self] _ in self?.sync() }
            .store(in: &cancellables)

        sync()
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
            let wanted = (isActive || prefs.stripDisplay == .highlightActiveScreen) && !hiddenByFullscreen

            guard wanted else {
                strips[id]?.panel.orderOut(nil)
                continue
            }

            let strip = strips[id] ?? build(on: screen)
            strips[id] = strip
            strip.screen = screen
            let drawActive = isActive || prefs.stripDisplay == .activeScreenOnly
            if strip.state.isActive != drawActive { strip.state.isActive = drawActive }
            let index = space?.index ?? (isActive ? model.currentSpaceIndex : nil)
            if strip.state.spaceIndex != index { strip.state.spaceIndex = index }
            layout(strip)
            if !strip.panel.isVisible {
                strip.panel.orderFrontRegardless()
                OverlaySpace.shared.adopt(strip.panel)
            }
        }

        for (id, strip) in strips where !present.contains(id) {
            strip.panel.orderOut(nil)
            strips[id] = nil
        }
    }

    private func build(on screen: NSScreen) -> ScreenStrip {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: store.prefs.stripWidth, height: 100))
        let state = StripScreenState()
        let view = StripView(model: model, store: store, screen: state, onSelect: onSelect) { [weak self, weak panel] window, offset in
            guard let self else { return }
            if window != nil { self.pointerStrip = self.strips.values.first { $0.panel === panel } }
            self.dragOffset = window.map { ($0.id, offset) }
            self.onHold(window)
        }
        let hosting = HoverHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        let strip = ScreenStrip(panel: panel, hosting: hosting, state: state, screen: screen)

        hosting.onPointerMoved = { [weak self, weak strip] point in
            guard let self, let strip else { return }
            self.pointerMoved(to: point, in: strip)
        }
        hosting.onScroll = { [weak self] delta in self?.scrolled(by: delta) }
        hosting.onMiddleClick = { [weak self, weak strip] point in
            guard let self, let strip, let window = self.window(at: point, in: strip.hosting) else { return }
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
        let visible = strip.screen.visibleFrame
        // Room for aiming mode to grow into: resizing the panel mid-animation would clip the
        // strip, so it is always as wide as the strip can ever get.
        let width = prefs.stripWidth * max(1, prefs.aimingScale)
        let x = prefs.stripSide == .left
            ? visible.minX + StripMetrics.screenMargin
            : visible.maxX - width - StripMetrics.screenMargin
        let target = NSRect(x: x, y: visible.minY, width: width, height: visible.height)
        guard target != strip.panel.frame else { return }
        strip.panel.setFrame(target, display: true)
    }

    private var contentLayout: StripLayout {
        StripLayout(windows: model.visibleWindows, prefs: store.prefs)
    }

    /// The strip the popup points from: the one under the pointer, else the selected screen's.
    private var anchorStrip: ScreenStrip? {
        if let pointerStrip, pointerStrip.panel.isVisible { return pointerStrip }
        let visible = strips.values.filter { $0.panel.isVisible }
        return visible.first { $0.state.isActive && $0.screen == NSScreen.main }
            ?? visible.first { $0.state.isActive }
            ?? visible.first
    }

    /// Frame of the strip content in screen coordinates, used to place the title toast beside it.
    private func contentFrame(of strip: ScreenStrip) -> NSRect {
        let frame = strip.panel.frame
        let height = contentLayout.totalHeight
        return NSRect(x: frame.minX, y: frame.midY - height / 2, width: frame.width, height: height)
    }

    /// Shows the window's name as soon as its icon is hovered, and drops it on the way out.
    private func pointerMoved(to point: NSPoint?, in strip: ScreenStrip) {
        if point != nil {
            pointerStrip = strip
        } else if dragOffset == nil, pointerStrip === strip {
            pointerStrip = nil
        }
        // A drag already owns the popup, and aiming is keyboard-driven and drawn scaled, so the
        // unscaled hit-test would land on the wrong icon.
        guard dragOffset == nil, model.aimingID == nil else { return }

        let hovered = point.flatMap { window(at: $0, in: strip.hosting) }

        guard hovered?.id != hoveredID else { return }
        hoveredID = hovered?.id
        onHold(hovered)
    }

    /// Turns wheel travel into whole steps through the queue: one icon per row of movement, so the
    /// selection keeps pace with what the strip actually looks like.
    private func scrolled(by delta: CGFloat) {
        let step = StripMetrics.rowHeight(prefs: store.prefs)
        scrollTravel += delta
        let steps = Int(scrollTravel / step)
        guard steps != 0 else { return }
        scrollTravel -= CGFloat(steps) * step
        onScroll(steps)
    }

    /// The window under a point in the hosting view, which spans the whole screen height while the
    /// strip content is centred inside it.
    private func window(at point: NSPoint, in view: NSView) -> ManagedWindow? {
        let layout = contentLayout
        let fromTop = view.isFlipped ? point.y : view.bounds.height - point.y
        let withinContent = fromTop - (view.bounds.height - layout.totalHeight) / 2
        return layout.windowIndex(atOffsetFromTop: withinContent)
            .map { model.visibleWindows[$0] }
    }

    /// Screen-space rect of one window's row, so the toast can point at that icon.
    func rowFrame(for id: CGWindowID) -> NSRect? {
        guard let strip = anchorStrip,
              let index = model.visibleWindows.firstIndex(where: { $0.id == id })
        else { return nil }
        let content = contentFrame(of: strip)
        let rowHeight = StripMetrics.rowHeight(prefs: store.prefs)
        // A dragged icon is drawn at the cursor while the queue order still has it in its old slot,
        // so shift the anchor by the drag. Screen coordinates run upwards, the drag downwards.
        let drag = dragOffset.flatMap { $0.id == id ? $0.y : nil } ?? 0
        var centreY = content.maxY - contentLayout.centreOffset(ofWindowAt: index) - drag

        // While aiming, the strip is drawn scaled about its vertical centre; the layout is not, so
        // the anchor has to follow the same transform or the popup drifts from its icon.
        if model.aimingID != nil {
            let scale = store.prefs.aimingScale
            centreY = content.midY + (centreY - content.midY) * scale
        }

        let scaledRowHeight = model.aimingID == nil ? rowHeight : rowHeight * store.prefs.aimingScale
        return NSRect(x: content.minX, y: centreY - scaledRowHeight / 2,
                      width: content.width, height: scaledRowHeight)
    }

    var side: StripSide { store.prefs.stripSide }
}
