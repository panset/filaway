import Foundation

/// FR-3.2's concurrency core (plan §3 M2-05, risk #2).
///
/// One actor owns every piece of state that a race could corrupt: what the AI
/// has already seen per note (the *organized baseline*), what is in flight, and
/// what is waiting for the user. The rules below are the whole contract, and
/// there is a test for every cell.
///
/// ## Per-note state
///
/// | | meaning | who clears it |
/// |---|---|---|
/// | baseline | text the AI has already had a chance to file | a completed pipeline |
/// | in flight | a request is running that includes this note | the reply, or the user typing |
/// | pending | a plan is on screen waiting for Accept/Edit/Dismiss | the user, or the user typing |
/// | dirty | a cancelled request left new material unfiled | the next session that covers it |
///
/// ## Session end
///
/// 1. Take the current text of every touched note (the tracker has already run
///    the autosave flush — see ``SessionTracker``'s ordering contract).
/// 2. Compute `baseline → current` per note. **No effective delta anywhere →
///    skip**: no request, no cost, and the baselines advance so the same
///    non-change is not reconsidered next time.
/// 3. Build the context (M2-06) and call the provider.
/// 4. Decode and validate. Invalid actions are dropped when what is left still
///    matches the plan's own summary; otherwise the whole plan goes — see
///    ``repair(plan:unknownActions:context:)``.
/// 5. *Ask* mode: hold it as `pending` and publish ``OrganizerEvent/proposed(_:)``.
///    *Auto* mode: apply it and publish ``OrganizerEvent/applied(_:)``.
///
/// ## The races
///
/// | Event | Effect |
/// |---|---|
/// | typing in a note with a request in flight | the request is cancelled, every note in it is marked dirty, **the baseline does not advance** — the next session sends the whole delta again |
/// | typing in a note with a pending plan | the plan is withdrawn (``WithdrawalReason/supersededByEdit``); the baseline does not advance |
/// | a newer session covering a pending plan's notes | the plan is withdrawn (``WithdrawalReason/supersededBySession``) |
/// | Accept after the note changed | the applier's compare-and-swap misses → ``OrganizerEvent/stale(_:noteIDs:)``, nothing written, baseline unchanged |
/// | Dismiss | the baseline advances to the text the plan was made against — the user said no to *that* content, and should not be asked again |
/// | Apply succeeded | the baseline advances to the post-apply text of every note the session or the plan touched |
/// | provider unreachable | the session is queued (FR-6.4) and retried with backoff; nothing blocks |
///
/// ## Serialization
///
/// Requests touching the same note never overlap — a queued session waits for
/// any in-flight session it shares a note with. Sessions over disjoint notes run
/// concurrently, up to ``OrganizerSettings/maxConcurrentRequests`` (2).
public actor Organizer {
    // MARK: Dependencies

    private var provider: any AIProvider
    private let source: any OrganizeLibrarySource
    private let baselines: any BaselineStore
    private let applier: any PlanApplying
    private let candidateFinder: any CandidateFinder
    private let queueStore: any PendingSessionStore
    private let clock: any AIClock
    private let promptsDirectory: URL?
    private let observer: (@Sendable (OrganizerEvent) -> Void)?
    private let continuation: AsyncStream<OrganizerEvent>.Continuation
    private let log = Log.make("organize")

    /// Everything the organizer publishes, in order.
    public nonisolated let events: AsyncStream<OrganizerEvent>

    // MARK: State

    private var settings: OrganizerSettings
    private var ready: [Work] = []
    private var inFlight: [SessionID: Flight] = [:]
    private var proposals: [ProposalID: ProposedPlan] = [:]
    /// Notes whose new material was left unfiled by a cancelled request. Folded
    /// into the next session that ends.
    private var dirty: Set<NoteID> = []
    private var status: AIStatus = .connected

    private struct Work: Sendable {
        var session: Session
        var noteIDs: [NoteID]
        var attempts: Int
    }

    private struct Flight: Sendable {
        var noteIDs: Set<NoteID>
        var token: UUID
        var task: Task<Void, Never>
    }

    /// Thrown internally when a race makes the rest of the pipeline pointless.
    private struct Superseded: Error {}

    public init(
        provider: any AIProvider,
        source: any OrganizeLibrarySource,
        baselines: any BaselineStore,
        applier: any PlanApplying,
        candidateFinder: any CandidateFinder = TitleOverlapCandidateFinder(),
        queueStore: any PendingSessionStore = InMemoryPendingSessionStore(),
        settings: OrganizerSettings = OrganizerSettings(),
        clock: any AIClock = SystemClock(),
        promptsDirectory: URL? = nil,
        observer: (@Sendable (OrganizerEvent) -> Void)? = nil
    ) {
        self.provider = provider
        self.source = source
        self.baselines = baselines
        self.applier = applier
        self.candidateFinder = candidateFinder
        self.queueStore = queueStore
        self.settings = settings
        self.clock = clock
        self.promptsDirectory = promptsDirectory
        self.observer = observer
        var escaped: AsyncStream<OrganizerEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { escaped = $0 }
        continuation = escaped
    }

    deinit {
        for flight in inFlight.values { flight.task.cancel() }
        continuation.finish()
    }

    // MARK: - Inputs

    /// A session ended (``SessionEvent/ended(_:)``). Never blocks the caller.
    public func sessionEnded(_ session: Session) async {
        var noteIDs = session.noteIDs
        // Notes whose delta a cancelled request left behind ride along: their
        // baselines never advanced, so one pass covers both.
        for id in dirty where !noteIDs.contains(id) { noteIDs.append(id) }
        dirty.removeAll()

        guard !noteIDs.isEmpty else {
            emit(.skipped(session.id, reason: .noNotes))
            return
        }
        withdrawProposals(touching: Set(noteIDs), reason: .supersededBySession)
        ready.append(Work(session: session, noteIDs: noteIDs, attempts: 0))
        pump()
    }

    /// The user typed in a note (FR-3.2).
    ///
    /// Called on every edit, alongside ``SessionTracker/noteEdited(_:at:)``. It
    /// is cheap when nothing is happening and decisive when something is.
    public func noteEdited(_ noteID: NoteID) async {
        for (sessionID, flight) in inFlight where flight.noteIDs.contains(noteID) {
            flight.task.cancel()
            inFlight.removeValue(forKey: sessionID)
            dirty.formUnion(flight.noteIDs)
            log.debug("cancelled in-flight session \(sessionID.uuidString, privacy: .public): the user resumed typing")
            emit(.cancelled(sessionID, noteID: noteID))
        }
        withdrawProposals(touching: [noteID], reason: .supersededByEdit)
        pump()
    }

    /// FR-4.2's Accept, and its Edit — pass the modified plan to re-validate it
    /// before applying.
    public func accept(_ id: ProposalID, plan editedPlan: OrganizationPlan? = nil) async {
        guard let proposal = proposals.removeValue(forKey: id) else { return }
        var plan = proposal.plan
        if let editedPlan {
            // The user changed a target or dropped an action: the edited plan
            // gets the same treatment a fresh one does, against the library as
            // it stands now.
            let context = await proposalContext(proposal)
            var candidate = editedPlan
            // Notes the original plan already covered keep their *original*
            // precondition, so an edit cannot smuggle a note past the
            // compare-and-swap; notes the user newly referenced get today's.
            var preconditions = context.preconditions(for: candidate)
            for (id, hash) in proposal.plan.preconditions.contentHashes where preconditions[id] != nil {
                preconditions[id] = hash
            }
            candidate.preconditions = preconditions
            let validation = PlanValidator(context: context).validate(candidate)
            guard validation.isValid else {
                emit(.failed(proposal.sessionID, failure: .invalidPlan(validation)))
                return
            }
            plan = candidate
        }
        await applyAndAdvance(plan, proposal: proposal)
    }

    /// FR-4.2's Dismiss.
    ///
    /// The baseline advances: the user has seen this content and decided it
    /// needs no filing, and re-proposing it after every future keystroke would
    /// be exactly the nagging FR-6.4 forbids.
    public func dismiss(_ id: ProposalID) async {
        guard let proposal = proposals.removeValue(forKey: id) else { return }
        await advanceBaselines(to: proposal.snapshotTexts, sessionID: proposal.sessionID)
        emit(.withdrawn(id, reason: .dismissed))
        pump()
    }

    /// Settings changed (mode, model, excluded folders, budget).
    public func setSettings(_ settings: OrganizerSettings) {
        self.settings = settings
    }

    /// The backend changed under the organizer's feet (FR-6.5, FR-8.1).
    ///
    /// Settings → AI switching Claude ↔ Ollama, or the base URL or the local
    /// model tag moving, must not need a relaunch. Requests already in flight
    /// keep the provider they started with — swapping mid-request would mean a
    /// half-finished exchange on one wire format and a decode on another — and
    /// the next request uses the new one. Pair it with ``setSettings(_:)`` so
    /// the model and the timeout move with it (ADR-069).
    public func setProvider(_ provider: any AIProvider) {
        self.provider = provider
        log.info("organizer provider is now \(provider.identifier, privacy: .public)")
    }

    /// Which provider the next request will use. Visible for the smoke phase.
    public var providerIdentifier: String { provider.identifier }

    /// The AI status pill moved. Reaching `connected` drains the offline queue
    /// (FR-6.4).
    public func aiStatusChanged(_ status: AIStatus) async {
        self.status = status
        if status.isUsable(at: clock.now()) { await retryQueuedSessions() }
    }

    /// Re-runs queued sessions whose backoff has elapsed.
    public func retryQueuedSessions(at now: Date? = nil) async {
        let instant = now ?? clock.now()
        let queued = (try? await queueStore.all()) ?? []
        for pending in queued {
            guard (pending.nextAttemptAt ?? instant) <= instant else { continue }
            guard inFlight[pending.id] == nil, !ready.contains(where: { $0.session.id == pending.id }) else { continue }
            try? await queueStore.remove(pending.id)
            emit(.retrying(pending.id, attempt: pending.attempts + 1))
            ready.append(Work(session: pending.session, noteIDs: pending.noteIDs, attempts: pending.attempts))
        }
        pump()
    }

    // MARK: - Observable state

    public var pendingProposals: [ProposedPlan] {
        proposals.values.sorted { $0.proposedAt < $1.proposedAt }
    }

    public var inFlightSessionIDs: Set<SessionID> { Set(inFlight.keys) }
    public var readySessionIDs: [SessionID] { ready.map(\.session.id) }
    public var dirtyNoteIDs: Set<NoteID> { dirty }
    public var currentSettings: OrganizerSettings { settings }

    /// Waits for every in-flight request to finish. Tests only — the app never
    /// needs to block on the organizer.
    public func drain() async {
        while true {
            let tasks = inFlight.values.map(\.task)
            guard !tasks.isEmpty else { return }
            for task in tasks { _ = await task.value }
        }
    }

    /// Cancels everything in flight. For teardown.
    public func stop() {
        for flight in inFlight.values { flight.task.cancel() }
        inFlight.removeAll()
        ready.removeAll()
    }

    // MARK: - Scheduling

    /// Starts whatever can run: FIFO, never two requests over the same note, at
    /// most ``OrganizerSettings/maxConcurrentRequests`` at a time.
    private func pump() {
        while inFlight.count < settings.maxConcurrentRequests {
            let busy = inFlight.values.reduce(into: Set<NoteID>()) { $0.formUnion($1.noteIDs) }
            guard let index = ready.firstIndex(where: { busy.isDisjoint(with: Set($0.noteIDs)) }) else { return }
            let work = ready.remove(at: index)
            start(work)
        }
    }

    private func start(_ work: Work) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.execute(work, token: token)
        }
        inFlight[work.session.id] = Flight(noteIDs: Set(work.noteIDs), token: token, task: task)
    }

    /// Removes a flight, but only if it is still *this* flight — a cancelled
    /// request must not evict the one that replaced it.
    private func finish(_ sessionID: SessionID, token: UUID) {
        if inFlight[sessionID]?.token == token { inFlight.removeValue(forKey: sessionID) }
        pump()
    }

    // MARK: - The pipeline

    private func execute(_ work: Work, token: UUID) async {
        do {
            try await run(work, token: token)
        } catch is Superseded {
            // The user got there first; noteEdited() has already published.
        } catch is CancellationError {
            // Same.
        } catch let error as AIError {
            await handleProviderError(error, work: work, token: token)
        } catch {
            emit(.failed(work.session.id, failure: .decoding("\(error)")))
        }
        finish(work.session.id, token: token)
    }

    private func run(_ work: Work, token: UUID) async throws {
        let session = work.session
        let snapshot = try await source.snapshot()
        try checkAlive(work, token: token)

        // 1. Deltas, against the organized baselines.
        let notes = Dictionary(snapshot.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let filter = ExclusionFilter(excludedFolders: settings.excludedFolders)
        var deltas: [SessionDelta] = []
        var snapshotTexts: [NoteID: String] = [:]
        for id in work.noteIDs {
            guard let note = notes[id] else { continue }
            // FR-4.5: a note the user has since moved into an excluded folder
            // must not be sent, even though it was typed in.
            guard !filter.isExcluded(note) else { continue }
            let text = (try await source.body(of: id)) ?? ""
            let baseline = try await baselines.baseline(for: id) ?? .creation(id, at: session.endedAt)
            snapshotTexts[id] = text
            deltas.append(SessionDelta(
                noteID: id,
                title: note.title,
                relativePath: note.relativePath,
                baselineText: baseline.text,
                currentText: text
            ))
        }
        try checkAlive(work, token: token)

        guard !deltas.isEmpty else {
            emit(.skipped(session.id, reason: .noNotes))
            return
        }
        let effective = deltas.filter(\.hasEffectiveChange)
        guard !effective.isEmpty else {
            // Deletions and reflows only. Advance so we do not look again.
            await advanceBaselines(to: snapshotTexts, sessionID: session.id)
            emit(.skipped(session.id, reason: .noEffectiveDelta))
            return
        }

        // 2. Context and request (M2-06).
        let built = try await settings.contextBuilder.build(
            sessionID: session.id,
            endedAt: session.endedAt,
            reason: session.reason,
            deltas: effective,
            snapshot: snapshot,
            mode: settings.mode,
            source: source,
            candidateFinder: candidateFinder
        )
        let request = try OrganizeRequestBuilder.request(
            for: built, settings: settings, promptsDirectory: promptsDirectory
        )
        try checkAlive(work, token: token)
        log.info("""
        organizing session \(session.id.uuidString, privacy: .public): \
        \(effective.count, privacy: .public) notes, \
        ~\(built.estimatedPromptTokens, privacy: .public) prompt tokens
        """)

        // 3. The provider.
        let response = try await provider.complete(request)
        try checkAlive(work, token: token)

        // 4. Decode and validate.
        let decoding: PlanDecoding
        do {
            decoding = try PlanDecoder.decode(
                response: response,
                promptVersion: settings.promptVersion,
                context: built.context
            )
        } catch {
            emit(.failed(session.id, failure: .decoding("\(error)")))
            return
        }

        let repaired = Self.repair(
            plan: decoding.plan, unknownActions: decoding.unknownActions, context: built.context
        )
        guard case let .keep(plan, validation, dropped) = repaired else {
            guard case let .discard(validation) = repaired else { return }
            emit(.failed(session.id, failure: .invalidPlan(validation)))
            return
        }

        guard !plan.isEmpty else {
            // FR-4.6: "nothing needed filing" is a real answer, and the
            // baseline advances so the same text is not re-sent every session.
            await advanceBaselines(to: built.snapshotTexts, sessionID: session.id)
            emit(.skipped(session.id, reason: .nothingToDo))
            return
        }

        // 5. Ask or auto (FR-4.2).
        let touched = planNoteIDs(plan, context: built.context, session: effective.map(\.noteID))
        switch settings.mode {
        case .ask:
            let proposal = ProposedPlan(
                sessionID: session.id,
                plan: plan,
                validation: validation,
                droppedActions: dropped,
                proposedAt: clock.now(),
                noteIDs: touched,
                snapshotTexts: built.snapshotTexts,
                sessionText: built.sessionText
            )
            proposals[proposal.id] = proposal
            emit(.proposed(proposal))

        case .auto:
            let proposal = ProposedPlan(
                sessionID: session.id,
                plan: plan,
                validation: validation,
                droppedActions: dropped,
                proposedAt: clock.now(),
                noteIDs: touched,
                snapshotTexts: built.snapshotTexts,
                sessionText: built.sessionText
            )
            await applyAndAdvance(plan, proposal: proposal)
        }
    }

    /// `Superseded` if the user's typing already killed this flight.
    private func checkAlive(_ work: Work, token: UUID) throws {
        if Task.isCancelled { throw Superseded() }
        guard inFlight[work.session.id]?.token == token else { throw Superseded() }
    }

    // MARK: - Apply

    private func applyAndAdvance(_ plan: OrganizationPlan, proposal: ProposedPlan) async {
        do {
            // FR-4.4: the raw session text rides along, so the Activity row
            // the apply opens can hand it back for the next 30 days (M4-08).
            var applied = try await applier.apply(plan, sessionText: proposal.sessionText)
            applied.sessionID = applied.sessionID ?? proposal.sessionID
            // The baseline advances to what is on disk *after* the apply, so
            // the text the plan itself wrote is never mistaken for new material
            // in the next session.
            await refreshBaselines(
                for: proposal.noteIDs + applied.createdNotes,
                removed: applied.removedNoteIDs,
                sessionID: proposal.sessionID,
                fallback: proposal.snapshotTexts
            )
            log.info("applied plan for session \(proposal.sessionID.uuidString, privacy: .public)")
            emit(.applied(applied))
        } catch let error as ApplyError {
            switch error {
            case let .preconditionFailed(noteIDs):
                // FR-3.2: the note moved under the plan. Nothing was written and
                // the baseline stays put, so the next session covers everything.
                log.debug("plan went stale for session \(proposal.sessionID.uuidString, privacy: .public)")
                emit(.stale(proposal.id, noteIDs: noteIDs))
            default:
                emit(.failed(proposal.sessionID, failure: .apply(error)))
            }
        } catch {
            emit(.failed(proposal.sessionID, failure: .apply(.io("\(error)"))))
        }
        pump()
    }

    // MARK: - Baselines

    private func advanceBaselines(to texts: [NoteID: String], sessionID: SessionID) async {
        let now = clock.now()
        for (id, text) in texts {
            try? await baselines.advance(id, to: text, at: now, sessionID: sessionID)
        }
    }

    /// Re-reads the notes a plan touched and advances their baselines.
    private func refreshBaselines(
        for noteIDs: [NoteID],
        removed: [NoteID],
        sessionID: SessionID,
        fallback: [NoteID: String]
    ) async {
        let now = clock.now()
        let removedSet = Set(removed)
        for id in Set(noteIDs).union(fallback.keys) {
            if removedSet.contains(id) {
                try? await baselines.removeBaseline(for: id)
                continue
            }
            let text = (try? await source.body(of: id)) ?? fallback[id]
            guard let text else {
                try? await baselines.removeBaseline(for: id)
                continue
            }
            try? await baselines.advance(id, to: text, at: now, sessionID: sessionID)
        }
    }

    // MARK: - Failure and the queue (FR-6.4)

    private func handleProviderError(_ error: AIError, work: Work, token: UUID) async {
        if case .cancelled = error { return }
        status = AIHealth.status(for: error, at: clock.now())

        guard Self.shouldQueue(error) else {
            log.error("organize failed: \(error.description, privacy: .public)")
            emit(.failed(work.session.id, failure: .provider(error)))
            return
        }

        let attempts = work.attempts + 1
        guard attempts < settings.maxQueueAttempts else {
            try? await queueStore.remove(work.session.id)
            emit(.failed(work.session.id, failure: .abandoned("\(attempts) attempts")))
            return
        }
        let delay = settings.retryPolicy.delay(
            afterAttempt: attempts, retryAfter: error.retryAfter, randomFraction: clock.randomFraction()
        )
        let retryAt = clock.now().addingTimeInterval(delay)
        try? await queueStore.enqueue(PendingSession(
            session: work.session,
            attempts: attempts,
            lastError: error.description,
            nextAttemptAt: retryAt
        ))
        // The notes stay unfiled but nothing is lost: the baseline never moved.
        log.info("queued session \(work.session.id.uuidString, privacy: .public) (attempt \(attempts, privacy: .public))")
        emit(.queued(work.session.id, attempt: attempts, retryAt: retryAt))
    }

    /// FR-6.4 / plan M2-09: an outage, a rate limit or a missing key is a "come
    /// back later", not a failure. A 400 or a bad model id is a real failure —
    /// retrying it would burn the user's quota forever.
    static func shouldQueue(_ error: AIError) -> Bool {
        switch error {
        case .rateLimited, .serverOverloaded, .network, .timedOut, .notConfigured, .invalidKey:
            return true
        case .badRequest, .modelNotFound, .malformedResponse, .cancelled, .missingRecording:
            return false
        }
    }

    // MARK: - Proposals

    private func withdrawProposals(touching noteIDs: Set<NoteID>, reason: WithdrawalReason) {
        for (id, proposal) in proposals where !noteIDs.isDisjoint(with: Set(proposal.noteIDs)) {
            proposals.removeValue(forKey: id)
            log.debug("withdrew proposal \(id.description, privacy: .public): \(reason.rawValue, privacy: .public)")
            emit(.withdrawn(id, reason: reason))
        }
    }

    /// The validation context for an edited plan.
    ///
    /// Rebuilt from a *fresh* snapshot rather than retained with the proposal:
    /// the user may have moved a folder since the card appeared, and an Edit
    /// must be judged against the library it will actually be applied to. The
    /// bodies come from the proposal, because they are what `moveSegment`'s
    /// verbatim check was made against.
    private func proposalContext(_ proposal: ProposedPlan) async -> OrganizeContext {
        guard let snapshot = try? await source.snapshot() else {
            return OrganizeContext(excludedFolders: settings.excludedFolders, bodies: proposal.snapshotTexts)
        }
        return OrganizeContext(
            snapshot: snapshot,
            excludedFolders: settings.excludedFolders,
            bodies: proposal.snapshotTexts
        )
    }

    private func planNoteIDs(_ plan: OrganizationPlan, context: OrganizeContext, session: [NoteID]) -> [NoteID] {
        var out = session
        for ref in plan.referencedNotes {
            guard let note = context.note(for: ref), !out.contains(note.id) else { continue }
            out.append(note.id)
        }
        return out
    }

    private func emit(_ event: OrganizerEvent) {
        observer?(event)
        continuation.yield(event)
    }

    // MARK: - Plan repair

    enum Repair {
        /// Usable, possibly with actions removed.
        case keep(OrganizationPlan, PlanValidation, dropped: [PlanIssue])
        /// Nothing usable is left.
        case discard(PlanValidation)
    }

    /// Decides what to do with a plan the validator objected to (risk #6).
    ///
    /// **The rule.** An action the validator rejected is dropped, not fatal —
    /// one hallucinated target must not cost the user the four good actions.
    /// But the card shows ``OrganizationPlan/summary``, and FR-4.2 requires it
    /// to state *exactly* what happens. So after dropping, the summary is
    /// checked against what is left: if it names a note or folder that only the
    /// dropped actions touched, the summary is now a lie about the plan, and the
    /// **whole plan is discarded** rather than shown with a wrong description.
    ///
    /// Plan-level errors (too many actions, a contradiction the validator could
    /// not pin to one index) always discard: there is no action to remove that
    /// would fix them.
    static func repair(
        plan: OrganizationPlan,
        unknownActions: [UnknownPlanAction],
        context: OrganizeContext
    ) -> Repair {
        let validator = PlanValidator(context: context)
        let validation = validator.validate(plan, unknownActions: unknownActions)
        if validation.isValid { return .keep(plan, validation, dropped: []) }

        let badIndices = Set(validation.errors.compactMap(\.actionIndex))
        guard !badIndices.isEmpty, badIndices.count < plan.actions.count else { return .discard(validation) }
        guard validation.errors.allSatisfy({ $0.actionIndex != nil }) else { return .discard(validation) }

        let kept = plan.actions.enumerated().filter { !badIndices.contains($0.offset) }.map(\.element)
        let dropped = plan.actions.enumerated().filter { badIndices.contains($0.offset) }.map(\.element)

        var reduced = plan
        reduced.actions = kept
        reduced.preconditions = context.preconditions(for: reduced)
        let revalidation = validator.validate(reduced)
        guard revalidation.isValid else { return .discard(validation) }
        guard summaryStillMatches(plan.summary, kept: kept, dropped: dropped, context: context) else {
            return .discard(validation)
        }
        let droppedIssues = validation.errors.filter { $0.actionIndex.map(badIndices.contains) ?? false }
        return .keep(reduced, revalidation, dropped: droppedIssues)
    }

    /// `false` when the summary names something only a dropped action was going
    /// to touch.
    static func summaryStillMatches(
        _ summary: String,
        kept: [PlanAction],
        dropped: [PlanAction],
        context: OrganizeContext
    ) -> Bool {
        let haystack = summary.lowercased()
        let keptNames = Set(kept.flatMap { names(of: $0, in: context) })
        for name in Set(dropped.flatMap({ names(of: $0, in: context) })) where !keptNames.contains(name) {
            if haystack.contains(name) { return false }
        }
        return true
    }

    /// Lowercased names an action would put in a summary: titles, folders, the
    /// new title of a retitle.
    static func names(of action: PlanAction, in context: OrganizeContext) -> [String] {
        var out: [String] = []
        func add(_ value: String?) {
            guard let value else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.count >= 3 { out.append(trimmed) }
        }
        func addFolder(_ path: String) {
            add(path)
            add(PathRules.name(of: path))
        }
        for ref in action.referencedNotes { add(context.note(for: ref)?.title) }
        for folder in action.targetFolderPaths { addFolder(folder) }
        for created in action.createdNotes { add(created.title) }
        if case let .retitleNote(retitle) = action { add(retitle.newTitle) }
        return out
    }
}
