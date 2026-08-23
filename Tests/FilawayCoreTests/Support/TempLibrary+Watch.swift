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
}
