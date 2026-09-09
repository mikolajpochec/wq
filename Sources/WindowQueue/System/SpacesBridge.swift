import AppKit

/// Thin facade over the private SkyLight (CGS) Spaces API.
///
/// macOS exposes no public way to read or switch Mission Control Spaces, so every symbol here is
/// resolved at runtime with `dlsym`. Nothing else in the app touches these symbols: if a future
/// macOS release removes them, `isAvailable` turns false and this file is the only thing to fix.
final class SpacesBridge {
    static let shared = SpacesBridge()

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    /// `kCGSSpaceIncludesCurrent | kCGSSpaceIncludesOthers | kCGSSpaceIncludesUser`
    private static let allSpacesMask: Int32 = 7
    /// Space "type" value for a normal user desktop; 4 is a fullscreen space.
    private static let userSpaceType = 0

    private let connectionID: Int32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let setCurrentSpace: SetCurrentSpaceFn?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        let mainConnection = symbol("CGSMainConnectionID", as: MainConnectionIDFn.self)
        connectionID = mainConnection?() ?? 0
        copyManagedDisplaySpaces = symbol("CGSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self)
        copySpacesForWindows = symbol("CGSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
        setCurrentSpace = symbol("CGSManagedDisplaySetCurrentSpace", as: SetCurrentSpaceFn.self)
    }

    var isAvailable: Bool {
        connectionID != 0 && copyManagedDisplaySpaces != nil
    }

    // MARK: - Topology

    private struct DisplaySpaces {
        let identifier: String
        /// User desktops only, in Mission Control order.
        let userSpaces: [(id: UInt64, uuid: String)]
        let currentSpaceID: UInt64?
    }

    private func displays() -> [DisplaySpaces] {
        guard let copyManagedDisplaySpaces,
              let raw = copyManagedDisplaySpaces(connectionID)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        return raw.compactMap { display in
            guard let identifier = display["Display Identifier"] as? String else { return nil }
            let spaces = (display["Spaces"] as? [[String: Any]]) ?? []
            let userSpaces: [(UInt64, String)] = spaces.compactMap { space in
                guard (space["type"] as? Int) == Self.userSpaceType,
                      let id = (space["id64"] as? NSNumber)?.uint64Value
                else { return nil }
                return (id, (space["uuid"] as? String) ?? "")
            }
            let current = (display["Current Space"] as? [String: Any])
                .flatMap { ($0["id64"] as? NSNumber)?.uint64Value }
            return DisplaySpaces(identifier: identifier, userSpaces: userSpaces, currentSpaceID: current)
        }
    }

    /// The display the strip lives on: the one matching the main screen, else the first.
    private func primaryDisplay() -> DisplaySpaces? {
        let all = displays()
        guard all.count > 1, let uuid = Self.mainScreenDisplayUUID() else { return all.first }
        return all.first { $0.identifier == uuid } ?? all.first
    }

    private static func mainScreenDisplayUUID() -> String? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    // MARK: - Queries

    var currentSpaceID: UInt64? {
        primaryDisplay()?.currentSpaceID
    }

    /// 1-based index of the active desktop, or nil when a fullscreen space is active.
    var currentSpaceIndex: Int? {
        guard let display = primaryDisplay(), let current = display.currentSpaceID else { return nil }
        guard let index = display.userSpaces.firstIndex(where: { $0.id == current }) else { return nil }
        return index + 1
    }

    /// Space id of the 1-based desktop index on the primary display.
    func spaceID(atIndex index: Int) -> UInt64? {
        guard let display = primaryDisplay() else { return nil }
        let position = index - 1
        guard display.userSpaces.indices.contains(position) else { return nil }
        return display.userSpaces[position].id
    }

    var spaceCount: Int {
        primaryDisplay()?.userSpaces.count ?? 0
    }

    /// Resolves which Space each of the given windows belongs to.
    func spaces(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: UInt64] {
        guard let copySpacesForWindows, !windowIDs.isEmpty else { return [:] }
        var result: [CGWindowID: UInt64] = [:]
        for id in windowIDs {
            let argument = [NSNumber(value: id)] as CFArray
            guard let spaces = copySpacesForWindows(connectionID, Self.allSpacesMask, argument)?
                .takeRetainedValue() as? [NSNumber],
                let first = spaces.first
            else { continue }
            result[id] = first.uint64Value
        }
        return result
    }

    // MARK: - Switching

    @discardableResult
    func switchToSpace(index: Int) -> Bool {
        guard let setCurrentSpace, let display = primaryDisplay() else { return false }
        let position = index - 1
        guard display.userSpaces.indices.contains(position) else { return false }
        setCurrentSpace(connectionID, display.identifier as CFString, display.userSpaces[position].id)
        return true
    }
}
