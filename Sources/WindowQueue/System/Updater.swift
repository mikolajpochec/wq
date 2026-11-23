import AppKit
import Security

/// Installs a release found by `UpdateChecker` in place: downloads its zip from GitHub, checks the
/// app inside is signed by the same identity as WindowQueue's releases (or as this copy), then
/// swaps it in for this copy once it has quit and opens it again.
final class Updater: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case installing
        case failed(String)
    }

    /// Releases are signed with the self-signed "WindowQueue Release" certificate; see
    /// `Scripts/release.sh`. A download that doesn't satisfy this (or this copy's own designated
    /// requirement) is never installed.
    static let releaseRequirement =
        #"identifier "com.mpochec.windowqueue" and certificate leaf = H"a028ff026f9b63696b73329ca75d30348aea1a2e""#
    static let appName = "WindowQueue"

    @Published private(set) var state: State = .idle

    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?

    /// Where a release's zip is attached, as `make release` names it.
    static func assetURL(version: String) -> URL {
        URL(string: "https://github.com/mikolajpochec/wq/releases/download/v\(version)/\(appName)-\(version).zip")!
    }

    var isBusy: Bool {
        switch state {
        case .downloading, .installing: return true
        default: return false
        }
    }

    /// The reason this copy can't replace itself, such as running from the disk image.
    static var cannotInstallReason: String? {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return "Move WindowQueue to the Applications folder first."
        }
        let parent = (path as NSString).deletingLastPathComponent
        if !FileManager.default.isWritableFile(atPath: parent) || !FileManager.default.isWritableFile(atPath: path) {
            return "WindowQueue can't write to \(parent)."
        }
        return nil
    }

    func install(_ release: UpdateChecker.Release) {
        guard !isBusy else { return }
        if let reason = Self.cannotInstallReason { return fail(reason) }
        Diagnostics.note("update: downloading \(release.version)")
        state = .downloading(0)
        var request = URLRequest(url: Self.assetURL(version: release.version), timeoutInterval: 60)
        request.setValue("\(Self.appName)/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        let task = URLSession.shared.downloadTask(with: request) { [weak self] file, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // The file is removed once this returns: move it somewhere of our own first.
            var zip: URL?
            if let file, error == nil, status == 200 {
                let dir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(Self.appName)-update-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let dest = dir.appendingPathComponent("\(Self.appName)-\(release.version).zip")
                if (try? FileManager.default.moveItem(at: file, to: dest)) != nil { zip = dest }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress = nil
                self.download = nil
                guard let zip else {
                    Diagnostics.note("update: download failed: status \(status) \(error.map { "\($0)" } ?? "")")
                    if (error as? URLError)?.code == .cancelled { self.state = .idle; return }
                    return self.fail(error?.localizedDescription ?? "GitHub answered \(status).")
                }
                self.state = .installing
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Self.prepare(zip: zip, version: release.version)
                    DispatchQueue.main.async {
                        switch result {
                        case .failure(let error): self.fail(error.message)
                        case .success(let app): self.swapAndRelaunch(with: app)
                        }
                    }
                }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                if case .downloading = self?.state { self?.state = .downloading(p.fractionCompleted) }
            }
        }
        download = task
        task.resume()
    }

    /// Sets the state directly, for rendering the window's looks offscreen.
    func preview(_ state: State) { self.state = state }

    func cancel() {
        download?.cancel()
    }

    private func fail(_ message: String) {
        Diagnostics.note("update: failed: \(message)")
        state = .failed(message)
    }

    struct Failure: Error { let message: String }

    /// Unpacks the zip next to it and checks what came out: the app, its version, its signature.
    static func prepare(zip: URL, version: String) -> Result<URL, Failure> {
        let dir = zip.deletingLastPathComponent()
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // ditto, not unzip: unzip leaves AppleDouble files that break the signature.
        ditto.arguments = ["-x", "-k", zip.path, dir.path]
        do { try ditto.run() } catch { return .failure(Failure(message: "Couldn't unpack the update.")) }
        ditto.waitUntilExit()
        let app = dir.appendingPathComponent("\(appName).app")
        guard ditto.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            return .failure(Failure(message: "The download didn't contain WindowQueue."))
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version else {
            return .failure(Failure(message: "The download isn't WindowQueue \(version)."))
        }
        guard isTrusted(app) else {
            return .failure(Failure(message: "The download isn't signed by WindowQueue's developer, so it wasn't installed."))
        }
        return .success(app)
    }

    /// Whether the app at `url` is intact and signed like the releases, or like this copy.
    static func isTrusted(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var requirements: [SecRequirement] = []
        var release: SecRequirement?
        if SecRequirementCreateWithString(releaseRequirement as CFString, [], &release) == errSecSuccess, let release {
            requirements.append(release)
        }
        var me: SecCode?
        var mine: SecRequirement?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me {
            var myStatic: SecStaticCode?
            if SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
               SecCodeCopyDesignatedRequirement(myStatic, [], &mine) == errSecSuccess, let mine {
                requirements.append(mine)
            }
        }
        return requirements.contains { SecStaticCodeCheckValidity(code, flags, $0) == errSecSuccess }
    }

    /// Hands the swap to a shell that outlives this process: it waits for WindowQueue to quit,
    /// moves the new app into place (putting the old one back if that fails) and opens it.
    private func swapAndRelaunch(with app: URL) {
        let target = Bundle.main.bundleURL
        let backup = app.deletingLastPathComponent().appendingPathComponent("\(Self.appName)-previous.app")
        let script = """
            pid="$1"; new="$2"; target="$3"; backup="$4"
            for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
            if mv "$target" "$backup"; then
                if mv "$new" "$target"; then rm -rf "$backup"; else mv "$backup" "$target"; fi
            fi
            xattr -dr com.apple.quarantine "$target" 2>/dev/null
            open "$target"
            rm -rf "$(dirname "$new")"
            """
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "sh", "\(ProcessInfo.processInfo.processIdentifier)",
                           app.path, target.path, backup.path]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = FileHandle.nullDevice
        shell.standardError = FileHandle.nullDevice
        do {
            try shell.run()
        } catch {
            return fail("Couldn't start the installer.")
        }
        Diagnostics.note("update: installing \(app.path) over \(target.path), relaunching")
        NSApp.terminate(nil)
    }
}
