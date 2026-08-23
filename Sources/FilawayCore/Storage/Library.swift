import Foundation

/// The user's notes folder plus the derived-data location that belongs to it.
///
/// DS-1 puts the notes in a user-visible folder (default `~/Notes`); DS-3 puts
/// everything derived in Application Support, keyed by ``key`` so several
/// libraries can coexist. NFR-5 requires that nothing assume the root is on the
/// boot volume, so the root is always carried as a resolved `URL` and can be
/// persisted as a security-scoped bookmark.
public struct Library: Sendable, Hashable, Codable {
    /// Absolute, symlink-resolved, standardised location of the notes folder.
    public let root: URL
    /// Parent of ``supportDirectory``; defaults to
    /// `~/Library/Application Support/Filaway`. Injectable so tests never touch
    /// the real Application Support directory.
    public let supportRoot: URL
    /// Stable 16-hex-character digest of the resolved root path.
    public let key: String

    /// The default notes folder, `~/Notes` (FR-7.1).
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Notes", isDirectory: true)
    }

    /// `~/Library/Application Support/Filaway`.
    public static var defaultSupportRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Filaway", isDirectory: true)
    }

    public init(root: URL, supportRoot: URL? = nil) {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        self.root = resolved
        self.supportRoot = (supportRoot ?? Self.defaultSupportRoot).resolvingSymlinksInPath().standardizedFileURL
        key = Self.key(forRoot: resolved)
    }

    /// Restores a library from bookmark data produced by ``bookmarkData()``.
    ///
    /// - Returns: the library and whether macOS reported the bookmark as stale
    ///   (the caller should then persist a fresh ``bookmarkData()``).
    public static func resolving(bookmark: Data, supportRoot: URL? = nil) throws -> (library: Library, isStale: Bool) {
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (Library(root: url, supportRoot: supportRoot), isStale)
    }

    /// Bookmark data to persist in preferences, so the root survives a rename or
    /// a move to another volume (NFR-5).
    public func bookmarkData() throws -> Data {
        try root.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// `~/Library/Application Support/Filaway/<key>` — DS-3 derived data.
    public var supportDirectory: URL {
        supportRoot.appendingPathComponent(key, isDirectory: true)
    }

    /// The GRDB database file (DS-3). Deleting it is always safe: everything in
    /// it is rebuildable from the notes folder.
    public var databaseURL: URL {
        supportDirectory.appendingPathComponent("filaway.sqlite", isDirectory: false)
    }

    /// Fallback recovery bin used when `FileManager.trashItem` is unavailable on
    /// the root's volume. Deleting is never a hard delete (plan §1 amendment 1).
    public var recoveryBinURL: URL {
        supportDirectory.appendingPathComponent("Recovered", isDirectory: true)
    }

    /// Absolute URL for a relative path (`""` yields the root itself).
    public func url(for relativePath: String) -> URL {
        let parts = PathRules.components(relativePath)
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    /// Relative path for an absolute URL, or `nil` when the URL is outside the root.
    ///
    /// Several spellings of the same path are tried, because
    /// `resolvingSymlinksInPath()` only strips the `/private` prefix from paths
    /// that still exist — an FSEvents notification about a *deleted* file would
    /// otherwise fail to map back into the library.
    public func relativePath(for url: URL) -> String? {
        let base = root.path
        for candidate in Self.pathVariants(of: url) {
            if candidate == base { return "" }
            if candidate.hasPrefix(base + "/") {
                return PathRules.normalize(String(candidate.dropFirst(base.count + 1)))
            }
        }
        return nil
    }

    private static func pathVariants(of url: URL) -> [String] {
        var out: [String] = []
        for path in [url.standardizedFileURL.path, url.resolvingSymlinksInPath().standardizedFileURL.path] {
            out.append(path)
            out.append(path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path)
        }
        return out
    }

    /// Creates the notes root and the Application Support directory if missing.
    public func prepareDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
    }

    /// Stable identifier for a root path — same folder, same key, across launches.
    public static func key(forRoot root: URL) -> String {
        Hashing.shortKey(root.resolvingSymlinksInPath().standardizedFileURL.path)
    }
}
