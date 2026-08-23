import ArgumentParser
import FilawayCore
import Foundation

/// `filaway-bench churn --root <dir> --seconds 60` — the app's Core watching a
/// notes folder while something else hammers it (DS-4, risk #3, M4-08).
///
/// `Tools/fs_churn.sh` does the hammering from outside the process, exactly as
/// BBEdit, Finder and a `git checkout` would. This runs the *real*
/// `LibraryWatcher` and `MetadataStore` against the same folder for a fixed
/// stretch, then checks the four invariants the M1 DoD names:
///
/// 1. **No loss** — every `.md` on disk is a row, with a matching content hash.
/// 2. **No duplicates** — one row per path, one identity per row.
/// 3. **Moves tracked** — a move is a `moved` change, not a delete plus a create.
/// 4. **DS-1** — nothing but `.md` files and folders inside the notes root.
///
/// ```
/// Tools/fs_churn.sh --root /tmp/churn/Notes -n 2000 --delay 0.02 &
/// swift run filaway-bench churn --root /tmp/churn/Notes --seconds 60
/// ```
///
/// Exits non-zero the moment an invariant breaks, naming what disagreed.
struct ChurnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "churn",
        abstract: "Watch a notes folder under external churn and assert no loss or duplicates (DS-4)."
    )

    @Option(help: "The notes folder to watch. Required — this command never generates one.")
    var root: String

    @Option(help: "How long to watch, in seconds.")
    var seconds = 60.0

    @Option(help: "FSEvents coalescing latency, in seconds.")
    var latency = 0.2

    @Option(help: "Seconds between the belt-and-braces full reconciles.")
    var reconcileEvery = 2.0

    @Option(help: "How long to wait, after the watch window, for the folder to go quiet.")
    var settleSeconds = 15.0

    @Flag(help: "Print every change the watcher reports.")
    var verbose = false

    mutating func run() async throws {
        let notesRoot = URL(fileURLWithPath: root)
        guard FileManager.default.fileExists(atPath: notesRoot.path) else {
            print("churn: \(root) does not exist")
            throw ExitCode.failure
        }
        let supportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("filaway-churn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportRoot) }
        let library = Library(root: notesRoot, supportRoot: supportRoot)

        let store = NoteStore(library: library)
        let metadata = try MetadataStore(library: library)
        let watcher = LibraryWatcher(store: store, metadata: metadata, latency: latency)
        try await metadata.rebuild(from: store.scan(settleWindow: 0))

        let tally = ChangeTally()
        let stream = await watcher.changes()
        let printChanges = verbose
        let collector = Task {
            for await change in stream {
                await tally.record(change)
                if printChanges { print("  \(change)") }
            }
        }
        guard await watcher.start() else {
            print("churn: could not start the FSEvents stream")
            throw ExitCode.failure
        }

        print("churn: watching \(notesRoot.path) for \(Int(seconds))s "
            + "(latency \(latency)s, reconcile every \(reconcileEvery)s)")
        let deadline = Date().addingTimeInterval(seconds)
        var reconciles = 0
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(reconcileEvery * 1_000_000_000))
            let changes = try await watcher.reconcile()
            reconciles += 1
            for change in changes { await tally.record(change) }
        }
        // Quiesce: keep reconciling until two in a row find nothing. The
        // invariants below are about a *settled* library, and the churn script
        // usually outlives the watch window by a second or two.
        var settled = false
        let settleDeadline = Date().addingTimeInterval(settleSeconds)
        var quietRuns = 0
        while Date() < settleDeadline {
            let changes = try await watcher.reconcile()
            reconciles += 1
            for change in changes { await tally.record(change) }
            quietRuns = changes.isEmpty ? quietRuns + 1 : 0
            if quietRuns >= 2 { settled = true; break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        await watcher.stop()
        collector.cancel()

        let counts = await tally.counts
        print("churn: \(reconciles) reconciles — "
            + counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        // The invariants.
        var failures: [String] = []
        let onDisk = try Self.markdownPaths(in: library).sorted()
        let rows = try await metadata.allNotes()
        let rowPaths = rows.map(\.relativePath).sorted()

        if rowPaths != onDisk {
            let missing = Set(onDisk).subtracting(rowPaths).sorted()
            let extra = Set(rowPaths).subtracting(onDisk).sorted()
            failures.append("database and disk disagree — missing \(missing.count), extra \(extra.count)")
            for path in missing.prefix(5) { failures.append("  missing: \(path)") }
            for path in extra.prefix(5) { failures.append("  extra:   \(path)") }
        }
        for row in rows {
            guard let data = FileManager.default.contents(atPath: library.url(for: row.relativePath).path) else {
                continue
            }
            if row.contentHash != Hashing.sha256Hex(data) {
                failures.append("stale hash: \(row.relativePath)")
            }
        }
        if Set(rowPaths).count != rowPaths.count { failures.append("duplicate paths in the database") }
        if Set(rows.map(\.id)).count != rows.count { failures.append("duplicate identities in the database") }
        if (counts["moved"] ?? 0) == 0 {
            failures.append("no move was tracked — the churn may not have moved anything")
        }
        let strays = try Self.strayEntries(in: library)
        if !strays.isEmpty { failures.append("stray non-.md files in the notes root: \(strays.prefix(5))") }
        if !settled {
            failures.append("the folder never went quiet within \(Int(settleSeconds))s "
                + "— is the churn script still running?")
        }

        print("churn: \(onDisk.count) notes on disk, \(rows.count) rows")
        guard failures.isEmpty else {
            for failure in failures { print("FAIL      \(failure)") }
            throw ExitCode.failure
        }
        print("PASS      no loss, no duplicates, moves tracked, nothing stray (DS-4)")
    }

    static func markdownPaths(in library: Library) throws -> [String] {
        try entries(in: library).filter { PathRules.isNotePath($0) }
    }

    static func strayEntries(in library: Library) throws -> [String] {
        try entries(in: library).filter { !PathRules.isNotePath($0) }
    }

    private static func entries(in library: Library) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: library.root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var out: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let relative = library.relativePath(for: url), !relative.hasPrefix(".") else { continue }
            out.append(relative)
        }
        return out
    }
}

/// Counts changes by kind, off the watcher's stream.
actor ChangeTally {
    private(set) var counts: [String: Int] = [:]

    func record(_ change: LibraryChange) {
        let kind: String
        switch change {
        case .added: kind = "added"
        case .modified: kind = "modified"
        case .removed: kind = "removed"
        case .moved: kind = "moved"
        case .conflict: kind = "conflict"
        case .folderAdded: kind = "folderAdded"
        case .folderRemoved: kind = "folderRemoved"
        }
        counts[kind, default: 0] += 1
    }
}
