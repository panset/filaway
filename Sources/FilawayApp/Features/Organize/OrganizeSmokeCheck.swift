import AppKit
import FilawayCore

/// The M2 half of the headless smoke suite (plan §8: no Xcode ⇒ no XCTest UI
/// tests, and the screen may be locked).
///
/// It drives the **real** objects — `AppModel`, `OrganizeCoordinator`, the live
/// `NSTextView`, `PlanApplier`, `ActivityLog`, `UndoService` — over a throwaway
/// notes root, with `FILAWAY_AI_MODE=replay` so the model's answer comes from a
/// committed fixture and no key or network is involved.
///
/// | Phase | What it proves |
/// |---|---|
/// | `organize` | ask mode: type → session ends → the Figure 2a card appears with the plan's summary → **Accept** → the bytes move on disk → Activity has the event with a diff → **Undo** restores every byte |
/// | `organize-auto` | auto mode: the same session applies itself and the card offers Undo |
/// | `organize-offline` | the provider fails with a network error: nothing changes, the session is queued durably, the pill says so, and capture still works |
/// | `organize-ollama` | **gated** (P2-03): the same session against a *live* local model. `Tools/smoke.sh` runs it only with `FILAWAY_SMOKE_OLLAMA=1` and a daemon answering `/api/tags`; everywhere else it prints SKIPPED and is not a failure. |
///
/// ## Why the corpus is spelled out here
///
/// A replay fixture's filename is a hash of the request, and the request is the
/// rendered prompt: the library tree, the note ids, the session delta, the
/// candidate ranking and the session's end time. So the phase has to reproduce
/// one exactly — hence the pinned note ids in the seeded front matter and
/// ``OrganizeCoordinator/endSessionNow(noteID:endedAt:)``, which ends the
/// session at a fixed instant instead of waiting out three real minutes.
///
/// The same corpus is `AppWiringFixture` in
/// `Tests/FilawayCoreTests/OrganizeWiringTests.swift`, which asserts the key it
/// hashes to. Keep the two in step: if they drift, replay throws
/// `missingRecording` and this phase fails loudly.
@MainActor
enum OrganizeSmokeCheck {

    // MARK: - The corpus (mirrors `AppWiringFixture`)

    static let curl = NoteID(UUID(uuidString: "60111111-1111-4111-8111-000000000001")!)
    static let git = NoteID(UUID(uuidString: "60222222-2222-4222-8222-000000000002")!)
    static let authDebug = NoteID(UUID(uuidString: "60333333-3333-4333-8333-000000000003")!)
    static let standup = NoteID(UUID(uuidString: "60444444-4444-4444-8444-000000000004")!)
    static let scratch = NoteID(UUID(uuidString: "60666666-6666-4666-8666-000000000006")!)

    /// The session's end time, pinned so the prompt — and the fixture key — is
    /// the same on every run.
    static let endedAt = Date(timeIntervalSince1970: 1_756_000_200)

    static let curlBody = """
    # curl

    Handy invocations.

    ## Fetch a page

    ```sh
    curl -sS https://example.test/
    ```
    """

    static let gitBody = """
    # git

    ```sh
    git rebase -i HEAD~3
    ```
    """

    static let authDebugBody = "Notes from debugging the auth API. The 401 was a clock skew.\n"
    static let standupBody = "# Standup\n\n- shipped the parser\n"

    static let curlSegment = """
    ```sh
    curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs
    ```
    """

    /// What the phase types into `Scratch.md`.
    static let sessionText = """
    curl to fetch docs from staging:

    \(curlSegment)

    remember: the token expires hourly
    """

    /// The card's text — Figure 2a, from the fixture's hand-authored plan.
    static let expectedSummary = "Code block merged into Commands / curl."

    struct Seed {
        var path: String
        var id: NoteID
        var body: String
        var tags: [String]
    }

    static var seeds: [Seed] {
        [
            Seed(path: "Commands/curl.md", id: curl, body: curlBody, tags: ["shell", "http"]),
            Seed(path: "Commands/git.md", id: git, body: gitBody, tags: ["git"]),
            Seed(path: "Auth API debug.md", id: authDebug, body: authDebugBody, tags: []),
            Seed(path: "Meetings/Standup.md", id: standup, body: standupBody, tags: []),
            Seed(path: "Scratch.md", id: scratch, body: "", tags: []),
        ]
    }

    static func rawText(_ seed: Seed) -> String {
        var lines = ["---", "id: \(seed.id.uuidString)"]
        if !seed.tags.isEmpty {
            lines.append("tags:")
            lines.append(contentsOf: seed.tags.map { "  - \($0)" })
        }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n" + seed.body
    }

    // MARK: - Driver

    private static var failures = 0

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures += 1 }
        print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private static func poll(seconds: Double, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            await settle(seconds: 0.15)
        }
        return await condition()
    }

    /// `mode` is `ask`, `auto` or `offline`.
    static func run(mode: String) async -> Int {
        failures = 0
        let model = AppModel.shared

        _ = await poll(seconds: 15) { model.isLoaded && model.organize?.isReady == true }
        guard let organize = model.organize, let store = model.store, let metadata = model.metadata else {
            check("organize-pipeline-ready", false, "the coordinator never started")
            return failures
        }
        check("organize-pipeline-ready", organize.isReady)
        check("organize-mode", organize.mode.rawValue == (mode == "auto" ? "auto" : "ask"),
              organize.mode.rawValue)

        // 1 — the library the fixture was recorded against.
        do {
            try await store.createFolder("Commands")
            try await store.createFolder("Meetings")
            for seed in seeds {
                _ = try await store.writeRaw(rawText(seed), to: seed.path)
            }
        } catch {
            check("seed-library", false, String(describing: error))
            return failures
        }
        await model.reconcile()
        await model.refreshSidebarNow()
        let indexed = await poll(seconds: 20) {
            ((try? await metadata.textIndexCount()) ?? 0) >= seeds.count
        }
        check("seed-library", model.noteCount == seeds.count, "notes=\(model.noteCount)")
        // The candidate ranker reads the FTS index, so the prompt is only
        // reproducible once indexing has caught up.
        check("index-caught-up", indexed)

        // 2 — type the session into Scratch.md through the real text view.
        await model.open(noteID: scratch)
        await settle(seconds: 0.4)
        guard let editor = MarkdownEditorController.mostRecent, model.openNote?.id == scratch else {
            check("scratch-open", false, model.openNote?.title ?? "nil")
            return failures
        }
        check("scratch-open", true)
        editor.insertText(sessionText)
        await settle(seconds: 0.4)
        check("session-text-typed", model.editorText == sessionText,
              String(model.editorText.prefix(40)).debugDescription)

        // 3 — end the session at the fixture's instant. The tracker runs the
        // autosave flush first (the ordering contract), so the organizer reads
        // the typed text off disk.
        await organize.endSessionNow(noteID: scratch, endedAt: endedAt)
        if mode != "auto" {
            // Auto mode has already rewritten the note by the time the pipeline
            // settles, so the flush is asserted on the two modes that leave the
            // file alone. The proof is the same either way: the model was sent
            // text that only ever existed in the editor's buffer.
            let onDisk = (try? await store.read("Scratch.md").body) ?? ""
            check("flush-before-organize", onDisk == sessionText, String(onDisk.prefix(40)).debugDescription)
        }

        switch mode {
        case "offline": return await runOffline(organize: organize, store: store)
        case "auto": return await runAuto(model: model, organize: organize, store: store)
        case "ollama": return await runLive(model: model, organize: organize, store: store)
        default: return await runAsk(model: model, organize: organize, store: store)
        }
    }

    // MARK: - Ask mode (FR-4.2)

    private static func runAsk(model: AppModel, organize: OrganizeCoordinator, store: NoteStore) async -> Int {
        let appeared = await poll(seconds: 20) { !organize.cards.isEmpty }
        guard appeared, let card = organize.cards.first else {
            check("card-appeared", false, "status=\(organize.status.label)")
            return failures
        }
        check("card-appeared", true)
        check("card-is-a-question", card.isProposal && card.title == "Organize this session?", card.title)
        check("card-summary-is-the-plan", card.summary == expectedSummary, card.summary)
        check("card-has-a-plan", card.plan?.actions.count == 1, "\(card.plan?.actions.count ?? -1)")

        let curlBefore = (try? await store.read("Commands/curl.md").body) ?? ""
        check("nothing-applied-yet", !curlBefore.contains("api.st.app/v2/docs"))

        // Accept.
        organize.accept(card)
        let applied = await poll(seconds: 20) {
            ((try? await store.read("Commands/curl.md").body) ?? "").contains("api.st.app/v2/docs")
        }
        check("accept-applied-the-plan", applied)
        let curlAfter = (try? await store.read("Commands/curl.md").body) ?? ""
        check("segment-landed-under-its-heading", curlAfter.contains("## Fetch staging docs"))
        let scratchAfter = (try? await store.read("Scratch.md").body) ?? ""
        check("segment-left-the-source", !scratchAfter.contains("api.st.app/v2/docs"))
        check("only-the-segment-moved", scratchAfter.contains("the token expires hourly"),
              String(scratchAfter.prefix(60)).debugDescription)

        // The sidebar and the open note followed.
        check("open-note-refreshed", model.editorText == scratchAfter,
              String(model.editorText.prefix(40)).debugDescription)

        // Activity (FR-4.3).
        guard let activity = organize.activity, let undo = organize.undoService else {
            check("activity-log", false)
            return failures
        }
        let events = (try? await activity.events(limit: 5)) ?? []
        check("activity-has-the-event", events.first?.kind == .applied, "\(events.count) events")
        check("activity-keeps-the-summary", events.first?.plan?.summary == expectedSummary,
              events.first?.plan?.summary ?? "nil")
        let diffs = (try? await activity.diff(for: events.first?.id ?? ActivityEventID())) ?? []
        check("activity-has-a-diff", diffs.contains { $0.diff.insertedLineCount > 0 }, "\(diffs.count) notes")

        // Undo (FR-4.3) — byte-for-byte.
        do {
            let result = try await undo.undoLatest()
            check("undo-completed", result.outcome == .complete, result.outcome.rawValue)
        } catch {
            check("undo-completed", false, String(describing: error))
        }
        let curlRestored = (try? await store.read("Commands/curl.md").body) ?? ""
        check("undo-restored-the-target", curlRestored == curlBefore)
        let scratchRestored = (try? await store.read("Scratch.md").body) ?? ""
        check("undo-restored-the-source", scratchRestored == sessionText)
        return failures
    }

    // MARK: - Auto mode

    private static func runAuto(model: AppModel, organize: OrganizeCoordinator, store: NoteStore) async -> Int {
        let applied = await poll(seconds: 25) {
            ((try? await store.read("Commands/curl.md").body) ?? "").contains("api.st.app/v2/docs")
        }
        check("auto-applied-without-asking", applied)
        let appeared = await poll(seconds: 10) { !organize.cards.isEmpty }
        guard appeared, let card = organize.cards.first else {
            check("auto-card-appeared", false, "status=\(organize.status.label)")
            return failures
        }
        check("auto-card-appeared", true)
        check("auto-card-is-a-statement", !card.isProposal && card.title == "Session organized", card.title)
        check("auto-card-summary", card.summary == expectedSummary, card.summary)
        check("auto-card-offers-undo", card.eventID != nil)

        organize.undo(card)
        let restored = await poll(seconds: 20) {
            ((try? await store.read("Scratch.md").body) ?? "") == sessionText
        }
        check("card-undo-restored-the-session-note", restored)
        return failures
    }

    // MARK: - A live local model (FR-6.5, P2-03)

    /// The same session as `organize`, but nothing is replayed: an 8B model on
    /// this machine is asked for a real plan and has to produce one the
    /// validator accepts.
    ///
    /// What it can and cannot assert is deliberately different from the
    /// replayed phases. The *summary* is the model's own words and the target
    /// note is the model's own choice, so neither is pinned. What is pinned is
    /// the contract: a card arrives, Accept moves bytes on disk, Activity
    /// records the event, and the event names the model that produced it.
    ///
    /// A model that returns nothing usable is a **finding**, not a flake: the
    /// check reports the validator's own content-free reason (NFR-4) so the
    /// prompt or the model can be looked at.
    private static func runLive(model: AppModel, organize: OrganizeCoordinator, store: NoteStore) async -> Int {
        let expectedModel = ProcessInfo.processInfo.environment["FILAWAY_SMOKE_OLLAMA_MODEL"]
            ?? AIModel.defaultOllama.id
        let probe = await organize.providerKindProbe()
        check("provider-is-the-local-daemon", probe.kind == .ollama, probe.kind.rawValue)
        check("provider-object-is-ollama", probe.identifier == "ollama", probe.identifier)
        check("model-is-the-local-tag", probe.model.id == expectedModel, probe.model.id)
        let budget = await organize.organizerSettingsProbe()?.requestTimeout
        check("organize-budget-is-the-local-one", budget == 180, budget.map { "\($0)s" } ?? "nil")

        // A cold model load plus a plan-shaped generation is tens of seconds on
        // a laptop; the phase's own watchdog is 240 s.
        let started = Date()
        let appeared = await poll(seconds: 190) { !organize.cards.isEmpty }
        let elapsed = Int(Date().timeIntervalSince(started))
        guard appeared, let card = organize.cards.first else {
            check("live-card-appeared", false,
                  "after \(elapsed)s — status=\(organize.status.label) "
                      + "reason=\(organize.lastFailureReason ?? "none")")
            return failures
        }
        check("live-card-appeared", true, "\(elapsed)s")
        check("live-card-is-a-question", card.isProposal && card.title == "Organize this session?", card.title)
        check("live-card-has-a-summary", !card.summary.isEmpty, card.summary)
        guard let plan = card.plan, !plan.actions.isEmpty else {
            check("live-plan-has-an-action", false,
                  "the model returned an empty plan — \(organize.lastFailureReason ?? "no reason given")")
            return failures
        }
        check("live-plan-has-an-action", true, "\(plan.actions.count) actions")

        let before = tree()
        organize.accept(card)
        let applied = await poll(seconds: 60) { tree() != before }
        check("live-accept-moved-bytes", applied,
              applied ? "" : "nothing on disk changed — \(organize.lastFailureReason ?? "no reason given")")

        // FR-4.3 / FR-6.6: the row has to say which model did it, or a mixed
        // Claude/Ollama history is unreadable.
        guard let activity = organize.activity else {
            check("live-activity-log", false)
            return failures
        }
        let events = (try? await activity.events(limit: 5)) ?? []
        check("live-activity-has-the-event", events.first?.kind == .applied, "\(events.count) events")
        let recorded = events.first?.plan?.model ?? events.first?.model
        check("live-activity-names-the-model", recorded == expectedModel, recorded ?? "nil")
        return failures
    }

    /// A content-free fingerprint of the corpus, so "something moved" needs no
    /// guess about *what* the model chose to do.
    ///
    /// It walks the notes root rather than reading the seeds' bodies, because
    /// the seed list cannot see half of what a plan may legally do: a note
    /// created at a new path, a retitle, a move, or a `tagNote` — front matter,
    /// which is not the body at all. A live model picks a different one of
    /// those every run, and a fingerprint that misses the one it picked fails
    /// the phase for no reason (P2-11).
    private static func tree() -> [String: Int] {
        var sizes: [String: Int] = [:]
        let root = AppSettings.notesRoot
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "md" else { continue }
            let path = url.path.replacingOccurrences(of: root.path + "/", with: "")
            sizes[path] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        }
        return sizes
    }

    // MARK: - Offline (FR-6.4, M2-09)

    private static func runOffline(organize: OrganizeCoordinator, store: NoteStore) async -> Int {
        let queued = await poll(seconds: 20) { organize.queuedSessionCount > 0 }
        check("session-was-queued", queued, "queued=\(organize.queuedSessionCount)")
        check("status-is-not-usable", !organize.status.isUsable(), organize.status.label)
        check("no-modal-alert", NSApp.modalWindow == nil)
        check("no-card", organize.cards.isEmpty, "\(organize.cards.count) cards")

        let curl = (try? await store.read("Commands/curl.md").body) ?? ""
        check("nothing-was-applied", !curl.contains("api.st.app/v2/docs"))
        let activityEvents = (try? await organize.activity?.events(limit: 5)) ?? []
        check("activity-is-empty", activityEvents.isEmpty, "\(activityEvents.count) events")

        // Capture still works while the AI is down — that is the whole promise.
        guard let editor = MarkdownEditorController.mostRecent else {
            check("capture-still-works", false, "no editor")
            return failures
        }
        editor.insertText("\nstill typing while the AI is offline\n")
        await AppModel.shared.flushNow(trigger: .manual)
        let after = (try? await store.read("Scratch.md").body) ?? ""
        check("capture-still-works", after.contains("still typing while the AI is offline"),
              String(after.suffix(50)).debugDescription)
        return failures
    }
}
