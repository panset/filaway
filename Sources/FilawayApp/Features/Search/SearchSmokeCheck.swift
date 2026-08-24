import AppKit
import FilawayCore

/// Headless end-to-end check for ⌘K keyword search (plan §8: no Xcode ⇒ no
/// XCTest UI tests, and the screen may be locked).
///
/// It drives the *real* objects — the launch-time index built by
/// `MetadataStore`, the live `SearchService`, ``SearchCoordinator`` and the
/// `NSTextView` the results scroll — against the three-note corpus
/// `Tools/smoke.sh` seeds on disk *before* the app starts. That ordering
/// matters: it proves the index is there after a cold launch on a library the
/// app has never seen.
///
/// ```
/// FILAWAY_SMOKE=search FILAWAY_NOTES_ROOT=… build/Filaway.app/Contents/MacOS/Filaway
/// ```
enum SearchSmokeCheck {

    /// Titles of the seeded corpus — kept in step with `seed_search_corpus` in
    /// `Tools/smoke.sh`.
    static let stagingTitle = "Staging docs"
    static let authTitle = "Auth API debug"
    static let dockerTitle = "Docker cheats"
    /// The line at the very end of `Staging docs`, well past one screenful.
    static let tailPhrase = "token expires hourly"

    @MainActor
    static func run() async -> Int {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            if !condition { failures += 1 }
            print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        let model = AppModel.shared
        let search = model.search

        // 0 — the seeded corpus reached the database *and* the text index.
        let indexed = await poll(seconds: 25) {
            guard model.noteCount >= 3 else { return false }
            guard let metadata = model.metadata else { return false }
            return ((try? await metadata.textIndexCount()) ?? 0) >= 3
        }
        var textCount = 0
        if let metadata = model.metadata { textCount = (try? await metadata.textIndexCount()) ?? 0 }
        check("corpus-indexed-on-launch", indexed,
              "notes=\(model.noteCount) indexed=\(textCount)")
        check("search-backend-installed", search.backend != nil)

        // 1 — ⌘K from anywhere opens the panel on Recents (FR-1.3).
        model.focusSearch()
        let recentsShown = await poll(seconds: 8) {
            search.isPresented && search.settledQuery == "" && !search.isSearching
        }
        check("cmd-k-presents-panel", search.isPresented)
        check("empty-query-shows-recents", recentsShown && search.results.count == 3,
              "\(search.results.map(\.title))")
        check("recents-are-recent-source", search.results.allSatisfy { $0.source == .recent })
        check("recents-preselect-first", search.selectedIndex == 0)

        // 2 — as-you-type: "curl" finds the two notes that contain one, and not
        // the one that does not (FR-5.1, offline, no AI).
        let curl = await results(for: "curl", in: search)
        check("curl-hit-count", curl.count == 2, "\(curl.map(\.title))")
        check("curl-hits-are-the-two-with-a-curl",
              Set(curl.map(\.title)) == [stagingTitle, dockerTitle], "\(curl.map(\.title))")
        check("curl-excludes-non-matching-note", !curl.contains { $0.title == authTitle })
        check("curl-hits-have-match-ranges", curl.allSatisfy { $0.matchRange != nil })
        check("curl-hits-have-snippet-ranges", curl.allSatisfy { $0.snippetRange != nil })
        for hit in curl where hit.snippetRange != nil {
            let highlighted = (hit.snippet as NSString).substring(with: hit.snippetRange!.nsRange)
            check("snippet-highlight-is-the-match", highlighted.lowercased() == "curl", highlighted)
        }
        check("hit-carries-folder-path",
              curl.first { $0.title == stagingTitle }
                  .map { PathRules.folderPath(of: $0.relativePath) } == "Commands",
              curl.first { $0.title == stagingTitle }?.relativePath ?? "nil")

        // 3 — keyboard navigation: ↑/↓ move, ⏎ opens (NFR-6, full keyboard).
        search.moveSelection(by: 1)
        check("arrow-down-moves", search.selectedIndex == 1, "index=\(search.selectedIndex)")
        search.moveSelection(by: 1)
        check("arrow-down-clamps-at-bottom", search.selectedIndex == curl.count - 1,
              "index=\(search.selectedIndex)")
        search.moveSelection(by: -1)
        check("arrow-up-moves", search.selectedIndex == curl.count - 2)

        // 4 — ⏎ opens the hit scrolled to its match range (FR-5.2). The long
        // note, so the match is genuinely off-screen to begin with.
        guard let target = curl.firstIndex(where: { $0.title == stagingTitle }) else {
            check("curl-hit-openable", false, "\(curl.map(\.title))")
            return failures
        }
        search.select(index: target)
        guard let hit = search.selectedHit, let matchRange = hit.matchRange?.nsRange else {
            check("curl-hit-openable", false)
            return failures
        }
        let opened = search.openSelected()
        check("return-opens-selection", opened)
        check("open-closes-panel", !search.isPresented)
        _ = await poll(seconds: 8) { model.openNote?.id == hit.id }
        check("opened-note-is-the-hit", model.openNote?.id == hit.id,
              model.openNote?.title ?? "nil")
        check("opened-note-selected-in-sidebar", model.selection?.noteID == hit.id)

        guard let editor = MarkdownEditorController.mostRecent else {
            check("editor-attached", false, "no MarkdownEditorView")
            return failures
        }
        let scrolled = await poll(seconds: 8) {
            editor.selectedRange == matchRange && editor.isRangeVisible(matchRange)
        }
        print("SMOKE info reveal match=\(NSStringFromRange(matchRange)) "
            + "selection=\(NSStringFromRange(editor.selectedRange)) "
            + "viewport=\(editor.visibleCharacterRange.map(NSStringFromRange) ?? "nil")")
        check("hit-selected-in-editor",
              editor.selectedRange == matchRange,
              NSStringFromRange(editor.selectedRange))
        check("hit-text-is-the-query",
              (editor.text as NSString).substring(with: editor.selectedRange).lowercased() == "curl",
              (editor.text as NSString).substring(with: editor.selectedRange).debugDescription)
        check("match-range-is-visible", scrolled && editor.isRangeVisible(matchRange))
        // The match sits ~160 lines down, so a visible match proves the editor
        // really scrolled rather than happening to show the whole note.
        check("editor-scrolled-off-the-top",
              !editor.isRangeVisible(NSRange(location: 0, length: 1)))

        // 5 — a hit inside the note that is *already* open still reveals.
        let tail = await results(for: tailPhrase, in: search)
        check("open-note-still-searchable", tail.first?.id == hit.id, tail.first?.title ?? "nil")
        if let tailHit = tail.first, let tailRange = tailHit.matchRange?.nsRange {
            _ = await model.openSearchHitAsync(tailHit)
            let revealed = await poll(seconds: 8) { editor.selectedRange == tailRange }
            check("same-note-hit-moves-selection", revealed,
                  (editor.text as NSString).substring(with: editor.selectedRange).debugDescription)
            check("same-note-hit-visible", editor.isRangeVisible(tailRange))
        } else {
            check("open-note-hit-has-range", false)
        }

        // 6 — a misremembered title still finds the note (fuzzy = titles only,
        // plan §1 amendment 6 / ADR-021).
        let typo = await results(for: "Auth API debgu", in: search)
        check("typo-title-found", typo.first?.title == authTitle, typo.first?.title ?? "nil")
        check("typo-hit-is-fuzzy", typo.first?.source == .titleFuzzy,
              typo.first.map { "\($0.source)" } ?? "nil")

        // 7 — "No matches" is a real state, not an empty list forever.
        let nothing = await results(for: "zzqqxnotinthelibrary", in: search)
        check("no-matches-is-empty", nothing.isEmpty)
        check("no-matches-empty-state", search.showsEmptyState)
        check("no-matches-status", search.statusDescription == "No matches", search.statusDescription)

        // 8 — stale queries lose to the newest one, however slow they are.
        if let real = search.backend {
            search.backend = { query, limit in
                if query == "cur" {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                return await real(query, limit)
            }
            search.query("cur")
            await settle(seconds: 0.2)          // "cur" is past the debounce, in flight
            search.query("curl")
            _ = await poll(seconds: 8) { search.settledQuery == "curl" }
            await settle(seconds: 0.8)          // long enough for "cur" to try to land
            check("latest-query-wins", search.settledQuery == "curl",
                  search.settledQuery ?? "nil")
            check("stale-results-dropped", search.results.count == 2,
                  "\(search.results.map(\.title))")
            search.backend = real
        }

        // 9 — Escape closes the panel and returns focus to the editor.
        search.handleEscape()
        check("escape-closes-panel", !search.isPresented)
        check("escape-keeps-query", search.text == "curl", search.text)
        let refocused = await poll(seconds: 8) { editor.isFirstResponder }
        check("escape-returns-focus-to-editor", refocused)
        // A second Escape clears the field.
        search.handleEscape()
        check("second-escape-clears-query", search.text.isEmpty, search.text)

        // 10 — how long a keystroke actually costs on this corpus (FR-5.1
        // "<100 ms perceived"). The gate lives in `filaway-bench keyword`; this
        // is the end-to-end number through the coordinator.
        var samples: [Double] = []
        if let backend = search.backend {
            for query in ["c", "cu", "cur", "curl", "curl comm"] {
                let start = DispatchTime.now()
                _ = await backend(query, SearchCoordinator.resultLimit)
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
            }
        }
        print(String(format: "SMOKE perf keyword backend (debounce is a further %.0f ms): %@",
                     SearchCoordinator.debounce * 1000,
                     samples.map { String(format: "%.1f ms", $0) }.joined(separator: ", ")))
        // One outlier in five is a scheduler hiccup, not perceived latency —
        // the strict p95 gate is `filaway-bench keyword`. All the rest must fit.
        let sorted = samples.sorted()
        let allButWorst = sorted.dropLast()
        check("as-you-type-under-budget",
              !samples.isEmpty && (allButWorst.max() ?? 0) < 100 && (sorted.last ?? 0) < 400,
              String(format: "worst %.1f ms, next %.1f ms", sorted.last ?? 0, allButWorst.max() ?? 0))

        return failures
    }

    // MARK: - Helpers

    /// Types a query and waits for *its* results — the coordinator publishes a
    /// set only when it is the newest one, so this cannot observe a stale list.
    @MainActor
    private static func results(
        for query: String, in coordinator: SearchCoordinator, seconds: Double = 8
    ) async -> [KeywordHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        coordinator.query(query)
        _ = await poll(seconds: seconds) {
            coordinator.settledQuery == trimmed && !coordinator.isSearching
        }
        return coordinator.results
    }

    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    @MainActor
    private static func poll(seconds: Double, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            await settle(seconds: 0.1)
        }
        return await condition()
    }
}
