import CoreGraphics

/// Works out how to make every window visible while changing as little as possible.
///
/// Tiling throws the windows' own frames away; decluttering keeps them as the starting point. The
/// area is cut in two again and again — a vertical or horizontal line, wherever it crosses the
/// windows least — until every window has a cell of its own. A window that already fits its cell
/// stays exactly where it is, one that pokes out is slid back in, and only one that is larger than
/// its cell is made smaller, and then only along the side that does not fit.
enum Declutter {
    /// - Parameters:
    ///   - frames: the windows' current frames, all in one coordinate space.
    ///   - area: the room to keep them in, in that same space.
    ///   - gap: room to leave between two windows that had to be pulled apart.
    ///   - minimumSize: the smallest a window is made, room permitting.
    /// - Returns: a frame for each window, in the same order; none of them overlap.
    static func arrange(_ frames: [CGRect], in area: CGRect, gap: CGFloat = 0,
                        minimumSize: CGSize = CGSize(width: 320, height: 220)) -> [CGRect] {
        guard !frames.isEmpty, area.width > 0, area.height > 0 else { return frames }
        let fitted = frames.map { fit($0, into: area) }
        // Nothing covers anything: whatever needed pulling on screen has been, and the rest stays.
        guard overlaps(fitted) else { return fitted }
        var out = fitted
        place(Array(fitted.indices), frames: fitted, in: area, gap: gap, minimumSize: minimumSize, into: &out)
        return out
    }

    /// Whether any two frames cover a visible part of each other; touching edges do not count.
    static func overlaps(_ frames: [CGRect]) -> Bool {
        for i in frames.indices {
            for j in frames.indices where j > i {
                let common = frames[i].intersection(frames[j])
                if !common.isNull, common.width > 1, common.height > 1 { return true }
            }
        }
        return false
    }

    /// The frame moved the least it takes to lie inside the cell, shrunk only where it is too big.
    static func fit(_ frame: CGRect, into cell: CGRect) -> CGRect {
        let width = min(frame.width, cell.width)
        let height = min(frame.height, cell.height)
        let x = min(max(frame.minX, cell.minX), cell.maxX - width)
        let y = min(max(frame.minY, cell.minY), cell.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private enum Axis { case x, y }

    private static func place(_ indices: [Int], frames: [CGRect], in cell: CGRect, gap: CGFloat,
                              minimumSize: CGSize, into out: inout [CGRect]) {
        guard indices.count > 1 else {
            if let only = indices.first { out[only] = fit(frames[only], into: cell) }
            return
        }
        // Cells that already hold their windows without a clash need no cutting at all.
        if !overlaps(indices.map { fit(frames[$0], into: cell) }) {
            for index in indices { out[index] = fit(frames[index], into: cell) }
            return
        }
        guard let split = bestSplit(indices, frames: frames, in: cell, gap: gap, minimumSize: minimumSize)
        else { return }
        let (first, second) = halves(of: cell, along: split.axis, at: split.line, gap: gap)
        place(split.before, frames: frames, in: first, gap: gap, minimumSize: minimumSize, into: &out)
        place(split.after, frames: frames, in: second, gap: gap, minimumSize: minimumSize, into: &out)
    }

    /// The two cells either side of a cut, a gap apart.
    private static func halves(of cell: CGRect, along axis: Axis, at line: CGFloat,
                               gap: CGFloat) -> (CGRect, CGRect) {
        let half = gap / 2
        switch axis {
        case .x:
            return (CGRect(x: cell.minX, y: cell.minY, width: line - half - cell.minX, height: cell.height),
                    CGRect(x: line + half, y: cell.minY, width: cell.maxX - line - half, height: cell.height))
        case .y:
            return (CGRect(x: cell.minX, y: cell.minY, width: cell.width, height: line - half - cell.minY),
                    CGRect(x: cell.minX, y: line + half, width: cell.width, height: cell.maxY - line - half))
        }
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : max(0, rect.width) * max(0, rect.height)
    }

    /// How much of the screen changes for a window going from one frame to the other: what it
    /// leaves plus what it newly covers. Moving and shrinking are measured alike.
    private static func change(_ from: CGRect, _ to: CGRect) -> CGFloat {
        area(from) + area(to) - 2 * area(from.intersection(to))
    }

    private struct Split {
        let axis: Axis
        let line: CGFloat
        let before: [Int]
        let after: [Int]
        let cost: CGFloat
    }

    /// The cut, along either axis and between any two neighbours in order, that disturbs the
    /// windows least. Two things are weighed: how much each window changes to fit its side, and how
    /// crowded each side is left — windows wanting more room than their side has will have to share
    /// it later. The crowding term is lowest when each side gets room in proportion to what its
    /// windows want, which is what spreads a pile of maximized windows out evenly.
    private static func bestSplit(_ indices: [Int], frames: [CGRect], in cell: CGRect, gap: CGFloat,
                                  minimumSize: CGSize) -> Split? {
        var best: Split?
        let wanted = Dictionary(uniqueKeysWithValues: indices.map { ($0, area(fit(frames[$0], into: cell))) })
        for axis in [Axis.x, .y] {
            let lower = { (r: CGRect) in axis == .x ? r.minX : r.minY }
            let upper = { (r: CGRect) in axis == .x ? r.maxX : r.maxY }
            let start = lower(cell), end = upper(cell)
            let sorted = indices.sorted {
                let a = frames[$0], b = frames[$1]
                return (lower(a) + upper(a), $0) < (lower(b) + upper(b), $1)
            }
            let count = sorted.count
            // Room for everyone, as far as the cell allows it.
            let smallest = min(axis == .x ? minimumSize.width : minimumSize.height,
                               (end - start - gap * CGFloat(count - 1)) / CGFloat(count))
            for k in 1..<count {
                let before = Array(sorted[..<k]), after = Array(sorted[k...])
                let low = start + (smallest + gap) * CGFloat(k) - gap / 2
                // Equal in exact arithmetic when the cell is only just big enough; keep rounding out.
                let high = max(low, end - (smallest + gap) * CGFloat(count - k) + gap / 2)
                let wantBefore = before.reduce(0) { $0 + wanted[$1]! }
                let wantAfter = after.reduce(0) { $0 + wanted[$1]! }
                // Window edges, where a window stops having to move; the share in proportion to what
                // each side wants; and a spread between the bounds for everything in between.
                var lines = (0...16).map { low + (high - low) * CGFloat($0) / 16 }
                lines.append(start + (end - start) * wantBefore / max(wantBefore + wantAfter, 1))
                lines += before.map { upper(frames[$0]) + gap / 2 }
                lines += after.map { lower(frames[$0]) - gap / 2 }
                for candidate in lines {
                    let line = min(max(candidate, low), high)
                    let (first, second) = halves(of: cell, along: axis, at: line, gap: gap)
                    var cost: CGFloat = 0
                    for (side, members, want) in [(first, before, wantBefore), (second, after, wantAfter)] {
                        for index in members { cost += change(frames[index], fit(frames[index], into: side)) }
                        let room = max(area(side), 1)
                        let crowding = max(0, want - room)
                        cost += crowding * crowding / room
                    }
                    if best == nil || cost < best!.cost - 0.5 {
                        best = Split(axis: axis, line: line, before: before, after: after, cost: cost)
                    }
                }
            }
        }
        return best
    }
}
