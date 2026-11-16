import AppKit
import Combine

/// Draws a border in its colour round every window the user has coloured (on its own or through its
/// group), and a tag with its name on every window they have named, so look-alike windows can be
/// told apart on screen and not only on the strip.
///
/// Each border is a click-through window of WindowQueue's own, kept just in front of the window it
/// frames: in the WindowServer's order rather than floating on top, so other windows over it cover
/// the border too. Other apps' windows can't be watched cheaply for moves and reordering, so a
/// light poll of the on-screen list keeps the borders in step while there are any to draw.
final class WindowBorderController {
    /// Window numbers of the border windows, which the enumerator must not take for windows to queue.
    private(set) static var ownWindowNumbers: Set<CGWindowID> = []

    static let borderWidth: CGFloat = 4

    private let marks: WindowMarks
    private let isEnabled: () -> Bool
    private var borders: [CGWindowID: BorderWindow] = [:]
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(marks: WindowMarks = .shared, isEnabled: @escaping () -> Bool = { true }) {
        self.marks = marks
        self.isEnabled = isEnabled
        marks.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.marksChanged() }
            .store(in: &cancellables)
        // A desktop switch takes the framed windows away at once; the poll would lag behind.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    /// The windows that get something drawn round them.
    private var wanted: Set<CGWindowID> {
        guard isEnabled() else { return [] }
        return marks.tintedWindowIDs.union(marks.names.keys)
    }

    func marksChanged() {
        let wanted = wanted
        if wanted.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.refresh() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        refresh()
    }

    func refresh() {
        let wanted = wanted
        for (id, border) in borders where !wanted.contains(id) {
            border.orderOut(nil)
            borders[id] = nil
        }
        guard !wanted.isEmpty else {
            Self.ownWindowNumbers = []
            return
        }

        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        var frames: [CGWindowID: CGRect] = [:]
        // Front to back; remembered so a border already right in front of its window is left alone.
        var order: [CGWindowID] = []
        for info in list {
            guard let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            order.append(number)
            guard wanted.contains(number), (info[kCGWindowLayer as String] as? Int) == 0,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { continue }
            frames[number] = bounds
        }

        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        for id in wanted {
            guard let bounds = frames[id] else {
                borders[id]?.orderOut(nil)
                continue
            }
            let border = borders[id] ?? {
                let border = BorderWindow()
                borders[id] = border
                return border
            }()
            border.update(tint: marks.tint(for: id), name: marks.name(for: id))
            // CoreGraphics counts from the top of the primary screen, AppKit from its bottom.
            let window = NSRect(x: bounds.minX, y: primaryHeight - bounds.maxY,
                                width: bounds.width, height: bounds.height)
            let frame = window.insetBy(dx: -Self.borderWidth, dy: -Self.borderWidth)
            if border.frame != frame { border.setFrame(frame, display: true) }
            let mine = CGWindowID(border.windowNumber)
            let inFront = order.firstIndex(of: mine).map { index in
                order.indices.contains(index + 1) && order[index + 1] == id
            } ?? false
            if !border.isVisible || !inFront {
                border.order(.above, relativeTo: Int(id))
            }
        }
        Self.ownWindowNumbers = Set(borders.values.map { CGWindowID($0.windowNumber) })
    }
}

/// One border: a transparent, click-through window drawing a coloured frame and a name tag.
private final class BorderWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let view = BorderView()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = .normal
        isFloatingPanel = false
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = view
    }

    func update(tint: WindowTint?, name: String?) {
        guard view.tint != tint || view.name != name else { return }
        view.tint = tint
        view.name = name
        view.needsDisplay = true
    }
}

private final class BorderView: NSView {
    var tint: WindowTint?
    var name: String?

    /// Roughly the corner of a macOS window, so the frame hugs it: Liquid Glass rounded them more.
    private let windowCorner: CGFloat = {
        if #available(macOS 26, *) { return 16 }
        return 10
    }()

    override func draw(_ dirtyRect: NSRect) {
        let width = WindowBorderController.borderWidth
        if let tint {
            let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
            let radius = windowCorner + width / 2
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = width
            tint.nsColor.setStroke()
            path.stroke()
        }
        guard let name, !name.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = NSAttributedString(string: name, attributes: attributes)
        let maxWidth = max(40, bounds.width - 2 * (windowCorner + width) - 160)
        let textSize = text.size()
        let pill = NSSize(width: min(textSize.width, maxWidth) + 16, height: textSize.height + 4)
        // Centred on the top edge, where the title sits, hanging down from the border.
        let rect = NSRect(x: bounds.midX - pill.width / 2, y: bounds.maxY - pill.height - 1,
                          width: pill.width, height: pill.height)
        (tint?.nsColor ?? NSColor(white: 0.15, alpha: 0.9)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        text.draw(with: NSRect(x: rect.minX + 8, y: rect.minY + 2, width: rect.width - 16, height: textSize.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
