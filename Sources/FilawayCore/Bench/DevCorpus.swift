import Foundation

/// One note of the M3-07 development corpus.
///
/// The corpus is committed as plain Markdown under `Tests/Fixtures/corpus/dev`
/// so it can be read, diffed and hand-edited; this type is what the generator
/// emits and what the loader reads back. Everything the benchmark needs beyond
/// the bytes — the two timestamps and the golden flag — travels in the
/// front-matter block, because **git does not preserve mtimes** and FR-5.3's
/// temporal queries are entirely a function of them.
public struct CorpusNote: Sendable, Equatable {
    /// Path relative to the library root, e.g. `Commands/curl/Staging docs.md`.
    public var relativePath: String
    /// Front-matter `created`.
    public var created: Date
    /// Front-matter `modified`, and the file mtime the materialiser stamps on.
    public var modified: Date
    public var tags: [String]
    /// `true` for the hand-curated notes a query is allowed to point at.
    public var isGolden: Bool
    /// Markdown body, front matter excluded.
    public var body: String

    public init(
        relativePath: String,
        created: Date,
        modified: Date? = nil,
        tags: [String] = [],
        isGolden: Bool = false,
        body: String
    ) {
        self.relativePath = relativePath
        self.created = created
        self.modified = modified ?? created
        self.tags = tags
        self.isGolden = isGolden
        // Normalised so a note round-trips: `fileText` always ends the file
        // with a newline, so a body that did not would come back different
        // from the one that was written.
        self.body = body.hasSuffix("\n") ? body : body + "\n"
    }

    public var title: String { PathRules.title(of: relativePath) }

    /// Stable identity, derived from the path so a regeneration does not churn
    /// every front-matter block. Not ``NoteID/derived(fromRelativePath:)``,
    /// which the reconciler reads as "this file was never saved by Filaway".
    public var id: NoteID {
        let digest = Hashing.sha256Hex("filaway.bench.corpus:" + relativePath)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var index = digest.startIndex
        for _ in 0 ..< 16 {
            let next = digest.index(index, offsetBy: 2)
            bytes.append(UInt8(digest[index ..< next], radix: 16) ?? 0)
            index = next
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40  // version 4
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return NoteID(UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }

    /// The whole file: front matter plus body.
    ///
    /// `modified` and `golden` are keys Filaway itself never writes; the
    /// front-matter codec keeps unknown keys verbatim (DS-2), so a corpus note
    /// round-trips through `NoteStore` unchanged.
    public var fileText: String {
        var out = "---\n"
        out += "id: \(id.uuidString)\n"
        out += "created: \(ISO8601.string(from: created))\n"
        out += "modified: \(ISO8601.string(from: modified))\n"
        if !tags.isEmpty { out += "tags: [\(tags.joined(separator: ", "))]\n" }
        if isGolden { out += "golden: true\n" }
        out += "---\n"
        out += body
        return out
    }

    /// Parses a file written by ``fileText``.
    public static func parse(relativePath: String, text: String) -> CorpusNote {
        let document = MarkdownDocument.parse(text)
        let front = document.frontMatter
        let created = front?.created ?? Date(timeIntervalSince1970: 0)
        let modifiedRaw = front?.entries.first { $0.key == "modified" }?
            .lines.first?.dropFirst("modified:".count)
            .trimmingCharacters(in: .whitespaces)
        let golden = front?.entries.contains { $0.key == "golden" } ?? false
        return CorpusNote(
            relativePath: relativePath,
            created: created,
            modified: modifiedRaw.flatMap { ISO8601.date(from: String($0)) } ?? created,
            tags: front?.tags ?? [],
            isGolden: golden,
            body: document.body
        )
    }
}

/// Reading and writing the committed development corpus (M3-07).
///
/// ```swift
/// let notes = try DevCorpus.load(from: DevCorpus.defaultDirectory)
/// try DevCorpus.materialize(notes, into: library)   // sets mtimes
/// ```
public enum DevCorpus {
    /// `Tests/Fixtures/corpus/dev`, resolved from this source file so neither
    /// the test suite nor `filaway-bench` cares about the working directory.
    /// The same trick `AITestPaths` uses for the AI recordings.
    public static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)     // …/Sources/FilawayCore/Bench/DevCorpus.swift
            .deletingLastPathComponent()     // …/Sources/FilawayCore/Bench
            .deletingLastPathComponent()     // …/Sources/FilawayCore
            .deletingLastPathComponent()     // …/Sources
            .deletingLastPathComponent()     // repo root
    }

    public static var defaultDirectory: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/corpus/dev", isDirectory: true)
    }

    public static var defaultQuerySetURL: URL {
        repositoryRoot.appendingPathComponent("Tests/Fixtures/queries/dev.json", isDirectory: false)
    }

    public static var exists: Bool {
        FileManager.default.fileExists(atPath: defaultDirectory.path)
    }

    /// Every `.md` file under `directory`, sorted by path.
    public static func load(
        from directory: URL = defaultDirectory,
        fileManager: FileManager = .default
    ) throws -> [CorpusNote] {
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else {
            throw BenchError.corpusMissing(directory.path)
        }
        var notes: [CorpusNote] = []
        let prefix = directory.standardizedFileURL.path.hasSuffix("/")
            ? directory.standardizedFileURL.path
            : directory.standardizedFileURL.path + "/"
        for case let url as URL in enumerator where url.pathExtension == "md" {
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            let text = try String(contentsOf: url, encoding: .utf8)
            notes.append(CorpusNote.parse(relativePath: relative, text: text))
        }
        guard !notes.isEmpty else { throw BenchError.corpusMissing(directory.path) }
        return notes.sorted { $0.relativePath < $1.relativePath }
    }

    /// Writes `notes` into `directory`, replacing whatever was there.
    @discardableResult
    public static func write(
        _ notes: [CorpusNote],
        to directory: URL,
        fileManager: FileManager = .default
    ) throws -> Int {
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var bytes = 0
        for note in notes {
            let url = directory.appendingPathComponent(note.relativePath)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = Data(note.fileText.utf8)
            try data.write(to: url)
            bytes += data.count
            try? fileManager.setAttributes([.modificationDate: note.modified], ofItemAtPath: url.path)
        }
        return bytes
    }

    /// Writes `notes` into a library root **and stamps their mtimes**.
    ///
    /// The stamping is the whole reason this is not a plain file copy: the
    /// committed fixture loses its mtimes in git, and every FR-5.3 query in the
    /// query set is answered from `notes.mtime`.
    public static func materialize(
        _ notes: [CorpusNote],
        into library: Library,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: library.root, withIntermediateDirectories: true)
        for note in notes {
            let url = library.url(for: note.relativePath)
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(note.fileText.utf8).write(to: url)
        }
        // A second pass: creating a subdirectory touches its parent, and
        // writing a file inside a folder updates the folder — neither matters
        // for notes, but the file mtimes have to be set *after* every write.
        for note in notes {
            let url = library.url(for: note.relativePath)
            try? fileManager.setAttributes(
                [.modificationDate: note.modified, .creationDate: note.created],
                ofItemAtPath: url.path
            )
        }
    }
}

/// Failures the M3-07/M3-09 bench harness raises.
public enum BenchError: Error, CustomStringConvertible, Equatable {
    case corpusMissing(String)
    case querySetMissing(String)
    case querySetInvalid(String)

    public var description: String {
        switch self {
        case let .corpusMissing(path):
            "no development corpus at \(path) — run `filaway-bench corpus generate`"
        case let .querySetMissing(path):
            "no query set at \(path) — see Tests/Fixtures/queries/dev.json"
        case let .querySetInvalid(detail):
            "query set is invalid: \(detail)"
        }
    }
}
