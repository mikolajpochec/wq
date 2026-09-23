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
        if cache.count > 8 {
            let oldest = cache.min { $0.value.taken < $1.value.taken }?.key
            if let oldest { cache.removeValue(forKey: oldest) }
        }
        return image
    }

    static func forget(_ id: CGWindowID) {
        cache.removeValue(forKey: id)
    }
}
