import Foundation
import FilawayCore

/// The seam between the toolbar's unified search field (FR-1.3) and keyword
/// search (FR-5.1).
///
/// **M1-09 ships the stub.** The field, the ⌘K focus shortcut and the
/// as-you-type call are real; `SearchService` and the results popover are
/// M1-06/M1-12. Everything the results UI needs is already here: the live query,
/// an activation flag the shell can hang a popover off, and a `results` array
/// the follow-up agent fills in.
@MainActor
final class SearchCoordinator: ObservableObject {

    /// A single hit. M1-12 replaces this with `SearchService`'s own result type
    /// (which additionally carries the match ranges for "open scrolled to
    /// match").
    struct Result: Identifiable, Equatable {
        let noteID: NoteID
        let relativePath: String
        let title: String
        let snippet: String
        var id: NoteID { noteID }
    }

    /// What is in the field, verbatim.
    @Published private(set) var text: String = ""
    /// `true` while the field holds a query worth showing results for.
    @Published private(set) var isActive: Bool = false
    /// Populated by M1-12; empty until then.
    @Published private(set) var results: [Result] = []

    /// Installed by M1-12 with `{ query in await searchService.keyword(query) }`.
    /// The stub leaves it `nil`, which makes every query a no-op.
    var backend: ((String) async -> [Result])?

    /// Opens the note behind a result. Wired to `AppModel.open(noteID:)` by the
    /// shell so the results UI does not need the whole app model.
    var onOpen: ((NoteID) -> Void)?

    private var inFlight: Task<Void, Never>?

    /// As-you-type entry point — the toolbar field calls this on every change.
    func query(_ text: String) {
        self.text = text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isActive = !trimmed.isEmpty

        inFlight?.cancel()
        guard isActive, let backend else {
            results = []
            return
        }
        inFlight = Task { [weak self] in
            let hits = await backend(trimmed)
            guard !Task.isCancelled else { return }
            self?.results = hits
        }
    }

    func open(_ noteID: NoteID) {
        onOpen?(noteID)
        dismiss()
    }

    /// Escape, or a successful open.
    func dismiss() {
        inFlight?.cancel()
        inFlight = nil
        text = ""
        isActive = false
        results = []
    }
}
