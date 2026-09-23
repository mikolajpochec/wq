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
    private typealias WindowBoolQueryFn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetTypeFn = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpaceDestroyFn = @convention(c) (Int32, UInt64) -> Void
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Void

    /// `kCGSSpaceIncludesCurrent | kCGSSpaceIncludesOthers | kCGSSpaceIncludesUser`
    private static let allSpacesMask: Int32 = 7
    /// Space "type" value for a normal user desktop; 4 is a fullscreen space.
    private static let userSpaceType = 0

    private let connectionID: Int32
    private let copyManagedDisplaySpaces: CopyManagedDisplaySpacesFn?
    private let copySpacesForWindows: CopySpacesForWindowsFn?
    private let setCurrentSpace: SetCurrentSpaceFn?
    private let windowIsOrderedIn: WindowBoolQueryFn?
    private let spaceCreate: SpaceCreateFn?
    private let spaceSetType: SpaceSetTypeFn?
    private let spaceDestroy: SpaceDestroyFn?
    private let showSpaces: ShowSpacesFn?

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
        windowIsOrderedIn = symbol("SLSWindowIsOrderedIn", as: WindowBoolQueryFn.self)
        spaceCreate = symbol("SLSSpaceCreate", as: SpaceCreateFn.self)
            ?? symbol("CGSSpaceCreate", as: SpaceCreateFn.self)
        spaceSetType = symbol("SLSSpaceSetType", as: SpaceSetTypeFn.self)
            ?? symbol("CGSSpaceSetType", as: SpaceSetTypeFn.self)
        spaceDestroy = symbol("SLSSpaceDestroy", as: SpaceDestroyFn.self)
            ?? symbol("CGSSpaceDestroy", as: SpaceDestroyFn.self)
        showSpaces = symbol("SLSShowSpaces", as: ShowSpacesFn.self)
            ?? symbol("CGSShowSpaces", as: ShowSpacesFn.self)
    }

    var isAvailable: Bool {
        connectionID != 0 && copyManagedDisplaySpaces != nil
    }

    // MARK: - Making a workspace

    /// Adds a desktop and hands back its id, or nil when the WindowServer will not have it.
    ///
    /// The WindowServer creates the space readily enough, but a space the Dock does not know about
    /// is not a workspace the user can switch to — it is nowhere in Mission Control and nothing puts
    /// it in the display's list. Whether the new space joins that list is what decides it, so the
    /// answer is read back from the display topology rather than from the call, and a space that did
    /// not make it is destroyed again rather than left behind.
    func createSpace() -> UInt64? {
        guard isAvailable, let spaceCreate, let showSpaces else { return nil }
        let before = Set(userSpaceIDs)
        let id = spaceCreate(connectionID, 0, nil)
        guard id != 0 else { return nil }
        spaceSetType?(connectionID, id, Int32(Self.userSpaceType))
        showSpaces(connectionID, [NSNumber(value: id)] as CFArray)

        guard userSpaceIDs.contains(id), !before.contains(id) else {
            Diagnostics.note("space \(id) created but the display will not list it")
            spaceDestroy?(connectionID, id)
            return nil
        }
        Diagnostics.note("created space \(id)")
        return id
    }

    /// The workspaces of the display a workspace lives on, in Mission Control order.
    ///
    /// Each display owns its own desktops, so a workspace to put a layout on has to come from the
    /// same monitor — a desktop on the other screen is not somewhere the windows can go.
    func spacesSharingDisplay(with space: UInt64) -> [UInt64] {
        guard let display = displays().first(where: { $0.userSpaces.contains { $0.id == space } })
        else { return [] }
        return display.userSpaces.map(\.id)
    }

    /// Takes a workspace away again. Only for one this app made and could not use.
    func destroySpace(_ id: UInt64) {
        guard isAvailable else { return }
        spaceDestroy?(connectionID, id)
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

    /// Every user desktop across every display, in the order the WindowServer reports them.
    ///
    /// Each display owns its own set of Spaces, so numbering only the current display's would leave
    /// every window on a second monitor without a workspace number at all. Mission Control counts
    /// desktops across displays, and so does this.
    private func allUserSpaces() -> [(id: UInt64, display: String)] {
        displays().flatMap { display in
            display.userSpaces.map { (id: $0.id, display: display.identifier) }
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

    static func displayUUID(of screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }

    /// What one screen is showing: its desktop number, or that it is in fullscreen.
    struct ScreenSpace: Equatable {
        var index: Int?
        var isFullscreen: Bool
    }

    /// The space on show on every screen, keyed by display UUID. When displays do not have
    /// separate Spaces there is a single entry, which applies to every screen.
    func screenSpaces() -> [String: ScreenSpace] {
        let all = displays()
        let desktops = all.flatMap { $0.userSpaces.map(\.id) }
        var result: [String: ScreenSpace] = [:]
        for display in all {
            guard let current = display.currentSpaceID else { continue }
            let index = desktops.firstIndex(of: current).map { $0 + 1 }
            result[display.identifier] = ScreenSpace(index: index,
                                                     isFullscreen: !desktops.isEmpty && index == nil)
        }
        return result
    }

    // MARK: - Queries

    var currentSpaceID: UInt64? {
        primaryDisplay()?.currentSpaceID
    }

    /// 1-based index of the desktop showing on the display the strip is on, or nil when that
    /// display is showing a fullscreen space.
    var currentSpaceIndex: Int? {
        guard let current = currentSpaceID,
              let index = allUserSpaces().firstIndex(where: { $0.id == current })
        else { return nil }
        return index + 1
    }

    /// Space id of the 1-based desktop index on the primary display.
    func spaceID(atIndex index: Int) -> UInt64? {
        guard let display = primaryDisplay() else { return nil }
        let position = index - 1
        guard display.userSpaces.indices.contains(position) else { return nil }
        return display.userSpaces[position].id
    }

    /// Space id of the 1-based desktop index counted across every display, which is how the queue
    /// numbers workspaces.
    func userSpaceID(atIndex index: Int) -> UInt64? {
        let all = allUserSpaces()
        guard all.indices.contains(index - 1) else { return nil }
        return all[index - 1].id
    }

    /// Space ids of every desktop, in Mission Control order.
    var userSpaceIDs: [UInt64] {
        allUserSpaces().map(\.id)
    }

    /// Whether the display the strip is on is showing a fullscreen window rather than a desktop.
    ///
    /// Fullscreen spaces are a different type from user desktops, so a current space that is not in
    /// the desktop list is a fullscreen one. Returns false when the topology cannot be read, so an
    /// unknown state never hides the strip.
    var isCurrentSpaceFullscreen: Bool {
        guard let current = currentSpaceID else { return false }
        let desktops = allUserSpaces()
        guard !desktops.isEmpty else { return false }
        return !desktops.contains { $0.id == current }
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

    /// Whether the WindowServer actually has the window ordered into its display list.
    ///
    /// This is what separates a window the user can see from one an application merely keeps
    /// around after it was closed — and unlike the Accessibility API it answers for windows on
    /// every Space, not just the active one. Returns nil when the symbol is unavailable.
    func isOrderedIn(_ windowID: CGWindowID) -> Bool? {
        guard let windowIsOrderedIn else { return nil }
        var result = false
        guard windowIsOrderedIn(connectionID, windowID, &result) == 0 else { return nil }
        return result
    }

    // MARK: - Switching

    @discardableResult
    func switchToSpace(index: Int) -> Bool {
        guard let id = spaceID(atIndex: index) else { return false }
        return switchToSpace(id: id)
    }

    @discardableResult
    func switchToSpace(id: UInt64) -> Bool {
        guard let setCurrentSpace,
              let space = allUserSpaces().first(where: { $0.id == id })
        else { return false }
        setCurrentSpace(connectionID, space.display as CFString, id)
        return true
    }
}
