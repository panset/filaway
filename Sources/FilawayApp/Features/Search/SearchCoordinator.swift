import AppKit
import Foundation
import FilawayCore

/// Which behaviour the one search bar is in (FR-5.1: "one search bar, two
/// behaviors").
///
/// Both are reachable "without mode-switching friction": typing is always
/// ``keyword``, ⏎ on something question-shaped is ``semantic``, and the
/// Find/Ask toggle in the panel header is the explicit override (M3-06).
enum SearchMode: String, CaseIterable, Sendable {

    /// As-you-type literal/fuzzy filtering over titles and bodies. Instant,
    /// fully offline, no AI (FR-5.1 keyword, FR-5.5). This is M1-12.
    case keyword

    /// Natural-language retrieval over the local embedding index plus a Claude
    /// answer step (FR-5.1 semantic, FR-5.2 answer card, FR-5.3 temporal).
    ///
    /// Retrieval is local and always available; only the *card* needs a
    /// provider, so Ask degrades to a ranked list with a notice rather than
    /// disappearing when the machine is offline (FR-5.5).
    case semantic

    /// The Find/Ask toggle in the panel header (Figure 2b).
    var label: String {
        switch self {
        case .keyword: "Find"
        case .semantic: "Ask"
        }
    }
}

/// One row of the ⌘K panel, in the order ↑/↓ walk them.
///
/// The answer card is the *first item*, not a decoration above the list: ⏎ on
/// it opens the note scrolled to the chunk and ⌘C copies its snippet, which
/// only works if selection can land on it.
enum SearchItem: Equatable {
    case answer(AnswerCard)
    case keyword(KeywordHit)
    case note(RankedNote)

    var noteID: NoteID {
        switch self {
        case let .answer(card): card.noteID
        case let .keyword(hit): hit.id
        case let .note(note): note.id
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
    /// Typing is always ``SearchMode/keyword``; ⏎ and the Find/Ask toggle flip
    /// this (M3-06).
    @Published private(set) var mode: SearchMode = SearchCoordinator.lastChosenMode

    // MARK: - Published state (semantic, M3-06)

    /// The best-match card of Figure 2b, once the answer step returns.
    @Published private(set) var answerCard: AnswerCard?
    /// The ranked notes under the card. Painted from the *local* hybrid result
    /// as soon as it lands, then replaced by the model's ranking.
    @Published private(set) var semanticNotes: [RankedNote] = []
    @Published private(set) var answerSource: AnswerSource = .none
    /// `nil` until the answer step has been decided for the settled query.
    @Published private(set) var availability: SemanticAvailability?
    /// `true` between ⏎ and the local ranking landing.
    @Published private(set) var isRetrieving = false
    /// `true` while Claude is still working on the card. The list is already up.
    @Published private(set) var isAsking = false
    /// The query the semantic panel is answering, or `nil` before the first one.
    @Published private(set) var askedQuery: String?
    /// Unobtrusive footer line (FR-5.4).
    @Published private(set) var indexStatus: IndexStatus = .idle

    /// Remembered for the session, not persisted: the toggle should stick while
    /// the user is in a rhythm, and reset to Find on the next launch.
    private nonisolated(unsafe) static var lastChosenMode: SearchMode = .keyword

    // MARK: - Collaborators

    var backend: Backend?
    /// Opens a hit: select the note, load it, scroll to `matchRange` (FR-5.2).
    var onOpen: ((KeywordHit) -> Void)?
    /// Opens a semantic result: the note, scrolled to the chunk (FR-5.2).
    var onOpenChunk: ((NoteID, MatchRange) -> Void)?
    /// Escape and a successful open both return focus to the editor.
    var onReturnFocusToEditor: (() -> Void)?
    /// Settings → AI, for the "connect your AI" notice.
    var onOpenAISettings: (() -> Void)?
    /// The retrieval stack. `nil` before ``AppModel`` has built it — which is
    /// simply keyword-only mode, exactly as FR-5.5 describes.
    weak var semantic: SemanticSearchCoordinator? {
        didSet { observeIndexStatus() }
    }

    /// Long enough that a fast typist issues one query per word rather than one
    /// per letter, short enough to stay inside FR-5.1's "<100 ms perceived":
    /// the search itself is 10–25 ms at 5,000 notes (ADR-021).
    static let debounce: TimeInterval = 0.080
    /// Figure 2b shows a short list; `SearchService` ranks well past it.
    static let resultLimit = 25

    private var inFlight: Task<Void, Never>?
    /// Monotonic; only the newest generation may publish results.
    private var generation = 0
    private var semanticTask: Task<Void, Never>?
    private var indexStatusTask: Task<Void, Never>?

    // MARK: - Input

    /// As-you-type entry point — the toolbar field calls this on every change.
    ///
    /// Typing never runs a semantic query: it costs money and a partial
    /// question is not a question. What it does do in Ask mode is retire the
    /// answer that was on screen, so a stale card cannot sit above a list that
    /// has moved on.
    func query(_ text: String) {
        guard text != self.text || !isPresented else { return }
        self.text = text
        isPresented = true
        if mode == .semantic, text.trimmingCharacters(in: .whitespacesAndNewlines) != askedQuery {
            clearSemanticResults()
        }
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
        clearSemanticResults()
    }

    private func clearSemanticResults() {
        semanticTask?.cancel()
        semanticTask = nil
        answerCard = nil
        semanticNotes = []
        answerSource = .none
        availability = nil
        isRetrieving = false
        isAsking = false
        askedQuery = nil
    }

    /// Focus left the field without an Escape (a click in the editor).
    func fieldLostFocus() {
        guard isPresented else { return }
        close()
    }

    // MARK: - Selection (↑/↓/⏎)

    /// Everything ↑/↓ can land on, in draw order. In Ask mode the answer card
    /// is item 0 (FR-5.2: it is a result, not a header).
    var items: [SearchItem] {
        switch mode {
        case .keyword:
            return results.map { .keyword($0) }
        case .semantic:
            var out: [SearchItem] = []
            if let answerCard { out.append(.answer(answerCard)) }
            out.append(contentsOf: semanticNotes.map { .note($0) })
            return out
        }
    }

    var itemCount: Int {
        switch mode {
        case .keyword: results.count
        case .semantic: (answerCard == nil ? 0 : 1) + semanticNotes.count
        }
    }

    /// `-1` (nothing) → first row on the way down, last row on the way up.
    func moveSelection(by delta: Int) {
        let count = itemCount
        guard count > 0 else {
            selectedIndex = -1
            return
        }
        if selectedIndex < 0 {
            selectedIndex = delta > 0 ? 0 : count - 1
            return
        }
        // Clamped rather than wrapping: ↓ at the bottom of a Spotlight list
        // stays put, it does not jump back to the top.
        selectedIndex = min(max(selectedIndex + delta, 0), count - 1)
    }

    func select(index: Int) {
        guard index >= 0, index < itemCount else { return }
        selectedIndex = index
    }

    var selectedHit: KeywordHit? {
        guard mode == .keyword else { return nil }
        return results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    var selectedItem: SearchItem? {
        let items = items
        return items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// `true` when the answer card is what ⏎ and ⌘C act on.
    var isAnswerCardSelected: Bool {
        if case .answer = selectedItem { return true }
        return false
    }

    /// Return. `false` when there is nothing to open, so the field can let the
    /// keystroke fall through.
    @discardableResult
    func openSelected() -> Bool {
        guard let item = selectedItem else { return false }
        open(item)
        return true
    }

    /// A click on a row, or ⏎ on the selection.
    func open(_ hit: KeywordHit) {
        onOpen?(hit)
        close()
    }

    func open(_ item: SearchItem) {
        switch item {
        case let .keyword(hit):
            onOpen?(hit)
        case let .answer(card):
            onOpenChunk?(card.noteID, card.chunkRange)
        case let .note(note):
            onOpenChunk?(note.id, note.bestChunk.range)
        }
        close()
    }

    /// ⌘C with the card selected, and the card's own Copy button (FR-5.2:
    /// "one-click Copy" copies the snippet, not the note).
    ///
    /// Returns what was copied, so the smoke driver can compare it against the
    /// pasteboard rather than against itself.
    @discardableResult
    func copyAnswerSnippet() -> String? {
        guard let card = answerCard, !card.snippetText.isEmpty else { return nil }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(card.snippetText, forType: .string)
        return card.snippetText
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

    // MARK: - Semantic (M3-06, FR-5.1/5.2/5.5)

    /// `true` when Ask is offerable at all: Settings has semantic search on and
    /// the retrieval stack is up. Off → the toggle is hidden and ⏎ opens the
    /// selected hit exactly as it did in M1.
    var isAskAvailable: Bool {
        guard let semantic else { return false }
        return semantic.isSemanticSearchEnabled && semantic.isReady
    }

    /// The Find/Ask toggle, and the ⏎ trigger. Keeps the text either way
    /// (FR-5.1: "no mode-switching friction").
    func setMode(_ mode: SearchMode) {
        guard mode != self.mode else { return }
        guard mode == .keyword || isAskAvailable else { return }
        self.mode = mode
        Self.lastChosenMode = mode
        selectedIndex = -1
        switch mode {
        case .keyword:
            clearSemanticResults()
            run(debounced: false)
        case .semantic:
            inFlight?.cancel()
            isSearching = false
            runSemantic()
        }
    }

    /// Return, from the search field.
    ///
    /// | mode | state | ⏎ does |
    /// |---|---|---|
    /// | Find | question-shaped query, Ask available | switch to Ask and run it |
    /// | Find | anything else | open the selected hit |
    /// | Ask | the query has moved on | run it |
    /// | Ask | the answer is up | open the selection |
    @discardableResult
    func submit() -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .keyword:
            if isAskAvailable, Self.looksLikeAQuestion(trimmed) {
                setMode(.semantic)
                return true
            }
            return openSelected()
        case .semantic:
            guard !trimmed.isEmpty else { return false }
            if askedQuery != trimmed || (!isRetrieving && !isAsking && askedQuery == nil) {
                runSemantic()
                return true
            }
            return openSelected()
        }
    }

    /// FR-5.1's trigger heuristic: a question mark, a wh-word, or simply more
    /// than one word. Deliberately generous — a keyword search the user meant
    /// still shows the same notes, and the Find toggle is one click away.
    static func looksLikeAQuestion(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("?") { return true }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        if let first = words.first, questionWords.contains(first.lowercased()) { return true }
        return words.count >= 2
    }

    private static let questionWords: Set<String> = [
        "what", "what's", "whats", "where", "where's", "wheres", "when", "when's",
        "who", "why", "how", "how's", "hows", "which", "did", "do", "does", "is", "was",
    ]

    /// Two stages, published as they land (FR-5.2, NFR-1).
    ///
    /// The local ranking goes up the moment retrieval returns — typically a few
    /// tens of milliseconds — and the card replaces the placeholder when the
    /// answer step finishes. Nothing ever waits on Claude to draw a result.
    func runSemantic() {
        semanticTask?.cancel()
        generation += 1
        let generation = self.generation
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let semantic else { return }

        answerCard = nil
        semanticNotes = []
        answerSource = .none
        availability = nil
        selectedIndex = -1
        isRetrieving = true
        isAsking = false
        askedQuery = query

        semanticTask = Task { [weak self] in
            guard let results = await semantic.candidates(query) else {
                self?.deliverRetrievalFailure(generation: generation)
                return
            }
            guard !Task.isCancelled else { return }
            self?.deliverCandidates(results, generation: generation)

            guard let answered = await semantic.answer(for: query, results: results) else { return }
            guard !Task.isCancelled else { return }
            self?.deliverAnswer(answered.answer, availability: answered.availability, generation: generation)
        }
    }

    private func deliverCandidates(_ results: SemanticResults, generation: Int) {
        guard generation == self.generation, isPresented else { return }
        semanticNotes = results.notes
        isRetrieving = false
        // Only *then* does the card become pending: the notice for a provider
        // we already know is unreachable can go up with the list.
        if let reason = semantic?.pendingUnavailability {
            availability = .offline(reason)
            isAsking = false
        } else {
            isAsking = true
        }
        selectedIndex = results.notes.isEmpty ? -1 : 0
    }

    private func deliverAnswer(
        _ answer: AnswerResult, availability: SemanticAvailability, generation: Int
    ) {
        guard generation == self.generation, isPresented else { return }
        let hadSelection = selectedIndex >= 0
        answerCard = answer.card
        semanticNotes = answer.rankedNotes
        answerSource = answer.source
        self.availability = availability
        isAsking = false
        // The card is the new item 0, so a selection on the old list would
        // point one row off. Preselect the card, or the first note.
        selectedIndex = itemCount == 0 ? -1 : (hadSelection || answer.card != nil ? 0 : -1)
    }

    private func deliverRetrievalFailure(generation: Int) {
        guard generation == self.generation, isPresented else { return }
        isRetrieving = false
        isAsking = false
        availability = .offline(.noProvider)
    }

    private func observeIndexStatus() {
        indexStatusTask?.cancel()
        guard let semantic else {
            indexStatus = .idle
            return
        }
        indexStatusTask = Task { [weak self] in
            for await _ in semantic.$indexStatus.values {
                self?.indexStatus = semantic.indexStatus
            }
        }
    }

    // MARK: - Presentation helpers

    /// `true` when the panel should say "No matches" rather than show a list.
    var showsEmptyState: Bool {
        switch mode {
        case .keyword:
            return isPresented && results.isEmpty && settledQuery != nil && !isSearching
        case .semantic:
            return isPresented && itemCount == 0 && askedQuery != nil && !isRetrieving && !isAsking
        }
    }

    /// Recents, not matches — the empty-query case (`SearchService` returns the
    /// same order as the sidebar).
    var isShowingRecents: Bool {
        mode == .keyword && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// FR-5.5's one-liner, or `nil` when the answer step is fine.
    var availabilityNotice: String? { availability?.notice }

    /// `true` when that notice should be a button that opens Settings → AI.
    var noticeOpensSettings: Bool {
        switch availability?.reason {
        case .notConfigured, .noProvider: true
        default: false
        }
    }

    /// The nudge under a multi-word query in Find mode (FR-5.1).
    var askHint: String? {
        guard mode == .keyword, isAskAvailable else { return nil }
        guard Self.looksLikeAQuestion(text) else { return nil }
        return "Press ⏎ to ask"
    }

    /// "Indexing 42 of 300" — small, in the footer, never a modal (FR-5.4).
    var indexStatusDescription: String? {
        switch indexStatus {
        case .idle: nil
        case let .indexing(completed, total): "Indexing \(completed) of \(total)"
        case let .reindexing(completed, total): "Rebuilding index \(completed) of \(total)"
        }
    }

    /// The panel's caption, and the field's VoiceOver announcement.
    var statusDescription: String {
        switch mode {
        case .keyword:
            if isShowingRecents { return results.isEmpty ? "No notes yet" : "Recent notes" }
            if isSearching && results.isEmpty { return "Searching…" }
            if results.isEmpty { return "No matches" }
            return results.count == 1 ? "1 result" : "\(results.count) results"
        case .semantic:
            if isRetrieving { return "Searching…" }
            if isAsking { return "Reading the best matches…" }
            if itemCount == 0 { return askedQuery == nil ? "Ask a question" : "No good match" }
            if answerCard != nil { return "Best match" }
            return itemCount == 1 ? "1 note" : "\(itemCount) notes"
        }
    }
}
