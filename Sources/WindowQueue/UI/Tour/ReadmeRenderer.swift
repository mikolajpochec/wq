import AppKit
import SwiftUI

/// The README's pictures: short scenes played on the tour's pretend desktop, saved frame by frame
/// (Scripts/make-readme-assets.sh turns them into GIFs), and the keys of each feature as SVG
/// keycaps. Uses the default settings, not the user's, so the pictures match a fresh install.
/// Debug command `readme-render <dir>`.
enum ReadmeRenderer {
    struct Scene {
        let name: String
        let setup: SimSetup
        let steps: [TourModel.DemoStep]
    }

    /// One picture of keys: groups of keys held together, with a word between groups.
    struct Keys {
        let name: String
        let groups: [[String]]
        let joiner: String
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
        let superKey = prefs.superModifier.symbol
        return [
            Keys(name: "queue", groups: [caps(.cyclePrevious), caps(.cycleNext), caps(.moveLeft), caps(.moveRight)], joiner: "·"),
            Keys(name: "aiming", groups: [[superKey], ["↓"], ["⇧", "↓"], ["↩"]], joiner: "then"),
            Keys(name: "tiling", groups: [[superKey], ["⇧", "↓"], ["→"], ["↩"]], joiner: "then"),
            Keys(name: "groups", groups: [["G"], caps(.toggleGroupLock)], joiner: "·"),
            Keys(name: "workspaces", groups: [caps(.space1) + ["…9"], caps(.moveToSpace1) + ["…9"], caps(.goToEmptySpace)], joiner: "·"),
            Keys(name: "search", groups: [caps(.search)], joiner: ""),
            Keys(name: "declutter", groups: [caps(.declutter)], joiner: ""),
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

    /// Keycaps in the tour's style: one cap per key, a modifier's name under its symbol.
    static func svg(_ keys: Keys) -> String {
        let names = ["⌘": "command", "⌥": "option", "⌃": "control", "⇧": "shift"]
        let height: CGFloat = 52, gap: CGFloat = 6, groupGap: CGFloat = 14, pad: CGFloat = 4
        let symbolFont = NSFont.systemFont(ofSize: 20, weight: .medium)
        let labelFont = NSFont.systemFont(ofSize: 10, weight: .medium)
        let wordFont = NSFont.systemFont(ofSize: 15, weight: .medium)
        func width(_ text: String, _ font: NSFont) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let family = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Segoe UI Symbol', 'Helvetica Neue', Arial, sans-serif"
        var body = ""
        var x = pad
        for (g, group) in keys.groups.enumerated() {
            if g > 0, !keys.joiner.isEmpty {
                let w = width(keys.joiner, wordFont)
                body += "<text x='\(x + groupGap / 2 + w / 2)' y='\(pad + height / 2 + 5)' font-size='15' font-weight='500' fill='#8b949e' text-anchor='middle'>\(escape(keys.joiner))</text>"
                x += w + groupGap
            } else if g > 0 {
                x += groupGap
            }
            for key in group {
                // "…9" after a key reads as a range, not a cap of its own.
                if key.hasPrefix("…") {
                    let w = width(key, wordFont)
                    body += "<text x='\(x + w / 2)' y='\(pad + height / 2 + 5)' font-size='15' font-weight='500' fill='#8b949e' text-anchor='middle'>\(escape(key))</text>"
                    x += w + gap
                    continue
                }
                let label = names[key]
                let symbol = key.count > 1 && label == nil ? key.lowercased() : key
                let w = max(height, width(symbol, symbolFont) + 26, label.map { width($0, labelFont) + 18 } ?? 0)
                let midX = x + w / 2
                body += "<rect x='\(x)' y='\(pad + 3)' width='\(w)' height='\(height - 3)' rx='9' fill='#b9bdc4'/>"
                body += "<rect x='\(x)' y='\(pad)' width='\(w)' height='\(height - 4)' rx='9' fill='url(#cap)' stroke='#c4c8ce'/>"
                if let label {
                    body += "<text x='\(midX)' y='\(pad + 24)' font-size='20' font-weight='500' fill='#24292f' text-anchor='middle'>\(escape(symbol))</text>"
                    body += "<text x='\(midX)' y='\(pad + 40)' font-size='10' font-weight='500' fill='#6e7781' text-anchor='middle'>\(label)</text>"
                } else {
                    body += "<text x='\(midX)' y='\(pad + height / 2 + 5)' font-size='20' font-weight='500' fill='#24292f' text-anchor='middle'>\(escape(symbol))</text>"
                }
                x += w + gap
            }
            x -= gap
        }
        let total = x + pad
        return """
        <svg xmlns='http://www.w3.org/2000/svg' width='\(Int(total.rounded(.up)))' height='\(Int(height + 2 * pad))' viewBox='0 0 \(Int(total.rounded(.up))) \(Int(height + 2 * pad))' font-family="\(family)">
        <defs><linearGradient id='cap' x1='0' y1='0' x2='0' y2='1'><stop offset='0' stop-color='#ffffff'/><stop offset='1' stop-color='#eef0f3'/></linearGradient></defs>
        \(body)
        </svg>

        """
    }
}
