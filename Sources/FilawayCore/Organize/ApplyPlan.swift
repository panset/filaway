import Foundation

/// Applies a validated ``OrganizationPlan`` to the library — all of it, or none
/// of it (M2-07; FR-4.2, FR-4.4, NFR-3).
///
/// The shape of one apply:
///
/// 1. **Re-validate** against a fresh scan. The plan was made against a snapshot
///    that is by now seconds or minutes old.
/// 2. **Compare and swap.** Every note in ``OrganizationPlan/preconditions``
///    must still hash to what the plan was computed against, and every
///    `moveSegment` segment must still be in its source verbatim. A miss throws
///    ``ApplyError/preconditionFailed(_:)`` and touches nothing (FR-3.2).
/// 3. **Journal.** A row goes into the Activity log with status
///    ``ActivityEventStatus/inProgress`` and the *before* image — the full raw
///    text — of every note the plan will change, **before** the first write.
/// 4. **Execute** in a fixed order: folders, new notes, appends, segment
///    removals, retitles, moves, tags. Every file operation goes through
///    ``NoteStore``, so every one of them is atomic on its own.
/// 5. **Commit.** After-images are written, then the status flips to
///    ``ActivityEventStatus/applied`` and the event becomes undoable.
///
/// Anything that throws in step 4 rolls the before-images back before
/// rethrowing. Anything that *kills the process* in step 4 leaves the journal
/// row behind, and ``recoverIncompleteEvents()`` finishes the job on the next
/// launch — that is NFR-3, "an AI failure must never corrupt or lose notes".
public actor PlanApplier: PlanApplying {
    private let store: NoteStore
    private let activity: ActivityLog
    private let excludedFolders: [String]
    private let clock: @Sendable () -> Date
    private let failureHook: ApplyFailureHook?
    private let fileManager = FileManager.default
    private let log = Log.make("organize")

    public init(
        store: NoteStore,
        activity: ActivityLog,
        excludedFolders: [String] = [],
        clock: @escaping @Sendable () -> Date = { Date() },
        failureHook: ApplyFailureHook? = nil
    ) {
        self.store = store
        self.activity = activity
        self.excludedFolders = excludedFolders
        self.clock = clock
        self.failureHook = failureHook
    }

    // MARK: - Apply

    public func apply(_ plan: OrganizationPlan) async throws -> AppliedPlan {
        try await apply(plan, sessionText: nil)
    }

    /// Applies a plan, keeping the session's raw text with the event so FR-4.4's
    /// "original raw session text remains recoverable" has something to recover.
    public func apply(_ plan: OrganizationPlan, sessionText: String?) async throws -> AppliedPlan {
        let prepared = try await prepare(plan)

        let eventID = try await activity.begin(
            kind: .applied,
            status: .inProgress,
            summary: plan.summary,
            plan: plan,
            sessionText: sessionText,
            images: prepared.beforeImages,
            isUndoable: false,
            at: clock()
        )

        var state = ApplyState(prepared: prepared)
        do {
            try await execute(plan, state: &state, eventID: eventID)
        } catch let error as ApplyError {
            if case .simulatedCrash = error { throw error }   // the process "died": no unwinding
            _ = await rollBack(eventID: eventID, images: prepared.beforeImages, progress: state.progress)
            throw error
        } catch {
            _ = await rollBack(eventID: eventID, images: prepared.beforeImages, progress: state.progress)
            throw error
        }

        try failureHook?.check(.beforeAfterImages)
        let images = try afterImages(state: state)
        try await activity.setImages(images, for: eventID)

        // Everything below this line is bookkeeping: the files are already in
        // their final state, which is why a crash here rolls *forward*.
        try failureHook?.check(.beforeCommit)
        let summary = Self.summarize(state.outcomes)
        // A plan that changed no note has nothing to undo, and must not become
        // the target of the card's Undo button.
        try await activity.setStatus(.applied, for: eventID, isUndoable: !images.isEmpty, summary: summary)

        log.info("applied plan: \(state.outcomes.count, privacy: .public) action(s)")
        return AppliedPlan(
            eventID: eventID,
            summary: summary,
            outcomes: state.outcomes,
            createdNotes: state.createdNotes,
            createdFolders: state.createdFolders,
            trashedNotes: state.trashed.map { TrashedNote(noteID: $0.key, relativePath: $0.value.path, trashURL: $0.value.url) }
                .sorted { $0.relativePath < $1.relativePath },
            changedPaths: state.pathByID.filter { state.trashed[$0.key] == nil },
            appliedAt: clock()
        )
    }

    // MARK: - Preparation

    private struct Prepared {
        /// Existing notes the plan touches, resolved from its references.
        var resolved: [NoteID: NoteSummary]
        /// `NoteRef` → note id, so execution never re-resolves.
        var references: [NoteRef: NoteID]
        /// The full raw text of every note the plan will change.
        var beforeImages: [NoteImage]
    }

    private func prepare(_ plan: OrganizationPlan) async throws -> Prepared {
        let snapshot = try await store.scan()
        let base = OrganizeContext(snapshot: snapshot, excludedFolders: excludedFolders)

        var resolved: [NoteID: NoteSummary] = [:]
        var references: [NoteRef: NoteID] = [:]
        var rawTexts: [NoteID: String] = [:]
        var bodies: [NoteID: String] = [:]
        for ref in plan.referencedNotes {
            guard let note = base.note(for: ref) else { continue }
            references[ref] = note.id
            resolved[note.id] = note
            if rawTexts[note.id] == nil {
                let raw = try rawText(at: note.relativePath)
                rawTexts[note.id] = raw
                bodies[note.id] = MarkdownDocument.parse(raw).body
            }
        }

        // (2) Compare-and-swap first: when the user has typed since the plan was
        // made, "your note moved on" is the honest answer, and a more specific
        // one than whatever else re-validation would find.
        var stale: [NoteID] = []
        for (id, hash) in plan.preconditions.contentHashes {
            guard let note = snapshot.notes.first(where: { $0.id == id }), note.contentHash == hash else {
                stale.append(id)
                continue
            }
        }
        if !stale.isEmpty {
            throw ApplyError.preconditionFailed(stale.sorted { $0.uuidString < $1.uuidString })
        }

        // A segment that is no longer in its source verbatim is the same class
        // of miss: the plan was made against text that has changed (ADR-016).
        for action in plan.actions {
            guard case let .moveSegment(move) = action else { continue }
            guard let id = references[move.source], let body = bodies[id] else { continue }
            guard body.contains(move.segment), move.expectedSegmentHash == Hashing.sha256Hex(move.segment) else {
                throw ApplyError.preconditionFailed([id])
            }
        }

        // (1) Re-validate against the library as it is *now*.
        let validation = PlanValidator(
            context: OrganizeContext(snapshot: snapshot, excludedFolders: excludedFolders, bodies: bodies)
        ).validate(plan)
        guard validation.isValid else { throw ApplyError.invalidPlan(validation.errors) }

        // (3) Before-images: the full raw text of every note that will change.
        let beforeImages = resolved.values
            .sorted { $0.relativePath < $1.relativePath }
            .map { note in
                NoteImage(
                    noteID: note.id,
                    title: note.title,
                    before: NoteImageSide(relativePath: note.relativePath, text: rawTexts[note.id] ?? ""),
                    after: nil,
                    created: false
                )
            }

        return Prepared(resolved: resolved, references: references, beforeImages: beforeImages)
    }

    // MARK: - Execution

    private struct ApplyState {
        var pathByID: [NoteID: String] = [:]
        var beforeByID: [NoteID: NoteImageSide] = [:]
        var references: [NoteRef: NoteID] = [:]
        var created: Set<NoteID> = []
        var createdNotes: [NoteID] = []
        var createdFolders: [String] = []
        var trashed: [NoteID: (path: String, url: String?)] = [:]
        /// New notes made to receive a `moveSegment`, keyed by action index.
        var segmentDestinations: [Int: NoteID] = [:]
        /// Where each `moveSegment`'s text landed, keyed by action index.
        var segmentDestinationPaths: [Int: String] = [:]
        /// `moveSegment` actions whose destination could not be written. Their
        /// sources keep every byte: the removal is skipped too.
        var segmentBlocked: Set<Int> = []
        var progress: [ApplyProgressEntry] = []
        var outcomes: [ActionOutcome] = []

        init(prepared: Prepared) {
            references = prepared.references
            for (id, note) in prepared.resolved {
                pathByID[id] = note.relativePath
            }
            for image in prepared.beforeImages {
                beforeByID[image.noteID] = image.before
            }
        }

        func id(for ref: NoteRef) -> NoteID? { references[ref] }
        func path(of id: NoteID) -> String? { pathByID[id] }
    }

    private func execute(_ plan: OrganizationPlan, state: inout ApplyState, eventID: ActivityEventID) async throws {
        // Deterministic order: containers before contents, additions before
        // removals, then the metadata-only actions. A `moveSegment` therefore
        // never removes text from its source until the copy has landed.
        for (index, action) in plan.actions.enumerated() {
            guard case let .createFolder(create) = action else { continue }
            let path = try PathRules.sanitizeFolderPath(create.path)
            try failureHook?.check(.createFolder(path))
            let existed = try await ensureFolder(path, state: &state, eventID: eventID)
            state.outcomes.append(ActionOutcome(
                index: index,
                kind: .createFolder,
                relativePath: path,
                detail: existed ? "Folder \(path) already existed" : "Created folder \(path)"
            ))
        }

        for (index, action) in plan.actions.enumerated() {
            switch action {
            case let .createNote(create):
                try await createNote(create, index: index, state: &state, eventID: eventID)
            case let .moveSegment(move):
                guard case let .newNote(title, folderPath, tags) = move.destination else { continue }
                let note = try await createNote(
                    CreateNoteAction(title: title, folderPath: folderPath, content: "", tags: tags),
                    index: index,
                    state: &state,
                    eventID: eventID,
                    recordOutcome: false
                )
                state.segmentDestinations[index] = note
            default:
                continue
            }
        }

        for (index, action) in plan.actions.enumerated() {
            switch action {
            case let .appendToNote(append):
                try await self.append(
                    append.content,
                    toNoteAt: index,
                    ref: append.target,
                    heading: append.heading,
                    divider: append.divider,
                    kind: .appendToNote,
                    state: &state,
                    eventID: eventID
                )
            case let .moveSegment(move):
                let destinationID: NoteID?
                switch move.destination {
                case let .existingNote(ref): destinationID = state.id(for: ref)
                case .newNote: destinationID = state.segmentDestinations[index]
                }
                guard let destinationID, let path = state.path(of: destinationID), state.trashed[destinationID] == nil else {
                    state.segmentBlocked.insert(index)
                    state.outcomes.append(ActionOutcome(
                        index: index,
                        kind: .moveSegment,
                        status: .skipped,
                        detail: "The destination note is no longer available"
                    ))
                    continue
                }
                try failureHook?.check(.appendToNote(index: index, path: path))
                try await appendText(move.segment, to: destinationID, heading: move.heading, divider: move.divider, state: &state, eventID: eventID)
                state.segmentDestinationPaths[index] = path
            default:
                continue
            }
        }

        for (index, action) in plan.actions.enumerated() {
            guard case let .moveSegment(move) = action, !state.segmentBlocked.contains(index) else { continue }
            try await removeSegment(move, index: index, state: &state, eventID: eventID)
        }

        for (index, action) in plan.actions.enumerated() {
            guard case let .retitleNote(retitle) = action else { continue }
            guard let id = state.id(for: retitle.note), let path = state.path(of: id), state.trashed[id] == nil else {
                state.outcomes.append(ActionOutcome(index: index, kind: .retitleNote, status: .skipped, detail: "The note is no longer available"))
                continue
            }
            try failureHook?.check(.retitleNote(index: index, path: path))
            let summary = try await store.rename(path, to: retitle.newTitle)
            relocated(id, to: summary.relativePath, state: &state)
            try await record(.init(kind: .relocated, noteID: id, path: summary.relativePath, previousPath: path), state: &state, eventID: eventID)
            state.outcomes.append(ActionOutcome(
                index: index,
                kind: .retitleNote,
                noteID: id,
                relativePath: summary.relativePath,
                previousPath: path,
                detail: "Renamed \(PathRules.title(of: path)) to \(summary.title)"
            ))
        }

        for (index, action) in plan.actions.enumerated() {
            guard case let .moveNote(move) = action else { continue }
            guard let id = state.id(for: move.note), let path = state.path(of: id), state.trashed[id] == nil else {
                state.outcomes.append(ActionOutcome(index: index, kind: .moveNote, status: .skipped, detail: "The note is no longer available"))
                continue
            }
            let folder = try PathRules.sanitizeFolderPath(move.toFolderPath)
            _ = try await ensureFolder(folder, state: &state, eventID: eventID)
            try failureHook?.check(.moveNote(index: index, path: path))
            let summary = try await store.move(path, toFolder: folder)
            relocated(id, to: summary.relativePath, state: &state)
            try await record(.init(kind: .relocated, noteID: id, path: summary.relativePath, previousPath: path), state: &state, eventID: eventID)
            state.outcomes.append(ActionOutcome(
                index: index,
                kind: .moveNote,
                noteID: id,
                relativePath: summary.relativePath,
                previousPath: path,
                detail: "Moved \(summary.title) to \(folder.isEmpty ? "the Library root" : folder)"
            ))
        }

        for (index, action) in plan.actions.enumerated() {
            guard case let .tagNote(tag) = action else { continue }
            guard let id = state.id(for: tag.note), let path = state.path(of: id), state.trashed[id] == nil else {
                state.outcomes.append(ActionOutcome(index: index, kind: .tagNote, status: .skipped, detail: "The note is no longer available"))
                continue
            }
            try failureHook?.check(.tagNote(index: index, path: path))
            let note = try await store.read(path)
            let merged = ApplyText.mergedTags(note.tags, adding: tag.tags)
            _ = try await store.save(body: note.body, to: path, tags: merged)
            try await record(.init(kind: .wrote, noteID: id, path: path), state: &state, eventID: eventID)
            state.outcomes.append(ActionOutcome(
                index: index,
                kind: .tagNote,
                noteID: id,
                relativePath: path,
                detail: "Tagged \(PathRules.title(of: path))"
            ))
        }
    }

    @discardableResult
    private func createNote(
        _ create: CreateNoteAction,
        index: Int,
        state: inout ApplyState,
        eventID: ActivityEventID,
        recordOutcome: Bool = true
    ) async throws -> NoteID {
        let folder = try PathRules.sanitizeFolderPath(create.folderPath)
        _ = try await ensureFolder(folder, state: &state, eventID: eventID)
        let intended = PathRules.relativePath(folder: folder, title: PathRules.sanitizeTitle(create.title))
        try failureHook?.check(.createNote(index: index, path: intended))

        var note = try await store.createNote(inFolder: folder, title: create.title, body: create.content)
        if !create.tags.isEmpty {
            let merged = ApplyText.mergedTags(note.tags, adding: create.tags)
            _ = try await store.save(body: note.body, to: note.relativePath, tags: merged)
            note = try await store.read(note.relativePath)
        }

        state.pathByID[note.id] = note.relativePath
        state.created.insert(note.id)
        state.createdNotes.append(note.id)
        try await record(.init(kind: .createdNote, noteID: note.id, path: note.relativePath), state: &state, eventID: eventID)
        if recordOutcome {
            state.outcomes.append(ActionOutcome(
                index: index,
                kind: .createNote,
                noteID: note.id,
                relativePath: note.relativePath,
                detail: "Created \(note.relativePath)"
            ))
        }
        return note.id
    }

    private func append(
        _ content: String,
        toNoteAt index: Int,
        ref: NoteRef,
        heading: String?,
        divider: Bool?,
        kind: PlanAction.Kind,
        state: inout ApplyState,
        eventID: ActivityEventID
    ) async throws {
        guard let id = state.id(for: ref), let path = state.path(of: id), state.trashed[id] == nil else {
            state.outcomes.append(ActionOutcome(index: index, kind: kind, status: .skipped, detail: "The target note is no longer available"))
            return
        }
        try failureHook?.check(.appendToNote(index: index, path: path))
        try await appendText(content, to: id, heading: heading, divider: divider, state: &state, eventID: eventID)
        state.outcomes.append(ActionOutcome(
            index: index,
            kind: kind,
            noteID: id,
            relativePath: path,
            detail: "Appended to \(path)"
        ))
    }

    private func appendText(
        _ content: String,
        to id: NoteID,
        heading: String?,
        divider: Bool?,
        state: inout ApplyState,
        eventID: ActivityEventID
    ) async throws {
        guard let path = state.path(of: id) else { throw ApplyError.noteMissing(id.uuidString) }
        let note = try await store.read(path)
        let body = ApplyText.appending(content, to: note.body, heading: heading, divider: divider)
        _ = try await store.save(body: body, to: path)
        try await record(.init(kind: .wrote, noteID: id, path: path), state: &state, eventID: eventID)
    }

    private func removeSegment(
        _ move: MoveSegmentAction,
        index: Int,
        state: inout ApplyState,
        eventID: ActivityEventID
    ) async throws {
        guard let id = state.id(for: move.source), let path = state.path(of: id), state.trashed[id] == nil else {
            state.outcomes.append(ActionOutcome(index: index, kind: .moveSegment, status: .skipped, detail: "The source note is no longer available"))
            return
        }
        let note = try await store.read(path)
        guard let remaining = ApplyText.removingSegment(move.segment, from: note.body) else {
            // Verified in `prepare`; if it is gone now, the file changed under
            // us mid-apply. Unwind rather than guess.
            throw ApplyError.preconditionFailed([id])
        }

        let destination = state.segmentDestinationPaths[index]
        if ApplyText.isEffectivelyEmpty(remaining) {
            // Plan §1 amendment 1: the emptied source goes to the Trash with its
            // text intact — never a hard delete, and never a rewrite first.
            try failureHook?.check(.trashEmptySource(index: index, path: path))
            let url = try await store.deleteNote(path)
            state.trashed[id] = (path, url.path)
            try await record(.init(kind: .trashed, noteID: id, path: path, trashURL: url.path), state: &state, eventID: eventID)
            state.outcomes.append(ActionOutcome(
                index: index,
                kind: .moveSegment,
                noteID: id,
                relativePath: destination,
                previousPath: path,
                detail: "Moved a section out of \(PathRules.title(of: path)); the empty note is in the Trash"
            ))
            return
        }

        try failureHook?.check(.removeSegment(index: index, path: path))
        _ = try await store.save(body: remaining, to: path)
        try await record(.init(kind: .wrote, noteID: id, path: path), state: &state, eventID: eventID)
        state.outcomes.append(ActionOutcome(
            index: index,
            kind: .moveSegment,
            noteID: id,
            relativePath: destination,
            previousPath: path,
            detail: "Moved a section from \(PathRules.title(of: path))"
        ))
    }

    /// Creates a folder if it is missing, recording it so a rollback or an undo
    /// can take it away again.
    @discardableResult
    private func ensureFolder(_ path: String, state: inout ApplyState, eventID: ActivityEventID) async throws -> Bool {
        guard !path.isEmpty else { return true }
        var existed = true
        var components: [String] = []
        for component in PathRules.components(path) {
            components.append(component)
            let partial = components.joined(separator: "/")
            if !folderExists(partial) {
                existed = false
                state.createdFolders.append(partial)
                try await record(.init(kind: .createdFolder, path: partial), state: &state, eventID: eventID)
            }
        }
        try await store.createFolder(path)
        return existed
    }

    private func relocated(_ id: NoteID, to newPath: String, state: inout ApplyState) {
        state.pathByID[id] = newPath
    }

    /// Appends to the journal's progress list and makes it durable before the
    /// *next* operation runs.
    private func record(_ entry: ApplyProgressEntry, state: inout ApplyState, eventID: ActivityEventID) async throws {
        state.progress.append(entry)
        try await activity.setProgress(Self.encode(state.progress), for: eventID)
    }

    // MARK: - Images

    private func afterImages(state: ApplyState) throws -> [NoteImage] {
        var images: [NoteImage] = []
        var ids = Set(state.beforeByID.keys)
        ids.formUnion(state.created)
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let before = state.beforeByID[id]
            if let trashed = state.trashed[id] {
                images.append(NoteImage(
                    noteID: id,
                    title: PathRules.title(of: trashed.path),
                    before: before,
                    after: nil,
                    trashedURL: trashed.url,
                    created: state.created.contains(id)
                ))
                continue
            }
            guard let path = state.path(of: id) else { continue }
            let text = try rawText(at: path)
            images.append(NoteImage(
                noteID: id,
                title: PathRules.title(of: path),
                before: before,
                after: NoteImageSide(relativePath: path, text: text),
                created: state.created.contains(id)
            ))
        }
        return images.sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: - Rollback and recovery (NFR-3)

    /// Repairs journal rows a crash left behind. Call once at launch, before the
    /// watcher reconciles.
    ///
    /// The rule, in order:
    ///
    /// * **Roll forward** when every note in the event has a durable
    ///   after-image *and* the file on disk still matches it — the work was
    ///   done and only the status flip was lost. The event becomes a normal,
    ///   undoable Activity entry.
    /// * **Roll back** otherwise: notes the event created are moved to the
    ///   Trash, every before-image is written back to the path it came from,
    ///   and any file left at an intermediate path is trashed. The plan then
    ///   counts as never applied, which is exactly what the user's next session
    ///   will assume.
    @discardableResult
    public func recoverIncompleteEvents() async throws -> [RecoveryOutcome] {
        var outcomes: [RecoveryOutcome] = []
        for event in try await activity.incompleteEvents() {
            let progress = Self.decode(try await activity.progressJSON(for: event.id))
            if canRollForward(event) {
                try await activity.setStatus(.applied, for: event.id, isUndoable: !event.images.isEmpty)
                outcomes.append(RecoveryOutcome(
                    eventID: event.id,
                    resolution: .rolledForward,
                    detail: "Every change was already on disk."
                ))
                continue
            }
            outcomes.append(await rollBack(eventID: event.id, images: event.images, progress: progress))
        }
        if !outcomes.isEmpty {
            log.notice("recovered \(outcomes.count, privacy: .public) incomplete apply event(s)")
        }
        return outcomes
    }

    private func canRollForward(_ event: ActivityEvent) -> Bool {
        guard !event.images.isEmpty else { return false }
        for image in event.images {
            if let after = image.after {
                guard let text = try? rawText(at: after.relativePath), Hashing.sha256Hex(text) == after.contentHash else {
                    return false
                }
            } else if image.trashedURL != nil {
                guard let before = image.before, !fileManager.fileExists(atPath: url(before.relativePath).path) else { return false }
            } else {
                return false
            }
        }
        return true
    }

    private func rollBack(
        eventID: ActivityEventID,
        images: [NoteImage],
        progress: [ApplyProgressEntry]
    ) async -> RecoveryOutcome {
        var restored: [String] = []
        var trashed: [String] = []
        var trashURLs: [String] = []
        var problems: [String] = []

        // 1. Anything the apply brought into existence goes first, so the paths
        //    the before-images want are free again.
        for entry in progress.reversed() where entry.kind == .createdNote {
            guard let path = entry.path, fileManager.fileExists(atPath: url(path).path) else { continue }
            do {
                trashURLs.append(try await store.deleteNote(path).path)
                trashed.append(path)
            } catch {
                problems.append("could not trash \(path)")
            }
        }

        // 2. Put every before-image back where it came from.
        for image in images.reversed() {
            guard let before = image.before else { continue }
            let current = progress.last(where: { $0.noteID == image.noteID && $0.path != nil })?.path
            do {
                _ = try await store.writeRaw(before.text, to: before.relativePath)
                restored.append(before.relativePath)
                if let current, current != before.relativePath, fileManager.fileExists(atPath: url(current).path) {
                    trashURLs.append(try await store.deleteNote(current).path)
                    trashed.append(current)
                }
            } catch {
                problems.append("could not restore \(before.relativePath)")
            }
        }

        // 3. Folders the apply created, if nothing has moved into them since.
        for entry in progress.reversed() where entry.kind == .createdFolder {
            guard let path = entry.path, folderExists(path), folderIsEmpty(path) else { continue }
            _ = try? await store.deleteFolder(path)
        }

        let resolution: RecoveryOutcome.Resolution = problems.isEmpty ? .rolledBack : .failed
        try? await activity.setStatus(
            problems.isEmpty ? .rolledBack : .failed,
            for: eventID,
            isUndoable: false,
            detail: problems.joined(separator: "; ")
        )
        return RecoveryOutcome(
            eventID: eventID,
            resolution: resolution,
            restoredPaths: restored,
            trashedPaths: trashed,
            trashURLs: trashURLs,
            detail: problems.joined(separator: "; ")
        )
    }

    // MARK: - Filesystem helpers

    private func url(_ relativePath: String) -> URL { store.library.url(for: relativePath) }

    /// The note's bytes exactly as they sit on disk, front matter and all.
    ///
    /// Read-only, so it stays out of ``NoteStore``'s own-operation ledger; the
    /// before/after images have to be byte-exact for Undo to restore an
    /// identical file (FR-4.3).
    private func rawText(at relativePath: String) throws -> String {
        guard let data = fileManager.contents(atPath: url(relativePath).path) else {
            throw ApplyError.noteMissing(relativePath)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw StorageError.notUTF8(relativePath)
        }
        return text
    }

    private func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url(path).path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func folderIsEmpty(_ path: String) -> Bool {
        let contents = (try? fileManager.contentsOfDirectory(atPath: url(path).path)) ?? []
        return contents.filter { $0 != ".DS_Store" }.isEmpty
    }

    // MARK: - Summary and coding

    static func summarize(_ outcomes: [ActionOutcome]) -> String {
        let applied = outcomes.filter { $0.status == .applied }
        guard !applied.isEmpty else { return "Nothing was changed." }
        return applied.map(\.detail).joined(separator: ". ") + "."
    }

    private static func encode(_ progress: [ApplyProgressEntry]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(progress) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String?) -> [ApplyProgressEntry] {
        guard let json, let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([ApplyProgressEntry].self, from: data)) ?? []
    }
}
