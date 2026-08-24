import AppKit
import FilawayCore
import SwiftUI

/// The organize pipeline, held together for the shell (M2-09, M2-10, M2-12).
///
/// `AppModel` owns the storage stack; this owns everything above it — the
/// session tracker, the organizer, the applier, the Activity log, Undo and the
/// FR-6.4 queue — and turns `OrganizerEvent`s into main-actor card state.
///
/// ## What it wires (docs/organize.md, "What the app layer has to wire")
///
/// ```text
/// editor keystroke ─┬─▶ SessionTracker.noteEdited      (starts/sustains a session)
///                   └─▶ Organizer.noteEdited           (supersede rules, FR-3.2)
/// scroll/selection ──▶ SessionTracker.editorActivity
/// ⌘-Tab / close / quit ▶ SessionTracker.appDid…        (grace, amendment 2)
///
/// tracker.events ──▶ flush ──▶ .ended ──▶ Organizer.sessionEnded
/// organizer.events ──▶ @MainActor cards / status pill
/// after apply or undo ──▶ LibraryWatcher.reconcile(paths:) ──▶ sidebar + index
/// ```
///
/// The ordering contract is the tracker's: it awaits the flush hook before it
/// publishes `.ended`, and nothing here may reorder the snapshot and the apply.
///
/// Nothing on this path can block capture. Every failure is a card that does
/// not appear, a status pill that changes, or a row in the log.
@MainActor
final class OrganizeCoordinator: ObservableObject {

    // MARK: - Card state (FR-4.2, Figure 2a)

    /// One organization card. Ask mode carries a proposal (Accept / Edit /
    /// Dismiss); auto mode and an accepted proposal carry an applied event
    /// (Undo / View changes).
    struct Card: Identifiable, Equatable {
        let id = UUID()
        var proposal: ProposedPlan?
        var eventID: ActivityEventID?
        /// The model's Figure 2a sentence. For an applied plan it is read back
        /// off the stored plan, because `AppliedPlan.summary` is the applier's
        /// own account of what it did ("Moved a section from Scratch.") and the
        /// spec's card is the plain-language one.
        var summary: String
        var plan: OrganizationPlan?
        var warnings: [PlanIssue] = []
        var createdAt: Date = Date()

        var isProposal: Bool { proposal != nil }

        /// FR-4.2: "Merge code block into Commands/curl?" vs "Session organized".
        var title: String { isProposal ? "Organize this session?" : "Session organized" }

        var accessibilityLabel: String { "\(title) \(summary)" }
    }

    /// Cards queue: several sessions can finish while the user is reading.
    @Published private(set) var cards: [Card] = []
    /// The card whose Edit sheet is open.
    @Published var editingCard: Card?
    /// The card, or Activity event, whose View-changes sheet is open.
    @Published var changesCard: Card?

    // MARK: - Status (FR-6.4, M2-09)

    @Published private(set) var status: AIStatus = .connected {
        didSet { if status != oldValue { onStatusChanged?(status) } }
    }
    /// Sessions waiting for the provider to come back.
    @Published private(set) var queuedSessionCount = 0
    /// `true` once the pipeline is running. Nothing below is non-nil before it.
    @Published private(set) var isReady = false
    /// The last content-free reason a session produced no card (P2-03).
    ///
    /// `OrganizeFailure.label` and `OrganizeSkipReason` are both content-free by
    /// construction (NFR-4), which is what lets the `organize-ollama` smoke
    /// phase — the one that asks a *real* local model for a real plan — say why
    /// nothing arrived instead of timing out with no explanation.
    @Published private(set) var lastFailureReason: String?

    /// The provider the preference (or `FILAWAY_AI_PROVIDER`) currently names —
    /// what the toolbar pill words its offline state for ("Ollama offline").
    var providerKind: AIProviderKind { settingsSource.providerKind }

    /// How long an auto-mode card stays up before it fades (FR-4.2's
    /// non-blocking summary). Undo stays reachable in the Activity window.
    static let autoDismissInterval: TimeInterval = 20

    // MARK: - Dependencies

    private let library: Library
    private let store: NoteStore
    private let metadata: MetadataStore
    private let watcher: LibraryWatcher
    private(set) var activity: ActivityLog?
    private(set) var undoService: UndoService?
    private var applier: PlanApplier?
    private var organizer: Organizer?
    private var tracker: SessionTracker?
    private var queue: PendingSessionStoreGRDB?
    private var settingsSource: any OrganizeSettingsSource

    private var sessionTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var settingsToken: CoreSettings.Observation?
    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    private let log = Log.make("organize-ui")

    /// Called after an apply or an undo, with the notes and paths that moved,
    /// so the shell can refresh the sidebar and reload the open note.
    var onLibraryChanged: ((Set<NoteID>) -> Void)?
    /// Non-blocking status messages (a stale plan, a partial undo).
    var onBanner: ((String, String) -> Void)?
    /// Clicking the AI status pill. Settings is M2-11's; this is the seam.
    var onOpenAISettings: (() -> Void)?
    /// The pill moved. FR-7.1's gentle "connect your AI" row listens, so it
    /// stops offering a connection that is already working — which under
    /// FR-6.5 may be a local daemon with no key at all (P2-03).
    var onStatusChanged: ((AIStatus) -> Void)?

    // MARK: - Init

    init(
        library: Library,
        store: NoteStore,
        metadata: MetadataStore,
        watcher: LibraryWatcher,
        settings: any OrganizeSettingsSource = CoreOrganizeSettings(SettingsModel.shared.settings)
    ) {
        self.library = library
        self.store = store
        self.metadata = metadata
        self.watcher = watcher
        settingsSource = settings
    }

    deinit {
        sessionTask?.cancel()
        eventTask?.cancel()
        retryTask?.cancel()
        connectionTask?.cancel()
    }

    // MARK: - Launch

    /// Builds the pipeline. Call once, off the first paint.
    ///
    /// - Returns: the recovery outcomes of ``PlanApplier/recoverIncompleteEvents()``,
    ///   which **must** run before the launch `reconcile()` — a rolled-back
    ///   apply moves files, and the reconcile has to see the tree afterwards
    ///   (docs/core-api.md, "Crash recovery").
    /// - Parameter candidateFinder: M3-08's hybrid finder, when the retrieval
    ///   stack can supply one. `nil` keeps the FTS-only default.
    @discardableResult
    func start(
        searchService: SearchService,
        autosave: AutosaveController?,
        candidateFinder: (any CandidateFinder)? = nil
    ) async -> [RecoveryOutcome] {
        guard organizer == nil else { return [] }
        let settings = settingsSource
        do {
            let activity = try await Task.detached(priority: .userInitiated) { [library] in
                try ActivityLog(library: library)
            }.value
            let queue = try await Task.detached(priority: .userInitiated) { [library] in
                try PendingSessionStoreGRDB(library: library)
            }.value
            let applier = PlanApplier(
                store: store, activity: activity, excludedFolders: settings.excludedFolders
            )
            let undoService = UndoService(store: store, activity: activity)

            let provider = try Self.makeProvider(
                kind: settings.providerKind, ollama: settings.ollamaConfiguration
            )
            Self.warmUpIfNeeded(kind: settings.providerKind, ollama: settings.ollamaConfiguration)
            let organizer = Organizer(
                provider: provider,
                source: OrganizeLibrarySourceLive(store: store),
                baselines: activity,
                applier: applier,
                candidateFinder: candidateFinder ?? KeywordCandidateFinder(search: searchService),
                queueStore: queue,
                settings: settings.organizerSettings
            )
            let tracker = SessionTracker(configuration: settings.sessionConfiguration)
            // The ordering contract's first half: the editor's buffer is on
            // disk before the organizer reads the note (docs/organize.md).
            await tracker.setFlushHook { @Sendable in
                await MainActor.run { autosave }?.flushNow(trigger: .manual)
            }

            self.activity = activity
            self.queue = queue
            self.applier = applier
            self.undoService = undoService
            self.organizer = organizer
            self.tracker = tracker

            consume(tracker: tracker, organizer: organizer)
            observeSettings()
            observeConnection()
            startRetryLoop()
            isReady = true

            // Crash recovery, before the caller reconciles.
            let outcomes = (try? await applier.recoverIncompleteEvents()) ?? []
            if !outcomes.isEmpty {
                log.info("recovered \(outcomes.count, privacy: .public) incomplete apply events")
                onBanner?("Filaway finished tidying up an interrupted organization.", "arrow.uturn.backward")
            }
            // FR-4.4 retention, once a day rather than once a launch (M4-08).
            // Fire-and-forget: nothing downstream waits on a prune, and the
            // scheduler's stamp makes a second launch in the same day a no-op.
            let maintenance = MaintenanceScheduler(library: library)
            Task.detached(priority: .background) {
                await maintenance.runIfDue(.activityPrune) { _ = try? await activity.prune() }
            }

            await refreshQueueCount()
            // A relaunch is the other half of FR-6.4: anything that was waiting
            // for the network gets its next attempt now.
            await organizer.retryQueuedSessions()
            return outcomes
        } catch {
            log.error("organize pipeline unavailable: \(String(describing: error), privacy: .public)")
            status = .error("Filaway could not start the organizer.")
            return []
        }
    }

    /// `FILAWAY_AI_MODE` picks the *harness*; `kind` picks the **backend**.
    ///
    /// The **app** defaults to `live` with the Keychain key where the test
    /// harness defaults to `replay` (`AIMode.current()`): a shipped build must
    /// never quietly serve fixtures, and the fixture directory only exists in
    /// the repository. `replay` therefore also needs `FILAWAY_AI_FIXTURES` —
    /// which is exactly what `Tools/smoke.sh` sets.
    ///
    /// The two axes are independent (ADR-069): `replay` serves a committed
    /// fixture whichever backend recorded it, and `FILAWAY_AI_FAIL` short-cuts
    /// both. `kind` only decides what a *live* or *recording* request talks to.
    ///
    /// - Parameters:
    ///   - kind: resolved by ``OrganizeSettingsSource/providerKind`` —
    ///     `FILAWAY_AI_PROVIDER` → the `ai.provider` preference → Claude.
    ///   - ollama: where the local daemon is, when `kind` is `.ollama`. An
    ///     invalid base URL (plaintext `http` to a non-loopback host) falls back
    ///     to the default rather than tripping `OllamaProvider`'s precondition.
    static func makeProvider(
        kind: AIProviderKind = AIProviderKind.fromEnvironment() ?? .claude,
        ollama: OllamaConfiguration = OllamaConfiguration(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any AIProvider {
        // `FILAWAY_AI_FAIL=network` is the smoke suite's outage: there is no
        // way to unplug the network from inside a test, and the degradation
        // path (FR-6.4) is exactly the one worth proving end to end.
        if let failure = environment["FILAWAY_AI_FAIL"], !failure.isEmpty {
            let error: AIError = failure == "invalidKey"
                ? .invalidKey(message: "smoke")
                : .network(code: URLError.notConnectedToInternet.rawValue, description: "smoke: offline")
            return MockProvider.failing(error)
        }
        let mode = AIMode.appMode(environment: environment)
        return try AIProviderFactory.make(
            mode: mode,
            store: AIRecordingStore.fromEnvironment(environment),
            keySource: .storeThenEnvironment(KeychainStore()),
            kind: kind,
            ollama: ollama.validate() ? ollama : OllamaConfiguration(model: ollama.model)
        )
    }

    /// One preload so the *first* answer card is not charged for a cold model
    /// load (ADR-069). Fire-and-forget: nothing waits on it, ever.
    ///
    /// Skipped for anything but a live Ollama — a replayed phase has no daemon
    /// to warm, and `FILAWAY_AI_FAIL` is an outage the phase is asserting.
    static func warmUpIfNeeded(
        kind: AIProviderKind,
        ollama: OllamaConfiguration,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard kind == .ollama, ollama.validate() else { return }
        guard environment["FILAWAY_AI_FAIL"]?.isEmpty ?? true else { return }
        let mode = AIMode.appMode(environment: environment)
        guard mode.isLive else { return }
        Task.detached(priority: .utility) {
            await OllamaProvider(configuration: ollama).warmUp()
        }
    }

    func stop() {
        sessionTask?.cancel()
        eventTask?.cancel()
        retryTask?.cancel()
        connectionTask?.cancel()
        settingsToken?.invalidate()
        settingsToken = nil
        for task in dismissTasks.values { task.cancel() }
        dismissTasks.removeAll()
        let tracker = self.tracker
        let organizer = self.organizer
        Task {
            await tracker?.stop()
            await organizer?.stop()
        }
    }

    // MARK: - Settings (FR-8.1)

    /// Settings changed. Safe to call at any time; the running session keeps its
    /// identity and only its deadline moves.
    func settingsChanged(to source: (any OrganizeSettingsSource)? = nil) {
        if let source { settingsSource = source }
        let settings = settingsSource
        let tracker = self.tracker
        let organizer = self.organizer
        let applier = self.applier
        Task {
            await tracker?.setConfiguration(settings.sessionConfiguration)
            await organizer?.setSettings(settings.organizerSettings)
            // FR-4.5 is enforced twice: the organizer never *proposes* a
            // destination inside an excluded folder, and the applier refuses to
            // write into one. Both have to hear about the change.
            await applier?.setExcludedFolders(settings.excludedFolders)
        }
    }

    var mode: OrganizeMode { settingsSource.organizationMode }

    /// FR-8.1's "changes apply live" (M4-02).
    ///
    /// `CoreSettings.observe(_:)` fires synchronously on whichever thread wrote
    /// the preference — which is the main actor for every path that goes
    /// through the Settings window — so the handler only re-reads the source
    /// and pushes it at the two actors. Nothing here restarts the pipeline: a
    /// running session keeps its identity and only its deadline moves.
    private func observeSettings() {
        guard settingsToken == nil, let core = (settingsSource as? CoreOrganizeSettings)?.settings else { return }
        settingsToken = core.observe { [weak self] key in
            switch key {
            case .organizationMode, .idleInterval, .excludedFolders,
                 .organizeModel, .advancedModelOverride:
                Task { @MainActor in self?.settingsChanged() }
            // FR-6.5 / FR-8.1: switching backend, or moving the daemon or the
            // local model tag, must not need a relaunch (ADR-069). The provider
            // is an *object*, not a per-request lookup like the Claude key, so
            // this rebuilds it and hands it to the running actor.
            case .aiProvider, .ollamaBaseURL, .ollamaModel:
                Task { @MainActor in self?.providerChanged() }
            default:
                break
            }
        }
    }

    /// Rebuilds the provider from the current settings and swaps it into the
    /// live `Organizer` (FR-6.5, FR-8.1).
    ///
    /// It pushes ``OrganizerSettings`` too, because the model *and* the request
    /// timeout move with the backend: `effectiveOrganizeModel` becomes the
    /// Ollama tag and `providerKind.timeout(for: .organize)` becomes 180 s.
    func providerChanged() {
        let settings = settingsSource
        let kind = settings.providerKind
        let ollama = settings.ollamaConfiguration
        guard let organizer else { return }
        let provider: any AIProvider
        do {
            provider = try Self.makeProvider(kind: kind, ollama: ollama)
        } catch {
            log.error("provider rebuild failed: \(String(describing: error), privacy: .public)")
            return
        }
        Self.warmUpIfNeeded(kind: kind, ollama: ollama)
        // Leaving Claude drops the key-based pill state on the floor; arriving
        // at Claude re-subscribes to it.
        if kind == .ollama {
            connectionTask?.cancel()
            connectionTask = nil
            if status == .notConfigured || status == .invalidKey { status = .connected }
        } else {
            observeConnection()
        }
        let organizerSettings = settings.organizerSettings
        Task {
            await organizer.setProvider(provider)
            await organizer.setSettings(organizerSettings)
        }
        log.info("organize provider switched to \(kind.rawValue, privacy: .public)")
    }

    /// FR-6.4 / FR-6.5: the key changed in Settings → AI, so the pill moves and
    /// anything that was queued waiting for a working key goes out now.
    ///
    /// The provider itself needs no rebuilding — `APIKeySource` reads the
    /// Keychain on every request, so "Change…" takes effect on the next call
    /// with no relaunch. What has to be told is the `Organizer`, whose own
    /// status gates the queue.
    private func observeConnection() {
        guard connectionTask == nil else { return }
        // FR-6.5: the local provider has no credential, so folding in the key
        // manager would park the pill on "Connect AI" for a setup that works
        // perfectly. What the pill reports under Ollama is what the *requests*
        // report — offline, rate limited, or nothing at all (ADR-069).
        guard settingsSource.providerKind != .ollama else { return }
        let connection = SettingsModel.shared.connection
        connectionTask = Task { [weak self] in
            for await status in await connection.statusChanges() {
                guard let self else { return }
                await self.connectionStatusChanged(status)
            }
        }
    }

    /// Visible for the smoke phase, which has no live Keychain to change.
    func connectionStatusChanged(_ status: AIStatus) async {
        // A live pipeline failure (offline, rate limit) is more specific than
        // "the key validates", so a `connected` report never overwrites one —
        // the retry loop clears it when the provider actually answers.
        if status == .connected {
            if self.status == .notConfigured || self.status == .invalidKey { self.status = .connected }
        } else {
            self.status = status
        }
        await organizer?.aiStatusChanged(status)
        await refreshQueueCount()
    }

    // MARK: - Editor and application inputs (FR-3.1)

    /// Every keystroke: the tracker starts or sustains the session, and the
    /// organizer applies FR-3.2's supersede rules.
    func noteEdited(_ noteID: NoteID) {
        guard let tracker, let organizer else { return }
        Task {
            await tracker.noteEdited(noteID)
            await organizer.noteEdited(noteID)
        }
    }

    /// Scroll and selection sustain a session but never start one.
    func editorActivity(_ noteID: NoteID, kind: EditorActivity) {
        guard let tracker else { return }
        let core: EditorActivityKind
        switch kind {
        case .typing: core = .keystroke
        case .selection: core = .selection
        case .scroll: core = .scroll
        }
        // A keystroke reaches the tracker through `noteEdited` already; sending
        // it twice would be harmless but pointless.
        guard core != .keystroke else { return }
        Task { await tracker.editorActivity(noteID, kind: core) }
    }

    func noteSwitched(to noteID: NoteID?) {
        guard let tracker else { return }
        Task { await tracker.noteSwitched(to: noteID) }
    }

    func appDidResignActive() { send { await $0.appDidResignActive() } }
    func appDidBecomeActive() { send { await $0.appDidBecomeActive() } }
    func windowClosed() { send { await $0.windowClosed() } }

    /// Quitting. Returns a task the terminate path can wait on, so the last
    /// session is published before the process goes.
    @discardableResult
    func appWillTerminate() -> Task<Void, Never>? {
        guard let tracker else { return nil }
        return Task { await tracker.appWillTerminate() }
    }

    private func send(_ body: @escaping @Sendable (SessionTracker) async -> Void) {
        guard let tracker else { return }
        Task { await body(tracker) }
    }

    // MARK: - Card actions (FR-4.2)

    func accept(_ card: Card, editedPlan: OrganizationPlan? = nil) {
        guard let proposal = card.proposal, let organizer else { return }
        remove(card)
        Task { await organizer.accept(proposal.id, plan: editedPlan) }
    }

    func dismiss(_ card: Card) {
        remove(card)
        guard let proposal = card.proposal, let organizer else { return }
        let activity = self.activity
        Task {
            await organizer.dismiss(proposal.id)
            // The log records the road not taken, so "View changes" and the
            // Activity window can explain why nothing happened.
            _ = try? await activity?.recordDismissed(
                plan: proposal.plan, summary: proposal.plan.summary, sessionText: nil, at: Date()
            )
        }
    }

    /// The card's Undo (FR-4.3). Auto mode's whole safety net.
    func undo(_ card: Card) {
        guard let eventID = card.eventID else { return }
        remove(card)
        undo(eventID: eventID)
    }

    func undo(eventID: ActivityEventID) {
        guard let undoService else { return }
        Task { [weak self] in
            do {
                let result = try await undoService.undo(eventID)
                await self?.libraryChanged(noteIDs: Set(result.notes.map(\.noteID)),
                                           paths: result.notes.flatMap { [$0.relativePath, $0.previousPath].compactMap { $0 } })
                if result.outcome == .partial {
                    self?.onBanner?("Some changes came back under a conflict heading.", "arrow.triangle.branch")
                }
            } catch {
                self?.onBanner?(Self.message(for: error), "exclamationmark.triangle")
            }
        }
    }

    /// The most recent undoable event, for Edit → Undo Last Organization.
    func undoLatest() {
        guard let undoService else { return }
        Task { [weak self] in
            do {
                let result = try await undoService.undoLatest()
                await self?.libraryChanged(noteIDs: Set(result.notes.map(\.noteID)),
                                           paths: result.notes.flatMap { [$0.relativePath, $0.previousPath].compactMap { $0 } })
            } catch {
                self?.onBanner?(Self.message(for: error), "exclamationmark.triangle")
            }
        }
    }

    static func message(for error: Error) -> String {
        if let undoError = error as? UndoError { return undoError.description }
        return "That could not be undone: \(error)"
    }

    func remove(_ card: Card) {
        dismissTasks.removeValue(forKey: card.id)?.cancel()
        cards.removeAll { $0.id == card.id }
    }

    // MARK: - Organizer events

    private func consume(tracker: SessionTracker, organizer: Organizer) {
        let sessions = tracker.events
        sessionTask = Task { [weak self] in
            for await event in sessions {
                guard case let .ended(session) = event else { continue }
                await organizer.sessionEnded(session)
                _ = self  // keep the task tied to the coordinator's lifetime
            }
        }
        let events = organizer.events
        eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
    }

    private func handle(_ event: OrganizerEvent) async {
        switch event {
        case let .proposed(proposal):
            status = .connected
            show(Card(
                proposal: proposal,
                summary: proposal.plan.summary,
                plan: proposal.plan,
                warnings: proposal.validation.warnings
            ))

        case let .applied(applied):
            status = .connected
            let plan = await storedPlan(for: applied.eventID)
            show(Card(
                eventID: applied.eventID,
                summary: plan?.summary ?? applied.summary,
                plan: plan
            ))
            await libraryChanged(
                noteIDs: Set(applied.changedPaths.keys).union(applied.createdNotes).union(applied.removedNoteIDs),
                paths: Array(applied.changedPaths.values)
                    + applied.outcomes.flatMap { [$0.relativePath, $0.previousPath].compactMap { $0 } }
                    + applied.trashedNotes.map(\.relativePath)
            )

        case let .withdrawn(id, _):
            cards.removeAll { $0.proposal?.id == id }

        case let .stale(id, _):
            cards.removeAll { $0.proposal?.id == id }
            onBanner?("That note changed while the plan was waiting, so nothing was written.", "clock.arrow.circlepath")

        case let .queued(_, attempt, _):
            status = status.isUsable() ? .offline : status
            await refreshQueueCount()
            log.info("session queued (attempt \(attempt, privacy: .public))")

        case .retrying:
            await refreshQueueCount()

        case let .failed(_, failure):
            log.error("organize failed: \(failure.label, privacy: .public)")
            lastFailureReason = failure.label
            if case let .provider(error) = failure {
                status = AIHealth.status(for: error)
            }
            await refreshQueueCount()
            // The session is not applied and not queued — saying nothing here
            // is how "no organizations yet" stays a mystery. One banner line,
            // content-free (the label is an error kind, never note text), and
            // a durable Activity row so the reason outlives the banner.
            let failedModel = await organizer?.currentSettings.model.id
            try? await activity?.recordFailure(reason: failure.label, model: failedModel)
            onBanner?("Couldn't organize this session (\(failure.label)) — details in Activity.", "exclamationmark.triangle")

        case let .skipped(_, reason):
            lastFailureReason = "skipped: \(reason)"

        case .cancelled:
            break
        }
    }

    private func show(_ card: Card) {
        cards.append(card)
        guard !card.isProposal else { return }
        // FR-4.2: the auto-mode card is a summary, not a question. It goes away
        // on its own; Undo lives on in the Activity window.
        dismissTasks[card.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoDismissInterval * 1e9))
            guard !Task.isCancelled else { return }
            self?.cards.removeAll { $0.id == card.id }
        }
    }

    // MARK: - Library follow-up

    /// After every apply and undo: the notes moved through `NoteStore`, whose
    /// own writes are deliberately kept out of the watcher's stream, so the
    /// sidebar and the search index only learn about them if we say so.
    private func libraryChanged(noteIDs: Set<NoteID>, paths: [String]) async {
        let touched = Set(paths.filter { !$0.isEmpty })
        do {
            if touched.isEmpty {
                _ = try await watcher.reconcile()
            } else {
                _ = try await watcher.reconcile(paths: touched)
            }
        } catch {
            log.error("reconcile after apply failed: \(String(describing: error), privacy: .public)")
        }
        onLibraryChanged?(noteIDs)
    }

    /// The plan the model produced, read back off the Activity row.
    /// `AppliedPlan.summary` is the applier's account of what it did; the card
    /// wants the model's plain-language sentence (FR-4.2, Figure 2a).
    func storedPlan(for eventID: ActivityEventID) async -> OrganizationPlan? {
        guard let activity else { return nil }
        return try? await activity.event(eventID)?.plan
    }

    private func refreshQueueCount() async {
        queuedSessionCount = (try? await queue?.count()) ?? 0
    }

    /// Retries the offline queue on a slow loop, so a network that came back
    /// while the app was idle does not wait for the next session (FR-6.4).
    private func startRetryLoop() {
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.organizer?.retryQueuedSessions()
                await self.refreshQueueCount()
            }
        }
    }

    // MARK: - Test hooks

    /// What the `Organizer` actor is actually running with (M4-02).
    ///
    /// The FR-8.1 promise is that a Settings edit applies live; proving it
    /// needs a look *past* `UserDefaults`, at the object that will build the
    /// next prompt. `nil` before ``start(searchService:autosave:candidateFinder:)``.
    func organizerSettingsProbe() async -> OrganizerSettings? {
        await organizer?.currentSettings
    }

    /// What the live `Organizer` will send its **next** request with (FR-6.5).
    ///
    /// Read off the actor, not off Settings, so `ProviderWiringSmokeCheck` is
    /// asserting the wiring rather than the preference it just wrote. The
    /// identifier is the provider object's own — `"ollama"`, `"claude"`,
    /// `"replay"`, `"mock"` — which is how a replayed phase stays honest about
    /// the fact that no backend was reached.
    func providerKindProbe() async -> (kind: AIProviderKind, model: AIModel, identifier: String) {
        let live = await organizer?.currentSettings
        return (
            kind: live?.providerKind ?? settingsSource.providerKind,
            model: live?.model ?? settingsSource.model,
            identifier: await organizer?.providerIdentifier ?? "none"
        )
    }

    /// The idle interval the `SessionTracker` is timing with (FR-3.1).
    func sessionConfigurationProbe() async -> SessionConfiguration? {
        await tracker?.configuration
    }

    /// Ends the current session **now**, as if the idle timer had fired at
    /// `endedAt`, and waits for the pipeline to settle.
    ///
    /// The smoke driver cannot wait out a three-minute idle interval, and the
    /// replayed fixture's key is a hash of a prompt that carries the session's
    /// end time — so the phase has to name that instant. Both are the same
    /// need, which is why this is one hook: rewind the last activity by the
    /// idle interval, then tick.
    func endSessionNow(noteID: NoteID, endedAt: Date) async {
        guard let tracker, let organizer else { return }
        let interval = settingsSource.sessionConfiguration.idleInterval
        await tracker.noteEdited(noteID, at: endedAt.addingTimeInterval(-interval))
        await tracker.tick()
        // The tracker publishes on a stream the consumer task drains; give it a
        // turn, then wait for the request itself.
        for _ in 0 ..< 250 {
            let busy = await organizer.inFlightSessionIDs.isEmpty == false
            let proposed = await organizer.pendingProposals.isEmpty == false
            if busy || proposed || !cards.isEmpty { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        await organizer.drain()
    }

    /// Drains everything in flight. Tests only.
    func drain() async {
        await organizer?.drain()
    }
}
