import Foundation

/// The last text of a note the AI has already had a chance to organize
/// (plan §1 "Session/concurrency": *each note has an organized baseline
/// (content hash + text)*).
///
/// The delta a session sends to the provider is `baseline → current`. A note
/// that has never been organized has no baseline, which
/// ``OrganizedBaseline/creation(_:at:)`` models as empty text: the first
/// session therefore sends the whole note, which is exactly right for a note
/// created during that session.
public struct OrganizedBaseline: Sendable, Hashable, Codable {
    public var noteID: NoteID
    /// SHA-256 (lowercase hex) of ``text``.
    public var contentHash: String
    /// The note body as it stood when the baseline was set.
    public var text: String
    /// When the baseline last advanced.
    public var updatedAt: Date
    /// The session that advanced it, when there was one.
    public var sessionID: SessionID?

    public init(noteID: NoteID, text: String, updatedAt: Date, sessionID: SessionID? = nil) {
        self.noteID = noteID
        self.text = text
        contentHash = Hashing.sha256Hex(text)
        self.updatedAt = updatedAt
        self.sessionID = sessionID
    }

    /// The stored form, with the hash as it was written. Used when reading a row
    /// back out of `note_baselines`, where the hash is a column rather than
    /// something to recompute.
    public init(noteID: NoteID, contentHash: String, text: String, updatedAt: Date, sessionID: SessionID? = nil) {
        self.noteID = noteID
        self.contentHash = contentHash
        self.text = text
        self.updatedAt = updatedAt
        self.sessionID = sessionID
    }

    /// The baseline of a note the AI has never seen.
    public static func creation(_ noteID: NoteID, at now: Date = Date()) -> OrganizedBaseline {
        OrganizedBaseline(noteID: noteID, text: "", updatedAt: now)
    }

    public var isEmpty: Bool { text.isEmpty }
}

/// Where organized baselines live.
///
/// Behind a protocol because the durable implementation is a GRDB table
/// (`note_baselines`, migration `v4-activity`) owned by the apply/activity work,
/// and neither ``Organizer`` nor its tests may depend on a database being there.
///
/// This is the *only* baseline contract (ADR-033). ``ActivityLog`` and
/// ``DatabaseBaselineStore`` are the durable implementations;
/// ``InMemoryBaselineStore`` is the reference one.
public protocol BaselineStore: Sendable {
    func baseline(for noteID: NoteID) async throws -> OrganizedBaseline?
    func baselines(for noteIDs: [NoteID]) async throws -> [NoteID: OrganizedBaseline]
    func setBaseline(_ baseline: OrganizedBaseline) async throws
    func removeBaseline(for noteID: NoteID) async throws
}

public extension BaselineStore {
    /// Default fan-out, overridden by stores that can do it in one query.
    func baselines(for noteIDs: [NoteID]) async throws -> [NoteID: OrganizedBaseline] {
        var out: [NoteID: OrganizedBaseline] = [:]
        for id in noteIDs {
            if let baseline = try await baseline(for: id) { out[id] = baseline }
        }
        return out
    }

    /// Advances a baseline to `text`.
    func advance(_ noteID: NoteID, to text: String, at now: Date, sessionID: SessionID? = nil) async throws {
        try await setBaseline(
            OrganizedBaseline(noteID: noteID, text: text, updatedAt: now, sessionID: sessionID)
        )
    }

    /// Column-shaped convenience, for callers that already hold the hash.
    func setBaseline(noteID: NoteID, hash: String, text: String, at now: Date = Date()) async throws {
        try await setBaseline(
            OrganizedBaseline(noteID: noteID, contentHash: hash, text: text, updatedAt: now)
        )
    }
}

/// The in-memory baseline store: what the tests use, what the app falls back to
/// before the database exists, and the reference for the durable one.
///
/// Losing it is not a correctness problem, only a cost one: an empty baseline
/// makes the next session look like "the whole note is new", so the AI is asked
/// to file text it has already seen. Nothing is lost or double-applied — the
/// plan still goes through validation and compare-and-swap.
public actor InMemoryBaselineStore: BaselineStore {
    private var baselines: [NoteID: OrganizedBaseline]

    public init(_ baselines: [NoteID: OrganizedBaseline] = [:]) {
        self.baselines = baselines
    }

    public func baseline(for noteID: NoteID) async throws -> OrganizedBaseline? {
        baselines[noteID]
    }

    public func baselines(for noteIDs: [NoteID]) async throws -> [NoteID: OrganizedBaseline] {
        var out: [NoteID: OrganizedBaseline] = [:]
        for id in noteIDs {
            if let baseline = baselines[id] { out[id] = baseline }
        }
        return out
    }

    public func setBaseline(_ baseline: OrganizedBaseline) async throws {
        baselines[baseline.noteID] = baseline
    }

    public func removeBaseline(for noteID: NoteID) async throws {
        baselines.removeValue(forKey: noteID)
    }

    /// Everything stored — tests and diagnostics only.
    public var all: [NoteID: OrganizedBaseline] { baselines }
}
