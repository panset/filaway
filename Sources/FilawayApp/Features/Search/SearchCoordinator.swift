import Foundation
import FilawayCore

/// Which behaviour the one search bar is in (FR-5.1: "one search bar, two
/// behaviors").
///
/// M1 ships ``keyword`` only. ``semantic`` is declared here — and nowhere
/// implemented — so the M3-06 agent has a single, obvious seam to fill rather
/// than a refactor to perform.
enum SearchMode: String, CaseIterable, Sendable {

    /// As-you-type literal/fuzzy filtering over titles and bodies. Instant,
    /// fully offline, no AI (FR-5.1 keyword, FR-5.5). This is M1-12.
    case keyword

    /// **Extension point — M3-06. Not implemented in M1.**
    ///
    /// Natural-language retrieval over the local embedding index plus a Claude
    /// rerank/answer step (FR-5.1 semantic, FR-5.2 answer card, FR-5.3 temporal).
    /// What the M3 agent has to add:
    ///
    /// 1. A second backend on ``SearchCoordinator`` (`semanticBackend`) and the
    ///    trigger heuristic — Return on a multi-word query, or the visible
    ///    Find/Ask toggle — that flips ``SearchCoordinator/mode``.
    /// 2. The answer card above the list in `SearchResultsPanel`
    ///    (`// MARK: - Extension point (M3-06)` marks the spot).
    /// 3. The "semantic answers unavailable offline" notice (FR-5.5).
    ///
    /// Nothing in M1 ever sets this case; ``SearchCoordinator/query(_:)``
    /// routes every keystroke to ``keyword``.
    case semantic

    /// What the Find/Ask toggle will read (M3-06).
    var label: String {
        switch self {
        case .keyword: "Find"
        case .semantic: "Ask"
        }
    }
}

/// The seam between the toolbar's unified search field (FR-1.3) and keyword
/// search (FR-5.1, FR-5.2).
///
/// One query at a time, latest wins. Every keystroke cancels the task in flight
/// and starts another behind an 80 ms debounce; a result set is published only
/// if it belongs to the newest query, so a slow search for `cur` can never
/// overwrite a fast one for `curl`. An empty query is a real query — it returns
/// Recents, which is what ⌘K shows before anything is typed.
///
/// The coordinator owns *selection* as well as results, because ↑/↓ arrive at
/// the text field (which keeps focus the whole time) and the panel merely
/// renders what is selected. See ADR-034.
@MainActor
final class SearchCoordinator: ObservableObject {

    /// `(query, limit) -> hits`. Installed by ``AppModel`` once the database is
    /// open; `nil` before that, which makes every query an empty result.
    typealias Backend = @Sendable (String, Int) async -> [KeywordHit]

    // MARK: - Published state

    /// What is in the field, verbatim.
    @Published private(set) var text: String = ""
    /// `true` while the results panel is on screen.
    @Published private(set) var isPresented: Bool = false
    /// The current result set, already ranked by `SearchService` — never re-sorted.
    @Published private(set) var results: [KeywordHit] = []
    /// Index into ``results``; `-1` when there is nothing to select.
    @Published private(set) var selectedIndex: Int = -1
    /// `true` between a keystroke and its results landing.
    @Published private(set) var isSearching: Bool = false
    /// The query the current ``results`` answer, or `nil` before the first one
    /// lands. Distinguishes "no matches" from "not searched yet".
    @Published private(set) var settledQuery: String?
    /// M1 is always ``SearchMode/keyword``; M3-06 flips this.
    @Published private(set) var mode: SearchMode = .keyword

    // MARK: - Collaborators

    var backend: Backend?
    /// Opens a hit: select the note, load it, scroll to `matchRange` (FR-5.2).
    var onOpen: ((KeywordHit) -> Void)?
    /// Escape and a successful open both return focus to the editor.
    var onReturnFocusToEditor: (() -> Void)?

    /// Long enough that a fast typist issues one query per word rather than one
    /// per letter, short enough to stay inside FR-5.1's "<100 ms perceived":
    /// the search itself is 10–25 ms at 5,000 notes (ADR-021).
    static let debounce: TimeInterval = 0.080
    /// Figure 2b shows a short list; `SearchService` ranks well past it.
    static let resultLimit = 25

    private var inFlight: Task<Void, Never>?
    /// Monotonic; only the newest generation may publish results.
    private var generation = 0

    // MARK: - Input

    /// As-you-type entry point — the toolbar field calls this on every change.
    func query(_ text: String) {
        guard text != self.text || !isPresented else { return }
        self.text = text
        isPresented = true
        run(debounced: true)
    }

    /// The field took focus (⌘K, or a click). Shows the panel immediately with
    /// Recents (or the results for whatever is still in the field).
    func activate() {
        isPresented = true
        run(debounced: false)
    }

    /// Escape.
    ///
    /// The first press closes the panel and hands focus back to the editor but
    /// keeps the query, so ⌘K resumes where the user left off (⌘K selects the
    /// text, so retyping replaces it). A second press — Escape while the field
    /// has focus but the panel is closed — clears the field.
    func handleEscape() {
        if isPresented {
            close()
        } else {
            clear()
        }
        onReturnFocusToEditor?()
    }

    /// The ✕ button in the field.
    func clear() {
        text = ""
        close()
    }

    /// Closes the panel and drops the in-flight query; the text survives.
    func close() {
        inFlight?.cancel()
        inFlight = nil
        isSearching = false
        isPresented = false
        results = []
        selectedIndex = -1
        settledQuery = nil
    }

    /// Focus left the field without an Escape (a click in the editor).
    func fieldLostFocus() {
        guard isPresented else { return }
        close()
    }

    // MARK: - Selection (↑/↓/⏎)

    /// `-1` (nothing) → first row on the way down, last row on the way up.
    func moveSelection(by delta: Int) {
        guard !results.isEmpty else {
            selectedIndex = -1
            return
        }
        if selectedIndex < 0 {
            selectedIndex = delta > 0 ? 0 : results.count - 1
            return
        }
        // Clamped rather than wrapping: ↓ at the bottom of a Spotlight list
        // stays put, it does not jump back to the top.
        selectedIndex = min(max(selectedIndex + delta, 0), results.count - 1)
    }

    func select(index: Int) {
        guard results.indices.contains(index) else { return }
        selectedIndex = index
    }

    var selectedHit: KeywordHit? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Return. `false` when there is nothing to open, so the field can let the
    /// keystroke fall through.
    @discardableResult
    func openSelected() -> Bool {
        guard let hit = selectedHit else { return false }
        open(hit)
        return true
    }

    /// A click on a row, or ⏎ on the selection.
    func open(_ hit: KeywordHit) {
        onOpen?(hit)
        close()
    }

    // MARK: - Querying

    /// Cancels whatever is in flight and schedules the current text.
    ///
    /// The generation counter is what makes "latest wins" true even when a task
    /// is already past its cancellation checks: a result set is published only
    /// while its generation is still the newest one.
    private func run(debounced: Bool) {
        inFlight?.cancel()
        generation += 1
        let generation = self.generation
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let backend else {
            results = []
            selectedIndex = -1
            settledQuery = nil
            isSearching = false
            return
        }

        isSearching = true
        let limit = Self.resultLimit
        let delay = debounced ? Self.debounce : 0
        inFlight = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
                guard !Task.isCancelled else { return }
            }
            let hits = await backend(trimmed, limit)
            guard !Task.isCancelled else { return }
            self?.deliver(hits, query: trimmed, generation: generation)
        }
    }

    /// Publishes a result set — unless a newer query has already started, in
    /// which case it is dropped on the floor.
    private func deliver(_ hits: [KeywordHit], query: String, generation: Int) {
        guard generation == self.generation, isPresented else { return }
        results = hits
        settledQuery = query
        isSearching = false
        // Spotlight preselects the top hit so ⏎ opens it without an arrow key.
        selectedIndex = hits.isEmpty ? -1 : 0
    }

    // MARK: - Presentation helpers

    /// `true` when the panel should say "No matches" rather than show a list.
    var showsEmptyState: Bool {
        isPresented && results.isEmpty && settledQuery != nil && !isSearching
    }

    /// Recents, not matches — the empty-query case (`SearchService` returns the
    /// same order as the sidebar).
    var isShowingRecents: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The panel's caption, and the field's VoiceOver announcement.
    var statusDescription: String {
        if isShowingRecents { return results.isEmpty ? "No notes yet" : "Recent notes" }
        if isSearching && results.isEmpty { return "Searching…" }
        if results.isEmpty { return "No matches" }
        return results.count == 1 ? "1 result" : "\(results.count) results"
    }
}
