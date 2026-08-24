import AppKit
import FilawayCore

/// `organize-ollama-suite` — the live plan-quality suite (P2-09, ADR-073).
///
/// ## Why it exists
///
/// The core thing Filaway does is file a writing session with a model. Three
/// dogfooding sessions in a row hit a *different* plan-quality failure, and a
/// person found every one of them: `titleCollision`, then `unknownFolder`, then
/// `folderTooDeep`. The gated `organize-ollama` phase was running one session
/// over one corpus — the classic curl library — and could not have caught any
/// of them, because none of them are about that shape of library.
///
/// This phase runs the shapes the failures actually came from, against the real
/// daemon, through the real objects:
///
/// | scenario | library | session | mode |
/// |---|---|---|---|
/// | `feedback-list` | ~8 notes at the root, **no folders** | a bulleted list of short app-feedback lines | ask |
/// | `command-note` | the same folderless library | one OIDC/`curl` invocation with a line of prose | auto |
/// | `existing-folders` | two folders, each with notes | a shell recipe whose home is one of them | auto |
///
/// `feedback-list` is the `folderTooDeep` shape verbatim: a model shown a
/// library with no folders invents a filing cabinet
/// (`Home/Projects/…/Skills/…`) to put the session in. `existing-folders` is
/// its opposite — the right answer is a folder that is already there — and is
/// what catches a repair that has started inventing folders instead of using
/// them.
///
/// ## What it asserts, and what it deliberately does not
///
/// The model's words and choices are its own, so the *summary*, the target and
/// the action kinds are never pinned. What is pinned is the **contract**:
///
/// * every scenario reaches a usable outcome — applied (auto), proposed and
///   then accepted (ask), or an explicit `nothingToDo`;
/// * a plan the validator **rejects is a phase failure**, and the transcript
///   prints the issue *kinds* so the next repair rule has a name;
/// * bytes moved or arrived on disk;
/// * the Activity log has the event and it names the model that produced it;
/// * **Settings → Activity** shows the same event through `ActivityModel`, the
///   object `ActivitySettingsView` reads — plus an `organizeFailed` row, which
///   is scripted rather than provoked (a live model that fails on demand is not
///   a thing).
///
/// Every line it prints is content-free (NFR-4): action kinds, issue kinds,
/// counts and seconds. No note text, no titles, no paths.
///
/// ## How it drives the app
///
/// One process, one Application Support, a **fresh notes root per scenario**
/// via ``AppModel/reopenLibrary(at:)`` — each root has its own database
/// (`Library.key`), so the baselines and the Activity journal start empty every
/// time. The session text is written through `NoteStore` rather than typed into
/// the live `NSTextView`: the organizer's delta is `baseline → what is on
/// disk`, so a fresh library plus a written note is exactly one session's worth
/// of text, and the phase then needs no window. Typing *is* covered — by
/// `organize` and `organize-ollama`, which is where it belongs.
@MainActor
enum OrganizeSuiteSmokeCheck {

    // MARK: - Scenarios

    struct Note {
        var path: String
        var body: String
    }

    struct Scenario {
        var name: String
        /// `.askBeforeFiling` or `.autoFile`.
        var mode: OrganizationMode
        var folders: [String] = []
        var notes: [Note]
        /// The note the session is written into; created by the scenario.
        var sessionPath: String
        var sessionBody: String
    }

    static var scenarios: [Scenario] {
        [
            Scenario(
                name: "feedback-list",
                mode: .askBeforeFiling,
                notes: folderlessLibrary,
                sessionPath: "App Updates.md",
                sessionBody: feedbackSession
            ),
            Scenario(
                name: "command-note",
                mode: .autoFile,
                notes: folderlessLibrary,
                sessionPath: "Scratch.md",
                sessionBody: commandSession
            ),
            Scenario(
                name: "existing-folders",
                mode: .autoFile,
                folders: ["Commands", "Reference"],
                notes: foldered,
                sessionPath: "Scratch.md",
                sessionBody: shellRecipeSession
            ),
        ]
    }

    /// The shape the live `folderTooDeep` came from: everything at the root,
    /// not one folder anywhere.
    static let folderlessLibrary: [Note] = [
        Note(path: "Meeting notes.md", body: "# Meeting notes\n\n- ship the importer behind a flag\n"),
        Note(path: "Reading list.md", body: "# Reading list\n\n- the one about caches\n"),
        Note(path: "Trip planning.md", body: "# Trip planning\n\n- book the ferry\n"),
        Note(path: "Standup.md", body: "# Standup\n\n- finished the parser\n"),
        Note(path: "Auth API debug.md", body: "Notes from debugging the auth API. The 401 was clock skew.\n"),
        Note(path: "Shell tricks.md", body: "# Shell tricks\n\n```sh\nfd -e md | xargs wc -l\n```\n"),
        Note(path: "Grocery list.md", body: "- oats\n- olive oil\n"),
        Note(path: "Book ideas.md", body: "# Book ideas\n\n- a novel about a lighthouse\n"),
    ]

    static let foldered: [Note] = [
        Note(path: "Commands/curl.md", body: "# curl\n\nHandy invocations.\n\n```sh\ncurl -sS https://example.test/\n```\n"),
        Note(path: "Commands/git.md", body: "# git\n\n```sh\ngit rebase -i HEAD~3\n```\n"),
        Note(path: "Reference/HTTP status codes.md", body: "# HTTP status codes\n\n429 is rate limiting.\n"),
        Note(path: "Standup.md", body: "# Standup\n\n- finished the parser\n"),
        Note(path: "Reading list.md", body: "# Reading list\n\n- the one about caches\n"),
    ]

    /// A numbered list of short feedback lines, which is what the user was
    /// writing when the live failure happened.
    static let feedbackSession = """
    Things to fix in the app:

    1. the organize card is too small to read the summary
    2. undo should be reachable from the menu bar, not only the card
    3. the sidebar forgets which folder was expanded after a rename
    4. searching for a two word phrase should not need quotes
    5. the status pill flickers when the daemon is slow
    """

    static let commandSession = """
    Getting an OIDC token out of staging:

    ```sh
    curl -sS -X POST https://auth.example.test/oidc/token \\
      -d grant_type=client_credentials \\
      -d client_id=$CLIENT_ID -d client_secret=$CLIENT_SECRET
    ```

    remember: the token expires in an hour
    """

    static let shellRecipeSession = """
    Counting lines across the tree without a subshell:

    ```sh
    curl -sS https://example.test/manifest.json | jq -r '.files[]' | wc -l
    ```

    handy when the manifest is huge
    """

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

    /// How long one scenario may take. A cold model load plus a plan-shaped
    /// generation is tens of seconds on an 8B model; `Tools/smoke.sh` gives the
    /// whole phase more than three of these.
    private static let scenarioBudget: Double = 190

    static func run() async -> Int {
        failures = 0
        let expectedModel = ProcessInfo.processInfo.environment["FILAWAY_SMOKE_OLLAMA_MODEL"]
            ?? AIModel.defaultOllama.id

        _ = await poll(seconds: 20) { AppModel.shared.isLoaded }
        let probe = await AppModel.shared.organize?.providerKindProbe()
        check("provider-is-the-local-daemon", probe?.kind == .ollama, probe?.kind.rawValue ?? "nil")
        check("model-is-the-local-tag", probe?.model.id == expectedModel, probe?.model.id ?? "nil")

        for scenario in scenarios {
            let seconds = await runScenario(scenario, expectedModel: expectedModel)
            print("SMOKE info scenario=\(scenario.name) mode=\(scenario.mode.rawValue) "
                + "seconds=\(String(format: "%.1f", seconds))")
        }
        return failures
    }

    // MARK: - One scenario

    /// Returns the wall clock from "the session ended" to "the outcome landed".
    private static func runScenario(_ scenario: Scenario, expectedModel: String) async -> Double {
        let label = scenario.name
        print("SMOKE info --- scenario \(label) ---")

        // A library of its own, so the baselines and the Activity journal for
        // this scenario start empty (`Library.key` keys the database).
        let root = AppSettings.notesRoot.appendingPathComponent(label, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The mode has to be in `CoreSettings` before the coordinator is built;
        // `observe(_:)` then pushes it at the actor anyway (M4-02).
        AppSettings.core.organizationMode = scenario.mode

        let model = AppModel.shared
        await model.reopenLibrary(at: root)
        let ready = await poll(seconds: 30) { model.isLoaded && model.organize?.isReady == true }
        guard ready, let organize = model.organize, let store = model.store, let metadata = model.metadata else {
            check("\(label)/pipeline-ready", false, "the coordinator never started")
            return 0
        }
        check("\(label)/pipeline-ready", true)
        let modeMatched = await poll(seconds: 10) {
            organize.mode.rawValue == (scenario.mode == .autoFile ? "auto" : "ask")
        }
        check("\(label)/mode", modeMatched, organize.mode.rawValue)

        // 1 — seed.
        do {
            for folder in scenario.folders { try await store.createFolder(folder) }
            for note in scenario.notes { _ = try await store.writeRaw(note.body, to: note.path) }
            _ = try await store.writeRaw(scenario.sessionBody, to: scenario.sessionPath)
        } catch {
            check("\(label)/seed", false, String(describing: error))
            return 0
        }
        await model.reconcile()
        await model.refreshSidebarNow()
        let expected = scenario.notes.count + 1
        let indexed = await poll(seconds: 30) {
            ((try? await metadata.textIndexCount()) ?? 0) >= expected
        }
        check("\(label)/seed", model.noteCount == expected, "notes=\(model.noteCount)")
        check("\(label)/index-caught-up", indexed)

        guard let session = try? await store.read(scenario.sessionPath) else {
            check("\(label)/session-note", false, "could not read it back")
            return 0
        }

        // 2 — end the session now. No fixture key to hit, so the instant is
        // simply "now"; the tracker rewinds by the idle interval itself.
        let before = await tree(store, scenario: scenario)
        let activityBefore = (try? await organize.activity?.events(limit: 50))?.count ?? 0
        let started = Date()
        await organize.endSessionNow(noteID: session.summary.id, endedAt: Date())

        // 3 — a usable outcome, or a named failure.
        let outcome = await waitForOutcome(organize, mode: scenario.mode)
        let seconds = Date().timeIntervalSince(started)

        switch outcome {
        case .nothingToDo:
            // FR-4.6: an explicit "this is already where it belongs" is a
            // correct answer and never a failure.
            check("\(label)/outcome", true, "nothingToDo")
            return seconds

        case .none:
            check("\(label)/outcome", false,
                  "nothing after \(Int(seconds))s — status=\(organize.status.label) "
                      + "issues=[\(organize.lastFailureIssueKinds.joined(separator: ", "))] "
                      + "reason-kind=\(reasonKind(organize.lastFailureReason))")
            return seconds

        case let .card(card):
            let kinds = (card.plan?.actions.map(\.kind.rawValue) ?? []).joined(separator: ", ")
            let warnings = card.warnings.map(\.kind.rawValue).joined(separator: ", ")
            print("SMOKE info \(label)/plan actions=[\(kinds)] warnings=[\(warnings)]")
            check("\(label)/plan-has-an-action", !(card.plan?.actions.isEmpty ?? true),
                  "\(card.plan?.actions.count ?? -1)")
            check("\(label)/card-has-a-summary", !card.summary.isEmpty, "\(card.summary.count) chars")

            if scenario.mode == .askBeforeFiling {
                check("\(label)/card-is-a-question", card.isProposal, card.title)
                organize.accept(card)
                let moved = await poll(seconds: 60) { await tree(store, scenario: scenario) != before }
                check("\(label)/accept-moved-bytes", moved,
                      moved ? "" : "nothing on disk changed — \(reasonKind(organize.lastFailureReason))")
            } else {
                check("\(label)/auto-card-is-a-statement", !card.isProposal, card.title)
                let moved = await poll(seconds: 30) { await tree(store, scenario: scenario) != before }
                check("\(label)/auto-applied-bytes", moved)
                check("\(label)/auto-card-offers-undo", card.eventID != nil)
            }
        }

        // 4 — Activity (FR-4.3, FR-6.6).
        guard let activity = organize.activity else {
            check("\(label)/activity-log", false)
            return seconds
        }
        let landed = await poll(seconds: 30) {
            ((try? await activity.events(limit: 50))?.first?.kind) == .applied
        }
        let events = (try? await activity.events(limit: 50)) ?? []
        check("\(label)/activity-has-the-event", landed && events.count > activityBefore,
              "\(events.count) events")
        let recorded = events.first?.plan?.model ?? events.first?.model
        check("\(label)/activity-names-the-model", recorded == expectedModel, recorded ?? "nil")
        let diffs = (try? await activity.diff(for: events.first?.id ?? ActivityEventID())) ?? []
        check("\(label)/activity-has-a-diff", !diffs.isEmpty, "\(diffs.count) notes")

        // 5 — the same event through Settings → Activity's own model.
        await checkSettingsActivity(label: label, organize: organize, expecting: events.first?.id)
        return seconds
    }

    // MARK: - Settings → Activity

    /// `ActivitySettingsView` renders `ActivityModel.events`; this is that
    /// object, attached to the live coordinator exactly as the pane attaches it.
    private static func checkSettingsActivity(
        label: String,
        organize: OrganizeCoordinator,
        expecting eventID: ActivityEventID?
    ) async {
        let pane = ActivityModel()
        pane.attach(to: organize)
        await pane.reload()
        check("\(label)/settings-activity-shows-it",
              eventID != nil && pane.events.contains { $0.id == eventID },
              "\(pane.events.count) rows")

        // FR-6.4 / ADR-072: a *failed* organization is a durable row too, and
        // the pane is where a user who missed the banner goes looking. A live
        // model cannot be made to fail on demand, so this one is scripted
        // through the same `ActivityLog` seam the coordinator uses.
        guard let activity = organize.activity else { return }
        try? await activity.recordFailure(reason: "scripted: the plan was rejected", model: nil)
        await pane.reload()
        check("\(label)/settings-activity-shows-a-failure",
              pane.events.contains { $0.kind == .organizeFailed },
              "\(pane.events.count) rows")
    }

    // MARK: - Helpers

    private enum Outcome {
        case card(OrganizeCoordinator.Card)
        case nothingToDo
        case none
    }

    private static func waitForOutcome(_ organize: OrganizeCoordinator, mode: OrganizationMode) async -> Outcome {
        let arrived = await poll(seconds: scenarioBudget) {
            !organize.cards.isEmpty || organize.lastFailureReason != nil
        }
        if let card = organize.cards.first { return .card(card) }
        guard arrived, let reason = organize.lastFailureReason else { return .none }
        return reason.hasPrefix("skipped: nothingToDo") ? .nothingToDo : .none
    }

    /// A content-free fingerprint of the whole library: relative path → byte
    /// count. "Something moved" then needs no guess about *what* the model
    /// chose to do, and no note text is read.
    private static func tree(_ store: NoteStore, scenario: Scenario) async -> [String: Int] {
        var sizes: [String: Int] = [:]
        for path in scenario.notes.map(\.path) + [scenario.sessionPath] {
            sizes[path] = ((try? await store.read(path).body) ?? "").utf8.count
        }
        // Anything the plan created lands outside that list; count the tree.
        let scanned = (try? await store.scan())?.notes.count ?? 0
        sizes["<note-count>"] = scanned
        return sizes
    }

    /// The first token of a failure label — "The", "Gave", … — never the
    /// summary, which names paths (NFR-4).
    private static func reasonKind(_ reason: String?) -> String {
        guard let reason else { return "none" }
        if reason.hasPrefix("skipped: ") { return reason }
        return String(reason.prefix(while: { $0 != ":" && $0 != "(" }))
    }
}
