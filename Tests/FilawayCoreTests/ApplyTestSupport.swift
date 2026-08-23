import Foundation
import Testing

@testable import FilawayCore

/// A monotonic, injectable clock.
///
/// Every read advances by a millisecond so no two Activity events can share a
/// timestamp (the LIFO ordering is `created_at DESC, id DESC`, and a uuid tie
/// break would be arbitrary). ``advance(_:)`` jumps forward for retention tests.
final class ApplyClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    var now: @Sendable () -> Date {
        { [self] in
            lock.lock()
            defer { lock.unlock() }
            let value = current
            current = current.addingTimeInterval(0.001)
            return value
        }
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    var date: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }
}

/// A throwaway library wired to a ``PlanApplier``, an ``ActivityLog`` and an
/// ``UndoService``, plus the fingerprinting the "byte-identical tree" tests need.
final class ApplyHarness {
    let temp: TempLibrary
    let activity: ActivityLog
    let clock: ApplyClock
    private(set) var applier: PlanApplier
    let undo: UndoService

    var store: NoteStore { temp.store }
    var library: Library { temp.library }

    init(
        clock: ApplyClock = ApplyClock(),
        excludedFolders: [String] = [],
        failureHook: ApplyFailureHook? = nil,
        onDisk: Bool = false
    ) throws {
        temp = try TempLibrary()
        self.clock = clock
        activity = onDisk
            ? try ActivityLog(library: temp.library)
            : try ActivityLog(inMemoryFor: temp.library)
        applier = PlanApplier(
            store: temp.store,
            activity: activity,
            excludedFolders: excludedFolders,
            clock: clock.now,
            failureHook: failureHook
        )
        undo = UndoService(store: temp.store, activity: activity, clock: clock.now)
    }

    /// A fresh applier over the same library and journal — "the app relaunched".
    func restart(failureHook: ApplyFailureHook? = nil) -> PlanApplier {
        applier = PlanApplier(
            store: temp.store,
            activity: activity,
            clock: clock.now,
            failureHook: failureHook
        )
        return applier
    }

    // MARK: - Seeding

    @discardableResult
    func seed(_ relativePath: String, _ body: String, tags: [String] = []) async throws -> NoteSummary {
        let folder = PathRules.folderPath(of: relativePath)
        if !folder.isEmpty { try await store.createFolder(folder) }
        return try await store.save(body: body, to: relativePath, tags: tags.isEmpty ? nil : tags)
    }

    func snapshot() async throws -> LibrarySnapshot {
        try await store.scan(settleWindow: 0)
    }

    func note(_ relativePath: String) async throws -> Note {
        try await store.read(relativePath)
    }

    func body(_ relativePath: String) async throws -> String {
        try await store.read(relativePath).body
    }

    func id(of relativePath: String) async throws -> NoteID {
        try await store.read(relativePath).id
    }

    /// Builds a plan and attaches the compare-and-swap preconditions the
    /// validator insists on, taken from the library as it stands right now.
    func plan(
        _ actions: [PlanAction],
        summary: String = "Test plan",
        bodiesFor paths: [String] = []
    ) async throws -> OrganizationPlan {
        let snapshot = try await snapshot()
        var bodies: [NoteID: String] = [:]
        for path in paths {
            let note = try await store.read(path)
            bodies[note.id] = note.body
        }
        let context = OrganizeContext(snapshot: snapshot, bodies: bodies)
        var plan = OrganizationPlan(summary: summary, actions: actions)
        plan.preconditions = context.preconditions(for: plan)
        return plan
    }

    // MARK: - Applying

    @discardableResult
    func apply(_ plan: OrganizationPlan, sessionText: String? = nil) async throws -> AppliedPlan {
        let result = try await applier.apply(plan, sessionText: sessionText)
        track(result)
        return result
    }

    @discardableResult
    func undoLatest() async throws -> UndoResult {
        let result = try await undo.undoLatest()
        track(result)
        return result
    }

    @discardableResult
    func undo(_ eventID: ActivityEventID) async throws -> UndoResult {
        let result = try await undo.undo(eventID)
        track(result)
        return result
    }

    /// Keeps the developer's Trash clean: everything the applier or Undo
    /// trashed is removed when the harness goes away.
    func track(_ applied: AppliedPlan) {
        for trashed in applied.trashedNotes {
            if let path = trashed.trashURL { temp.trackTrashed(URL(fileURLWithPath: path)) }
        }
    }

    func track(_ result: UndoResult) {
        for note in result.notes {
            if let path = note.trashURL { temp.trackTrashed(URL(fileURLWithPath: path)) }
        }
    }

    func track(_ outcomes: [RecoveryOutcome]) {
        for outcome in outcomes {
            for url in outcome.trashURLs { temp.trackTrashed(URL(fileURLWithPath: url)) }
        }
    }

    @discardableResult
    func recover() async throws -> [RecoveryOutcome] {
        let outcomes = try await applier.recoverIncompleteEvents()
        track(outcomes)
        return outcomes
    }

    // MARK: - Fingerprints

    /// Every `.md` file in the library, as `path → SHA-256 of its bytes`. Two
    /// equal fingerprints mean two byte-identical trees.
    func fingerprint() -> [String: String] {
        var out: [String: String] = [:]
        for path in temp.allMarkdownPaths() {
            let data = FileManager.default.contents(atPath: temp.url(path).path) ?? Data()
            out[path] = Hashing.sha256Hex(data)
        }
        return out
    }

    /// Every folder in the library, sorted.
    func folders() -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: temp.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let relative = temp.library.relativePath(for: url) else { continue }
            out.append(relative)
        }
        return out.sorted()
    }
}

/// `#expect(throws:)` cannot see inside an associated value, so the apply and
/// undo suites use this instead.
func expectThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    _ check: (any Error) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        _ = try await expression()
        Issue.record("expected an error, got a value", sourceLocation: sourceLocation)
    } catch {
        if !check(error) {
            Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
        }
    }
}
