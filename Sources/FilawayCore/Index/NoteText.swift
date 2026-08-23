import Foundation

/// One note's searchable text: what the FTS indexes are built from (M1-06).
///
/// The body is the *clean* Markdown — front matter stripped — so a match range
/// returned by ``SearchService`` lines up with the editor's buffer, which is
/// also front-matter-free (see ``Note/body``).
public struct NoteText: Sendable, Equatable {
    public let id: NoteID
    public let relativePath: String
    public let title: String
    public let body: String
    /// The `contentHash` of the summary this text was read from; lets the index
    /// skip notes it already holds.
    public let contentHash: String

    public init(id: NoteID, relativePath: String, title: String, body: String, contentHash: String) {
        self.id = id
        self.relativePath = relativePath
        self.title = title
        self.body = body
        self.contentHash = contentHash
    }
}

/// How ``MetadataStore`` gets a note's body when it needs to index it.
///
/// The default (``NoteTextLoader/reading(from:)``) reads the file and strips
/// front matter; tests inject their own, and a future importer could too. It is
/// `@Sendable` because the store calls it from its own actor.
public struct NoteTextLoader: Sendable {
    public let load: @Sendable (NoteSummary) -> String?

    public init(load: @Sendable @escaping (NoteSummary) -> String?) {
        self.load = load
    }

    /// Reads `<root>/<relpath>` and returns the body with front matter removed.
    ///
    /// Returns `nil` when the file is gone or is not UTF-8 — the caller then
    /// leaves the note out of the text index rather than failing the write, so
    /// a single unreadable file can never break a reconcile.
    public static func reading(from library: Library) -> NoteTextLoader {
        NoteTextLoader { summary in
            let url = library.url(for: summary.relativePath)
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8)
            else { return nil }
            return MarkdownDocument.parse(text).body
        }
    }

    /// A loader that indexes nothing — for callers that maintain the text index
    /// themselves, and for tests that only care about `notes`.
    ///
    /// Named `disabled` rather than `none` because the initialiser's parameter
    /// is optional, and `.none` there would silently mean `nil`.
    public static let disabled = NoteTextLoader { _ in nil }
}
