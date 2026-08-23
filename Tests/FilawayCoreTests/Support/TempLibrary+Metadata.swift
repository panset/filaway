import Foundation

@testable import FilawayCore

extension TempLibrary {
    /// A metadata database rooted in this temp library's Application Support
    /// directory, so it never touches the developer's real derived data.
    func metadataStore() throws -> MetadataStore {
        try MetadataStore(library: library)
    }
}

extension MetadataStore {
    /// Convenience for polling helpers that cannot throw.
    func noteCountOrZero() -> Int { (try? noteCount()) ?? 0 }
}
