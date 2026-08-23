import Foundation
import GRDB

/// Opening a SQLite file that a power cut, a half-synced cloud folder or a bad
/// sector left unreadable (NFR-3, M4-08).
///
/// SQLite recovers from a torn write on its own — that is what the WAL is for.
/// What it cannot recover from is a file whose *header* no longer says
/// "SQLite format 3", which is what a truncated copy, an interrupted restore or
/// a cloud-sync conflict produces. Every open in Filaway therefore goes through
/// ``open(at:configuration:fileManager:now:prepare:)``:
///
/// 1. Open and migrate.
/// 2. If that fails with `SQLITE_NOTADB` / `SQLITE_CORRUPT`, move the file (and
///    its `-wal` / `-shm` sidecars) aside as `<name>.corrupt-<timestamp>` and
///    try once more against an empty file.
/// 3. Report where the old file went, so the caller can rebuild and the user
///    can be told rather than left wondering.
///
/// The corrupt file is **moved, never deleted**: `filaway.sqlite` holds the
/// Activity log and the organized baselines as well as the derived index, and
/// only the derived half can be rebuilt from the notes folder. Keeping the
/// bytes leaves a salvage path (see ADR-049).
public enum DatabaseFile {
    private static let log = Log.make("storage")

    /// A database that is open, plus where its unreadable predecessor went.
    public struct Opened {
        public var queue: DatabaseQueue
        /// Non-`nil` when the file that was there had to be moved aside; the
        /// caller is holding a brand-new, empty database.
        public var movedAside: URL?

        public init(queue: DatabaseQueue, movedAside: URL? = nil) {
            self.queue = queue
            self.movedAside = movedAside
        }
    }

    /// SQLite sidecar files that belong to `url` and must travel with it.
    public static func sidecars(of url: URL) -> [URL] {
        ["-wal", "-shm", "-journal"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// `<name>.corrupt-<yyyyMMdd-HHmmss>`, uniquified if that already exists.
    public static func asideURL(for url: URL, at now: Date, fileManager: FileManager = .default) -> URL {
        let stamp = ISO8601.string(from: now)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        var candidate = URL(fileURLWithPath: url.path + ".corrupt-" + stamp)
        var attempt = 2
        while fileManager.fileExists(atPath: candidate.path), attempt < 1_000 {
            candidate = URL(fileURLWithPath: url.path + ".corrupt-" + stamp + "-\(attempt)")
            attempt += 1
        }
        return candidate
    }

    /// `true` for the two result codes that mean "these bytes are not a
    /// database" rather than "this query was wrong".
    public static func isCorruption(_ error: any Error) -> Bool {
        guard let database = error as? DatabaseError else { return false }
        return database.resultCode == .SQLITE_NOTADB || database.resultCode == .SQLITE_CORRUPT
    }

    /// Moves an unreadable database out of the way, sidecars and all.
    ///
    /// - Returns: where the main file went.
    @discardableResult
    public static func moveAside(
        _ url: URL,
        at now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = asideURL(for: url, at: now, fileManager: fileManager)
        try fileManager.moveItem(at: url, to: destination)
        for sidecar in sidecars(of: url) where fileManager.fileExists(atPath: sidecar.path) {
            let suffix = String(sidecar.path.dropFirst(url.path.count))
            try? fileManager.moveItem(at: sidecar, to: URL(fileURLWithPath: destination.path + suffix))
        }
        return destination
    }

    /// Opens `url`, moving it aside and starting over if its bytes are not a
    /// database.
    ///
    /// - Parameter prepare: migrations and any first-open bookkeeping. It runs
    ///   inside the corruption guard, because a bad header only surfaces when
    ///   something actually reads the file.
    public static func open(
        at url: URL,
        configuration: Configuration,
        fileManager: FileManager = .default,
        now: Date = Date(),
        prepare: (DatabaseQueue) throws -> Void
    ) throws -> Opened {
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            try prepare(queue)
            return Opened(queue: queue)
        } catch {
            guard isCorruption(error), fileManager.fileExists(atPath: url.path) else { throw error }
            let aside = try moveAside(url, at: now, fileManager: fileManager)
            log.error("""
            \(url.lastPathComponent, privacy: .public) was unreadable \
            (\(String(describing: error), privacy: .public)); moved to \
            \(aside.lastPathComponent, privacy: .public) and started over
            """)
            let queue = try DatabaseQueue(path: url.path, configuration: configuration)
            try prepare(queue)
            return Opened(queue: queue, movedAside: aside)
        }
    }
}
