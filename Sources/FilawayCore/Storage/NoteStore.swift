import Foundation

/// The only thing in Filaway that touches the user's notes folder (DS-1, DS-2).
///
/// Every mutation is atomic (write to a temp directory on the same volume, then
/// rename), every delete goes to the macOS Trash, and nothing but `.md` files
/// and folders is ever created inside the root. Each mutation is also recorded
/// in an ``OwnOperationLedger`` so ``LibraryWatcher`` can tell the app's own
/// writes apart from external edits.
///
/// ```swift
/// let store = NoteStore(library: Library(root: root))
/// try await store.prepare()
/// let note = try await store.createNote(inFolder: "Commands")
/// try await store.save(body: "curl -sS https://example.com\n", to: note.relativePath)
/// ```
public actor NoteStore {
    public let library: Library
    private let fileManager: FileManager
    private var ledger = OwnOperationLedger()
    private var failureHook: StorageFailureHook?

    public init(library: Library, fileManager: FileManager = .default, failureHook: StorageFailureHook? = nil) {
        self.library = library
        self.fileManager = fileManager
        self.failureHook = failureHook
    }

    /// Installs (or clears) the ``StorageFailureHook`` — the only way to model a
    /// `kill -9` inside ``atomicWrite`` without killing the test process.
    public func setFailureHook(_ hook: StorageFailureHook?) {
        failureHook = hook
    }

    /// Creates the notes root and the Application Support directory if missing.
    public func prepare() throws {
        try library.prepareDirectories(fileManager: fileManager)
    }

    // MARK: - Reading

    /// Loads a note with its body, front-matter stripped.
    public func read(_ relativePath: String) throws -> Note {
        let path = PathRules.normalize(relativePath)
        guard PathRules.isNotePath(path) else { throw StorageError.notAMarkdownFile(relativePath) }
        let url = library.url(for: path)
        guard let data = fileManager.contents(atPath: url.path) else { throw StorageError.notFound(relativePath) }
        return try Self.note(from: data, relativePath: path, url: url, fileManager: fileManager)
    }

    /// Metadata for a single note without keeping its body around.
    public func summary(of relativePath: String) throws -> NoteSummary {
        try read(relativePath).summary
    }

    /// `true` when a `.md` file exists at the relative path.
    public func exists(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: library.url(for: PathRules.normalize(relativePath)).path)
    }

    /// Full stat-scan of the library (DS-4, "reconciles on next launch").
    ///
    /// - Parameters:
    ///   - cache: previously known summaries keyed by relative path. A file whose
    ///     `(mtime, size)` match the cache and whose mtime is older than
    ///     `settleWindow` is reused without being re-read or re-hashed.
    ///   - settleWindow: how recently a file must have changed for its cache
    ///     entry to be distrusted. Guards against filesystems that report a
    ///     coarse mtime, where two writes in the same second would otherwise be
    ///     indistinguishable.
    public func scan(reusing cache: [String: NoteSummary] = [:], settleWindow: TimeInterval = 2) throws -> LibrarySnapshot {
        try Self.scan(library: library, fileManager: fileManager, reusing: cache, settleWindow: settleWindow)
    }

    // MARK: - Writing

    /// Writes a note body, adding or preserving the front-matter block.
    ///
    /// The `id` and `created` keys are stamped on first save; unknown keys from
    /// other tools are re-emitted verbatim. This is the *only* place Filaway
    /// writes front-matter (DS-2).
    @discardableResult
    public func save(body: String, to relativePath: String, tags: [String]? = nil) throws -> NoteSummary {
        let path = PathRules.normalize(relativePath)
        guard PathRules.isNotePath(path) else { throw StorageError.notAMarkdownFile(relativePath) }
        let url = library.url(for: path)

        var document: MarkdownDocument
        if let existing = fileManager.contents(atPath: url.path), let text = String(data: existing, encoding: .utf8) {
            document = MarkdownDocument.parse(text)
        } else {
            document = MarkdownDocument()
        }
        document.body = body

        var frontMatter = document.frontMatter ?? FrontMatter()
        if frontMatter.id == nil { frontMatter.id = NoteID() }
        if frontMatter.created == nil {
            frontMatter.created = Self.creationDate(of: url, fileManager: fileManager) ?? Date()
        }
        if let tags { frontMatter.tags = tags }
        document.frontMatter = frontMatter

        return try writeRaw(document.serialized(), to: path)
    }

    /// Writes exact file bytes, front-matter untouched.
    ///
    /// Used by conflict resolution (DS-4) and by importers; prefer
    /// ``save(body:to:tags:)`` for ordinary edits.
    @discardableResult
    public func writeRaw(_ text: String, to relativePath: String) throws -> NoteSummary {
        let path = PathRules.normalize(relativePath)
        guard PathRules.isNotePath(path) else { throw StorageError.notAMarkdownFile(relativePath) }
        try requireDepth(ofFolder: PathRules.folderPath(of: path), original: relativePath)
        let url = library.url(for: path)
        let data = Data(text.utf8)
        try atomicWrite(data, to: url, relativePath: path)

        let summary = try Self.summary(
            from: data,
            relativePath: path,
            url: url,
            fileManager: fileManager
        )
        ledger.record(OwnOperation(
            kind: .write,
            relativePath: path,
            contentHash: summary.contentHash,
            modified: summary.modified
        ))
        return summary
    }

    /// Creates a new note, picking a free filename.
    ///
    /// With no title this yields `Untitled note.md`, then `Untitled note 2.md`,
    /// … (FR-1.1 "⌘N yields a focused blank note").
    @discardableResult
    public func createNote(inFolder folderPath: String = "", title: String? = nil, body: String = "") throws -> Note {
        let folder = try PathRules.sanitizeFolderPath(folderPath)
        try createFolder(folder)
        let stem = PathRules.sanitizeTitle(title ?? PathRules.untitled)
        let path = try freeRelativePath(folder: folder, title: stem)
        let summary = try save(body: body, to: path)
        return try read(summary.relativePath)
    }

    /// Renames a note — DS-1 makes the filename stem the title, so this *is* the
    /// title change. Collisions get a ` 2`, ` 3`, … suffix.
    @discardableResult
    public func rename(_ relativePath: String, to newTitle: String) throws -> NoteSummary {
        let source = PathRules.normalize(relativePath)
        let folder = PathRules.folderPath(of: source)
        let stem = PathRules.sanitizeTitle(newTitle)
        if PathRules.title(of: source) == stem { return try summary(of: source) }
        return try relocate(source, to: try freeRelativePath(folder: folder, title: stem, excluding: source))
    }

    /// Moves a note into another folder, keeping its title where possible.
    ///
    /// - Throws: ``StorageError/folderTooDeep(_:)`` when the destination is
    ///   deeper than ``PathRules/maxFolderDepth``.
    @discardableResult
    public func move(_ relativePath: String, toFolder folderPath: String) throws -> NoteSummary {
        let source = PathRules.normalize(relativePath)
        let folder = try PathRules.sanitizeFolderPath(folderPath)
        if PathRules.folderPath(of: source) == folder { return try summary(of: source) }
        try createFolder(folder)
        return try relocate(source, to: try freeRelativePath(folder: folder, title: PathRules.title(of: source)))
    }

    /// Creates a folder (and its parent), enforcing the depth cap. A no-op for
    /// the root and for folders that already exist.
    public func createFolder(_ folderPath: String) throws {
        let folder = try PathRules.sanitizeFolderPath(folderPath)
        guard !folder.isEmpty else { return }
        try fileManager.createDirectory(at: library.url(for: folder), withIntermediateDirectories: true)
    }

    // MARK: - Deleting

    /// Moves a note to the macOS Trash. Never a hard delete.
    ///
    /// - Returns: where the file went, so the caller can report it or undo.
    @discardableResult
    public func deleteNote(_ relativePath: String) throws -> URL {
        let path = PathRules.normalize(relativePath)
        guard PathRules.isNotePath(path) else { throw StorageError.notAMarkdownFile(relativePath) }
        let url = library.url(for: path)
        guard fileManager.fileExists(atPath: url.path) else { throw StorageError.notFound(relativePath) }
        let destination = try trash(url, relativePath: path)
        ledger.record(OwnOperation(kind: .remove, relativePath: path, contentHash: nil, modified: nil))
        return destination
    }

    /// Moves a folder and everything under it to the macOS Trash.
    @discardableResult
    public func deleteFolder(_ folderPath: String) throws -> URL {
        let folder = PathRules.normalize(folderPath)
        guard !folder.isEmpty else { throw StorageError.notFound("<root>") }
        let url = library.url(for: folder)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageError.notFound(folderPath)
        }
        // Record the notes inside so the watcher suppresses their removal echoes.
        let snapshot = try scan()
        for note in snapshot.notes where note.relativePath == folder || note.relativePath.hasPrefix(folder + "/") {
            ledger.record(OwnOperation(kind: .remove, relativePath: note.relativePath, contentHash: nil, modified: nil))
        }
        return try trash(url, relativePath: folder)
    }

    // MARK: - Own-write ledger (used by LibraryWatcher)

    /// Consumes a record matching this change; `true` means "this was us".
    ///
    /// Pass `nil` for `contentHash` to match a removal.
    public func consumeOwnOperation(relativePath: String, contentHash: String?, now: Date = Date()) -> Bool {
        ledger.consume(relativePath: PathRules.normalize(relativePath), contentHash: contentHash, now: now)
    }

    /// Number of un-consumed own-operation records; diagnostics only.
    public var pendingOwnOperationCount: Int { ledger.count }

    /// Registers an own write the store did not perform itself (e.g. a test
    /// harness or a future importer writing through another path).
    public func recordOwnOperation(_ operation: OwnOperation) {
        ledger.record(operation)
    }

    // MARK: - Naming

    /// First free `<folder>/<title>.md`, `<folder>/<title> 2.md`, …
    public func freeRelativePath(folder: String, title: String, excluding: String? = nil) throws -> String {
        let folder = try PathRules.sanitizeFolderPath(folder)
        let stem = PathRules.sanitizeTitle(title)
        let skip = excluding.map(PathRules.normalize)
        for attempt in 1 ... 999 {
            let candidate = PathRules.relativePath(folder: folder, title: PathRules.suffixed(stem, attempt))
            // A case-only rename ("notes.md" → "Notes.md") targets the same file
            // on a case-insensitive volume, so it must not collide with itself.
            if let skip, candidate.compare(skip, options: .caseInsensitive) == .orderedSame { return candidate }
            if !fileManager.fileExists(atPath: library.url(for: candidate).path) { return candidate }
        }
        throw StorageError.couldNotFindFreeName(PathRules.relativePath(folder: folder, title: stem))
    }

    // MARK: - Private

    private func relocate(_ source: String, to destination: String) throws -> NoteSummary {
        let sourceURL = library.url(for: source)
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw StorageError.notFound(source) }
        let destinationURL = library.url(for: destination)
        let sameFile = destination.compare(source, options: .caseInsensitive) == .orderedSame
        guard sameFile || !fileManager.fileExists(atPath: destinationURL.path) else {
            throw StorageError.alreadyExists(destination)
        }
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)

        let moved = try summary(of: destination)
        ledger.record(OwnOperation(kind: .remove, relativePath: source, contentHash: nil, modified: nil))
        ledger.record(OwnOperation(
            kind: .write,
            relativePath: destination,
            contentHash: moved.contentHash,
            modified: moved.modified
        ))
        return moved
    }

    private func requireDepth(ofFolder folder: String, original: String) throws {
        guard PathRules.depth(ofFolder: folder) <= PathRules.maxFolderDepth else {
            throw StorageError.folderTooDeep(original)
        }
    }

    /// Temp-file + rename. The temp file lives in an OS-provided replacement
    /// directory on the *same volume* (NFR-5: the root may be anywhere), never
    /// inside the notes root, so DS-1's "nothing but `.md` files and folders"
    /// holds even mid-write.
    private func atomicWrite(_ data: Data, to url: URL, relativePath: String) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: directory,
            create: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent(url.lastPathComponent)
        try data.write(to: temporary, options: .atomic)
        // NFR-3's worst instant: the new bytes exist, the old file is still the
        // one at `url`, and the rename has not happened. A `kill -9` here must
        // leave the original intact and nothing behind inside the notes root.
        try failureHook?.check(.beforeRename(relativePath))
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    /// macOS Trash, with a recoverable fallback for volumes that have none.
    private func trash(_ url: URL, relativePath: String) throws -> URL {
        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: url, resultingItemURL: &trashed)
            if let trashed = trashed as URL? { return trashed }
            return url
        } catch {
            // Some volumes (network shares, some external disks) have no Trash.
            // Never hard-delete: move into the library's recovery bin instead.
            let bin = library.recoveryBinURL
                .appendingPathComponent(ISO8601.string(from: Date()).replacingOccurrences(of: ":", with: "-"), isDirectory: true)
            do {
                try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
                let destination = bin.appendingPathComponent(url.lastPathComponent)
                try fileManager.moveItem(at: url, to: destination)
                return destination
            } catch let fallbackError {
                throw StorageError.couldNotTrash(relativePath, "\(error); fallback failed: \(fallbackError)")
            }
        }
    }

    // MARK: - Scanning (nonisolated so benchmarks and reconciles can reuse it)

    /// Stat-scan implementation, shared by ``NoteStore/scan(reusing:settleWindow:)``
    /// and `filaway-bench scan`.
    public nonisolated static func scan(
        library: Library,
        fileManager: FileManager = .default,
        reusing cache: [String: NoteSummary] = [:],
        settleWindow: TimeInterval = 2
    ) throws -> LibrarySnapshot {
        let now = Date()
        var notes: [NoteSummary] = []
        var folders: [String] = []

        let keys: [URLResourceKey] = [
            .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey,
            .fileSizeKey, .creationDateKey, .nameKey,
        ]
        guard fileManager.fileExists(atPath: library.root.path) else {
            return LibrarySnapshot(notes: [], folderPaths: [], scannedAt: now)
        }
        guard let enumerator = fileManager.enumerator(
            at: library.root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return LibrarySnapshot(notes: [], folderPaths: [], scannedAt: now)
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard let relative = library.relativePath(for: url), !relative.isEmpty else { continue }
            if values?.isDirectory == true {
                folders.append(relative)
                continue
            }
            guard values?.isRegularFile == true, PathRules.isNotePath(relative) else { continue }

            let modified = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let size = values?.fileSize ?? 0
            if let cached = cache[relative],
               cached.size == size,
               abs(cached.modified.timeIntervalSince(modified)) < 0.000_5,
               now.timeIntervalSince(modified) > settleWindow {
                notes.append(cached)
                continue
            }
            guard let data = fileManager.contents(atPath: url.path) else { continue }
            notes.append(try summary(
                from: data,
                relativePath: relative,
                url: url,
                fileManager: fileManager,
                resourceValues: values
            ))
        }

        notes.sort { $0.relativePath < $1.relativePath }
        folders.sort()
        return LibrarySnapshot(notes: notes, folderPaths: folders, scannedAt: now)
    }

    /// Builds a summary from bytes already in hand.
    static func summary(
        from data: Data,
        relativePath: String,
        url: URL,
        fileManager: FileManager,
        resourceValues: URLResourceValues? = nil
    ) throws -> NoteSummary {
        guard let text = String(data: data, encoding: .utf8) else { throw StorageError.notUTF8(relativePath) }
        let document = MarkdownDocument.parse(text)
        let values = resourceValues ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey]))
        let modified = values?.contentModificationDate ?? Date()
        let created = document.frontMatter?.created ?? values?.creationDate ?? modified
        return NoteSummary(
            id: document.frontMatter?.id ?? NoteID.derived(fromRelativePath: relativePath),
            relativePath: relativePath,
            title: PathRules.title(of: relativePath),
            folderPath: PathRules.folderPath(of: relativePath),
            tags: document.frontMatter?.tags ?? [],
            created: created,
            modified: modified,
            size: data.count,
            contentHash: Hashing.sha256Hex(data)
        )
    }

    static func note(from data: Data, relativePath: String, url: URL, fileManager: FileManager) throws -> Note {
        guard let text = String(data: data, encoding: .utf8) else { throw StorageError.notUTF8(relativePath) }
        let document = MarkdownDocument.parse(text)
        let summary = try summary(from: data, relativePath: relativePath, url: url, fileManager: fileManager)
        return Note(
            summary: summary,
            body: document.body,
            frontMatter: document.frontMatter,
            hasByteOrderMark: document.hasByteOrderMark
        )
    }

    static func creationDate(of url: URL, fileManager: FileManager) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
