import AppKit

/// Pictures of windows, for the popup to show what it is naming.
///
/// `CGWindowListCreateImage` is the only way to get at one window's contents without a capture
/// stream, and it needs Screen Recording access — the same grant that fills window titles in.
/// Without it, and for a window on another workspace, there is nothing to show and the popup falls
/// back to text alone.
enum WindowPreview {
    private static var cache: [CGWindowID: (image: NSImage, taken: Date)] = [:]
    /// A window's contents change as the user works; a picture is only reused for a moment.
    private static let maximumAge: TimeInterval = 2

    /// Longest side of the thumbnail handed back, in points.
    static let maximumSize: CGFloat = 420

    static func image(for id: CGWindowID) -> NSImage? {
        if let cached = cache[id], Date().timeIntervalSince(cached.taken) < maximumAge {
            return cached.image
        }
        guard CGPreflightScreenCaptureAccess(),
              let capture = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                    [.boundsIgnoreFraming, .nominalResolution]),
              capture.width > 40, capture.height > 40
        else { return nil }

        let scale = min(maximumSize / CGFloat(capture.width), maximumSize / CGFloat(capture.height), 1)
        let size = NSSize(width: (CGFloat(capture.width) * scale).rounded(),
                          height: (CGFloat(capture.height) * scale).rounded())
        let image = NSImage(cgImage: capture, size: size)
        cache[id] = (image, Date())
        // Pictures of windows are large; keep only a handful of the most recent ones.
        if cache.count > 12 {
            let oldest = cache.min { $0.value.taken < $1.value.taken }?.key
            if let oldest { cache.removeValue(forKey: oldest) }
        }
        return image
    }

    /// One window of a tiled group, as the popup draws it: its picture (if one can be taken) at
    /// its place on screen.
    struct Tile: Identifiable {
        let id: CGWindowID
        let image: NSImage?
        /// Screen frame, top-left origin; only the windows' places relative to each other matter.
        let frame: CGRect
        /// The window the popup is about; the others are only context.
        let isFocus: Bool
    }

    /// Pictures of every window of a tiled group, each where it sits on screen, so the popup can
    /// show the whole layout with the hovered window picked out. Nil when there is nothing to lay
    /// out (fewer than two windows with a known place).
    static func group(_ ids: [CGWindowID], focus: CGWindowID,
                      knownFrames: [CGWindowID: CGRect]) -> [Tile]? {
        guard ids.count > 1, CGPreflightScreenCaptureAccess() else { return nil }
        let live = bounds(of: ids)
        let tiles = ids.compactMap { id -> Tile? in
            guard let frame = live[id] ?? knownFrames[id], frame.width > 40, frame.height > 40
            else { return nil }
            return Tile(id: id, image: image(for: id), frame: frame, isFocus: id == focus)
        }
        guard tiles.count > 1, tiles.contains(where: \.isFocus) else { return nil }
        return tiles
    }

    /// Where the WindowServer has these windows now; the model's frames can lag a relayout.
    private static func bounds(of ids: [CGWindowID]) -> [CGWindowID: CGRect] {
        var pointers = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &pointers, pointers.count, nil),
              let info = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]]
        else { return [:] }
        var result: [CGWindowID: CGRect] = [:]
        for entry in info {
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { continue }
            result[CGWindowID(number.uint32Value)] = rect
        }
        return result
    }

    static func forget(_ id: CGWindowID) {
        cache.removeValue(forKey: id)
    }
}
