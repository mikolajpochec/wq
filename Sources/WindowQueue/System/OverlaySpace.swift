import AppKit

/// A private WindowServer space that sits above every desktop.
///
/// Windows marked "join all Spaces" are still owned by whichever desktop is showing, so they take
/// part in the Space switch transition and are redrawn once it ends. A window placed in a space of
/// its own, shown at an absolute level above the desktops, never leaves the screen at all: the
/// desktops slide underneath it. Falls back to doing nothing when the symbols are missing, which
/// leaves the panels' ordinary collection behaviour in charge.
final class OverlaySpace {
    static let shared = OverlaySpace()

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias CreateFn = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SetLevelFn = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias SpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias WindowsSpacesFn = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias CopySpacesFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private let connectionID: Int32
    private let spaceID: UInt64?
    private let addWindows: WindowsSpacesFn?
    private let removeWindows: WindowsSpacesFn?
    private let copySpaces: CopySpacesFn?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        connectionID = symbol("CGSMainConnectionID", as: ConnectionFn.self)?() ?? 0
        addWindows = symbol("CGSAddWindowsToSpaces", as: WindowsSpacesFn.self)
        removeWindows = symbol("CGSRemoveWindowsFromSpaces", as: WindowsSpacesFn.self)
        copySpaces = symbol("CGSCopySpacesForWindows", as: CopySpacesFn.self)

        guard connectionID != 0,
              let create = symbol("CGSSpaceCreate", as: CreateFn.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SetLevelFn.self),
              let show = symbol("CGSShowSpaces", as: SpacesFn.self),
              addWindows != nil
        else {
            spaceID = nil
            return
        }

        // The flag has to be 1: other values make Finder draw desktop icons into the space.
        let id = create(connectionID, 1, nil)
        guard id != 0 else {
            spaceID = nil
            return
        }
        _ = setLevel(connectionID, id, Self.level)
        _ = show(connectionID, [NSNumber(value: id)] as CFArray)
        spaceID = id
    }

    /// Desktops and fullscreen spaces; the overlay space itself only shows up in wider masks.
    private static let userSpacesMask: Int32 = 7

    /// High enough to stay above desktops and fullscreen spaces.
    private static let level: Int32 = 100

    var isAvailable: Bool { spaceID != nil }

    /// Experimental, off by default: `defaults write com.mpochec.windowqueue overlayOnlyPanels -bool true`.
    ///
    /// Adding a "join all Spaces" window to the overlay space does not take it off the desktops: it
    /// stays a member of every one of them as well, so it still slides and is redrawn with the switch
    /// — the glitch the overlay space was meant to cure. Only a window that belongs to the overlay
    /// alone stays put. Probed on macOS 26: an ordinary window left in the overlay space alone is drawn
    /// normally, while a "join all Spaces" one taken off the desktops disappears, which is why the
    /// behaviour has to be dropped first. Not yet watched through a real switch, hence the switch.
    static var isExclusive: Bool { UserDefaults.standard.bool(forKey: "overlayOnlyPanels") }

    /// Moves a window into the overlay space. Safe to call repeatedly; call it after the window has
    /// been ordered in, because a window without a WindowServer id cannot be placed.
    func adopt(_ window: NSWindow) {
        guard let spaceID, let addWindows, window.windowNumber > 0 else { return }
        let exclusive = Self.isExclusive && removeWindows != nil && copySpaces != nil
        if exclusive { window.collectionBehavior.remove(.canJoinAllSpaces) }
        let windows = [NSNumber(value: window.windowNumber)] as CFArray
        addWindows(connectionID, windows, [NSNumber(value: spaceID)] as CFArray)

        guard exclusive, let removeWindows, let copySpaces,
              let current = copySpaces(connectionID, Self.userSpacesMask, windows)?
                  .takeRetainedValue() as? [NSNumber]
        else { return }
        let others = current.filter { $0.uint64Value != spaceID }
        guard !others.isEmpty else { return }
        removeWindows(connectionID, windows, others as CFArray)
    }
}
