import AppKit
import Combine
import SwiftUI

/// What a showcased feature says about itself, and the try-it tip played on the tour's pretend desktop.
extension ShowcasedFeature {
    var symbol: String {
        switch self {
        case .monitorBrackets: return "display.2"
        }
    }

    var title: String {
        switch self {
        case .monitorBrackets: return "Step between monitors"
        }
    }

    /// A few sentences for the left column, in the user's own key bindings.
    func description(_ model: TourModel) -> [String] {
        switch self {
        case .monitorBrackets:
            return [
                "\(model.combo(.previousMonitor)) and \(model.combo(.nextMonitor)) go to the monitor on the left or the right, like [ and ] step along the queue. Past the last monitor they come round to the first.",
                "Add Shift to take the window along: \(model.combo(.sendToPreviousMonitor)) and \(model.combo(.sendToNextMonitor)).",
                "Change them in Settings › Shortcuts.",
            ]
        }
    }

    func tip(_ model: TourModel) -> TourTip {
        switch self {
        case .monitorBrackets:
            let left = model.combo(.previousMonitor), right = model.combo(.nextMonitor)
            let sendLeft = model.combo(.sendToPreviousMonitor), sendRight = model.combo(.sendToNextMonitor)
            return TourTip(id: rawValue, symbol: symbol, title: title,
                           goals: [.init(keys: left, event: .wentToPreviousMonitor), .init(keys: right, event: .wentToNextMonitor),
                                   .init(keys: sendLeft, event: .sentToPreviousMonitor), .init(keys: sendRight, event: .sentToNextMonitor)],
                           text: "\(left) / \(right) go to the monitor on the left or right; with Shift the window comes along.",
                           hint: "\(right), \(left), then \(sendRight) and \(sendLeft)",
                           setup: SimSetup(windows: [.safari, .notes, .terminal, .mail, .music],
                                           monitors: [3: 1, 4: 2, 7: 2], monitorCount: 3),
                           preview: [.wait(0.9), .action(.nextMonitor), .wait(1.3), .action(.nextMonitor), .wait(1.3),
                                     .action(.nextMonitor), .wait(1.4), .action(.previousMonitor), .wait(1.4),
                                     .action(.sendToNextMonitor), .wait(1.6), .action(.sendToPreviousMonitor), .wait(1.6)])
        }
    }
}

/// The "What's new" window: one feature at a time, previewed on the pretend desktop and then the
/// user's to try, each shortcut turning green once used.
struct WhatsNewView: View {
    @ObservedObject var model: TourModel
    @ObservedObject var sim: TourSim
    let features: [ShowcasedFeature]
    var close: () -> Void = {}

    /// The width; the height follows the content (`fittingSize`), so nothing is left empty.
    static let width: CGFloat = 760
    private static let margin: CGFloat = 32
    /// The pretend desk: the column's full width, only as tall as a row of monitors needs.
    static let deskSize = CGSize(width: width - 2 * margin, height: 330)

    init(model: TourModel, features: [ShowcasedFeature], close: @escaping () -> Void = {}) {
        self.model = model
        self.sim = model.sim
        self.features = features
        self.close = close
    }

    private var feature: ShowcasedFeature? { features[safe: model.tipIndex] }

    /// One column: what's new and how it works on top, the pretend desktop to try it on below.
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                details
                desktop
            }
            .padding(.horizontal, Self.margin)
            .padding(.top, 24)
            .padding(.bottom, 16)
            Divider()
            HStack {
                Text("Reopen this any time from the menu bar icon.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(allDone ? "Got It" : "Close") { close() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
        }
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var allDone: Bool { features.allSatisfy { model.finishedTips.contains($0.rawValue) } }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New in WindowQueue", systemImage: "sparkles")
                .font(.system(size: 26, weight: .heavy))
                .foregroundStyle(Color.accentColor)
            if features.count > 1 {
                // Several new features: one chip each, ticked once tried.
                HStack(spacing: 6) {
                    ForEach(Array(features.enumerated()), id: \.element) { index, item in
                        let finished = model.finishedTips.contains(item.rawValue)
                        Button { model.pickTip(index) } label: {
                            Label(item.title, systemImage: finished ? "checkmark.circle.fill" : item.symbol)
                                .font(.system(size: 12, weight: index == model.tipIndex ? .semibold : .regular))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(index == model.tipIndex ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let feature, let tip = model.currentTip {
                HStack(spacing: 10) {
                    Image(systemName: feature.symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor)
                    Text(feature.title).font(.system(size: 20, weight: .bold))
                }
                .padding(.top, 2)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(feature.description(model).enumerated()), id: \.offset) { _, text in
                        Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Each shortcut turns green once the user has used it on the desktop.
                HStack(spacing: 8) {
                    Text("TRY IT").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    ForEach(Array(tip.goals.enumerated()), id: \.offset) { _, goal in
                        KeyCaps(text: goal.keys, small: true, done: model.done.contains(goal.event))
                    }
                    Spacer(minLength: 0)
                    if model.finishedTips.contains(feature.rawValue) {
                        Label("You've got it", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                }
                .padding(.top, 2)
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.finishedTips)
    }

    private var desktop: some View {
        VStack(spacing: 8) {
            SimDesktopView(sim: sim, prefs: model.prefs, onClick: { model.click($0) }, onDragStart: { model.takeOver() },
                           frameSize: Self.deskSize)
                .overlay(alignment: .topLeading) {
                    if model.demoPlaying {
                        Label("PREVIEW", systemImage: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                            .foregroundStyle(.white)
                            .padding(.top, 22)
                            .padding(.leading, 10)
                            .transition(.opacity)
                    }
                }
                .overlay {
                    if model.awaitingUser, let hint = model.currentTip?.hint {
                        VStack(spacing: 6) {
                            Label("Your turn", systemImage: "hand.point.up.left.fill")
                                .font(.system(size: 15, weight: .bold))
                            Text("This desktop is pretend; your real windows stay put.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(.init("Try: **\(hint)**")).font(.system(size: 12)).padding(.top, 2)
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 8)
                        .allowsHitTesting(false)
                        .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
                .animation(.easeOut(duration: 0.25), value: model.demoPlaying)
                .animation(.easeOut(duration: 0.25), value: model.awaitingUser)
            HStack(spacing: 8) {
                Circle().fill(model.demoPlaying ? Color.red : Color.green).frame(width: 7, height: 7)
                Text(model.demoPlaying ? "Preview: press its keys to try it yourself" : "Your turn: the keys work here as they will on your windows")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.demoPlaying {
                    Button("Stop Preview") { model.finishDemo() }.controlSize(.small)
                } else {
                    Button("Watch Preview") { model.playDemo() }.controlSize(.small)
                }
            }
            .frame(width: Self.deskSize.width)
        }
    }
}

/// Hosts What's New in a normal window. Like the tour, while it has the keyboard the keys and the
/// super key tap go to its pretend desktop, and `onKeyboardChange` stands the app's shortcuts down.
final class WhatsNewWindowController: NSWindowController, NSWindowDelegate {
    var onKeyboardChange: ((Bool) -> Void)?
    /// The features shown, to be marked as seen.
    var onClose: (([ShowcasedFeature]) -> Void)?

    let features: [ShowcasedFeature]
    private let model: TourModel
    private let taps = ModifierTapMonitor()
    private var keyMonitor: Any?

    init(store: PreferencesStore, features: [ShowcasedFeature]) {
        self.features = features
        model = Self.makeModel(store: store, features: features)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: WhatsNewView.width, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "What's New in WindowQueue"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let host = NSHostingView(rootView: WhatsNewView(model: model, features: features) { [weak window] in
            window?.performClose(nil)
        })
        window.contentView = host
        // As tall as the content, no taller.
        window.setContentSize(host.fittingSize)
        window.center()
        window.delegate = self
        taps.onTap = { [weak self] in self?.model.superTap() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unsupported") }

    private static func makeModel(store: PreferencesStore, features: [ShowcasedFeature]) -> TourModel {
        TourModel(store: store) { model in features.map { $0.tip(model) } }
    }

    func present() {
        if window?.isVisible != true { model.show(.tips) }
        showWindow(nil)
        if let window { OwnWindows.present(window) }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        taps.modifiers = model.prefs.superModifier.eventFlags
        taps.start(includingOtherApps: false)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            self.taps.cancel()
            return self.model.handleKey(keyCode: Int(event.keyCode), flags: event.modifierFlags,
                                        characters: event.charactersIgnoringModifiers, isRepeat: event.isARepeat) ? nil : event
        }
        onKeyboardChange?(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        taps.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        onKeyboardChange?(false)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        onClose?(features)
    }

    /// Draws the window offscreen: each feature's preview step by step, the user's turn, and a
    /// tried one. Run as `WindowQueue --render whatsnew <dir>`.
    static func render(store: PreferencesStore, to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let features = ShowcasedFeature.allCases
        let model = makeModel(store: store, features: features)
        model.sim.animated = false
        let host = NSHostingView(rootView: WhatsNewView(model: model, features: features))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: host.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        func snap(_ name: String) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.45))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
        }
        model.show(.tips, scheduled: false)
        for (index, feature) in features.enumerated() {
            model.showTip(index, scheduled: false)
            snap("\(index)-\(feature.rawValue)-0")
            var shot = 1
            for step in model.tips[index].preview {
                if case .wait = step { continue }
                model.run(step)
                snap("\(index)-\(feature.rawValue)-\(shot)")
                shot += 1
            }
            model.finishDemo()
            snap("\(index)-\(feature.rawValue)-turn")
            for goal in [HotkeyAction.nextMonitor, .previousMonitor, .sendToNextMonitor, .sendToPreviousMonitor] {
                model.takeOver()
                model.run(.action(goal))
            }
            snap("\(index)-\(feature.rawValue)-tried")
        }
        window.close()
    }
}
