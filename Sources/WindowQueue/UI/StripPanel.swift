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

/// Owns the strip panel: builds it, keeps it positioned, and resizes it as the queue changes.
final class StripController {
    private let model: WindowQueueModel
    private let store: PreferencesStore
    private let onSelect: (ManagedWindow) -> Void
    private let onHold: (ManagedWindow?) -> Void
    private let onClose: (ManagedWindow) -> Void
    /// Steps the selection by whole rows as the wheel turns.
    private let onScroll: (Int) -> Void

    private var panel: OverlayPanel?
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
            .sink { [weak self] _ in self?.layout() }
            .store(in: &cancellables)

        sync()
    }

    private func sync() {
        guard store.prefs.stripEnabled else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        if panel == nil { build() }
        layout()
        panel?.orderFrontRegardless()
    }

    private func build() {
        let panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: store.prefs.stripWidth, height: 100))
        let view = StripView(model: model, store: store, onSelect: onSelect) { [weak self] window, offset in
            self?.dragOffset = window.map { ($0.id, offset) }
            self?.onHold(window)
        }
        let hosting = HoverHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        hosting.onPointerMoved = { [weak self] point in self?.pointerMoved(to: point, in: hosting) }
        hosting.onScroll = { [weak self] delta in self?.scrolled(by: delta) }
        hosting.onMiddleClick = { [weak self] point in
            guard let self, let window = self.window(at: point, in: hosting) else { return }
            self.onClose(window)
        }
        panel.acceptsMouseMovedEvents = true
        panel.contentView = hosting
        self.panel = panel
    }

    /// The panel spans the full height of the screen and never resizes; the content centres itself
    /// inside it, so adding or removing a window is a pure SwiftUI animation with no window resize.
    /// Empty areas of an `NSHostingView` do not hit-test, so clicks there fall through to the app
    /// underneath.
    private func layout() {
        guard let panel, let screen = NSScreen.main else { return }
        let prefs = store.prefs
        let visible = screen.visibleFrame
        let width = prefs.stripWidth
        let x = prefs.stripSide == .left
            ? visible.minX + StripMetrics.screenMargin
            : visible.maxX - width - StripMetrics.screenMargin
        let target = NSRect(x: x, y: visible.minY, width: width, height: visible.height)
        guard target != panel.frame else { return }
        panel.setFrame(target, display: true)
    }

    private var contentLayout: StripLayout {
        StripLayout(windows: model.visibleWindows, prefs: store.prefs)
    }

    /// Frame of the strip content in screen coordinates, used to place the title toast beside it.
    var currentFrame: NSRect? {
        guard let panel else { return nil }
        let height = contentLayout.totalHeight
        return NSRect(x: panel.frame.minX,
                      y: panel.frame.midY - height / 2,
                      width: panel.frame.width,
                      height: height)
    }

    /// Shows the window's name as soon as its icon is hovered, and drops it on the way out.
    private func pointerMoved(to point: NSPoint?, in view: NSView) {
        // A drag already owns the popup; hovering must not fight it for position.
        guard dragOffset == nil else { return }

        let hovered = point.flatMap { window(at: $0, in: view) }

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
        guard let content = currentFrame,
              let index = model.visibleWindows.firstIndex(where: { $0.id == id })
        else { return nil }
        let rowHeight = StripMetrics.rowHeight(prefs: store.prefs)
        // A dragged icon is drawn at the cursor while the queue order still has it in its old slot,
        // so shift the anchor by the drag. Screen coordinates run upwards, the drag downwards.
        let drag = dragOffset.flatMap { $0.id == id ? $0.y : nil } ?? 0
        let centreY = content.maxY - contentLayout.centreOffset(ofWindowAt: index) - drag
        return NSRect(x: content.minX, y: centreY - rowHeight / 2,
                      width: content.width, height: rowHeight)
    }

    var side: StripSide { store.prefs.stripSide }
}
