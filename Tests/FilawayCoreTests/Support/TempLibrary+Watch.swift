import Foundation

@testable import FilawayCore

extension TempLibrary {
    func watcher(_ metadata: MetadataStore, latency: TimeInterval = 0.2) -> LibraryWatcher {
        LibraryWatcher(store: store, metadata: metadata, latency: latency)
    }
}

/// Collects changes from a watcher stream in the background.
actor ChangeCollector {
    private(set) var changes: [LibraryChange] = []
    private var task: Task<Void, Never>?

    func attach(to watcher: LibraryWatcher) async {
        let stream = await watcher.changes()
        task = Task { [weak self] in
            for await change in stream { await self?.append(change) }
        }
    }

    func detach() {
        task?.cancel()
        task = nil
    }

    private func append(_ change: LibraryChange) { changes.append(change) }

    func snapshot() -> [LibraryChange] { changes }

    /// `true` once any collected change matches — the shape every FSEvents
    /// barrier and every `waitUntil` in `WatcherTests` is built out of.
    func contains(_ predicate: (LibraryChange) -> Bool) -> Bool {
        changes.contains(where: predicate)
    }

    /// Forgets everything collected so far, so an assertion about what the
    /// stream delivered is not confused by the barrier that opened it.
    func reset() { changes.removeAll() }
}
