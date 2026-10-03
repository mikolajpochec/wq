import Foundation

/// Looks for a newer release on GitHub, at launch and once a day. It only tells: downloading and
/// installing stay the user's to do, from the release page.
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let page: URL
        let notes: String
    }

    static let latestURL = URL(string: "https://api.github.com/repos/mikolajpochec/wq/releases/latest")!
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
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("WindowQueue/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap(Self.release(from:))
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil, status == 200, let release else {
                    Diagnostics.note("update check failed: status \(status) \(error.map { "\($0)" } ?? "")")
                    if userAsked { self.onFailure?(error?.localizedDescription ?? "GitHub answered \(status)") }
                    return
                }
                self.handle(release, userAsked: userAsked)
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

    /// The release GitHub calls latest; drafts and pre-releases are never it.
    static func release(from data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, page: page, notes: json["body"] as? String ?? "")
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
