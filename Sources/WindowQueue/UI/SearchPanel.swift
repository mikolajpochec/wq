import AppKit
import Combine
import SwiftUI

/// The window finder: type to narrow the queue, Return to focus.
///
/// Like aiming mode, it never takes focus. The panel is only there to be looked at; the typing
/// arrives through a `KeyboardGrabber`, so nothing is activated and the window the user is about to
/// leave keeps its focus until they choose another.
final class SearchController {
    private let model: WindowQueueModel
    private let store: PreferencesStore
    private let dim: DimOverlay?
    private let onAccept: (ManagedWindow) -> Void

    private let grabber = KeyboardGrabber()
    private var state: SearchState?
    private var panel: OverlayPanel?
    private var cancellable: AnyCancellable?

    init(model: WindowQueueModel,
         store: PreferencesStore,
         dim: DimOverlay?,
         onAccept: @escaping (ManagedWindow) -> Void) {
        self.model = model
        self.store = store
        self.dim = dim
        self.onAccept = onAccept

        grabber.onKeyDown = { [weak self] event in self?.handle(event) ?? false }
        grabber.onDismiss = { [weak self] in self?.close() }
        // Typing is slower than picking with the arrows, so the finder waits longer before it
        // decides it has been abandoned.
        grabber.idleTimeout = 30
    }

    var isOpen: Bool { panel != nil }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        guard panel == nil, !model.windows.isEmpty else { return }

        let state = SearchState(model: model)
        self.state = state

        let view = SearchView(state: state) { [weak self] window in
            self?.accept(window)
        }
        let hosting = NSHostingView(rootView: view)
        let size = SearchView.size(forResultCount: state.results.count)

        let panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = hosting
        panel.setFrame(NSRect(origin: origin(for: size), size: size), display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        // The list grows and shrinks as the query narrows, so the panel has to follow it.
        cancellable = state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.resize() }

        dim?.show()
        grabber.begin()
    }

    func close() {
        grabber.end()
        dim?.hide()
        cancellable = nil
        panel?.orderOut(nil)
        panel = nil
        state = nil
    }

    private func accept(_ window: ManagedWindow) {
        close()
        onAccept(window)
    }

    private func origin(for size: NSSize) -> NSPoint {
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSPoint(x: screen.midX - size.width / 2,
                       y: screen.maxY - size.height - screen.height * 0.22)
    }

    /// `objectWillChange` fires before the change lands, so the new size is worked out on the next
    /// turn of the run loop, once the query and its results are current.
    private func resize() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let state = self.state else { return }
            let size = SearchView.size(forResultCount: state.results.count)
            guard size != panel.frame.size else { return }
            panel.setFrame(NSRect(origin: self.origin(for: size), size: size), display: true)
        }
    }

    private func handle(_ event: CGEvent) -> Bool {
        guard let state else { return false }

        switch event.keyCode {
        case 53:                                  // Escape
            DispatchQueue.main.async { [weak self] in self?.close() }
        case 36, 76:                              // Return, keypad Enter
            DispatchQueue.main.async { [weak self] in
                guard let window = state.highlightedWindow else { return }
                self?.accept(window)
            }
        case 126:                                 // Up
            DispatchQueue.main.async { state.moveHighlight(by: -1) }
        case 125:                                 // Down
            DispatchQueue.main.async { state.moveHighlight(by: 1) }
        case 48:                                  // Tab walks the list too
            DispatchQueue.main.async { state.moveHighlight(by: 1) }
        case 51:                                  // Delete
            DispatchQueue.main.async {
                if !state.query.isEmpty { state.query.removeLast() }
            }
        default:
            let typed = event.typedCharacters
            // Control characters would otherwise end up in the query as invisible junk.
            guard !typed.isEmpty, typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return true }
            DispatchQueue.main.async { state.query.append(typed) }
        }

        // Everything is swallowed: while the finder is open the keys belong to it.
        return true
    }
}
