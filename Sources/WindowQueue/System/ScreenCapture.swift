import AppKit
import Combine

/// Recording the screen and taking pictures of windows, both through `screencapture`.
///
/// The command-line tool is what macOS itself uses for ⌘⇧5, so the files land where the user's own
/// screenshots land, with their format and their naming — nothing here has to be configurable.
/// Doing it in-process would mean a capture stream and a video encoder for no gain.
final class ScreenCapture: ObservableObject {
    static let shared = ScreenCapture()

    /// A recording is running, which the strip shows in place of the workspace number.
    @Published private(set) var isRecording = false

    private var recorder: Process?
    private var recordingURL: URL?

    private init() {}

    // MARK: - Recording

    /// Starts recording the screen, or stops the recording already running.
    /// - Returns: what happened, for the popup to say.
    @discardableResult
    func toggleRecording() -> (started: Bool, url: URL?) {
        if isRecording {
            let url = recordingURL
            stopRecording()
            return (false, url)
        }
        let url = destination(name: "Recording", extension: "mov")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v records video, -k keeps the shutter sound out of the way, and the tool records until
        // it is interrupted.
        process.arguments = ["-v", url.path]
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.recorder = nil
                self?.isRecording = false
            }
        }
        do {
            try process.run()
        } catch {
            Diagnostics.note("recording failed to start: \(error.localizedDescription)")
            return (false, nil)
        }
        recorder = process
        recordingURL = url
        isRecording = true
        Diagnostics.note("recording started at \(url.path)")
        return (true, url)
    }

    /// Interrupts the recorder, which is how `screencapture` is asked to finish the file properly.
    func stopRecording() {
        guard let recorder, recorder.isRunning else {
            isRecording = false
            return
        }
        kill(recorder.processIdentifier, SIGINT)
        isRecording = false
        Diagnostics.note("recording stopped")
    }

    // MARK: - Screenshots

    /// Takes a picture of each window, one file each.
    /// - Returns: the files written, in the order the windows were given.
    @discardableResult
    func screenshot(_ windows: [ManagedWindow]) -> [URL] {
        var written: [URL] = []
        for window in windows {
            let url = destination(name: name(for: window), extension: "png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            // -l picks the window by id, -o leaves the drop shadow out, -x keeps it silent.
            process.arguments = ["-l\(window.id)", "-o", "-x", url.path]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                Diagnostics.note("screenshot failed: \(error.localizedDescription)")
                continue
            }
            guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
                Diagnostics.note("screenshot of \(window.id) produced nothing")
                continue
            }
            written.append(url)
        }
        return written
    }

    // MARK: - Files

    /// Where the user's own screenshots go, which is the Desktop unless they have moved it.
    private var directory: URL {
        let defaults = UserDefaults(suiteName: "com.apple.screencapture")
        if let path = defaults?.string(forKey: "location"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
    }

    private func destination(name: String, extension ext: String) -> URL {
        let stamp = Self.stampFormatter.string(from: Date())
        var url = directory.appendingPathComponent("\(name) \(stamp).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name) \(stamp) (\(counter)).\(ext)")
            counter += 1
        }
        return url
    }

    /// The window's own name, cut down to something that can be a file name.
    private func name(for window: ManagedWindow) -> String {
        let title = window.displayTitle
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = title.isEmpty ? window.appName : title
        return String(base.prefix(60))
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return formatter
    }()
}
