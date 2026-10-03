import Foundation

/// Looks for a newer release on GitHub, at launch and once a day. It only tells: downloading and
/// installing stay the user's to do, from the release page.
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
        let notes: String
    }

    /// Redirects to the newest release's page. Not the REST API: that allows 60 anonymous requests
    /// an hour per IP address, shared with everything else on the network, and answers 403 after.
    static let latestURL = URL(string: "https://github.com/mikolajpochec/wq/releases/latest")!
    /// The changelog as tagged with a release, for its notes.
    static func changelogURL(tag: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/mikolajpochec/wq/\(tag)/CHANGELOG.md")!
    }
    private static let interval: TimeInterval = 24 * 60 * 60
    /// The newest version the user has been shown the window for; later checks only keep the menu
    /// item up, so declining is not asked again every day.
    private static let announcedKey = "updateAnnouncedVersion"

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// A newer release than this copy, once a check has found one.
    private(set) var available: Release?
    /// A newer release was found. `announce` is true the first time for that version, or when the
    /// user asked: that is when the window comes up; otherwise only the menu says so.
    var onAvailable: ((Release, _ announce: Bool) -> Void)?
    /// A check the user asked for found nothing newer, or could not reach GitHub.
    var onUpToDate: (() -> Void)?
    var onFailure: ((String) -> Void)?

    private var timer: Timer?

    /// Checks shortly after launch, then once a day, for as long as automatic checks are on.
    func start() {
        guard timer == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.timer != nil else { return }
            self.check(userAsked: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.check(userAsked: false)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check(userAsked: Bool) {
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 20)
        request.httpMethod = "HEAD"
        request.setValue("WindowQueue/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let page = response?.url
            let tag = page.flatMap(Self.tag(fromReleasePage:))
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, status == 200, let page, let tag else {
                    Diagnostics.note("update check failed: status \(status) \(page?.absoluteString ?? "") \(error.map { "\($0)" } ?? "")")
                    if userAsked {
                        self.onFailure?(error?.localizedDescription
                                        ?? (status == 200 ? "No release found on GitHub" : "GitHub answered \(status); try again later"))
                    } else if self.timer != nil {
                        // Offline, or GitHub having a moment: an hour on, not a day.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 60 * 60) { [weak self] in
                            guard let self, self.timer != nil else { return }
                            self.check(userAsked: false)
                        }
                    }
                    return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                Diagnostics.note("update check: latest is \(version), this is \(Self.currentVersion)")
                guard Self.isVersion(version, newerThan: Self.currentVersion) else {
                    self.handle(Release(version: version, page: page, notes: ""), userAsked: userAsked)
                    return
                }
                // The notes are a nicety: without them the release is still announced.
                URLSession.shared.dataTask(with: Self.changelogURL(tag: tag)) { data, _, _ in
                    let notes = data.flatMap { String(data: $0, encoding: .utf8) }.map { Self.notes(for: version, in: $0) } ?? ""
                    DispatchQueue.main.async {
                        self.handle(Release(version: version, page: page, notes: notes), userAsked: userAsked)
                    }
                }.resume()
            }
        }.resume()
    }

    private func handle(_ release: Release, userAsked: Bool) {
        guard Self.isVersion(release.version, newerThan: Self.currentVersion) else {
            available = nil
            if userAsked { onUpToDate?() }
            return
        }
        Diagnostics.note("update available: \(release.version)")
        available = release
        let defaults = UserDefaults.standard
        let announce = userAsked || defaults.string(forKey: Self.announcedKey) != release.version
        defaults.set(release.version, forKey: Self.announcedKey)
        onAvailable?(release, announce)
    }

    /// The tag of a release page, `…/releases/tag/v1.2.0`; nil for anything else, such as the
    /// releases list GitHub sends to when there is no release.
    static func tag(fromReleasePage url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 2, parts[parts.count - 2] == "tag" else { return nil }
        return parts.last
    }

    /// A version's section of the changelog, its wrapped lines joined back up.
    static func notes(for version: String, in changelog: String) -> String {
        var lines: [String] = []
        var inside = false
        for line in changelog.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.dropFirst(3).hasPrefix(version + " ") || line.dropFirst(3) == version
                continue
            }
            if inside { lines.append(line) }
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compares dotted version numbers part by part; a missing part counts as 0.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
