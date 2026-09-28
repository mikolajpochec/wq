import ApplicationServices
import CoreGraphics

/// `_AXUIElementGetWindow` is the only reliable way to get a stable `CGWindowID` for an
/// accessibility window element. It is private but has been present since 10.x; when it cannot be
/// resolved we fall back to a synthetic identity so the app still works, just without the
/// Spaces integration (which needs a real window number).
enum AXPrivate {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindow: GetWindowFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(pointer, to: GetWindowFn.self)
    }()

    static var supportsWindowNumbers: Bool { getWindow != nil }

    /// How long any single accessibility call may block. The default is measured in seconds, long
    /// enough that one busy application stalls whatever thread asked it something.
    static let messagingTimeout: Float = 0.25

    /// Application element with a bounded messaging timeout. Always prefer this over
    /// `AXUIElementCreateApplication` directly.
    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }

    private typealias RemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    private static let createWithRemoteToken: RemoteTokenFn? = {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementCreateWithRemoteToken") else {
            return nil
        }
        return unsafeBitCast(pointer, to: RemoteTokenFn.self)
    }()

    /// The accessibility element of one window, found however it can be.
    ///
    /// The application's own window list comes first, then its focused window. Some applications
    /// list nothing at times — Ghostty goes blind for whole stretches, Chrome never lists at all —
    /// and for those the element is made from a remote token instead: the app's pid, a magic word,
    /// and an element number, tried in turn until one turns out to be this window. It is the trick
    /// AltTab uses, and costs up to a couple of thousand small calls to the app, so it belongs off
    /// the main thread.
    static func windowElement(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = application(pid)
        if let listed = app.attribute(kAXWindowsAttribute, as: [AXUIElement].self)?
            .first(where: { windowID(of: $0) == id }) {
            return listed
        }
        if let focused = app.attribute(kAXFocusedWindowAttribute, as: AXUIElement.self),
           windowID(of: focused) == id {
            return focused
        }
        guard let createWithRemoteToken else { return nil }
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f_636f)) { Data($0) })
        for number: UInt64 in 0..<2000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: number) { Data($0) })
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.05)
            if windowID(of: element) == id {
                AXUIElementSetMessagingTimeout(element, messagingTimeout)
                return element
            }
        }
        return nil
    }
}

extension AXUIElement {
    func attribute<T>(_ name: String, as type: T.Type) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func boolAttribute(_ name: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success,
              let number = value, CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue((number as! CFBoolean))
    }

    @discardableResult
    func setAttribute(_ name: String, value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, name as CFString, value) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(self, action as CFString) == .success
    }
}
