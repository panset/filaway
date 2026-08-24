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
    /// FR-8.1's Semantic-search switch, mirrored so SwiftUI redraws when it
    /// moves. `settings.semanticSearchEnabled` is the source of truth; this is
    /// the published shadow (M4-02).
    @Published private(set) var semanticEnabled = CoreSettings.defaultSemanticSearchEnabled

    private(set) var indexer: Indexer?
    private(set) var metadata: MetadataStore?
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
    /// FR-6.6's counter, kept so a live provider rebuild does not silently stop
    /// billing search requests to it.
    private var ledger: AIUsageLedger?
    private var deferredFinder: DeferredCandidateFinder?

    /// Told when FR-8.1's semantic switch moves, so ⌘K can leave Ask mode
    /// (M4-02). `AppModel` wires it to ``SearchCoordinator``.
    var onEnabledChanged: ((Bool) -> Void)?

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

    /// FR-8.1's toggle. Off → the Ask mode is hidden, ⏎ stays keyword, and the
    /// indexer is parked (M4-02).
    var isSemanticSearchEnabled: Bool { settings.semanticSearchEnabled }

    // MARK: - Launch

    /// Builds the stack behind the first frame. Safe to call twice.
    func start(metadata: MetadataStore, library: Library) {
        guard indexTask == nil else { return }
        self.metadata = metadata
        let ledger = try? AIUsageLedger(library: library)
        self.ledger = ledger
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
            self.deferredFinder?.adopt(hybrid)
            self.observeIndexStatus()
            self.observeSettings()
            self.observeAIStatus()

            guard let indexer else { return }
            // FR-8.1: with semantic search off there is nothing to index for —
            // the embeddings are derived data nobody is about to read, and
            // building them would spend battery on a feature the user turned
            // off. The switch coming back on runs the catch-up (M4-02).
            self.semanticEnabled = settings.semanticSearchEnabled
            guard settings.semanticSearchEnabled else { return }
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

    /// ADR-069's resolution order for the answer step: `FILAWAY_AI_PROVIDER` →
    /// the `ai.provider` preference → Claude. Same order, same reasons, as
    /// `CoreOrganizeSettings.providerKind` — the two must never disagree, or
    /// ⌘K and the organizer would be talking to different backends.
    static func resolvedKind(_ settings: CoreSettings) -> AIProviderKind {
        settings.resolvedAIProvider
    }

    /// The provider the answer step uses — the same one the organizer gets.
    private static func makeExtractor(
        settings: CoreSettings,
        ledger: AIUsageLedger?,
        override: (any AIProvider)?
    ) -> AnswerExtractor? {
        let kind = resolvedKind(settings)
        let configuration = AnswerExtractor.Configuration(
            model: settings.effectiveSearchModel, providerKind: kind
        )
        if let override {
            return AnswerExtractor(provider: override, ledger: ledger, configuration: configuration)
        }
        // One convention for the whole app: default `live`, `replay` only with
        // `FILAWAY_AI_FIXTURES`, `FILAWAY_AI_FAIL` for the offline phases
        // (ADR-041). `makeProvider` throws when replay has nothing to replay,
        // which is the "connect your AI" state rather than an outage.
        guard let provider = try? OrganizeCoordinator.makeProvider(
            kind: kind, ollama: settings.ollamaConfiguration
        ) else { return nil }
        OrganizeCoordinator.warmUpIfNeeded(kind: kind, ollama: settings.ollamaConfiguration)
        return AnswerExtractor(provider: provider, ledger: ledger, configuration: configuration)
    }

    /// Tears the retrieval stack down so ``start(metadata:library:)`` can build
    /// a new one against a different library (Settings → General → Change…,
    /// M4-02).
    ///
    /// The embedder is deliberately *not* kept: the vector store, the index and
    /// the ranker are all keyed to one `MetadataStore`, and half-swapping them
    /// is how you get answers from the folder the user just left.
    func resetForLibraryChange() {
        indexTask?.cancel()
        statusTask?.cancel()
        changeTask?.cancel()
        settingsToken?.invalidate()
        let stopping = indexer
        Task { await stopping?.stop() }
        indexTask = nil
        statusTask = nil
        changeTask = nil
        settingsToken = nil
        indexer = nil
        metadata = nil
        vectors = nil
        hybrid = nil
        extractor = nil
        service = nil
        deferredFinder = nil
        ledger = nil
        isReady = false
        indexStatus = .idle
        // Re-resolving re-points the exclusion box at the new library's list —
        // `excludedFolders` is per `Library.key` (FR-4.5).
        resolvedSettings = nil
    }

    /// Smoke and previews: swap the answer step's provider, before or after
    /// ``start(metadata:library:)``.
    func overrideProvider(_ provider: any AIProvider) {
        providerOverride = provider
        let replacement = AnswerExtractor(
            provider: provider,
            configuration: AnswerExtractor.Configuration(
                model: settings.effectiveSearchModel, providerKind: Self.resolvedKind(settings)
            )
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

    /// What the live ``AnswerExtractor`` will ask with (FR-6.5).
    ///
    /// Read off the actor rather than off Settings, so the smoke check is
    /// asserting the wiring and not the preference it just wrote.
    func providerKindProbe() async -> (kind: AIProviderKind, model: AIModel, identifier: String) {
        guard let extractor else {
            return (Self.resolvedKind(settings), settings.effectiveSearchModel, "none")
        }
        return (
            kind: await extractor.providerKind,
            model: await extractor.model,
            identifier: extractor.providerIdentifier
        )
    }

    /// FR-8.1's live rebuild of the answer step.
    ///
    /// A provider override (the `semantic` smoke phase scripts one) always
    /// wins: the phase is proving the panel, not the backend.
    private func rebuildExtractor() {
        guard let hybrid else { return }
        let settings = self.settings
        let kind = Self.resolvedKind(settings)
        let replacement: AnswerExtractor?
        if let providerOverride {
            replacement = AnswerExtractor(
                provider: providerOverride,
                ledger: ledger,
                configuration: AnswerExtractor.Configuration(
                    model: settings.effectiveSearchModel, providerKind: kind
                )
            )
        } else {
            replacement = Self.makeExtractor(settings: settings, ledger: ledger, override: nil)
        }
        guard let replacement else { return }
        extractor = replacement
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
        // Ollama has no key to be missing, so the FR-6.1 gate does not apply to
        // it: a dead daemon is an outage the request itself reports.
        if kind == .ollama { providerReady.set(true) }
        Log.ai.info("answer extractor rebuilt for \(kind.rawValue, privacy: .public)")
    }

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

    /// FR-4.5, the half `catchUp()` cannot do (M4-02).
    ///
    /// Excluding a folder has to *remove* what is already indexed, not merely
    /// stop adding to it — otherwise the chunks stay retrievable and land in a
    /// prompt, which is exactly what the setting promises will never happen.
    /// `catchUp()` is no help: an indexed note whose content has not changed is
    /// not stale, so it is never revisited. `Indexer.index(noteID:)` *does*
    /// purge an excluded note, so this walks the library and asks for each one
    /// the filter now covers.
    ///
    /// - Returns: how many notes were purged, which the smoke phase asserts.
    @discardableResult
    func purgeExcluded(_ filter: ExclusionFilter) async -> Int {
        guard !filter.isEmpty, let indexer, let metadata else { return 0 }
        let notes = (try? await metadata.allNotes()) ?? []
        var purged = 0
        for note in notes where filter.isExcluded(path: note.relativePath) {
            let report = try? await indexer.index(noteID: note.id)
            purged += report?.notesPurged ?? 0
        }
        if purged > 0 {
            try? await vectors?.reload()
            await hybrid?.invalidate()
        }
        return purged
    }

    /// After a `MetadataStore.rebuild(from:)`, which drops chunks with the notes.
    func catchUp() async {
        guard let indexer else { return }
        _ = try? await indexer.catchUp()
        try? await vectors?.reload()
        await hybrid?.invalidate()
    }

    // MARK: - Merge-target retrieval (M3-08)

    /// A `CandidateFinder` the organizer can be built with **before** the
    /// retrieval stack is up.
    ///
    /// `OrganizeCoordinator.start` runs on the first paint; the embedder is
    /// still compiling then, so `hybrid` is `nil` and there is nothing to hand
    /// it. This returns a stable object that forwards to `fallback` until the
    /// index exists and to ``HybridCandidateFinder`` from then on — so the
    /// organizer is constructed once and silently gets better (FR-4.6).
    func candidateFinder(fallback: any CandidateFinder) -> any CandidateFinder {
        let finder = DeferredCandidateFinder(fallback: fallback)
        deferredFinder = finder
        if let hybrid { finder.adopt(hybrid) }
        return finder
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
            switch key {
            case .excludedFolders, .searchModel, .advancedModelOverride, .semanticSearchEnabled,
             .aiProvider, .ollamaBaseURL, .ollamaModel:
                Task { @MainActor in self?.settingsChanged(key) }
            default:
                break
            }
        }
    }

    private func settingsChanged(_ key: CoreSettings.Key) {
        switch key {
        case .semanticSearchEnabled:
            let enabled = settings.semanticSearchEnabled
            guard enabled != semanticEnabled else { return }
            semanticEnabled = enabled
            onEnabledChanged?(enabled)
            guard let indexer else { return }
            Task { [weak self] in
                if enabled {
                    // Catching up first means the index is usable the moment
                    // the loop starts, rather than one poll interval later.
                    await self?.catchUp()
                    await indexer.start()
                } else {
                    await indexer.stop()
                }
            }

        case .excludedFolders:
            let filter = ExclusionFilter(excludedFolders: settings.excludedFolders)
            exclusions.set(filter)
            Task { [weak self] in
                await self?.service?.setExclusions(filter)
                // Order matters: purge what is now excluded *before* catching
                // up, so a folder that was excluded and re-included in one
                // session does not end up half-indexed.
                await self?.purgeExcluded(filter)
                await self?.catchUp()
            }
        case .searchModel, .advancedModelOverride:
            let model = settings.effectiveSearchModel
            Task { [weak self] in await self?.extractor?.setModel(model) }
        // FR-6.5 / FR-8.1: the backend moved. The provider object is `let`
        // inside `AnswerExtractor`, so this rebuilds the extractor and the
        // service around it rather than mutating one (ADR-069).
        case .aiProvider, .ollamaBaseURL, .ollamaModel:
            rebuildExtractor()
        default:
            break
        }
    }

    /// The gate the answer step is behind: a live provider needs a valid key,
    /// a replayed one does not.
    private func observeAIStatus() {
        guard aiStatusTask == nil else { return }
        let mode = ProcessInfo.processInfo.environment[AIMode.environmentVariable]
            .flatMap { AIMode(rawValue: $0.lowercased()) } ?? .live
        guard mode.isLive else {
            providerReady.set(extractor != nil)
            return
        }
        // FR-6.5: the local provider has no credential, so gating it on the
        // key manager would leave the answer card permanently "not configured".
        // A daemon that is down surfaces as `.network` from the request itself.
        guard Self.resolvedKind(settings) != .ollama else {
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

/// Forwards to ``HybridCandidateFinder`` once there is an index, and to the
/// keyword finder until then (M3-08).
private final class DeferredCandidateFinder: CandidateFinder, @unchecked Sendable {
    private let lock = NSLock()
    private let fallback: any CandidateFinder
    private var hybrid: (any CandidateFinder)?

    init(fallback: any CandidateFinder) {
        self.fallback = fallback
    }

    func adopt(_ search: HybridSearch) {
        let finder = HybridCandidateFinder(hybrid: search, fallback: fallback)
        lock.lock()
        defer { lock.unlock() }
        hybrid = finder
    }

    private var current: any CandidateFinder {
        lock.lock()
        defer { lock.unlock() }
        return hybrid ?? fallback
    }

    func candidates(
        for query: CandidateQuery, in context: OrganizeContext
    ) async throws -> [OrganizeCandidate] {
        try await current.candidates(for: query, in: context)
    }
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
