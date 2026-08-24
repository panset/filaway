import Foundation
import Testing

@testable import FilawayCore

extension Tag {
    /// Heavier suites (5,000-note scale, filesystem churn). Skipped when
    /// `FILAWAY_SKIP_SLOW_TESTS=1`.
    @Tag static var slow: Self
    /// Needs a live FSEvents stream; timing-sensitive.
    @Tag static var fsevents: Self
}

/// Swift Testing tags are not filterable from the SwiftPM 6.0.3 command line, so
/// the heavy suites are additionally gated on environment variables:
///
/// * `FILAWAY_SKIP_SLOW_TESTS=1` — skip the churn, scale and FSEvents suites.
/// * `FILAWAY_SKIP_FSEVENTS_TESTS=1` — skip only the live-FSEvents suite, which
///   is the timing-sensitive one on a loaded CI runner.
enum TestEnvironment {
    static var runsSlowTests: Bool {
        ProcessInfo.processInfo.environment["FILAWAY_SKIP_SLOW_TESTS"] != "1"
    }

    static var runsFSEventsTests: Bool {
        runsSlowTests && ProcessInfo.processInfo.environment["FILAWAY_SKIP_FSEVENTS_TESTS"] != "1"
    }

    /// `true` on a hosted CI runner (GitHub Actions sets `CI=true`).
    static var isCI: Bool {
        ProcessInfo.processInfo.environment["CI"] != nil
    }

    /// Perf budgets describe *the machine* (convention 8, NFR-1/NFR-2), and a
    /// shared virtualized runner is not the machine — measured 107.8 ms there
    /// for a p95 that is 60 ms on the M2 the numbers were set on. On CI the
    /// budgets stretch ×2: still a regression gate for anything real, no longer
    /// a coin toss over the runner's neighbours.
    static var perfBudgetScale: Double { isCI ? 2.0 : 1.0 }
}

/// A throwaway notes root plus its own Application Support directory, so no test
/// ever touches `~/Notes` or the user's real derived data.
final class TempLibrary {
    let base: URL
    let root: URL
    let supportRoot: URL
    let library: Library
    let store: NoteStore
    /// Anything moved to the Trash during the test, removed again on teardown.
    private var trashed: [URL] = []

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("filaway-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Notes", isDirectory: true)
        supportRoot = base.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportRoot, withIntermediateDirectories: true)
        library = Library(root: root, supportRoot: supportRoot)
        store = NoteStore(library: library)
    }

    deinit {
        for url in trashed { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: base)
    }

    /// Remember a Trash URL so teardown removes it — tests must not litter the
    /// developer's Trash.
    func trackTrashed(_ url: URL) { trashed.append(url) }

    // MARK: - "External" filesystem operations (as if another app did them)

    func url(_ relativePath: String) -> URL { library.url(for: relativePath) }

    @discardableResult
    func writeExternal(_ text: String, to relativePath: String) throws -> URL {
        let url = url(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    func readExternal(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    func removeExternal(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: url(relativePath))
    }

    func moveExternal(_ from: String, to: String) throws {
        let destination = url(to)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(from), to: destination)
    }

    func makeExternalFolder(_ path: String) throws {
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
    }

    /// Pushes a file's mtime into the past so scans treat it as settled.
    func backdate(_ relativePath: String, by seconds: TimeInterval = 5) throws {
        let target = url(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        try FileManager.default.setAttributes(
            [.modificationDate: modified.addingTimeInterval(-seconds)],
            ofItemAtPath: target.path
        )
    }

    /// Every `.md` file under the root, as relative paths.
    func allMarkdownPaths() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            guard let relative = library.relativePath(for: url), PathRules.isNotePath(relative) else { continue }
            out.append(relative)
        }
        return out.sorted()
    }

    /// Every non-`.md`, non-folder entry inside the notes root — DS-1 says there
    /// must never be one.
    func strayEntries() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let relative = library.relativePath(for: url) else { continue }
            if !PathRules.isNotePath(relative) { out.append(relative) }
        }
        return out.sorted()
    }
}

/// Polls `condition` until it holds or `timeout` elapses.
func waitUntil(
    timeout: TimeInterval = 10,
    pollInterval: TimeInterval = 0.05,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    return await condition()
}
