import AppKit

/// What the tracker needs from the outside world: windows, their frames, the mouse and time. The
/// app answers over AX; tests answer with a simulated desktop.
protocol TiledResizeHost: AnyObject {
    /// The tiled group holding the window: its id and every member, the window included.
    func tiledGroup(of id: CGWindowID) -> (id: Int, members: [CGWindowID])?
    /// The window's frame right now, in Cocoa screen coordinates.
    func frame(of id: CGWindowID) -> NSRect?
    /// The frame the tiler last asked of the window, in Cocoa screen coordinates.
    func placedFrame(of id: CGWindowID) -> NSRect?
    /// The window's room in the layout the tiler just made (the window may be smaller, centred
    /// in it), in Cocoa screen coordinates.
    func layoutRoom(of id: CGWindowID) -> NSRect?
    /// Sets the window's frame once; returns where it landed.
    @discardableResult func nudge(_ id: CGWindowID, to frame: NSRect) -> NSRect?
    /// The tiled group is no more: its windows are free.
    func breakTiling(groupID: Int)
    var isMouseDown: Bool { get }
    /// When the left mouse button last went up.
    var mouseReleasedAt: Date { get }
    var now: Date { get }
    func after(_ delay: TimeInterval, _ block: @escaping () -> Void)
    var innerGap: CGFloat { get }
    func note(_ text: String)
}

/// Keeps a tiled layout together while the user resizes its windows by hand, and breaks it when
/// they move one.
///
/// Two frames are kept per window:
/// - its *cell*: its place in the layout, exact, with exact gaps to its neighbours, so dividers
///   that line up really do. Apps do not always fill their cell (a terminal keeps to whole rows of
///   text, an app has a smallest size), but that never shifts the cell;
/// - its *resting frame*: where the window really is, to tell a change from a notification about
///   nothing.
///
/// A frame change of a tiled window, measured against its resting frame:
/// - the same frame: nothing (apps report moves for focus and the like);
/// - a resize with the mouse button held: a drag. It lasts until the button goes up. Each step
///   moves the dragged window's cell by as much as its edges moved, the cells of the windows
///   sharing those edges follow (`TiledResize.follow`), and each follower is put in its cell.
///   Once the button is up, a follower that would not fit its cell (an app's smallest size)
///   holds the divider back, and everyone's cell and resting frame are settled;
/// - a resize without the mouse: the app's own doing (a terminal rounding to whole rows): only
///   its resting frame changes;
/// - a move: the user took the window out, and the layout is broken.
final class TiledResizeTracker {
    weak var host: TiledResizeHost?

    /// How long after the tiler placed them the windows' frames are read as their resting places.
    var recordDelay: TimeInterval = 2
    /// How long a follower's own frame changes are taken as settling after it was last asked.
    var followGrace: TimeInterval = 1.5
    /// How long after the drag ends the followers' landed frames are read.
    var settleDelay: TimeInterval = 0.6
    var mousePollInterval: TimeInterval = 0.05
    /// How long after the button went up a frame change still counts as the end of a drag: apps
    /// can report the last steps late (a quick flick, a busy terminal).
    var lateDragReport: TimeInterval = 0.5
    /// Cells are exact, so neighbours are found with almost no slack.
    private let cellTolerance: CGFloat = 2

    /// Where each tiled window really rests; anything else is the user (or the app) changing it.
    private(set) var restingFrames: [CGWindowID: NSRect] = [:]
    /// Each tiled window's place in the layout.
    private(set) var cells: [CGWindowID: NSRect] = [:]
    /// Followers of a drag, until when their changes are ours.
    private var followingUntil: [CGWindowID: Date] = [:]
    /// When the drag a follower followed ended. A button released after that is a new gesture: a
    /// change to the follower is then the user's, not the tail of ours.
    private var followEnded: [CGWindowID: Date] = [:]
    private var sessions: [Int: Session] = [:]
    /// The settling of a drag just ended, per group: run when due, or straight away when the next
    /// drag in the group begins (it must start from settled cells).
    private var pendingSettle: [Int: (CGWindowID?) -> Void] = [:]
    /// Bumped whenever a layout is applied or broken, so a delayed step of an older one does nothing.
    private var generation: [Int: Int] = [:]

    /// One drag of a tiled window's edge.
    struct Session {
        let id: CGWindowID
        let groupID: Int
        let began: Date
        /// Whether the button was down when the drag began; a drag only reported after the button
        /// went up is over already.
        let heldAtStart: Bool
        /// Where the dragged window really was when the drag began, and its cell.
        let start: NSRect
        let startCell: NSRect
        /// Where it really is now.
        var latest: NSRect
        /// The mates' cells when the drag began.
        let mates: [CGWindowID: NSRect]
        /// The cells last asked of the mates.
        var asked: [CGWindowID: NSRect] = [:]
        /// A cell the dragged window was held back to, overriding what its frame says.
        var heldCell: NSRect?

        /// The dragged window's cell now: moved by exactly as much as its edges moved.
        var cell: NSRect {
            if let heldCell { return heldCell }
            let minX = startCell.minX + (latest.minX - start.minX)
            let maxX = startCell.maxX + (latest.maxX - start.maxX)
            let minY = startCell.minY + (latest.minY - start.minY)
            let maxY = startCell.maxY + (latest.maxY - start.maxY)
            return NSRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        }
    }

    var isDragging: Bool { !sessions.isEmpty }
    func session(of groupID: Int) -> Session? { sessions[groupID] }

    // MARK: Layout lifecycle

    /// The tiler has just laid these windows out: their cells are what it asked for, and their
    /// resting frames are read once its own corrections are done.
    func layoutApplied(_ ids: [CGWindowID]) {
        guard let host else { return }
        for id in ids {
            restingFrames[id] = nil
            followingUntil[id] = nil
            cells[id] = host.layoutRoom(of: id) ?? host.placedFrame(of: id) ?? host.frame(of: id)
        }
        let groupIDs = Set(ids.compactMap { host.tiledGroup(of: $0)?.id })
        for groupID in groupIDs {
            sessions[groupID] = nil
            pendingSettle[groupID] = nil
            generation[groupID, default: 0] += 1
        }
        let stamp = groupIDs.map { ($0, generation[$0] ?? 0) }
        let appliedAt = host.now
        host.after(recordDelay) { [weak self] in
            guard let self, let host = self.host else { return }
            guard stamp.allSatisfy({ self.generation[$0.0] == $0.1 }) else { return }
            // With the mouse button down the user may already be dragging one of them: a frame read
            // now would be a moment of that drag, and the drag would seem to start from there. The
            // frame the tiler asked for is where they rest.
            let mouseDown = host.isMouseDown
            for id in ids {
                guard let group = host.tiledGroup(of: id), self.sessions[group.id] == nil else { continue }
                let frame = mouseDown ? host.placedFrame(of: id) ?? host.frame(of: id) : host.frame(of: id)
                if let frame { self.restingFrames[id] = frame }
            }
            if !mouseDown, host.mouseReleasedAt > appliedAt { self.settleEarlyDrags(ids) }
        }
    }

    /// A drag made and finished while the tiler's own changes were still being ignored left no
    /// trace but the frame it ended at. The window resized furthest from its cell is taken as
    /// dragged, and the layout settles around it as after any drag.
    private func settleEarlyDrags(_ ids: [CGWindowID]) {
        guard let host else { return }
        var byGroup: [Int: (id: CGWindowID, cell: NSRect, now: NSRect, change: CGFloat)] = [:]
        for id in ids {
            guard let group = host.tiledGroup(of: id), let cell = cells[id], let now = host.frame(of: id),
                  TiledFrameChange.between(cell, now) == .resized
            else { continue }
            let change = abs(now.width - cell.width) + abs(now.height - cell.height)
            if change > (byGroup[group.id]?.change ?? 0) { byGroup[group.id] = (id, cell, now, change) }
        }
        for (groupID, dragged) in byGroup {
            guard let group = host.tiledGroup(of: dragged.id) else { continue }
            host.note("resized tiled window \(dragged.id) while the layout settled, from \(dragged.cell)")
            sessions[groupID] = Session(id: dragged.id, groupID: groupID, began: host.now, heldAtStart: false,
                                        start: dragged.cell, startCell: dragged.cell, latest: dragged.now,
                                        mates: mateCells(of: dragged.id, in: group.members))
            endDrag(groupID)
        }
    }

    /// These windows left their layout (or it was broken): nothing about them is kept.
    func forget(_ ids: [CGWindowID]) {
        for id in ids {
            restingFrames[id] = nil
            followingUntil[id] = nil
            followEnded[id] = nil
            cells[id] = nil
        }
    }

    func groupBroken(_ groupID: Int, members: [CGWindowID]) {
        sessions[groupID] = nil
        pendingSettle[groupID] = nil
        generation[groupID, default: 0] += 1
        forget(members)
    }

    /// A window was replaced by another with a new id (an app recreating it).
    func renamed(_ old: CGWindowID, to new: CGWindowID) {
        if let frame = restingFrames.removeValue(forKey: old) { restingFrames[new] = frame }
        if let cell = cells.removeValue(forKey: old) { cells[new] = cell }
    }

    private func cell(of id: CGWindowID) -> NSRect? {
        cells[id] ?? host?.placedFrame(of: id) ?? host?.frame(of: id)
    }

    private func mateCells(of id: CGWindowID, in members: [CGWindowID]) -> [CGWindowID: NSRect] {
        var mates: [CGWindowID: NSRect] = [:]
        for mate in members where mate != id {
            if let cell = cell(of: mate) { mates[mate] = cell }
        }
        return mates
    }

    // MARK: Frame changes

    func frameChanged(_ id: CGWindowID) {
        guard let host, let group = host.tiledGroup(of: id), var now = host.frame(of: id) else { return }
        if let session = sessions[group.id], id != session.id,
           host.mouseReleasedAt > session.began || !session.heldAtStart {
            // The button went up since the drag began (too briefly for the poll to see): that drag
            // is over, and this may be the next one.
            endDrag(group.id)
        }
        // A drag under way: the dragged window leads, its mates are following it (their changes are
        // ours), and everything is measured from where the windows were when the drag began.
        if var session = sessions[group.id] {
            guard id == session.id else { return }
            if TiledFrameChange.between(session.start, now, tolerance: TiledFrameChange.snapTolerance,
                                        sizeTolerance: 1) == .moved {
                host.note("tiling broken by moving window \(id) from \(session.start) to \(now) while resizing")
                breakTiling(group.id, members: group.members)
                return
            }
            session.latest = now
            sessions[group.id] = session
            follow(group.id)
            return
        }
        let mouseDown = host.isMouseDown
        // A window that followed a neighbour's resize a moment ago: still settling, and ours. That
        // drag ended with the mouse button going up, so with the button down again it is the user,
        // grabbing this window next.
        if let until = followingUntil[id], host.now < until, !mouseDown,
           host.mouseReleasedAt <= followEnded[id] ?? .distantFuture {
            restingFrames[id] = now
            return
        }
        followingUntil[id] = nil
        // With the user at the mouse even a nudge of an edge is a resize: the neighbours have to
        // follow it, or the next drag starts off.
        let userDrag = mouseDown || host.now.timeIntervalSince(host.mouseReleasedAt) < lateDragReport
        // A new drag starts from the last one's settled cells; this window is already being
        // dragged (or just was), so where it is now is not where it rests.
        if userDrag, pendingSettle[group.id] != nil {
            flushSettle(group.id, grabbed: id)
            // The settling may have moved this very window.
            guard let frame = host.frame(of: id), host.tiledGroup(of: id) != nil else { return }
            now = frame
        }
        // Before its resting place is read, its cell stands in for it.
        let resting = restingFrames[id] ?? cell(of: id) ?? now
        // Under the mouse a shift of a few points at the same size is not a move yet: a terminal
        // dragged by its left edge shifts like that before it gives up a whole column of text. A
        // real move goes past the slack within moments.
        switch TiledFrameChange.between(resting, now, tolerance: userDrag ? TiledFrameChange.snapTolerance : 4,
                                        sizeTolerance: userDrag ? 1 : 4) {
        case .unchanged:
            restingFrames[id] = restingFrames[id] ?? resting
        case .resized where userDrag:
            let startCell = cell(of: id) ?? resting
            let mates = mateCells(of: id, in: group.members)
            host.note("resizing tiled window \(id) from \(resting) cell \(startCell)\(mouseDown ? "" : " (reported late)")")
            sessions[group.id] = Session(id: id, groupID: group.id, began: host.now, heldAtStart: mouseDown,
                                         start: resting, startCell: startCell, latest: now, mates: mates)
            follow(group.id)
            watchForMouseUp(group.id)
        case .resized:
            // The app changed its own size (a terminal rounding to whole rows, say): no one is
            // dragging anything, so that is simply where it is now. Its cell stays.
            restingFrames[id] = now
        case .moved:
            host.note("tiling broken by moving window \(id) from \(resting) to \(now)")
            breakTiling(group.id, members: group.members)
        }
    }

    private func breakTiling(_ groupID: Int, members: [CGWindowID]) {
        groupBroken(groupID, members: members)
        host?.breakTiling(groupID: groupID)
    }

    // MARK: Following

    /// Moves the mates' cells along the dragged window's moved edges and puts each mate in its cell.
    /// Always worked out from the cells at the start of the drag.
    private func follow(_ groupID: Int, force: Bool = false) {
        guard let host, var session = sessions[groupID] else { return }
        let moves = TiledResize.follow(from: session.startCell, to: session.cell, others: session.mates,
                                       gap: host.innerGap, tolerance: cellTolerance)
        let until = host.now.addingTimeInterval(followGrace)
        for (mate, start) in session.mates.sorted(by: { $0.key < $1.key }) {
            // One that followed earlier in the drag but no longer has to goes back where it began.
            guard let target = moves[mate] ?? (session.asked[mate] != nil ? start : nil) else { continue }
            followingUntil[mate] = until
            followEnded[mate] = nil
            guard force || session.asked[mate] != target else { continue }
            session.asked[mate] = target
            place(mate, in: target, start: start)
        }
        sessions[groupID] = session
    }

    /// Puts a window in its cell. One whose app will not take the cell's size keeps its own,
    /// against the cell's far edge: the one the drag did not move.
    @discardableResult
    private func place(_ id: CGWindowID, in cell: NSRect, start: NSRect) -> NSRect? {
        guard let host, let landed = host.nudge(id, to: cell) else { return nil }
        guard abs(landed.width - cell.width) > 1 || abs(landed.height - cell.height) > 1 else { return landed }
        let anchored = TiledResize.anchor(asked: cell, landed: landed.size, start: start)
        guard !Self.matches(anchored, landed) else { return landed }
        return host.nudge(id, to: anchored) ?? landed
    }

    /// The drag lasts as long as the mouse button is held; a pause mid-drag does not end it.
    private func watchForMouseUp(_ groupID: Int) {
        host?.after(mousePollInterval) { [weak self] in
            guard let self, let host = self.host, let session = self.sessions[groupID] else { return }
            if session.heldAtStart, host.isMouseDown, host.mouseReleasedAt <= session.began {
                self.watchForMouseUp(groupID)
                return
            }
            self.endDrag(groupID)
        }
    }

    /// The drag is over: the mates are asked once more (an app busy with the drag may have missed a
    /// step), the cells are kept, and a moment later the layout settles.
    private func endDrag(_ groupID: Int) {
        guard let host, var session = sessions[groupID] else { return }
        if let now = host.frame(of: session.id) { session.latest = now }
        host.note("drag of tiled window \(session.id) ended at \(session.latest)")
        sessions[groupID] = session
        follow(groupID, force: true)
        session = sessions[groupID] ?? session
        sessions[groupID] = nil
        // Until the settling, these are everyone's places, so a drag started straight after this
        // one begins from here, not from before this one.
        cells[session.id] = session.cell
        restingFrames[session.id] = session.latest
        for (mate, cell) in session.asked {
            cells[mate] = cell
            followEnded[mate] = host.now
            if let frame = host.frame(of: mate) { restingFrames[mate] = frame }
        }
        let stamp = generation[groupID] ?? 0
        var ran = false
        let settle: (CGWindowID?) -> Void = { [weak self] grabbed in
            guard !ran else { return }
            ran = true
            guard let self else { return }
            self.pendingSettle[groupID] = nil
            guard self.generation[groupID] == stamp, self.host?.tiledGroup(of: session.id)?.id == groupID
            else { return }
            self.settle(session, grabbed: grabbed)
        }
        pendingSettle[groupID] = settle
        host.after(settleDelay) { settle(nil) }
    }

    /// Runs the group's pending settling now, before a new drag reads the cells.
    private func flushSettle(_ groupID: Int, grabbed: CGWindowID) {
        pendingSettle[groupID]?(grabbed)
    }

    /// A follower that would not fit its cell (an app's smallest size) holds the divider back: the
    /// dragged window's cell stops where that follower's window ends, and the other followers come
    /// back with it. Then everyone's resting frame is read.
    /// - Parameter grabbed: a window the user has already started dragging again, left alone.
    private func settle(_ ended: Session, grabbed: CGWindowID?) {
        guard let host else { return }
        var session = ended
        let gap = host.innerGap
        // How far each mate really reaches: its cell, or more where its app would not shrink.
        var reach: [(start: NSRect, now: NSRect)] = []
        for (mate, start) in session.mates {
            let cell = session.asked[mate] ?? start
            guard let frame = host.frame(of: mate) else { continue }
            let tooBig = frame.width > cell.width + 1 || frame.height > cell.height + 1
            reach.append((start: start, now: tooBig ? frame : cell))
        }
        let cell = session.cell
        let clamped = TiledResize.clamp(cell, start: session.startCell, mates: reach, gap: gap,
                                        tolerance: cellTolerance)
        var heldBack = false
        if !Self.matches(clamped, cell) {
            heldBack = true
            session.heldCell = clamped
            followingUntil[session.id] = host.now.addingTimeInterval(followGrace)
            place(session.id, in: clamped, start: session.startCell)
            sessions[session.groupID] = session
            follow(session.groupID, force: true)
            session = sessions[session.groupID] ?? session
            sessions[session.groupID] = nil
            cells[session.id] = clamped
            for (mate, cell) in session.asked { cells[mate] = cell }
            // A button released after this is the user again, not the tail of the hold-back.
            for id in [session.id] + Array(session.asked.keys) { followEnded[id] = host.now }
        }
        // A window the user has already grabbed again is mid-drag: where it is now is not where it
        // rests, unless the hold-back just put it somewhere, which is then where the drag starts.
        let movedByHoldBack = heldBack ? Set([session.id] + Array(session.asked.keys)) : []
        for id in [session.id] + Array(session.mates.keys) where id != grabbed || movedByHoldBack.contains(id) {
            if let frame = host.frame(of: id) { restingFrames[id] = frame }
        }
        let summary = session.mates.keys.sorted().map { "\($0)=\(cells[$0].map { "\($0)" } ?? "?")" }
        host.note("resize of tiled window \(session.id) settled: \(session.id)=\(cells[session.id].map { "\($0)" } ?? "?")"
                  + (heldBack ? " (held back)" : "") + " " + summary.joined(separator: " "))
    }

    private static func matches(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1
            && abs(a.width - b.width) <= 1 && abs(a.height - b.height) <= 1
    }
}
