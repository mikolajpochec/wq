import AppKit

/// The connected displays, numbered left to right the way the monitor shortcuts count them.
enum Monitors {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Screens left to right (top to bottom where they are stacked).
    static var orderedScreens: [NSScreen] {
        NSScreen.screens.sorted { lhs, rhs in
            lhs.frame.minX != rhs.frame.minX ? lhs.frame.minX < rhs.frame.minX : lhs.frame.maxY > rhs.frame.maxY
        }
    }

    static func current() -> [WindowQueueModel.Monitor] {
        orderedScreens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            let uuid = SpacesBridge.displayUUID(of: screen)
            return WindowQueueModel.Monitor(id: id, frame: CGDisplayBounds(id),
                                            spaceIDs: uuid.map { SpacesBridge.shared.userSpaceIDs(onDisplay: $0) } ?? [],
                                            shownSpaceID: uuid.flatMap { SpacesBridge.shared.shownSpaceID(onDisplay: $0) })
        }
    }

    /// The screen's visible frame less a menu bar it does not account for. A secondary display
    /// can report a visible frame reaching its very top while it shows a menu bar all the same
    /// (seen on macOS 27 with separate Spaces), and apps keep their windows below that bar; a
    /// layout reaching under it would leave every window a little short of filling its room.
    static func usableFrame(of screen: NSScreen) -> NSRect {
        var frame = screen.visibleFrame
        guard let bar = menuBarHeight(on: screen) else { return frame }
        // Apps keep a window's top a point under the bar, as the visible frame does where it is right.
        let top = screen.frame.maxY - bar - 1
        if frame.maxY > top { frame.size.height = max(0, top - frame.minY) }
        return frame
    }

    private static var menuBars: (at: Date, bars: [CGRect])?

    /// The height of the menu bar on show at the top of that screen, if there is one.
    private static func menuBarHeight(on screen: NSScreen) -> CGFloat? {
        if menuBars == nil || Date().timeIntervalSince(menuBars!.at) > 1 {
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
            let level = Int(CGWindowLevelForKey(.mainMenuWindow))
            let bars = list.compactMap { info -> CGRect? in
                guard info[kCGWindowOwnerName as String] as? String == "Window Server",
                      info[kCGWindowLayer as String] as? Int == level,
                      let bounds = info[kCGWindowBounds as String] as? [String: Any]
                else { return nil }
                return CGRect(dictionaryRepresentation: bounds as CFDictionary)
            }
            menuBars = (Date(), bars)
        }
        // Window bounds count from the top of the main screen, downwards.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let top = primaryHeight - screen.frame.maxY
        let bar = menuBars?.bars.first { bar in
            abs(bar.minY - top) < 1 && abs(bar.minX - screen.frame.minX) < 1
                && abs(bar.width - screen.frame.width) < 1 && bar.height > 0 && bar.height < 80
        }
        return bar?.height
    }

    /// The screen holding most of a frame given in Cocoa coordinates.
    static func screen(containing frame: NSRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let common = screen.frame.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
    }
}
