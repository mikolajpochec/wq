import AppKit
import Combine
import QuartzCore
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

    private var panel: OverlayPanel?
    private var cancellables = Set<AnyCancellable>()

    init(model: WindowQueueModel, store: PreferencesStore, onSelect: @escaping (ManagedWindow) -> Void) {
        self.model = model
        self.store = store
        self.onSelect = onSelect
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
        let view = StripView(model: model, store: store, onSelect: onSelect)
        let hosting = NSHostingView(rootView: view)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        self.panel = panel
    }

    private func layout() {
        guard let panel, let screen = NSScreen.main else { return }
        let prefs = store.prefs
        let frame = screen.visibleFrame
        let height = min(StripMetrics.height(itemCount: model.visibleWindows.count, prefs: prefs),
                         frame.height)
        let width = prefs.stripWidth
        let margin = StripMetrics.screenMargin
        let x = prefs.stripSide == .left ? frame.minX + margin : frame.maxX - width - margin
        let y = frame.midY - height / 2
        let target = NSRect(x: x, y: y, width: width, height: height)
        guard target != panel.frame else { return }

        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = StripMetrics.layoutDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Frame of the strip in screen coordinates, used to place the title toast beside it.
    var currentFrame: NSRect? { panel?.frame }
    var side: StripSide { store.prefs.stripSide }
}
