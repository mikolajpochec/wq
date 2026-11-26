import Foundation

/// Notices when the main thread stops responding, and leaves evidence of why.
///
/// A timer on the main run loop beats a few times a second. When a beat comes late, the stall is
/// noted in `events.log` (always on: one line per stall, next to the breadcrumbs that say what was
/// happening). With diagnostics on, a stall that is still going on after `sampleAfter` also gets a
/// `sample` of the whole process taken while it is stuck, written to `hang-<time>.txt` beside the
/// other logs, so the stack that froze is on record rather than guessed at.
enum HangWatchdog {
    /// A beat this late is a stall worth a line in the log.
    static let reportAfter: TimeInterval = 0.5
    /// A stall this long, still going, is sampled (diagnostics only).
    static let sampleAfter: TimeInterval = 1.2
    /// At most one sample this often, so a run of freezes does not fill the disk.
    static let sampleInterval: TimeInterval = 300
    /// Hang samples kept; older ones are deleted.
    static let samplesKept = 5

    private static let beatInterval: TimeInterval = 0.25
    private static let lock = NSLock()
    private static var lastBeat = Date()
    private static var started = false

    static func start() {
        guard !started else { return }
        started = true
        lastBeat = Date()

        var previous = Date()
        let timer = Timer(timeInterval: beatInterval, repeats: true) { _ in
            let now = Date()
            let gap = now.timeIntervalSince(previous) - beatInterval
            previous = now
            lock.lock()
            lastBeat = now
            lock.unlock()
            // Far longer than any freeze: the Mac was asleep, not the app.
            if gap >= reportAfter, gap < 60 {
                Diagnostics.note(String(format: "hang: main thread stalled for %.2f s", gap))
            }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)

        let thread = Thread { watch() }
        thread.name = "WindowQueue.hangWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    private static func watch() {
        var lastSample = Date.distantPast
        var sampledThisStall = false
        var lastWake = Date()
        while true {
            Thread.sleep(forTimeInterval: beatInterval)
            let now = Date()
            // This thread was not running either (the Mac slept): what looks like a stall is not one.
            let asleep = now.timeIntervalSince(lastWake) > 2
            lastWake = now
            lock.lock()
            if asleep { lastBeat = now }
            let stalled = now.timeIntervalSince(lastBeat)
            lock.unlock()

            if stalled < reportAfter {
                sampledThisStall = false
                continue
            }
            guard stalled >= sampleAfter, !sampledThisStall,
                  now.timeIntervalSince(lastSample) >= sampleInterval,
                  Diagnostics.isEnabled
            else { continue }
            sampledThisStall = true
            lastSample = now
            takeSample()
        }
    }

    /// Runs `/usr/bin/sample` on this process for a couple of seconds; the main thread's stack in
    /// it is the one that is stuck.
    private static func takeSample() {
        let directory = Diagnostics.eventsURL.deletingLastPathComponent()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = directory.appendingPathComponent("hang-\(formatter.string(from: Date())).txt")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), "2", "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in pruneSamples(in: directory) }
        do {
            try process.run()
            Diagnostics.note("hang: sampling the stalled main thread to \(file.lastPathComponent)")
        } catch {
            Diagnostics.note("hang: could not run sample: \(error.localizedDescription)")
        }
    }

    private static func pruneSamples(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // The names sort by time.
        let samples = names.filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }.sorted()
        for name in samples.dropLast(samplesKept) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
