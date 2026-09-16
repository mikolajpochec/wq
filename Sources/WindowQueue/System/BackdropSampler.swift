import AppKit
import ScreenCaptureKit

/// Measures how light the screen is behind a small area, so text drawn there can pick a colour
/// that stays readable.
///
/// With Screen Recording access this reads what is actually on screen underneath, leaving
/// WindowQueue's own windows out. Without it only the desktop picture is known, which is still the
/// right answer on an empty desktop and a reasonable guess elsewhere.
final class BackdropSampler {
    private var shareableContent: SCShareableContent?
    private var contentFetchedAt = Date.distantPast
    private var wallpapers: [URL: CGImage] = [:]

    /// Calls back on the main queue with a relative luminance from 0 (black) to 1 (white), or nil
    /// when nothing could be read.
    func luminance(behind rect: NSRect, on screen: NSScreen, completion: @escaping (CGFloat?) -> Void) {
        if CGPreflightScreenCaptureAccess() {
            captureLuminance(behind: rect, on: screen) { [weak self] value in
                DispatchQueue.main.async {
                    completion(value ?? self?.wallpaperLuminance(behind: rect, on: screen))
                }
            }
        } else {
            completion(wallpaperLuminance(behind: rect, on: screen))
        }
    }

    // MARK: - Screen contents

    private func captureLuminance(behind rect: NSRect, on screen: NSScreen,
                                  completion: @escaping (CGFloat?) -> Void) {
        content { content in
            guard let content,
                  let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return completion(nil) }

            let ownPID = ProcessInfo.processInfo.processIdentifier
            let own = content.applications.filter { $0.processID == ownPID }
            let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])

            let configuration = SCStreamConfiguration()
            // Display-relative, top-left origin.
            configuration.sourceRect = CGRect(x: rect.minX - screen.frame.minX,
                                              y: screen.frame.maxY - rect.maxY,
                                              width: rect.width, height: rect.height)
            configuration.width = 8
            configuration.height = 8
            configuration.showsCursor = false

            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, _ in
                completion(image.flatMap(Self.averageLuminance))
            }
        }
    }

    /// The window list is slow to fetch and only needed for the display and our own app, so it is
    /// reused for a while.
    private func content(_ completion: @escaping (SCShareableContent?) -> Void) {
        if let shareableContent, Date().timeIntervalSince(contentFetchedAt) < 30 {
            return completion(shareableContent)
        }
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { [weak self] content, _ in
            DispatchQueue.main.async {
                self?.shareableContent = content
                self?.contentFetchedAt = Date()
                completion(content)
            }
        }
    }

    // MARK: - Desktop picture

    private func wallpaperLuminance(behind rect: NSRect, on screen: NSScreen) -> CGFloat? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let image = wallpaper(at: url)
        else { return nil }

        // The desktop picture fills the screen, cropped to keep its aspect ratio.
        let frame = screen.frame
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = max(imageSize.width / frame.width, imageSize.height / frame.height)
        let shown = CGSize(width: frame.width * scale, height: frame.height * scale)
        let inset = CGPoint(x: (imageSize.width - shown.width) / 2, y: (imageSize.height - shown.height) / 2)
        let crop = CGRect(x: inset.x + (rect.minX - frame.minX) * scale,
                          y: inset.y + (frame.maxY - rect.maxY) * scale,
                          width: rect.width * scale, height: rect.height * scale)
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard !crop.isNull, let region = image.cropping(to: crop) else { return nil }
        return Self.averageLuminance(of: region)
    }

    private func wallpaper(at url: URL) -> CGImage? {
        if let cached = wallpapers[url] { return cached }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              // A thumbnail is plenty for an average, and full-size desktop pictures are huge.
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary)
        else { return nil }
        wallpapers = [url: image]
        return image
    }

    // MARK: - Maths

    private static func averageLuminance(of image: CGImage) -> CGFloat? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let red = CGFloat(pixel[0]) / 255, green = CGFloat(pixel[1]) / 255, blue = CGFloat(pixel[2]) / 255
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
