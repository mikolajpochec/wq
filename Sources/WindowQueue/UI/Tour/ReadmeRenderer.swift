import AppKit
import SwiftUI

/// The README's pictures: short scenes played on the tour's pretend desktop, saved frame by frame
/// (Scripts/make-readme-assets.sh turns them into GIFs), and the keys of each feature as SVG
/// keycaps. Uses the default settings, not the user's, so the pictures match a fresh install.
/// Run as `WindowQueue --render readme <dir>`.
enum ReadmeRenderer {
    struct Scene {
        let name: String
        let setup: SimSetup
        let steps: [TourModel.DemoStep]
    }

    /// One picture of keys: a row per shortcut, the keys on the left and what they do on the right.
    struct Keys {
        struct Row {
            /// Keys held together; several groups are alternatives, shown with a slash between.
            let groups: [[String]]
            let text: String
        }
        let name: String
        let rows: [Row]
    }

    static var prefs: Preferences {
        var prefs = Preferences()
        prefs.superModifier = .option
        prefs.bindings = Preferences.defaultBindings(superMask: SuperModifier.option.carbonMask)
        return prefs
    }

    static let fps: Double = 15

    static var scenes: [Scene] {
        let four: [SimWindow] = [.safari, .notes, .terminal, .mail]
        return [
            Scene(name: "queue", setup: SimSetup(windows: four),
                  steps: [.wait(0.9), .action(.cycleNext), .wait(0.8), .action(.cycleNext), .wait(0.8), .action(.cycleNext),
                          .wait(1), .action(.moveLeft), .wait(0.8), .action(.moveLeft), .wait(0.8), .action(.moveLeft),
                          .wait(1.6)]),
            Scene(name: "aiming", setup: SimSetup(windows: four + [.music]),
                  steps: [.wait(0.9), .superTap, .wait(0.9), .key(.next), .wait(0.6), .key(.next), .wait(0.6),
                          .key(.next, extend: true), .wait(0.6), .key(.next, extend: true), .wait(1.2), .key(.cancel),
                          .wait(0.8), .superTap, .wait(0.7), .key(.next), .wait(0.6), .key(.next), .wait(0.6), .key(.next),
                          .wait(0.8), .superTap, .wait(1.6)]),
            Scene(name: "tiling", setup: SimSetup(windows: [.xcode, .simulator, .safari, .terminal]),
                  steps: [.wait(0.9), .superTap, .wait(0.7), .key(.next, extend: true), .wait(0.6), .key(.next, extend: true),
                          .wait(0.8), .key(.into), .wait(1.1), .key(.enter), .wait(1.6), .superTap, .wait(0.7), .key(.next),
                          .wait(0.7), .key(.previous, carry: true), .wait(1.6), .key(.cancel), .wait(1.2)]),
            Scene(name: "groups", setup: SimSetup(windows: four + [.music]),
                  steps: [.wait(0.9), .superTap, .wait(0.7), .key(.next), .wait(0.6), .key(.next, extend: true), .wait(0.8),
                          .bareAction(.toggleGroup), .wait(1.4), .action(.toggleGroupLock), .wait(1.2), .action(.cycleNext),
                          .wait(0.8), .action(.cycleNext), .wait(0.8), .action(.cycleNext), .wait(1), .action(.toggleGroupLock),
                          .wait(1.4)]),
            Scene(name: "workspaces", setup: SimSetup(windows: four, spaces: [3: 2, 4: 2], spaceCount: 3),
                  steps: [.wait(0.8), .action(.space2), .wait(1.3), .action(.space1), .wait(1.1), .action(.cycleNext),
                          .wait(0.9), .action(.moveToSpace2), .wait(1.5), .action(.goToEmptySpace), .wait(1.4),
                          .action(.space1), .wait(1.3)]),
            Scene(name: "search", setup: SimSetup(windows: four + [.music]),
                  steps: [.wait(0.8), .action(.search), .wait(0.8), .type("t"), .wait(0.35), .type("e"), .wait(0.35),
                          .type("r"), .wait(1.1), .key(.enter), .wait(1.8)]),
            Scene(name: "declutter", setup: SimSetup(windows: four + [.music]),
                  steps: [.wait(1.2), .action(.declutter), .wait(2.8)]),
            Scene(name: "drag", setup: SimSetup(windows: four),
                  steps: [.wait(0.6), .pointer(SimWindow.mail.id), .wait(0.8), .lift(SimWindow.mail.id), .wait(0.4),
                          .dragStep(-1), .wait(0.45), .dragStep(-1), .wait(0.45), .dragStep(-1), .wait(0.6), .drop,
                          .wait(0.8), .pointer(nil), .wait(1.2)]),
        ]
    }

    static var keys: [Keys] {
        let prefs = self.prefs
        func caps(_ action: HotkeyAction) -> [String] {
            let combo = prefs.combo(for: action)
            return combo.modifierSymbols.map(String.init) + [KeyCombo.keyName(for: combo.keyCode)]
        }
        typealias Row = Keys.Row
        let superKey = prefs.superModifier.symbol
        return [
            Keys(name: "queue", rows: [
                Row(groups: [caps(.cyclePrevious), caps(.cycleNext)], text: "Previous / next window"),
                Row(groups: [caps(.moveLeft), caps(.moveRight)], text: "Move the window earlier / later"),
            ]),
            Keys(name: "aiming", rows: [
                Row(groups: [[superKey]], text: "Tap on its own to start aiming"),
                Row(groups: [["["], ["]"]], text: "Move the aim"),
                Row(groups: [["⇧", "]"]], text: "Aim at more windows"),
                Row(groups: [["↩"]], text: "Focus the aimed window"),
            ]),
            Keys(name: "tiling", rows: [
                Row(groups: [["⇧", "]"]], text: "While aiming: aim at windows"),
                Row(groups: [["→"]], text: "Open the layouts"),
                Row(groups: [["↩"]], text: "Tile"),
                Row(groups: [[superKey, "["]], text: "Move a window; the tiles follow"),
            ]),
            Keys(name: "groups", rows: [
                Row(groups: [["G"]], text: "While aiming: group the aimed windows"),
                Row(groups: [caps(.toggleGroupLock)], text: "Lock cycling to the group"),
            ]),
            Keys(name: "workspaces", rows: [
                Row(groups: [caps(.space1) + ["…9"]], text: "Go to workspace 1–9"),
                Row(groups: [caps(.moveToSpace1) + ["…9"]], text: "Take the window there"),
                Row(groups: [caps(.goToEmptySpace)], text: "Go to an empty workspace"),
            ]),
            Keys(name: "search", rows: [
                Row(groups: [caps(.search)], text: "Find a window by name"),
            ]),
            Keys(name: "declutter", rows: [
                Row(groups: [caps(.declutter)], text: "Spread out every window in view"),
            ]),
        ]
    }

    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prefs = self.prefs
        for scene in scenes {
            record(scene, prefs: prefs, to: directory.appendingPathComponent(scene.name))
        }
        for keys in keys {
            try? svg(keys).write(to: directory.appendingPathComponent("keys-\(keys.name).svg"), atomically: true, encoding: .utf8)
        }
    }

    private static func record(_ scene: Scene, prefs: Preferences, to directory: URL) {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sim = TourSim()
        sim.reset(scene.setup)
        let size = SimDesktopView.size
        let host = NSHostingView(rootView: SimDesktopView(sim: sim, prefs: prefs, cornerRadius: 0).environment(\.colorScheme, .light))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        var frame = 0
        var clock = Date()
        func capture(for seconds: TimeInterval) {
            let end = clock.addingTimeInterval(seconds)
            while clock < end {
                RunLoop.current.run(until: clock)
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let name = String(format: "frame-%04d.png", frame)
                    try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
                }
                frame += 1
                clock = clock.addingTimeInterval(1 / fps)
            }
        }
        for step in scene.steps {
            if case .wait(let seconds) = step {
                capture(for: seconds)
            } else {
                TourModel.perform(step, on: sim, prefs: prefs)
            }
        }
        window.close()
    }

    /// Small keycaps, one per key, and what the keys do beside them. The text is a mid grey that
    /// reads on GitHub's light and dark pages alike.
    static func svg(_ keys: Keys) -> String {
        let cap: CGFloat = 26, gap: CGFloat = 4, rowHeight: CGFloat = 34, pad: CGFloat = 2
        let capFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textFont = NSFont.systemFont(ofSize: 14)
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        func capWidth(_ key: String) -> CGFloat {
            key.hasPrefix("…") ? width(key, capFont) : max(cap, width(key.count > 1 ? key.lowercased() : key, capFont) + 14)
        }
        func rowWidth(_ row: Keys.Row) -> CGFloat {
            let slash = width("/", capFont) + 2 * gap
            return row.groups.map { group in group.map(capWidth).reduce(0, +) + gap * CGFloat(group.count - 1) }
                .reduce(0, +) + slash * CGFloat(row.groups.count - 1)
        }
        let keysWidth = keys.rows.map(rowWidth).max() ?? 0
        let textX = pad + keysWidth + 14
        let textWidth = keys.rows.map { width($0.text, textFont) }.max() ?? 0
        let total = (textX + textWidth + pad).rounded(.up)
        let height = (CGFloat(keys.rows.count) * rowHeight + 2 * pad).rounded(.up)

        var body = ""
        for (r, row) in keys.rows.enumerated() {
            let top = pad + CGFloat(r) * rowHeight + (rowHeight - cap) / 2
            let baseline = top + cap / 2 + 4.5
            var x = pad
            for (g, group) in row.groups.enumerated() {
                if g > 0 {
                    let w = width("/", capFont)
                    body += "<text x='\(x + gap + w / 2)' y='\(baseline)' font-size='13' fill='#8b949e' text-anchor='middle'>/</text>"
                    x += w + 2 * gap
                }
                for key in group {
                    let w = capWidth(key)
                    if key.hasPrefix("…") {
                        body += "<text x='\(x + w / 2)' y='\(baseline)' font-size='13' fill='#8b949e' text-anchor='middle'>\(escape(key))</text>"
                    } else {
                        let label = key.count > 1 ? key.lowercased() : key
                        body += "<rect x='\(x)' y='\(top + 2)' width='\(w)' height='\(cap - 2)' rx='6' fill='#b9bdc4'/>"
                        body += "<rect x='\(x)' y='\(top)' width='\(w)' height='\(cap - 2.5)' rx='6' fill='url(#cap)' stroke='#c4c8ce'/>"
                        body += "<text x='\(x + w / 2)' y='\(baseline - 1)' font-size='13' font-weight='500' fill='#24292f' text-anchor='middle'>\(escape(label))</text>"
                    }
                    x += w + gap
                }
                x -= gap
            }
            body += "<text x='\(textX)' y='\(baseline)' font-size='14' fill='#8b949e'>\(escape(row.text))</text>"
        }
        let family = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Segoe UI Symbol', 'Helvetica Neue', Arial, sans-serif"
        return """
        <svg xmlns='http://www.w3.org/2000/svg' width='\(Int(total))' height='\(Int(height))' viewBox='0 0 \(Int(total)) \(Int(height))' font-family="\(family)">
        <defs><linearGradient id='cap' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#ffffff'/><stop offset='1' stop-color='#eef0f3'/></linearGradient></defs>
        \(body)
        </svg>

        """
    }
}
