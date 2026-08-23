import Foundation

/// A filesystem change Filaway itself made.
///
/// FSEvents cannot tell the app's own atomic write apart from the user editing
/// the file in BBEdit, so ``NoteStore`` records every write, move and delete it
/// performs and the watcher *consumes* the matching record instead of emitting
/// an echo (DS-4, plan §1 "own writes tagged for echo suppression").
public struct OwnOperation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case write
        case remove
    }

    public let kind: Kind
    public let relativePath: String
    /// Hash of the bytes written; `nil` for removals.
    public let contentHash: String?
    /// The file's mtime after the write; `nil` for removals.
    public let modified: Date?
    public let recordedAt: Date

    public init(kind: Kind, relativePath: String, contentHash: String?, modified: Date?, recordedAt: Date = Date()) {
        self.kind = kind
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.modified = modified
        self.recordedAt = recordedAt
    }
}

/// Bounded, self-pruning ledger of ``OwnOperation`` records.
///
/// Records expire after ``timeToLive`` so a crash mid-reconcile cannot suppress
/// a genuine external change forever, and the ledger is capped so a long
/// autosave session cannot grow it without bound.
struct OwnOperationLedger {
    var timeToLive: TimeInterval = 30
    var capacity: Int = 512
    private var records: [OwnOperation] = []

    var count: Int { records.count }

    mutating func record(_ operation: OwnOperation) {
        prune(now: operation.recordedAt)
        records.append(operation)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }

    /// Removes and reports a matching record.
    ///
    /// A write matches on path *and* hash, so a genuine external edit that lands
    /// after our own write is never mistaken for an echo. A removal matches on
    /// path alone.
    mutating func consume(relativePath: String, contentHash: String?, now: Date = Date()) -> Bool {
        prune(now: now)
        let wanted: OwnOperation.Kind = contentHash == nil ? .remove : .write
        guard let index = records.lastIndex(where: {
            $0.relativePath == relativePath && $0.kind == wanted && $0.contentHash == contentHash
        }) else { return false }
        records.remove(at: index)
        return true
    }

    mutating func prune(now: Date = Date()) {
        records.removeAll { now.timeIntervalSince($0.recordedAt) > timeToLive }
    }
}
