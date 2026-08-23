import AppKit
import FilawayCore

/// Everything semantic search needs, assembled once and owned here (M3-06).
///
/// `AppModel` builds the *storage* stack; this builds the *retrieval* stack on
/// top of it and keeps it fed:
///
/// ```
/// EmbedderFactory.default()  →  VectorStore  →  Indexer      ← autosave, watcher, exclusions
///                                           →  HybridSearch  →  SemanticSearchService
///                                              AnswerExtractor ← AIProviderFactory(FILAWAY_AI_MODE)
/// ```
///
/// It is a separate object from ``AppModel`` on purpose: the only thing the
/// shell has to know is "start it, tell it when a note changed". Everything
/// else — which embedder is live, whether the index is warm, whether Claude is
/// reachable — stays behind ``SearchCoordinator``'s semantic seam.
///
/// **Nothing here is on the launch path.** `start` returns immediately and does
/// the model load, the `catchUp()` and the vector load on a detached task, so a
/// cold launch is never charged for an index (NFR-1). Until that finishes,
/// ``isReady`` is `false` and ⌘K is keyword-only — which is exactly the
/// offline behaviour FR-5.5 asks for anyway.
@MainActor
final class SemanticSearchCoordinator: ObservableObject {

    /// `.indexing(n, of: m)` drives the panel's footer line.
    @Published private(set) var indexStatus: IndexStatus = .idle
    /// `true` once retrieval can answer a query.
    @Published private(set) var isReady = false
    /// "bge-small-en-v1.5 (bundled)" — Settings shows it, the panel does not.
    @Published private(set) var embedderDescription: String?
    /// `false` when no embedder loaded: retrieval falls back to BM25 only.
    @Published private(set) var supportsVectors = false

    private(set) var indexer: Indexer?
    private(set) var vectors: VectorStore?
    private(set) var hybrid: HybridSearch?
    private(set) var extractor: AnswerExtractor?
    private(set) var service: SemanticSearchService?

    /// Resolved on first use, never in `init`.
    ///
    /// `AppModel` is constructed before `NSApplicationMain`, and reaching for
    /// `SettingsModel.shared` from there drags a `Library`, a Keychain-backed
    /// connection manager and the usage ledger's SQLite file onto the launch
    /// path — the window is then late and NFR-1's cold-launch budget is spent
    /// on preferences nobody has asked for yet.
    private var injectedSettings: CoreSettings?
    private var resolvedSettings: CoreSettings?
    private var settings: CoreSettings {
        if let resolvedSettings { return resolvedSettings }
        let resolved = injectedSettings ?? SettingsModel.shared.settings
        resolvedSettings = resolved
        exclusions.set(ExclusionFilter(excludedFolders: resolved.excludedFolders))
        return resolved
    }

    private let exclusions = ExclusionBox()
    private let providerReady = Flag(false)

    private var indexTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var changeTask: Task<Void, Never>?
    private var settingsToken: CoreSettings.Observation?
    private var aiStatusTask: Task<Void, Never>?
    private var providerOverride: (any AIProvider)?

    init(settings: CoreSettings? = nil) {
        injectedSettings = settings
    }

    deinit {
        indexTask?.cancel()
        statusTask?.cancel()
        changeTask?.cancel()
        aiStatusTask?.cancel()
    }

    // MARK: - Settings the panel reads

    /// FR-8.1's toggle. Off → the Ask mode is hidden and ⏎ stays keyword.
    var isSemanticSearchEnabled: Bool { settings.semanticSearchEnabled }

    // MARK: - Launch

    /// Builds the stack behind the first frame. Safe to call twice.
    func start(metadata: MetadataStore, library: Library) {
        guard indexTask == nil else { return }
        let ledger = try? AIUsageLedger(library: library)
        let settings = self.settings
        let exclusions = self.exclusions

        indexTask = Task { [weak self] in
            // The bundled Core ML model compiles on first launch (1.5–3 s) and
            // loads in ~45 ms warm. Never on the main actor.
            let (embedder, active) = await EmbedderFactory.default()
            guard !Task.isCancelled else { return }
            guard let self else { return }

            self.embedderDescription = active.displayName
            self.supportsVectors = active.supportsSemanticSearch

            var vectors: VectorStore?
            var indexer: Indexer?
            if let embedder {
                let store = VectorStore(
                    reader: metadata.reader, modelID: embedder.identifier, dimension: embedder.dimension
                )
                vectors = store
                indexer = Indexer(
                    metadata: metadata, embedder: embedder, vectorStore: store,
                    isExcluded: { exclusions.isExcluded($0) }
                )
            }
            let hybrid = HybridSearch(metadata: metadata, embedder: embedder, vectorStore: vectors)
            let extractor = Self.makeExtractor(settings: settings, ledger: ledger, override: self.providerOverride)
            let service = SemanticSearchService(
                hybrid: hybrid,
                extractor: extractor,
                options: HybridSearch.Options(exclusions: exclusions.current),
                gate: .init(
                    isEnabled: { settings.semanticSearchEnabled },
                    isProviderReady: { [providerReady] in providerReady.value }
                )
            )

            self.vectors = vectors
            self.indexer = indexer
            self.hybrid = hybrid
            self.extractor = extractor
            self.service = service
            self.isReady = true
            self.observeIndexStatus()
            self.observeSettings()
            self.observeAIStatus()

            guard let indexer else { return }
            do {
                _ = try await indexer.synchronizeModel()
                _ = try await indexer.catchUp()
                try await vectors?.reload()
                await hybrid.invalidate()
            } catch {
                Log.index.error("semantic catch-up failed: \(String(describing: error), privacy: .public)")
            }
            await indexer.start()
        }
    }

    /// The provider the answer step uses.
    ///
    /// `replay` with no fixture directory — a normal launch of the shipped app
    /// — gets **no** extractor at all rather than a stand-in that throws, so
    /// the panel says "connect your AI" instead of "offline" (FR-6.4).
    private static func makeExtractor(
        settings: CoreSettings,
        ledger: AIUsageLedger?,
        override: (any AIProvider)?
    ) -> AnswerExtractor? {
        let configuration = AnswerExtractor.Configuration(model: settings.effectiveSearchModel)
        if let override {
            return AnswerExtractor(provider: override, ledger: ledger, configuration: configuration)
        }
        let mode = AIMode.current()
        let store = AIRecordingStore.fromEnvironment()
        guard mode != .replay || store != nil else { return nil }
        guard let provider = try? AIProviderFactory.make(
            mode: mode, store: store, keySource: .storeThenEnvironment(KeychainStore())
        ) else { return nil }
        return AnswerExtractor(provider: provider, ledger: ledger, configuration: configuration)
    }

    /// Smoke and previews: swap the answer step's provider, before or after
    /// ``start(metadata:library:)``.
    func overrideProvider(_ provider: any AIProvider) {
        providerOverride = provider
        let replacement = AnswerExtractor(
            provider: provider,
            configuration: AnswerExtractor.Configuration(model: settings.effectiveSearchModel)
        )
        extractor = replacement
        guard let hybrid else { return }
        let settings = self.settings
        let exclusions = self.exclusions
        let providerReady = self.providerReady
        service = SemanticSearchService(
            hybrid: hybrid,
            extractor: replacement,
            options: HybridSearch.Options(exclusions: exclusions.current),
            gate: .init(
                isEnabled: { settings.semanticSearchEnabled },
                isProviderReady: { providerReady.value }
            )
        )
    }

    /// Smoke: force the gate open without a Keychain round trip.
    func setProviderReady(_ ready: Bool) { providerReady.set(ready) }

    // MARK: - Feeding the index (FR-5.4)

    /// Every autosave flush.
    func noteSaved(_ id: NoteID) {
        guard let indexer else { return }
        Task { await indexer.markDirty(id) }
    }

    /// Every watcher change.
    func libraryChanged(_ change: LibraryChange) {
        guard let indexer else { return }
        Task { await indexer.apply([change]) }
    }

    /// `Settings → Rebuild index` (FR-5.4). Exposed rather than wired, so the
    /// Settings pane can call it without this file knowing about the pane.
    @discardableResult
    func rebuildAll() async -> IndexReport? {
        guard let indexer else { return nil }
        do {
            let report = try await indexer.rebuildAll()
            try await vectors?.reload()
            await hybrid?.invalidate()
            return report
        } catch {
            Log.index.error("rebuild failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// After a `MetadataStore.rebuild(from:)`, which drops chunks with the notes.
    func catchUp() async {
        guard let indexer else { return }
        _ = try? await indexer.catchUp()
        try? await vectors?.reload()
        await hybrid?.invalidate()
    }

    // MARK: - Searching

    /// Stage one: the local ranking, immediately (FR-5.5 — this never needs AI).
    func candidates(_ query: String) async -> SemanticResults? {
        guard let service else { return nil }
        return await service.candidates(query)
    }

    /// Stage two: the card.
    func answer(
        for query: String, results: SemanticResults
    ) async -> (answer: AnswerResult, availability: SemanticAvailability)? {
        guard let service else { return nil }
        return await service.answer(for: query, results: results)
    }

    /// Why the answer step cannot run, before running it — so the panel can
    /// show its notice next to the first, local result set.
    var pendingUnavailability: SemanticUnavailable? {
        if !settings.semanticSearchEnabled { return .semanticSearchDisabled }
        if extractor == nil { return .noProvider }
        if !providerReady.value { return .notConfigured }
        return nil
    }

    // MARK: - Observation

    private func observeIndexStatus() {
        guard let indexer, statusTask == nil else { return }
        statusTask = Task { [weak self] in
            for await status in await indexer.statusStream() {
                self?.indexStatus = status
            }
        }
    }

    /// FR-4.5: excluding a folder later purges what is already indexed, and
    /// re-including one indexes it. Both go through `catchUp()`.
    private func observeSettings() {
        guard settingsToken == nil else { return }
        settingsToken = settings.observe { [weak self] key in
            guard key == .excludedFolders || key == .searchModel || key == .advancedModelOverride else { return }
            Task { @MainActor in self?.settingsChanged(key) }
        }
    }

    private func settingsChanged(_ key: CoreSettings.Key) {
        switch key {
        case .excludedFolders:
            let filter = ExclusionFilter(excludedFolders: settings.excludedFolders)
            exclusions.set(filter)
            Task { [weak self] in
                await self?.service?.setExclusions(filter)
                await self?.catchUp()
            }
        case .searchModel, .advancedModelOverride:
            let model = settings.effectiveSearchModel
            Task { [weak self] in await self?.extractor?.setModel(model) }
        default:
            break
        }
    }

    /// The gate the answer step is behind: a live provider needs a valid key,
    /// a replayed one does not.
    private func observeAIStatus() {
        guard aiStatusTask == nil else { return }
        guard AIMode.current().isLive else {
            providerReady.set(extractor != nil)
            return
        }
        let connection = SettingsModel.shared.connection
        aiStatusTask = Task { [providerReady] in
            await connection.refresh()
            providerReady.set(await connection.status == .connected)
            for await status in await connection.statusChanges() {
                providerReady.set(status == .connected)
            }
        }
    }
}

// MARK: - Small shared boxes

/// The current exclusions, readable from the `@Sendable` closure `Indexer`
/// holds for the life of the process.
private final class ExclusionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var filter = ExclusionFilter.none

    var current: ExclusionFilter {
        lock.lock()
        defer { lock.unlock() }
        return filter
    }

    func set(_ filter: ExclusionFilter) {
        lock.lock()
        defer { lock.unlock() }
        self.filter = filter
    }

    func isExcluded(_ path: String) -> Bool { current.isExcluded(path: path) }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool

    init(_ value: Bool) { stored = value }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        stored = value
    }
}
