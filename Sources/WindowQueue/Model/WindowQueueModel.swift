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
    /// The window aiming mode is pointing at. Nil whenever the mode is off. Aiming deliberately
    /// does not touch `selectedID`: nothing is focused until the user confirms.
    @Published var aimingID: CGWindowID?
    /// Where a multi-window aim started; the aimed windows run from here to `aimingID`.
    @Published var aimAnchorID: CGWindowID?
    /// Windows picked one by one with Shift-click, aimed at alongside the run. Need not be next to
    /// each other.
    @Published var aimPinnedIDs: Set<CGWindowID> = []
    @Published var scope: QueueScope = .global
    /// Keeps the queue grouped by workspace as windows come and go.
    @Published var autoSortByWorkspace = true
    @Published var currentSpaceID: UInt64? {
        didSet {
            guard currentSpaceID != oldValue else { return }
            // The marker belongs to one workspace; leaving it takes the marker away, and arriving
            // on another empty one puts it back there.
            updateEmptySlot(clearingSelection: true)
        }
    }

    /// The user is on a workspace with no windows left: nothing is selected, and the strip marks
    /// the place in the queue where that workspace's windows would be.
    struct EmptySlot: Equatable {
        let spaceID: UInt64
        /// The window the marker sits in front of, or nil for the end of the queue.
        let beforeID: CGWindowID?
    }

    @Published private(set) var emptySlot: EmptySlot?
    /// The window that has just taken the marker's place, so the strip can animate it in there.
    @Published private(set) var slotFilledID: CGWindowID?
    @Published var currentSpaceIndex: Int?
    /// The display the strip is on is showing a fullscreen window.
    @Published var currentSpaceIsFullscreen = false
    /// Desktop ids in Mission Control order, so a window can be labelled with its workspace number.
    @Published var spaceOrder: [UInt64] = [] {
        didSet { if spaceOrder != oldValue { updateEmptySlot() } }
    }

    /// The window filling its workspace, which the queue puts first there and cycling sticks to.
    @Published private(set) var maximizedID: CGWindowID?
    /// Where that window sat in the queue before, to put it back.
    private var positionBeforeMaximize: Int?

    /// A set of windows laid out together and still holding that layout. The arrangement follows
    /// the queue: reorder them and they are laid out again that way.
    struct TiledGroup: Identifiable, Equatable {
        /// Small number shown in the strip, so several groups can be told apart.
        let id: Int
        var ids: [CGWindowID]
        var layout: String
    }

    @Published private(set) var tiledGroups: [TiledGroup] = []

    /// Fires whenever the selection changes in a way that should be announced to the user.
    let announcement = PassthroughSubject<ManagedWindow, Never>()

    /// Called when the user reorders the queue by hand. Automatic sorting gives way to a manual
    /// arrangement rather than undoing it a moment later; the sort shortcut turns it back on.
    var onManualReorder: (() -> Void)?

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
        // A workspace we cannot resolve — a fullscreen space, or one not read yet — should not blank
        // the strip out entirely. A desktop that is simply empty shows nothing but its empty slot.
        guard filtered.isEmpty, !spaceOrder.contains(current) else { return filtered }
        return Array(windows.indices)
    }

    var aimedWindow: ManagedWindow? {
        guard let aimingID else { return nil }
        return windows.first { $0.id == aimingID }
    }

    /// Starts aiming at whatever is selected, so the first step moves from where the user is.
    @discardableResult
    func beginAiming() -> ManagedWindow? {
        aimAnchorID = nil
        aimPinnedIDs = []
        let aimable = aimableWindows
        let selected = selectedID.flatMap { id in aimable.first { $0.id == id }?.id }
        aimingID = selected ?? aimable.first?.id
        return aimedWindow
    }

    /// Windows the aim can land on: the same ones cycling reaches, so the collapsed tile is passed
    /// over rather than stepped into.
    private var aimableWindows: [ManagedWindow] { cyclableWindows }

    func endAiming() {
        aimingID = nil
        aimAnchorID = nil
        aimPinnedIDs = []
    }

    /// Every window the aim covers, in queue order: the run from the anchor to the aim — or just
    /// the aimed window — plus any picked one by one.
    var aimedWindows: [ManagedWindow] {
        let visible = visibleWindows
        guard let aim = visible.firstIndex(where: { $0.id == aimingID }) else { return [] }
        var ids = aimPinnedIDs
        let anchor = visible.firstIndex(where: { $0.id == aimAnchorID }) ?? aim
        for window in visible[min(aim, anchor)...max(aim, anchor)] { ids.insert(window.id) }
        return visible.filter { ids.contains($0.id) }
    }

    var aimedIDs: Set<CGWindowID> { Set(aimedWindows.map(\.id)) }

    /// Grows or shrinks the aimed run by moving its free end, stopping at the ends of the queue.
    @discardableResult
    func extendAim(by delta: Int) -> ManagedWindow? {
        let visible = aimableWindows
        guard let current = visible.firstIndex(where: { $0.id == aimingID }) else { return nil }
        if aimAnchorID == nil { aimAnchorID = aimingID }
        aimingID = visible[min(max(current + delta, 0), visible.count - 1)].id
        return aimedWindow
    }

    /// Adds a window to what is aimed at, or takes it out again, leaving the rest as it is.
    func toggleAim(_ id: CGWindowID) {
        guard aimingID != nil, let window = visibleWindows.first(where: { $0.id == id }),
              !isCovered(window)
        else { return }
        // Everything aimed so far stays aimed, whether it came from a run or from earlier clicks.
        var picked = Set(aimedWindows.map(\.id))
        aimAnchorID = nil
        if picked.contains(id) {
            guard picked.count > 1 else { return }
            picked.remove(id)
            // The aim itself has to stay on something that is still aimed.
            if aimingID == id {
                let order = visibleWindows.map(\.id)
                let origin = order.firstIndex(of: id) ?? 0
                aimingID = order.enumerated()
                    .filter { picked.contains($0.element) }
                    .min { abs($0.offset - origin) < abs($1.offset - origin) }?.element
            }
        } else {
            picked.insert(id)
            aimingID = id
        }
        aimPinnedIDs = picked
    }

    /// Moves the whole aimed run one slot along the queue, keeping it together and aimed.
    func moveAimedGroup(by delta: Int) {
        moveGroup(aimedWindows.map(\.id), by: delta)
    }

    /// Moves a set of windows one slot along the queue, keeping them together.
    func moveGroup(_ groupIDs: [CGWindowID], by delta: Int) {
        let visible = visibleWindows
        let ids = Set(groupIDs)
        let group = visible.filter { ids.contains($0.id) }
        guard !group.isEmpty else { return }
        guard let first = visible.firstIndex(where: { ids.contains($0.id) }) else { return }
        let destination = min(max(first + delta, 0), visible.count - group.count)
        guard destination != first else { return }
        noteManualReorder()

        var order = visible.filter { !ids.contains($0.id) }
        order.insert(contentsOf: group, at: destination)
        for (slot, index) in visibleIndices.enumerated() {
            windows[index] = order[slot]
        }
    }

    /// Moves the aim within the visible slice, wrapping around, without focusing anything.
    @discardableResult
    func moveAim(by delta: Int) -> ManagedWindow? {
        aimAnchorID = nil
        aimPinnedIDs = []
        let visible = aimableWindows
        guard !visible.isEmpty else { return nil }
        let current = visible.firstIndex { $0.id == aimingID } ?? (delta > 0 ? -1 : 0)
        let count = visible.count
        aimingID = visible[((current + delta) % count + count) % count].id
        return aimedWindow
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

    // MARK: - Tiled groups

    /// Records a layout. The windows leave whatever group they were in before, and a group that
    /// loses too many windows to be a layout disappears.
    @discardableResult
    func setTiled(_ ids: [CGWindowID], layout: String) -> TiledGroup? {
        let moving = Set(ids)
        for index in tiledGroups.indices {
            tiledGroups[index].ids.removeAll { moving.contains($0) }
        }
        tiledGroups.removeAll { $0.ids.count < 2 }
        guard ids.count > 1 else {
            objectWillChange.send()
            return nil
        }
        // The lowest number nobody is using, so the numbers stay small as groups come and go.
        var number = 1
        while tiledGroups.contains(where: { $0.id == number }) { number += 1 }
        let group = TiledGroup(id: number, ids: ids, layout: layout)
        tiledGroups.append(group)
        objectWillChange.send()
        return group
    }

    /// Frees the group a window belongs to: its windows keep their frames, they are simply no
    /// longer held in a layout.
    func clearTiled(containing id: CGWindowID) {
        guard tiledGroups.contains(where: { $0.ids.contains(id) }) else { return }
        tiledGroups.removeAll { $0.ids.contains(id) }
        objectWillChange.send()
    }

    func clearTiled() {
        guard !tiledGroups.isEmpty else { return }
        tiledGroups = []
        objectWillChange.send()
    }

    func isTiled(_ window: ManagedWindow) -> Bool {
        tiledGroup(of: window.id) != nil
    }

    func tiledGroup(of id: CGWindowID) -> TiledGroup? {
        tiledGroups.first { $0.ids.contains(id) }
    }

    var tiledIDs: [CGWindowID] { tiledGroups.flatMap(\.ids) }

    /// A group's windows in the order the queue has them now, which is the order they should be
    /// laid out in.
    func tiledWindowsInQueueOrder(_ group: TiledGroup) -> [ManagedWindow] {
        let ids = Set(group.ids)
        return windows.filter { ids.contains($0.id) }
    }

    // MARK: - Focus on one window

    /// A window has been maximized: it goes to the head of its workspace's run in the queue, and
    /// everything else on that workspace steps aside — drawn as covered, and skipped while cycling.
    func beginFocus(on id: CGWindowID) {
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
        if maximizedID != id { endFocus() }
        positionBeforeMaximize = index
        maximizedID = id
        guard let space = windows[index].spaceID,
              let first = windows.firstIndex(where: { $0.spaceID == space })
        else { return }
        let window = windows.remove(at: index)
        windows.insert(window, at: min(first, windows.count))
    }

    /// The window is no longer maximized: the queue goes back to the order it had.
    func endFocus() {
        guard let id = maximizedID else { return }
        maximizedID = nil
        defer { positionBeforeMaximize = nil }
        guard let position = positionBeforeMaximize,
              let index = windows.firstIndex(where: { $0.id == id })
        else { return }
        let window = windows.remove(at: index)
        windows.insert(window, at: min(max(position, 0), windows.count))
    }

    /// Whether a window is one of those the maximized window is covering.
    func isCovered(_ window: ManagedWindow) -> Bool {
        guard let maximizedID, window.id != maximizedID,
              let maximized = windows.first(where: { $0.id == maximizedID })
        else { return false }
        return window.spaceID != nil && window.spaceID == maximized.spaceID
    }

    /// Windows cycling can reach: everything, less the ones a maximized window is covering.
    /// Everything except the windows a maximized window covers.
    private var cyclableWindows: [ManagedWindow] {
        guard maximizedID != nil else { return visibleWindows }
        return visibleWindows.filter { !isCovered($0) }
    }

    // MARK: - Reconciliation

    /// Merges a freshly enumerated set of windows into the queue, preserving existing order.
    func reconcile(with discovered: [ManagedWindow]) {
        let discoveredByID = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        // If the selected window is about to disappear, where it was decides what comes next.
        let previousOrder = windows.map(\.id)
        let vanishedSelection = selectedID.flatMap { id in
            discoveredByID[id] == nil ? windows.first { $0.id == id } : nil
        }
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
        var fresh = discovered.filter { !known.contains($0.id) }

        // A window opening on the empty workspace the user is on takes the marked place.
        if let slot = emptySlot,
           let filler = fresh.firstIndex(where: { ($0.spaceID ?? currentSpaceID) == slot.spaceID }) {
            let window = fresh.remove(at: filler)
            let index = slot.beforeID.flatMap { id in next.firstIndex { $0.id == id } } ?? next.count
            next.insert(window, at: index)
            emptySlot = nil
            selectedID = window.id
            slotFilledID = window.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.slotFilledID == window.id { self?.slotFilledID = nil }
            }
        }

        if !fresh.isEmpty {
            let insertionIndex = selectedID
                .flatMap { id in next.firstIndex { $0.id == id } }
                .map { $0 + 1 } ?? next.count
            next.insert(contentsOf: fresh, at: insertionIndex)
        }

        guard next != windows else { return }
        windows = next
        // A tiled window that has gone leaves its group; below two there is no layout left.
        if !tiledGroups.isEmpty {
            let present = Set(windows.map(\.id))
            for index in tiledGroups.indices {
                tiledGroups[index].ids.removeAll { !present.contains($0) }
            }
            tiledGroups.removeAll { $0.ids.count < 2 }
        }
        // A maximized window that has gone takes the covering with it.
        if let maximizedID, !windows.contains(where: { $0.id == maximizedID }) {
            self.maximizedID = nil
            positionBeforeMaximize = nil
        }
        keepAimOnQueue(previousOrder: previousOrder)
        if autoSortByWorkspace { sortByWorkspace() }
        if let vanished = vanishedSelection {
            followVanishedSelection(vanished, previousOrder: previousOrder)
        }
        updateEmptySlot()
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
        guard changed else { return }
        if autoSortByWorkspace { sortByWorkspace() }
        updateEmptySlot()
        objectWillChange.send()
    }

    private func clampSelection() {
        if let selectedID, windows.contains(where: { $0.id == selectedID }) { return }
        // On an empty workspace nothing is meant to be selected.
        if emptySlot != nil {
            selectedID = nil
            return
        }
        selectedID = visibleWindows.first?.id
    }

    /// A window that closes while it is aimed at hands the aim to its nearest neighbour, and a run
    /// whose anchor closed carries on from where the aim is.
    private func keepAimOnQueue(previousOrder: [CGWindowID]) {
        let present = Set(windows.map(\.id))
        if let anchor = aimAnchorID, !present.contains(anchor) { aimAnchorID = nil }
        aimPinnedIDs.formIntersection(present)
        guard let aim = aimingID, !present.contains(aim), let origin = previousOrder.firstIndex(of: aim) else { return }
        let visible = Set(visibleWindows.map(\.id))
        let nearest = previousOrder.enumerated()
            .filter { visible.contains($0.element) }
            .min { abs($0.offset - origin) < abs($1.offset - origin) }
        aimingID = nearest?.element ?? visibleWindows.first?.id
        if aimAnchorID == aimingID { aimAnchorID = nil }
    }

    // MARK: - Selection

    func select(id: CGWindowID, announce: Bool) {
        guard let window = windows.first(where: { $0.id == id }) else { return }
        if Diagnostics.isEnabled, selectedID != id {
            Diagnostics.note("select \(window.appName) id=\(id) announce=\(announce)")
        }
        selectedID = id
        emptySlot = nil
        if announce { announcement.send(window) }
    }

    /// Moves the selection by `delta` positions within the visible slice, wrapping around.
    @discardableResult
    func cycle(by delta: Int) -> ManagedWindow? {
        let visible = cyclableWindows
        guard !visible.isEmpty else { return nil }
        let current = visible.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : 0)
        let count = visible.count
        let next = ((current + delta) % count + count) % count
        let window = visible[next]
        select(id: window.id, announce: true)
        return window
    }

    // MARK: - Reordering

    /// The maximized window and the windows it covers, which move through the queue as one.
    var maximizedGroupIDs: [CGWindowID] {
        guard let maximizedID else { return [] }
        let group = visibleWindows.filter { $0.id == maximizedID || isCovered($0) }
        return group.count > 1 ? group.map(\.id) : []
    }

    /// Swaps the selected window with its neighbour `delta` positions away in the visible slice.
    func move(by delta: Int) {
        // A maximized window carries the windows it covers with it; they are one block in the queue.
        let group = maximizedGroupIDs
        if selectedID == maximizedID, !group.isEmpty {
            moveGroup(group, by: delta)
            return
        }
        let indices = visibleIndices
        guard let position = selectedVisiblePosition else { return }
        let target = position + delta
        guard indices.indices.contains(target) else { return }
        noteManualReorder()
        windows.swapAt(indices[position], indices[target])
    }

    private func noteManualReorder() {
        guard autoSortByWorkspace else { return }
        autoSortByWorkspace = false
        onManualReorder?()
    }

    func moveToStart() {
        guard let selectedID else { return }
        move(id: selectedID, toVisiblePosition: 0)
    }

    func moveToEnd() {
        guard let selectedID else { return }
        move(id: selectedID, toVisiblePosition: visibleIndices.count - 1)
    }

    /// The window the selection should fall to once `id` is gone.
    func neighbour(after id: CGWindowID) -> ManagedWindow? {
        let visible = visibleWindows
        guard let position = visible.firstIndex(where: { $0.id == id }), visible.count > 1 else {
            return nil
        }
        return visible[position + 1 < visible.count ? position + 1 : position - 1]
    }

    /// First and last visible position of the run of windows sharing `id`'s workspace.
    func groupBounds(of id: CGWindowID) -> ClosedRange<Int>? {
        let visible = visibleWindows
        guard let position = visible.firstIndex(where: { $0.id == id }) else { return nil }
        let workspace = workspaceNumber(of: visible[position])

        var lower = position
        while lower > 0, workspaceNumber(of: visible[lower - 1]) == workspace { lower -= 1 }
        var upper = position
        while upper < visible.count - 1, workspaceNumber(of: visible[upper + 1]) == workspace {
            upper += 1
        }
        return lower...upper
    }

    /// Puts the queue back into a previously saved order.
    ///
    /// Greedy and forgiving: each saved key claims the first window still unplaced that matches it,
    /// and anything the save does not mention keeps its discovered position at the end. A window
    /// whose title has changed since simply fails to match, which costs nothing.
    func applyOrder(keys: [String]) {
        var remaining = windows
        var ordered: [ManagedWindow] = []

        for key in keys {
            guard let index = remaining.firstIndex(where: { $0.orderKey == key }) else { continue }
            ordered.append(remaining.remove(at: index))
        }
        ordered.append(contentsOf: remaining)

        guard ordered.map(\.id) != windows.map(\.id) else { return }
        windows = ordered
        if autoSortByWorkspace { sortByWorkspace() }
    }

    /// Groups the queue by workspace, in Mission Control order.
    ///
    /// The selected window closed. On the workspace the user is looking at, the selection moves to
    /// the nearest window left there, or to an empty slot when there is none — never to a window
    /// out of sight on another workspace.
    private func followVanishedSelection(_ vanished: ManagedWindow, previousOrder: [CGWindowID]) {
        guard let space = vanished.spaceID, space == currentSpaceID else { return }
        if let nearest = nearestWindow(on: space, to: vanished.id, in: previousOrder) {
            selectedID = nearest.id
        } else {
            showEmptySlot(for: space)
        }
    }

    /// The window on `space` closest in `order` to where `id` sits, `id` itself excluded.
    func nearestWindow(on space: UInt64, to id: CGWindowID, in order: [CGWindowID],
                       excluding excluded: Set<CGWindowID> = []) -> ManagedWindow? {
        guard let origin = order.firstIndex(of: id) else { return nil }
        return visibleWindows
            .filter { $0.id != id && $0.spaceID == space && !$0.isMinimized && !excluded.contains($0.id) }
            .min { left, right in
                let leftDistance = order.firstIndex(of: left.id).map { abs($0 - origin) } ?? .max
                let rightDistance = order.firstIndex(of: right.id).map { abs($0 - origin) } ?? .max
                return leftDistance < rightDistance
            }
    }

    /// Keeps the empty slot true to the workspace in view: shown whenever it has no windows, in the
    /// place a new window would go, and gone as soon as a window is there.
    /// - Parameter clearingSelection: also drop a selection left on another workspace. Only right
    ///   for arriving on the workspace: during a switch already under way, the selection is the
    ///   window being travelled to.
    func updateEmptySlot(clearingSelection: Bool = false) {
        // Before the first enumeration, or on a fullscreen space, there is nothing to say.
        guard let current = currentSpaceID, spaceOrder.contains(current), !windows.isEmpty else { return }
        let occupied = windows.contains { $0.spaceID == current && !$0.isMinimized }

        if occupied {
            // Arriving from an empty workspace, or a window turning up on this one.
            guard emptySlot != nil else { return }
            emptySlot = nil
            if selectedID == nil {
                selectedID = visibleWindows.first { $0.spaceID == current && !$0.isMinimized }?.id
            }
        } else if emptySlot?.spaceID != current || emptySlot?.beforeID != slotAnchor(for: current) {
            let keep = clearingSelection ? nil : selectedID
            showEmptySlot(for: current)
            if let keep { selectedID = keep }
        }
    }

    /// The first window of a later workspace, which a new window on `space` would go in front of.
    private func slotAnchor(for space: UInt64) -> CGWindowID? {
        guard let rank = spaceOrder.firstIndex(of: space) else { return nil }
        return windows.first { window in
            guard let other = window.spaceID.flatMap({ spaceOrder.firstIndex(of: $0) }) else { return false }
            return other > rank
        }?.id
    }

    /// Leaves the user on a workspace with no windows: nothing selected, and a marker where that
    /// workspace's windows would sit in the queue.
    func showEmptySlot(for space: UInt64) {
        selectedID = nil
        emptySlot = EmptySlot(spaceID: space, beforeID: slotAnchor(for: space))
    }

    /// The marker's place among the windows the strip shows.
    var slotPlacement: StripLayout.SlotPlacement? {
        guard let emptySlot else { return nil }
        guard let before = emptySlot.beforeID, visibleWindows.contains(where: { $0.id == before }) else {
            return .end
        }
        return .before(before)
    }

    /// Records that windows now live on `space` and moves them in the queue to where that workspace's
    /// windows are: after its last one, or, when it had none, just before the first window of a
    /// later workspace. Their order among themselves is kept.
    func relocate(_ ids: [CGWindowID], toSpace space: UInt64) {
        let moving = Set(ids)
        guard !moving.isEmpty, let targetRank = spaceOrder.firstIndex(of: space) else { return }

        var moved = windows.filter { moving.contains($0.id) }
        for index in moved.indices { moved[index].spaceID = space }
        var rest = windows.filter { !moving.contains($0.id) }

        let insertion: Int
        if let last = rest.lastIndex(where: { $0.spaceID == space }) {
            insertion = last + 1
        } else if let later = rest.firstIndex(where: { window in
            window.spaceID.flatMap { spaceOrder.firstIndex(of: $0) }.map { $0 > targetRank } ?? false
        }) {
            insertion = later
        } else {
            insertion = rest.count
        }
        rest.insert(contentsOf: moved, at: insertion)
        windows = rest
        updateEmptySlot()
    }

    /// The sort is stable, so the order the user arranged inside a workspace is kept; windows whose
    /// workspace cannot be resolved (a minimised window has none) collect at the end.
    func sortByWorkspace() {
        let order = spaceOrder
        func rank(_ window: ManagedWindow) -> Int {
            guard let space = window.spaceID,
                  let index = order.firstIndex(of: space)
            else { return Int.max }
            return index
        }

        let sorted = windows.enumerated()
            .sorted { left, right in
                let leftRank = rank(left.element)
                let rightRank = rank(right.element)
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }
            .map(\.element)

        guard sorted.map(\.id) != windows.map(\.id) else { return }
        windows = sorted
    }

    /// Moves a group of windows to an absolute slot within the visible slice, keeping them
    /// together and in their own order — what dragging the collapsed tile does.
    func move(ids: [CGWindowID], toVisiblePosition target: Int) {
        let moving = Set(ids)
        let visible = visibleWindows
        let group = visible.filter { moving.contains($0.id) }
        guard !group.isEmpty, group.count < visible.count else { return }
        noteManualReorder()

        var order = visible.filter { !moving.contains($0.id) }
        let destination = min(max(target, 0), order.count)
        order.insert(contentsOf: group, at: destination)
        for (slot, index) in visibleIndices.enumerated() {
            windows[index] = order[slot]
        }
    }

    /// Moves one window to an absolute slot within the visible slice, leaving windows the current
    /// scope hides where they are.
    func move(id: CGWindowID, toVisiblePosition target: Int) {
        let group = maximizedGroupIDs
        if id == maximizedID, !group.isEmpty {
            move(ids: group, toVisiblePosition: target)
            return
        }
        let indices = visibleIndices
        guard let position = visibleWindows.firstIndex(where: { $0.id == id }),
              indices.indices.contains(target),
              position != target
        else { return }
        noteManualReorder()

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
