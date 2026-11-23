import AppKit
import SwiftUI

/// "A new version is out": what is in it, and a button that installs it and relaunches. Closing
/// it leaves an "Update Available" item in the menu bar menu.
struct UpdateView: View {
    let release: UpdateChecker.Release
    let currentVersion: String
    @ObservedObject var updater: Updater
    var install: () -> Void = {}
    var cancel: () -> Void = {}
    var openPage: () -> Void = {}
    var later: () -> Void = {}

    static let size = CGSize(width: 460, height: 360)

    /// The release notes up to their install instructions, which say nothing new here.
    private var notes: AttributedString {
        let text = release.notes.components(separatedBy: "\n## ").first ?? release.notes
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text.trimmingCharacters(in: .whitespacesAndNewlines), options: options))
            ?? AttributedString(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text("WindowQueue \(release.version) is available")
                        .font(.system(size: 17, weight: .bold))
                    Text("You have \(currentVersion).")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(notes)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            footer
        }
        .padding(20)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 10) {
            switch updater.state {
            case .downloading(let fraction):
                ProgressView(value: fraction)
                    .frame(maxWidth: .infinity)
                Text("Downloading…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel") { cancel() }
                    .keyboardShortcut(.cancelAction)
            case .installing:
                ProgressView()
                    .controlSize(.small)
                Text("Installing; WindowQueue will reopen in a moment.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Release Page") { openPage() }
                Button("Try Again") { install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            case .idle:
                Text("Your settings and Accessibility access carry over.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Not Now") { later() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") { install() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(minHeight: 24)
    }
}

final class UpdateWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow

    init(release: UpdateChecker.Release, updater: Updater) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: UpdateView.size),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let view = UpdateView(release: release, currentVersion: UpdateChecker.currentVersion, updater: updater,
                              install: { updater.install(release) },
                              cancel: { updater.cancel() },
                              openPage: { [weak self] in
                                  NSWorkspace.shared.open(release.page)
                                  self?.window.close()
                              },
                              later: { [weak self] in self?.window.close() })
        window.contentView = NSHostingView(rootView: view)
        window.center()
    }

    func present() {
        OwnWindows.present(window)
    }

    /// Draws the window's content into a PNG without putting anything on screen, for checking its
    /// look. Run as `WindowQueue --render update <dir>`.
    static func render(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let release = UpdateChecker.Release(
            version: "1.0.2", page: URL(string: "https://github.com/mikolajpochec/wq/releases")!,
            notes: "Welcome tour improvements.\n\n- A new **Close windows** tip: ⌥Q, or Q while aiming.\n- Opening the window finder (⌥Space) is enough for the Search tip.\n\n## Install\n\nDownload the DMG.")
        let states: [(String, Updater.State)] = [
            ("update", .idle), ("update-downloading", .downloading(0.4)), ("update-installing", .installing),
            ("update-failed", .failed("The download isn't signed by WindowQueue's developer, so it wasn't installed.")),
        ]
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: UpdateView.size.width, height: UpdateView.size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for (name, state) in states {
            let updater = Updater()
            updater.preview(state)
            let host = NSHostingView(rootView: UpdateView(release: release, currentVersion: "1.0.1", updater: updater))
            host.frame = NSRect(origin: .zero, size: UpdateView.size)
            window.contentView = host
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
            }
        }
        window.close()
    }
}
