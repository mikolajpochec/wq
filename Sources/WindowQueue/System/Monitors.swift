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

    /// The screen holding most of a frame given in Cocoa coordinates.
    static func screen(containing frame: NSRect) -> NSScreen? {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let common = screen.frame.intersection(frame)
            return common.isNull ? 0 : common.width * common.height
        }
        return NSScreen.screens.max { overlap($0) < overlap($1) }.flatMap { overlap($0) > 0 ? $0 : nil }
    }
}
