import AppKit
import Combine
import ScreenCaptureKit

/// Recording a window and taking a picture of one.
///
/// Pictures go through `screencapture -l`, which is what macOS itself uses for ⌘⇧4 Space, so the
/// files land where the user's own screenshots land. Recordings have no such tool — `screencapture
/// -v` only does whole displays or rectangles — so they run a ScreenCaptureKit stream filtered to
/// the one window, which keeps other windows, the desktop and the strip out of the video.
final class ScreenCapture: NSObject, ObservableObject, SCStreamDelegate {
    static let shared = ScreenCapture()

    /// A recording is running, which the strip shows in place of the workspace number.
    @Published private(set) var isRecording = false

    private var stream: SCStream?
    private var output: AnyObject?
    private var recordingURL: URL?

    private override init() {}

    // MARK: - Recording

    /// Starts recording this one window, or stops the recording already running.
    /// - Parameter completion: on the main queue, what happened, for the popup to say; `url` is nil
    ///   when a recording could not be started.
    func toggleRecording(_ window: ManagedWindow?, completion: @escaping (_ started: Bool, _ url: URL?) -> Void) {
        if isRecording {
            let url = recordingURL
            stopRecording { completion(false, url) }
            return
        }
        guard let window else { return completion(false, nil) }
        guard #available(macOS 15.0, *) else {
            Diagnostics.note("recording a window needs macOS 15")
            return completion(false, nil)
        }
        let url = destination(name: name(for: window), extension: "mov")
        // Not only on-screen windows: the window may sit on another workspace, and a
        // desktop-independent filter records it all the same.
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let target = content?.windows.first(where: { $0.windowID == window.id }) else {
                    Diagnostics.note("recording: window \(window.id) not shareable \(error?.localizedDescription ?? "")")
                    return completion(false, nil)
                }
                self.startRecording(target, to: url, completion: completion)
            }
        }
    }

    @available(macOS 15.0, *)
    private func startRecording(_ window: SCWindow, to url: URL,
                                completion: @escaping (_ started: Bool, _ url: URL?) -> Void) {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = max(2, Int(filter.contentRect.width * scale))
        configuration.height = max(2, Int(filter.contentRect.height * scale))
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.showsCursor = true
        configuration.ignoreShadowsSingleWindow = true

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = url
        recordingConfiguration.outputFileType = .mov
        let recording = SCRecordingOutput(configuration: recordingConfiguration, delegate: RecordingDelegate.shared)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addRecordingOutput(recording)
        } catch {
            Diagnostics.note("recording failed to start: \(error.localizedDescription)")
            return completion(false, nil)
        }
        self.stream = stream
        output = recording
        recordingURL = url
        isRecording = true
        stream.startCapture { [weak self] error in
            DispatchQueue.main.async {
                if let error {
                    Diagnostics.note("recording failed to start: \(error.localizedDescription)")
                    self?.reset()
                    return completion(false, nil)
                }
                Diagnostics.note("recording window \(window.windowID) to \(url.path)")
                completion(true, url)
            }
        }
    }

    /// Ends the capture, which finishes the file.
    func stopRecording(_ completion: @escaping () -> Void = {}) {
        guard let stream else {
            reset()
            return completion()
        }
        stream.stopCapture { [weak self] error in
            DispatchQueue.main.async {
                if let error { Diagnostics.note("recording stop: \(error.localizedDescription)") }
                self?.reset()
                Diagnostics.note("recording stopped")
                completion()
            }
        }
    }

    private func reset() {
        stream = nil
        output = nil
        isRecording = false
    }

    /// The stream ends by itself when the window goes away.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            Diagnostics.note("recording ended: \(error.localizedDescription)")
            self.reset()
        }
    }

    // MARK: - Screenshots

    /// Takes a picture of the window on its own — nothing around or over it.
    /// - Returns: the file written.
    func screenshot(_ window: ManagedWindow) -> URL? {
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
            return nil
        }
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: url.path) else {
            Diagnostics.note("screenshot of \(window.id) produced nothing")
            return nil
        }
        return url
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

@available(macOS 15.0, *)
private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    static let shared = RecordingDelegate()

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Diagnostics.note("recording output started")
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Diagnostics.note("recording output finished")
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Diagnostics.note("recording output failed: \(error.localizedDescription)")
    }
}
