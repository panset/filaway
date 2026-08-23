import Foundation

@testable import FilawayCore

/// A metadata store with its search index built, and a service reading it.
struct SearchStack {
    let metadata: MetadataStore
    let search: SearchService
    let watcher: LibraryWatcher
}

extension TempLibrary {
    /// Writes a note through ``NoteStore`` — the same path the editor uses, so
    /// front matter is present and the indexer has to strip it.
    @discardableResult
    func makeNote(_ title: String, folder: String = "", body: String) async throws -> Note {
        try await store.createNote(inFolder: folder, title: title, body: body)
    }

    /// Rebuilds the database (and the FTS index) from what is on disk, and
    /// hands back a ``SearchService`` reading it.
    func searchStack() async throws -> SearchStack {
        let metadata = try metadataStore()
        let watcher = LibraryWatcher(store: store, metadata: metadata)
        try await metadata.rebuild(from: try await store.scan())
        return SearchStack(metadata: metadata, search: SearchService(metadata: metadata), watcher: watcher)
    }
}

extension Array where Element == KeywordHit {
    var titles: [String] { map(\.title) }
    func hit(titled title: String) -> KeywordHit? { first { $0.title == title } }
}
