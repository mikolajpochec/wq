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

/// Owns the strip panel: builds it, keeps it positioned, and resizes it as the queue changes.
final class StripController {
    private let model: WindowQueueModel
    private let store: PreferencesStore
    private let onSelect: (ManagedWindow) -> Void
    private let onHold: (ManagedWindow?) -> Void

    private var panel: OverlayPanel?
    private var cancellables = Set<AnyCancellable>()
    /// Live position of an icon being dragged, which the queue order does not yet reflect.
    private var dragOffset: (id: CGWindowID, y: CGFloat)?

    init(model: WindowQueueModel,
         store: PreferencesStore,
         onSelect: @escaping (ManagedWindow) -> Void,
         onHold: @escaping (ManagedWindow?) -> Void) {
        self.model = model
        self.store = store
        self.onSelect = onSelect
        self.onHold = onHold
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
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
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

    /// Frame of the strip content in screen coordinates, used to place the title toast beside it.
    var currentFrame: NSRect? {
        guard let panel else { return nil }
        let height = StripMetrics.height(itemCount: model.visibleWindows.count, prefs: store.prefs)
        return NSRect(x: panel.frame.minX,
                      y: panel.frame.midY - height / 2,
                      width: panel.frame.width,
                      height: height)
    }

    /// Screen-space rect of one window's row, so the toast can point at that icon.
    func rowFrame(for id: CGWindowID) -> NSRect? {
        guard let content = currentFrame,
              let index = model.visibleWindows.firstIndex(where: { $0.id == id })
        else { return nil }
        let prefs = store.prefs
        let rowHeight = StripMetrics.rowHeight(prefs: prefs)
        // A dragged icon is drawn at the cursor while the queue order still has it in its old slot,
        // so shift the anchor by the drag. Screen coordinates run upwards, the drag downwards.
        let drag = dragOffset.flatMap { $0.id == id ? $0.y : nil } ?? 0
        let centreY = content.maxY - StripMetrics.rowCentreOffset(index: index, prefs: prefs) - drag
        return NSRect(x: content.minX, y: centreY - rowHeight / 2,
                      width: content.width, height: rowHeight)
    }

    var side: StripSide { store.prefs.stripSide }
}
