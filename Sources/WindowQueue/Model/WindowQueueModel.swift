import AppKit
import Combine

/// The ordered window queue.
///
/// Order is stable: new windows are appended, and cycling never reorders. Only the explicit
/// move operations change the order. Scope filtering is a view over the same array, so the
/// manual order survives workspace switches.
final class WindowQueueModel: ObservableObject {
    @Published private(set) var windows: [ManagedWindow] = []
    @Published var selectedID: CGWindowID?
    @Published var scope: QueueScope = .global
    @Published var currentSpaceID: UInt64?
    @Published var currentSpaceIndex: Int?
    /// Desktop ids in Mission Control order, so a window can be labelled with its workspace number.
    @Published var spaceOrder: [UInt64] = []

    /// Fires whenever the selection changes in a way that should be announced to the user.
    let announcement = PassthroughSubject<ManagedWindow, Never>()

    // MARK: - Visible slice

    var visibleWindows: [ManagedWindow] {
        visibleIndices.map { windows[$0] }
    }

    /// Indices into `windows` of the entries the current scope exposes.
    private var visibleIndices: [Int] {
        guard scope == .currentSpace, let current = currentSpaceID else {
            return Array(windows.indices)
        }
        let filtered = windows.indices.filter { windows[$0].spaceID == current }
        // A workspace we cannot resolve should not blank the strip out entirely.
        return filtered.isEmpty ? Array(windows.indices) : filtered
    }

    var selectedWindow: ManagedWindow? {
        guard let selectedID else { return nil }
        return windows.first { $0.id == selectedID }
    }

    private var selectedVisiblePosition: Int? {
        guard let selectedID else { return nil }
        return visibleWindows.firstIndex { $0.id == selectedID }
    }

    /// 1-based workspace number a window sits on, or nil for a minimised or unplaced window.
    func workspaceNumber(of window: ManagedWindow) -> Int? {
        guard let space = window.spaceID, let index = spaceOrder.firstIndex(of: space) else { return nil }
        return index + 1
    }

    // MARK: - Reconciliation

    /// Merges a freshly enumerated set of windows into the queue, preserving existing order.
    func reconcile(with discovered: [ManagedWindow]) {
        let discoveredByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        var next: [ManagedWindow] = []

        for existing in windows {
            guard var updated = discoveredByID[existing.id] else { continue }
            updated.spaceID = updated.spaceID ?? existing.spaceID
            // AX only sees the active Space, so keep what we learned while the window was visible.
            updated.element = updated.element ?? existing.element
            if updated.title.isEmpty { updated.title = existing.title }
            next.append(updated)
        }

        // New windows land directly after the current one, the way a tiling WM inserts next to the
        // focused client, rather than at the far end of the queue.
        let known = Set(next.map(\.id))
        let fresh = discovered.filter { !known.contains($0.id) }
        if !fresh.isEmpty {
            let insertionIndex = selectedID
                .flatMap { id in next.firstIndex { $0.id == id } }
                .map { $0 + 1 } ?? next.count
            next.insert(contentsOf: fresh, at: insertionIndex)
        }

        guard next != windows else { return }
        windows = next
        clampSelection()
    }

    func updateSpaces(_ spaces: [CGWindowID: UInt64]) {
        var changed = false
        for index in windows.indices {
            let resolved = spaces[windows[index].id]
            if resolved != nil, windows[index].spaceID != resolved {
                windows[index].spaceID = resolved
                changed = true
            }
        }
        if changed { objectWillChange.send() }
    }

    private func clampSelection() {
        if let selectedID, windows.contains(where: { $0.id == selectedID }) { return }
        selectedID = visibleWindows.first?.id
    }

    // MARK: - Selection

    func select(id: CGWindowID, announce: Bool) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        if Diagnostics.isEnabled, selectedID != id {
            Diagnostics.note("select \(window.appName) id=\(id) announce=\(announce)")
        }
        selectedID = id
        if announce { announcement.send(window) }
    }

    /// Moves the selection by `delta` positions within the visible slice, wrapping around.
    @discardableResult
    func cycle(by delta: Int) -> ManagedWindow? {
        let visible = visibleWindows
        guard !visible.isEmpty else { return nil }
        let current = selectedVisiblePosition ?? (delta > 0 ? -1 : 0)
        let count = visible.count
        let next = ((current + delta) % count + count) % count
        let window = visible[next]
        select(id: window.id, announce: true)
        return window
    }

    // MARK: - Reordering

    /// Swaps the selected window with its neighbour `delta` positions away in the visible slice.
    func move(by delta: Int) {
        let indices = visibleIndices
        guard let position = selectedVisiblePosition else { return }
        let target = position + delta
        guard indices.indices.contains(target) else { return }
        windows.swapAt(indices[position], indices[target])
    }

    func moveToStart() {
        guard let selectedID else { return }
        move(id: selectedID, toVisiblePosition: 0)
    }

    func moveToEnd() {
        guard let selectedID else { return }
        move(id: selectedID, toVisiblePosition: visibleIndices.count - 1)
    }

    /// Moves one window to an absolute slot within the visible slice, leaving windows the current
    /// scope hides where they are.
    func move(id: CGWindowID, toVisiblePosition target: Int) {
        let indices = visibleIndices
        guard let position = visibleWindows.firstIndex(where: { $0.id == id }),
              indices.indices.contains(target),
              position != target
        else { return }

        let sourceIndex = indices[position]
        let window = windows.remove(at: sourceIndex)
        // Recompute after removal so the destination slot is still correct.
        let remaining = visibleIndices
        let insertionIndex: Int
        if target <= 0 {
            insertionIndex = remaining.first ?? 0
        } else if target >= remaining.count {
            insertionIndex = (remaining.last.map { $0 + 1 }) ?? windows.count
        } else {
            insertionIndex = remaining[target]
        }
        windows.insert(window, at: min(insertionIndex, windows.count))
    }
}
