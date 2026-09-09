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

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
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
