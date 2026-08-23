import Foundation
import Testing

@testable import FilawayCore

// MARK: - A library that lives in memory

/// The library the organizer reads, without touching the disk.
///
/// Mutating it mid-test is the point: an "external edit" is one
/// ``setBody(_:for:)`` call, and that is exactly what makes the
/// compare-and-swap and supersede tests real rather than staged.
actor FakeLibrary: OrganizeLibrarySource {
    private var summaries: [NoteID: NoteSummary] = [:]
    private var bodies: [NoteID: String] = [:]
    private var folders: [String] = []
    private(set) var bodyReads = 0

    init() {}

    @discardableResult
    func add(
        id: NoteID,
        path: String,
        body: String,
        tags: [String] = [],
        modified: Date = Date(timeIntervalSince1970: 1_755_000_000)
    ) -> NoteSummary {
        let summary = NoteSummary(
            id: id,
            relativePath: path,
            title: PathRules.title(of: path),
            folderPath: PathRules.folderPath(of: path),
            tags: tags,
            created: Date(timeIntervalSince1970: 1_750_000_000),
            modified: modified,
            size: body.utf8.count,
            contentHash: Hashing.sha256Hex(body)
        )
        summaries[id] = summary
        bodies[id] = body
        let folder = summary.folderPath
        if !folder.isEmpty, !folders.contains(folder) { folders.append(folder) }
        return summary
    }

    func addFolder(_ path: String) {
        if !folders.contains(path) { folders.append(path) }
    }

    /// An edit, from the user or from an apply.
    func setBody(_ body: String, for id: NoteID) {
        bodies[id] = body
        guard let existing = summaries[id] else { return }
        summaries[id] = NoteSummary(
            id: existing.id,
            relativePath: existing.relativePath,
            title: existing.title,
            folderPath: existing.folderPath,
            tags: existing.tags,
            created: existing.created,
            modified: existing.modified.addingTimeInterval(1),
            size: body.utf8.count,
            contentHash: Hashing.sha256Hex(body)
        )
    }

    func remove(_ id: NoteID) {
        summaries.removeValue(forKey: id)
        bodies.removeValue(forKey: id)
    }

    func currentBody(_ id: NoteID) -> String? { bodies[id] }
    func contentHash(_ id: NoteID) -> String? { summaries[id]?.contentHash }

    // OrganizeLibrarySource

    func snapshot() async throws -> LibrarySnapshot {
        LibrarySnapshot(
            notes: summaries.values.sorted { $0.relativePath < $1.relativePath },
            folderPaths: folders.sorted(),
            scannedAt: Date(timeIntervalSince1970: 1_756_000_000)
        )
    }

    func body(of noteID: NoteID) async throws -> String? {
        bodyReads += 1
        return bodies[noteID]
    }
}

// MARK: - A gate the test opens by hand

/// Holds tasks at a known point so a race can be staged deterministically.
///
/// `wait()` is cancellation-aware, which is what lets the "typing cancels the
/// in-flight request" test assert that `Task.cancel()` actually unwinds the
/// provider call rather than merely setting a flag.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var arrivedCount = 0
    private var nextToken = 0
    private var waiters: [Int: CheckedContinuation<Void, Error>] = [:]

    init(open: Bool = false) {
        isOpen = open
    }

    /// How many tasks have reached the gate.
    var arrivals: Int {
        lock.lock()
        defer { lock.unlock() }
        return arrivedCount
    }

    var waiting: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for (_, continuation) in pending { continuation.resume() }
    }

    func wait() async throws {
        let token: Int = {
            lock.lock()
            defer { lock.unlock() }
            arrivedCount += 1
            nextToken += 1
            return nextToken
        }()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[token] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: token)
            lock.unlock()
            waiter?.resume(throwing: CancellationError())
        }
        try Task.checkCancellation()
    }
}

// MARK: - A provider the test scripts

/// Answers organize requests from a script, optionally behind a ``TestGate``.
final class ScriptedProvider: AIProvider, @unchecked Sendable {
    typealias Handler = @Sendable (AIRequest) throws -> AIResponse

    let identifier = "scripted"
    let gate: TestGate?
    private let lock = NSLock()
    private var handlers: [Handler]
    private var sent: [AIRequest] = []

    init(gate: TestGate? = nil, handlers: [Handler]) {
        self.gate = gate
        self.handlers = handlers
    }

    /// One answer, repeated.
    convenience init(gate: TestGate? = nil, plan: JSONValue) {
        self.init(gate: gate, handlers: [{ _ in .toolUse(name: OrganizationPlan.toolName, input: plan) }])
    }

    convenience init(gate: TestGate? = nil, failing error: AIError) {
        self.init(gate: gate, handlers: [{ _ in throw error }])
    }

    /// Synchronous so the lock is never touched from an async context.
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var requests: [AIRequest] { locked { sent } }

    var requestCount: Int { requests.count }

    func complete(_ request: AIRequest) async throws -> AIResponse {
        let handler: Handler = locked {
            sent.append(request)
            return handlers.count > 1 ? handlers.removeFirst() : handlers[0]
        }
        if let gate { try await gate.wait() }
        try Task.checkCancellation()
        return try handler(request)
    }

    func validateKey() async throws -> [AIModelInfo] {
        AIModel.known.map { AIModelInfo(id: $0.id, displayName: $0.id) }
    }
}

// MARK: - An applier the test scripts

/// Stands in for M2-07's real `PlanApplier`.
///
/// The default behaviour is the honest one: it enforces the plan's
/// compare-and-swap preconditions against the ``FakeLibrary`` it was given, so
/// "accept after an external edit" fails the way the real applier would,
/// without any test having to fake the failure.
final class FakeApplier: PlanApplying, @unchecked Sendable {
    private let lock = NSLock()
    private let library: FakeLibrary?
    private var appliedPlans: [OrganizationPlan] = []
    /// Overrides the default behaviour entirely.
    var handler: (@Sendable (OrganizationPlan) async throws -> AppliedPlan)?
    /// Applied to the library on success, so the organizer's baseline refresh
    /// reads what an apply would really have written.
    var effect: (@Sendable (OrganizationPlan, FakeLibrary) async -> Void)?
    var appliedAt = Date(timeIntervalSince1970: 1_756_000_500)
    /// The Activity event the real applier would have written.
    var eventID = ActivityEventID()

    init(library: FakeLibrary? = nil) {
        self.library = library
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var applied: [OrganizationPlan] { locked { appliedPlans } }

    func apply(_ plan: OrganizationPlan) async throws -> AppliedPlan {
        if let handler {
            let result = try await handler(plan)
            locked { appliedPlans.append(plan) }
            return result
        }

        if let library {
            var missed: [NoteID] = []
            for (id, expected) in plan.preconditions.contentHashes {
                let actual = await library.contentHash(id)
                if actual != expected { missed.append(id) }
            }
            guard missed.isEmpty else { throw ApplyError.preconditionFailed(missed.sorted { $0.uuidString < $1.uuidString }) }
            await effect?(plan, library)
        }

        locked { appliedPlans.append(plan) }

        return AppliedPlan(
            eventID: eventID,
            summary: plan.summary,
            outcomes: plan.actions.enumerated().map { index, action in
                ActionOutcome(index: index, kind: action.kind, detail: "\(action.kind.rawValue) applied")
            },
            changedPaths: changedPaths(plan),
            appliedAt: appliedAt
        )
    }

    /// The final path of every note the plan named, as the real applier reports
    /// it. Only its keys matter to the organizer: they are the notes whose
    /// baselines advance.
    private func changedPaths(_ plan: OrganizationPlan) -> [NoteID: String] {
        var out: [NoteID: String] = [:]
        for id in plan.preconditions.noteIDs { out[id] = id.uuidString }
        return out
    }
}

// MARK: - Waiting without sleeping

/// Yields until `condition` holds.
///
/// Used only to observe that a *task* has reached a known point; every actual
/// deadline in these suites is a manual clock. Falls back to short sleeps after
/// a burst of yields so a genuine hang fails the test instead of spinning
/// forever.
@discardableResult
func waitUntil(
    _ description: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    for spin in 0 ..< 2_000 {
        if await condition() { return true }
        if spin < 200 {
            await Task.yield()
        } else {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    Issue.record("timed out waiting for \(description)", sourceLocation: sourceLocation)
    return false
}

// MARK: - Plans as tool input

enum PlanFixtures {
    static func toolInput(summary: String, actions: [JSONValue]) -> JSONValue {
        .object(["summary": .string(summary), "actions": .array(actions)])
    }

    static func createNote(title: String, folder: String, content: String, tags: [String] = []) -> JSONValue {
        .object([
            "action": "createNote",
            "title": .string(title),
            "folderPath": .string(folder),
            "content": .string(content),
            "tags": .array(tags.map { .string($0) }),
        ])
    }

    static func appendToNote(_ id: NoteID, content: String, heading: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "action": "appendToNote",
            "target": .object(["id": .string(id.uuidString)]),
            "content": .string(content),
        ]
        if let heading { object["heading"] = .string(heading) }
        return .object(object)
    }

    static func retitle(_ id: NoteID, to title: String) -> JSONValue {
        .object([
            "action": "retitleNote",
            "note": .object(["id": .string(id.uuidString)]),
            "newTitle": .string(title),
        ])
    }

    static func createFolder(_ path: String) -> JSONValue {
        .object(["action": "createFolder", "path": .string(path)])
    }

    static func tag(_ id: NoteID, _ tags: [String]) -> JSONValue {
        .object([
            "action": "tagNote",
            "note": .object(["id": .string(id.uuidString)]),
            "tags": .array(tags.map { .string($0) }),
        ])
    }

    static func moveSegment(
        from source: NoteID,
        segment: String,
        toExisting destination: NoteID,
        heading: String? = nil
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "action": "moveSegment",
            "source": .object(["id": .string(source.uuidString)]),
            "segment": .string(segment),
            "segmentHash": .string(Hashing.sha256Hex(segment)),
            "destination": .object([
                "kind": "existingNote",
                "note": .object(["id": .string(destination.uuidString)]),
            ]),
        ]
        if let heading { object["heading"] = .string(heading) }
        return .object(object)
    }

    static func moveNote(_ id: NoteID, to folder: String) -> JSONValue {
        .object([
            "action": "moveNote",
            "note": .object(["id": .string(id.uuidString)]),
            "toFolderPath": .string(folder),
        ])
    }
}

// MARK: - Event helpers

extension EventRecorder where Event == OrganizerEvent {
    var proposals: [ProposedPlan] {
        events.compactMap { if case let .proposed(plan) = $0 { return plan } else { return nil } }
    }

    var appliedPlans: [AppliedPlan] {
        events.compactMap { if case let .applied(plan) = $0 { return plan } else { return nil } }
    }

    var kinds: [String] {
        events.map { event in
            switch event {
            case .proposed: return "proposed"
            case .applied: return "applied"
            case let .withdrawn(_, reason): return "withdrawn(\(reason.rawValue))"
            case .stale: return "stale"
            case .cancelled: return "cancelled"
            case let .skipped(_, reason): return "skipped(\(reason.rawValue))"
            case .failed: return "failed"
            case .queued: return "queued"
            case .retrying: return "retrying"
            }
        }
    }

    var failures: [OrganizeFailure] {
        events.compactMap { if case let .failed(_, failure) = $0 { return failure } else { return nil } }
    }
}
