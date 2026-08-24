import AppKit
import FilawayCore

/// Headless end-to-end check for ⌘K semantic search (M3-06, Figure 2b).
///
/// It drives the *real* objects — the bundled Core ML embedder, the launch-time
/// `Indexer`, `HybridSearch`, `AnswerExtractor`, ``SearchCoordinator`` and the
/// live `NSTextView` — against the three-note corpus `Tools/smoke.sh` seeds on
/// disk *before* the app starts, with fixed modification times so the temporal
/// query (FR-5.3) has something deterministic to filter.
///
/// ```
/// FILAWAY_SMOKE=semantic FILAWAY_AI_MODE=replay FILAWAY_NOTES_ROOT=… build/Filaway.app/Contents/MacOS/Filaway
/// ```
///
/// The provider is scripted rather than replayed: a replay fixture's key is a
/// hash of the rendered prompt, and the prompt contains the *indexed* chunks,
/// so a committed fixture would break the first time the chunker or the
/// embedder moved. The scripted provider reads the same prompt the real one
/// would get and answers from it, which tests the rendering as well — the
/// prompt→tool contract itself is covered offline by `AnswerGoldenTests`.
enum SemanticSmokeCheck {

    /// Kept in step with `seed_semantic_corpus` in `Tools/smoke.sh`.
    static let stagingTitle = "Staging docs"
    static let authTitle = "Auth API debug"
    static let dockerTitle = "Docker cheats"
    /// The command the answer card must come back with.
    static let curlCommand = #"curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs"#
    static let query = "curl command to fetch documents"
    static let temporalQuery = "the thing I edited two days ago about auth"

    @MainActor
    static func run() async -> Int {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let model = AppModel.shared
        let search = model.search
        let semantic = model.semanticSearch

        // 0 — the retrieval stack came up and indexed the seeded corpus.
        func chunkCount() async -> Int {
            guard let indexer = semantic.indexer else { return 0 }
            return (try? await indexer.chunkCount()) ?? 0
        }
        let ready = await poll(seconds: 60) {
            guard semantic.isReady, model.noteCount >= 3, semantic.indexStatus == .idle else { return false }
            return await chunkCount() > 0
        }
        let chunks = await chunkCount()
        check("semantic-stack-ready", ready, "notes=\(model.noteCount) chunks=\(chunks)")
        check("embedder-loaded", semantic.supportsVectors,
              semantic.embedderDescription ?? "none")
        print("SMOKE info embedder=\(semantic.embedderDescription ?? "none") chunks=\(chunks)")
        guard ready else {
            print("SMOKE phase=semantic result failures=\(failures)")
            return failures
        }

        // 1 — with no AI configured, Ask still answers from the local index and
        // says why the card is not Claude's (FR-5.5, FR-6.4).
        semantic.setProviderReady(false)
        model.focusSearch()
        check("ask-is-offered", search.isAskAvailable)
        check("ask-hint-appears-on-a-multi-word-query", {
            search.query(Self.query)
            return search.askHint == "Press ⏎ to ask"
        }(), search.askHint ?? "nil")

        _ = search.submit()
        check("return-switches-to-ask", search.mode == .semantic, search.mode.rawValue)
        var settled = await poll(seconds: 20) { !search.isRetrieving && !search.isAsking }
        check("offline-search-settles", settled)
        check("offline-notice-is-shown",
              search.availabilityNotice == "Connect your AI in Settings to get answers",
              search.availabilityNotice ?? "nil")
        check("offline-notice-opens-settings", search.noticeOpensSettings)
        check("offline-list-is-local", !search.semanticNotes.isEmpty,
              "\(search.semanticNotes.map(\.title))")
        check("offline-card-is-local", search.answerSource == .localHeuristic,
              "\(search.answerSource)")

        // 2 — with a provider, the card is Claude's, and its snippet is the
        // command verbatim (FR-5.2, Figure 2b).
        // A deliberately slow answer, so "the list is up while Claude is still
        // thinking" is an ordering proof rather than a race.
        semantic.overrideProvider(Self.answeringProvider(delay: 0.6))
        semantic.setProviderReady(true)
        // **Leave the pointer resting where the rows are about to be drawn.**
        // A panel that opens under a stationary mouse must not hand it the
        // selection: SwiftUI reports `onHover(true)` for whatever row lands
        // beneath the cursor with no movement at all, and letting that select
        // moves ⏎ and ⌘C off the answer card onto a note the user never pointed
        // at (ADR-034 amendment). Parked *before* the query, so the pointer is
        // motionless for everything below — which is the whole point.
        let parkedPointer = await parkPointerOverTheFirstRow()
        search.runSemantic()
        let listFirst = await poll(seconds: 20) { !search.isRetrieving && !search.semanticNotes.isEmpty }
        check("hybrid-list-paints-first", listFirst, "\(search.semanticNotes.map(\.title))")
        check("card-is-still-pending-while-the-list-is-up",
              search.isAsking && search.answerCard == nil,
              "asking=\(search.isAsking) card=\(search.answerCard != nil)")
        settled = await poll(seconds: 20) { !search.isAsking && search.answerCard != nil }
        check("answer-card-arrives", settled)

        guard let card = search.answerCard else {
            check("answer-card", false, "no card")
            print("SMOKE phase=semantic result failures=\(failures)")
            return failures
        }
        check("card-came-from-the-model", search.answerSource == .model, "\(search.answerSource)")
        check("card-snippet-is-the-command", card.snippetText == Self.curlCommand,
              card.snippetText.debugDescription)
        check("card-is-a-code-block", card.isCode, card.language ?? "nil")
        check("card-source-is-the-note", card.title == Self.stagingTitle, card.title)
        check("card-source-label-has-the-folder", card.sourceLabel == "Commands / \(Self.stagingTitle)",
              card.sourceLabel)
        check("card-is-selected-first", search.selectedIndex == 0 && search.isAnswerCardSelected,
              parkedPointer ? "with the pointer resting on row 1" : "no window to park a pointer in")
        check("ranked-notes-below-the-card", !search.semanticNotes.isEmpty,
              "\(search.semanticNotes.map(\.title))")
        check("card-note-not-repeated-below",
              !search.semanticNotes.contains { $0.id == card.noteID })
        print("SMOKE info card=\(card.sourceLabel) rows=\(search.semanticNotes.map(\.title))")

        // 3 — Copy puts the snippet, and only the snippet, on the pasteboard.
        NSPasteboard.general.clearContents()
        let copied = search.copyAnswerSnippet()
        let pasteboard = NSPasteboard.general.string(forType: .string)
        check("copy-returns-the-snippet", copied == Self.curlCommand, copied?.debugDescription ?? "nil")
        check("copy-reaches-the-pasteboard", pasteboard == Self.curlCommand,
              pasteboard?.debugDescription ?? "nil")

        // 4 — ↑/↓ walk the card and the rows; ⏎ opens the card scrolled to its
        // chunk (FR-5.2).
        search.moveSelection(by: 1)
        check("arrow-down-leaves-the-card", search.selectedIndex == 1 && !search.isAnswerCardSelected)
        search.moveSelection(by: -1)
        check("arrow-up-returns-to-the-card", search.isAnswerCardSelected)

        let opened = search.openSelected()
        check("return-opens-the-card", opened)
        check("open-closes-panel", !search.isPresented)
        _ = await poll(seconds: 10) { model.openNote?.id == card.noteID }
        check("card-opens-its-note", model.openNote?.id == card.noteID,
              model.openNote?.title ?? "nil")

        // The scroll assertions need a real view hierarchy. A run in a session
        // with no window server has none — report it and carry on rather than
        // failing on the environment (see `SmokeDriver.hasWindow`).
        if let editor = MarkdownEditorController.mostRecent {
            let chunkRange = card.chunkRange.nsRange
            let scrolled = await poll(seconds: 10) {
                editor.selectedRange == chunkRange && editor.isRangeVisible(chunkRange)
            }
            print("SMOKE info reveal chunk=\(NSStringFromRange(chunkRange)) "
                + "selection=\(NSStringFromRange(editor.selectedRange))")
            check("card-opens-scrolled-to-the-chunk", scrolled, NSStringFromRange(editor.selectedRange))
            check("chunk-text-contains-the-command",
                  (editor.text as NSString).substring(with: editor.selectedRange).contains("api.st.app"),
                  (editor.text as NSString).substring(with: editor.selectedRange).prefix(60).debugDescription)
            // The fence sits ~160 lines down, so a visible chunk proves a real scroll.
            check("editor-scrolled-off-the-top", !editor.isRangeVisible(NSRange(location: 0, length: 1)))
        } else if SmokeDriver.hasWindow {
            check("editor-attached", false, "a window is up but no MarkdownEditorView is")
        } else {
            print("SMOKE info no-window — skipping the scroll assertions (headless session)")
        }

        restorePointer()

        // 5 — a temporal query filters by edit time (FR-5.3). Only the auth
        // note was touched two days ago.
        model.focusSearch()
        search.setMode(.semantic)
        search.query(Self.temporalQuery)
        _ = search.submit()
        settled = await poll(seconds: 20) { !search.isRetrieving && !search.isAsking }
        check("temporal-search-settles", settled)
        let temporalTitles = Set(search.semanticNotes.map(\.title) + [search.answerCard?.title].compactMap { $0 })
        check("temporal-query-filters-by-edit-time", temporalTitles == [Self.authTitle],
              "\(temporalTitles.sorted())")

        // 6 — offline: the notice goes up, the local list stays (FR-5.5).
        semantic.overrideProvider(MockProvider { _ in
            throw AIError.network(code: -1009, description: "The Internet connection appears to be offline.")
        })
        semantic.setProviderReady(true)
        search.query(Self.query)
        _ = search.submit()
        settled = await poll(seconds: 20) { !search.isRetrieving && !search.isAsking }
        check("offline-search-settles-too", settled)
        check("offline-notice-is-the-fr-5-5-line",
              search.availabilityNotice == "Semantic answers unavailable offline — showing local matches",
              search.availabilityNotice ?? "nil")
        check("offline-keeps-the-local-list", !search.semanticNotes.isEmpty,
              "\(search.semanticNotes.map(\.title))")
        check("offline-card-is-local-again", search.answerSource == .localHeuristic,
              "\(search.answerSource)")

        // 7 — Find still works with no AI at all, as it must (FR-5.5).
        search.setMode(.keyword)
        check("toggle-back-to-find-keeps-the-text", search.text == Self.query, search.text)
        // Find ANDs its terms, so the *question* legitimately matches nothing;
        // what matters is that literal search still works with no AI at all.
        search.query("curl")
        let keywordSettled = await poll(seconds: 10) {
            search.settledQuery == "curl" && !search.isSearching
        }
        check("find-still-answers", keywordSettled && search.results.count == 2,
              "\(search.results.map(\.title))")
        check("find-has-no-answer-card", search.answerCard == nil)

        // 8 — how long the whole thing takes (NFR-1: semantic < 5 s typical).
        semantic.overrideProvider(Self.answeringProvider())
        var samples: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now()
            search.setMode(.semantic)
            search.query(Self.query)
            search.runSemantic()
            _ = await poll(seconds: 20) { !search.isRetrieving && !search.isAsking }
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            search.setMode(.keyword)
        }
        print(String(format: "SMOKE perf semantic end to end: %@",
                     samples.map { String(format: "%.0f ms", $0) }.joined(separator: ", ")))
        check("semantic-under-the-5s-budget", (samples.max() ?? .infinity) < 5_000,
              String(format: "max %.0f ms", samples.max() ?? 0))

        search.handleEscape()
        print("SMOKE phase=semantic result failures=\(failures)")
        return failures
    }

    /// Where the pointer was before ``parkPointerOverTheFirstRow()`` moved it.
    @MainActor private static var pointerOrigin: NSPoint?

    /// Moves the real pointer onto the row that sits under the answer card and
    /// leaves it there.
    ///
    /// Both halves are needed: `CGWarpMouseCursorPosition` moves the cursor but
    /// generates no event, and a posted `NSEvent` is routed without moving the
    /// cursor `onHover` reads — either alone leaves the panel none the wiser.
    ///
    /// The offset is Figure 2b's layout: caption, then the answer card, then
    /// the rows. Returns `false` in a session with no window, where there is
    /// nothing to prove.
    @MainActor
    private static func parkPointerOverTheFirstRow() async -> Bool {
        // `mainWindow` is nil whenever the app is not the active one, which a
        // scripted run cannot rely on being true — go by the scene itself.
        let window = NSApp.mainWindow ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible }
        guard let window, let screen = NSScreen.screens.first else { return false }
        pointerOrigin = NSEvent.mouseLocation
        window.acceptsMouseMovedEvents = true
        let frame = window.frame
        /// Below the caption and the card, on the first ranked note.
        let inset: CGFloat = 180
        CGWarpMouseCursorPosition(
            CGPoint(x: frame.midX, y: screen.frame.height - frame.maxY + inset))
        if let move = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: frame.width / 2, y: frame.height - inset),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0
        ) {
            NSApp.postEvent(move, atStart: false)
        }
        await settle(seconds: 0.3)
        return true
    }

    /// Puts the pointer back where the person running the suite left it.
    @MainActor
    private static func restorePointer() {
        guard let origin = pointerOrigin, let screen = NSScreen.screens.first else { return }
        pointerOrigin = nil
        CGWarpMouseCursorPosition(CGPoint(x: origin.x, y: screen.frame.height - origin.y))
    }

    // MARK: - The scripted provider

    /// Answers `answer_selection` by *reading the prompt it was given*: it
    /// finds the numbered chunk that contains the staging curl command and
    /// returns that number with the command as the snippet.
    ///
    /// That keeps the check independent of how retrieval happened to rank the
    /// chunks, while still proving the prompt carried the right one.
    static func answeringProvider(delay: TimeInterval = 0) -> MockProvider {
        MockProvider(identifier: "smoke") { request in
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
            let prompt = request.messages.first?.text ?? ""
            guard let number = chunkNumber(containing: "api.st.app/v2/docs", in: prompt) else {
                return AIResponse(
                    id: "msg_smoke", model: request.model.id,
                    content: [.toolUse(id: "t", name: AnswerSelection.toolName, input: .object([
                        "best_chunk_id": .null, "snippet": .null,
                        "confidence": "low", "ranked_chunk_ids": .array([]),
                    ]))],
                    stopReason: .toolUse, usage: AIUsage(inputTokens: 900, outputTokens: 40)
                )
            }
            let others = chunkNumbers(in: prompt).filter { $0 != number }
            return AIResponse(
                id: "msg_smoke", model: request.model.id,
                content: [.toolUse(id: "t", name: AnswerSelection.toolName, input: .object([
                    "best_chunk_id": .integer(number),
                    "snippet": .string(curlCommand),
                    "confidence": "high",
                    "ranked_chunk_ids": .array(([number] + others).map { .integer($0) }),
                ]))],
                stopReason: .toolUse, usage: AIUsage(inputTokens: 900, outputTokens: 90)
            )
        }
    }

    /// `[3] Staging docs — Commands/Staging docs.md` → `3`.
    static func chunkNumbers(in prompt: String) -> [Int] {
        prompt.components(separatedBy: "\n").compactMap { line in
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
            return Int(line[line.index(after: line.startIndex)..<close])
        }
    }

    static func chunkNumber(containing needle: String, in prompt: String) -> Int? {
        var current: Int?
        for line in prompt.components(separatedBy: "\n") {
            if line.hasPrefix("["), let close = line.firstIndex(of: "]"),
               let number = Int(line[line.index(after: line.startIndex)..<close]) {
                current = number
            }
            if line.contains(needle), let current { return current }
        }
        return nil
    }

    // MARK: - Helpers

    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    @MainActor
    private static func poll(seconds: Double, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            await settle(seconds: 0.15)
        }
        return await condition()
    }
}
