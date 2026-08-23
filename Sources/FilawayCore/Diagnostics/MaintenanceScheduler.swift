import Foundation

/// Housekeeping that has to happen *sometimes*, not *every launch* (M4-08).
///
/// FR-4.4 asks for a 30-day retention window on raw session text; running
/// ``ActivityLog/prune(olderThan:now:keepingUndoDepth:)`` is what enforces it.
/// Running it on every launch would put a write transaction on the launch path
/// for no reason — the window moves by a day at a time — so the scheduler keeps
/// a durable stamp and lets a task through at most once per ``interval``.
///
/// ```swift
/// let maintenance = MaintenanceScheduler(library: library)
/// if await maintenance.isDue(.activityPrune) {
///     let report = try await activity.prune()
///     await maintenance.markRan(.activityPrune)
/// }
/// // …or, in one call:
/// await maintenance.runIfDue(.activityPrune) { try? await activity.prune() }
/// ```
///
/// The stamp lives in `maintenance.json` next to the database rather than in
/// `UserDefaults`: it is per-library derived data, it must not survive the user
/// pointing Filaway at a different folder, and it costs nothing to lose. The
/// clock is injected so the tests can jump a month forward without sleeping.
public actor MaintenanceScheduler {
    /// A recurring job, identified by the key its stamp is filed under.
    public enum Job: String, Sendable, Hashable, CaseIterable, Codable {
        /// ``ActivityLog/prune(olderThan:now:keepingUndoDepth:)`` — FR-4.4.
        case activityPrune
    }

    /// Once a day. FR-4.4's window is 30 days, so a day of slack is invisible.
    public static let defaultInterval: TimeInterval = 24 * 60 * 60

    public let interval: TimeInterval
    private let stampURL: URL
    private let clock: @Sendable () -> Date
    private let fileManager: FileManager
    private var stamps: [String: Date]?
    private let log = Log.make("maintenance")

    public init(
        library: Library,
        interval: TimeInterval = MaintenanceScheduler.defaultInterval,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            stampURL: library.supportDirectory.appendingPathComponent("maintenance.json", isDirectory: false),
            interval: interval,
            fileManager: fileManager,
            clock: clock
        )
    }

    /// Direct form, for tests that want the stamp somewhere specific.
    public init(
        stampURL: URL,
        interval: TimeInterval = MaintenanceScheduler.defaultInterval,
        fileManager: FileManager = .default,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.stampURL = stampURL
        self.interval = interval
        self.fileManager = fileManager
        self.clock = clock
    }

    /// When `job` last ran, as far as the stamp knows.
    public func lastRun(_ job: Job) -> Date? {
        load()[job.rawValue]
    }

    /// `true` when `job` has never run, or ran longer ago than ``interval``.
    public func isDue(_ job: Job) -> Bool {
        guard let last = lastRun(job) else { return true }
        let now = clock()
        // A stamp in the future means the clock moved backwards (a timezone
        // fix, a restored backup). Treat it as due rather than as a lockout.
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Records `job` as having just run.
    public func markRan(_ job: Job) {
        var current = load()
        current[job.rawValue] = clock()
        stamps = current
        save(current)
    }

    /// Runs `work` if it is due, stamping it afterwards.
    ///
    /// - Returns: `true` when `work` ran.
    @discardableResult
    public func runIfDue(_ job: Job, _ work: @Sendable () async -> Void) async -> Bool {
        guard isDue(job) else { return false }
        await work()
        markRan(job)
        log.debug("ran maintenance task \(job.rawValue, privacy: .public)")
        return true
    }

    /// Forgets every stamp — `Settings → Rebuild index` territory.
    public func reset() {
        stamps = [:]
        try? fileManager.removeItem(at: stampURL)
    }

    // MARK: - Stamp file

    private func load() -> [String: Date] {
        if let stamps { return stamps }
        guard let data = fileManager.contents(atPath: stampURL.path),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data)
        else {
            stamps = [:]
            return [:]
        }
        stamps = decoded
        return decoded
    }

    private func save(_ values: [String: Date]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        try? fileManager.createDirectory(
            at: stampURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: stampURL, options: .atomic)
    }
}
