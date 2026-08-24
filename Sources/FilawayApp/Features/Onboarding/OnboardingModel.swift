import AppKit
import FilawayCore

/// The state behind the first-run flow (M4-01, FR-7.1).
///
/// Three steps, no more: choose the notes folder, connect the AI, and see where
/// things are. Every one of them is answerable with the keyboard alone, and two
/// of the three are skippable — the app has to be *usable* with the AI
/// connection skipped (capture plus keyword search), so the only thing this flow
/// insists on is a folder, and even that arrives pre-filled with `~/Notes`.
///
/// The model owns no window. ``OnboardingWindowController`` draws it and
/// ``OnboardingPresenter`` runs it; the smoke driver calls the same methods with
/// no window at all, which is what makes a three-screen flow testable on a
/// locked screen.
///
/// It is a plain class with an ``onStateChange`` callback rather than an
/// `ObservableObject`, because the window it drives is AppKit (ADR-049).
@MainActor
final class OnboardingModel {

    /// FR-7.1's "three steps maximum".
    enum Step: Int, CaseIterable, Comparable {
        case welcome = 0
        case connectAI
        case orientation

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }

        /// "2 of 3", as Figure 3 spells it.
        var label: String { "\(rawValue + 1) of \(Step.allCases.count)" }
    }

    /// Where the key field is in its life cycle (Figure 3's live validation).
    enum KeyPhase: Equatable {
        case idle
        case validating
        case valid
        case failed(String)
    }

    /// The instance the presenter and the smoke driver share.
    static let shared = OnboardingModel()

    // MARK: - Published state

    private(set) var step: Step = .welcome { didSet { changed() } }
    /// The folder step 1 will adopt. Starts at whatever the app would open now.
    private(set) var notesRoot: URL { didSet { changed() } }
    /// How many `.md` files are already in ``notesRoot`` — "adopting an existing
    /// folder just works" is only reassuring if the flow says so out loud.
    private(set) var existingNoteCount: Int = 0 { didSet { changed() } }
    var apiKey: String = ""
    private(set) var keyPhase: KeyPhase = .idle { didSet { changed() } }
    private(set) var status: AIStatus = .notConfigured { didSet { changed() } }
    private(set) var isFinished = false
    /// Which card of Figure 3's step 2 is selected (FR-6.5). Claude by default:
    /// a first-run user who has never heard of Ollama should not have to
    /// un-choose it.
    private(set) var provider: AIProviderKind = .claude { didSet { changed() } }
    /// The local-model card's own state machine, in Core so it is unit-tested
    /// (``OllamaSetupModel``).
    let ollama: OllamaSetupModel

    /// Called once, when the flow ends. The presenter uses it to stop the modal.
    var onFinish: (() -> Void)?
    /// Called whenever anything the window draws has changed.
    var onStateChange: (() -> Void)?

    private func changed() { onStateChange?() }

    let settings: CoreSettings
    let connection: AIConnectionManager

    // MARK: - Init

    init(
        settings: CoreSettings = AppSettings.core,
        connection: AIConnectionManager? = nil,
        notesRoot: URL = AppSettings.notesRoot,
        ollamaValidator: (any OllamaValidating)? = nil
    ) {
        self.settings = settings
        self.connection = connection ?? OnboardingModel.makeConnection()
        self.notesRoot = notesRoot
        ollama = OllamaSetupModel(validator: ollamaValidator ?? OnboardingModel.makeOllamaValidator())
        refreshFolderSummary()
        ollama.onChange = { [weak self] in self?.changed() }
    }

    /// A smoke run must never touch the real Keychain — an unsigned bundle can
    /// prompt, and a scripted run has no business writing the user's credential.
    /// The manager is deliberately *not* library-bound: the key is app-global,
    /// and the library does not exist yet when this flow runs.
    private static func makeConnection() -> AIConnectionManager {
        AppSettings.isSmokeRun ? AIConnectionManager(secrets: InMemorySecretStore()) : AIConnectionManager()
    }

    /// A smoke run must never reach a daemon either — the `onboarding-ollama`
    /// phase asserts the *flow*, and a machine with no Ollama installed would
    /// otherwise fail it for the wrong reason. `FILAWAY_SMOKE_OLLAMA_MODELS`
    /// scripts the list, and an empty value scripts a dead daemon.
    private static func makeOllamaValidator() -> any OllamaValidating {
        guard AppSettings.isSmokeRun else { return LiveOllamaValidator() }
        let raw = ProcessInfo.processInfo.environment["FILAWAY_SMOKE_OLLAMA_MODELS"]
        let tags = (raw ?? AIModel.defaultOllama.id)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if tags.isEmpty {
            return StubOllamaValidator(
                models: [], failure: .network(code: -1004, description: "smoke: no daemon")
            )
        }
        return StubOllamaValidator(models: tags)
    }

    /// `true` when the launch gate should show this flow at all.
    static var isNeeded: Bool { !AppSettings.core.onboardingCompleted }

    // MARK: - Step 1: the notes folder

    /// The path as the welcome step shows it, with `~` restored.
    var notesRootDisplayPath: String {
        (notesRoot.path as NSString).abbreviatingWithTildeInPath
    }

    /// "12 notes already here — Filaway will adopt them." / "" for a new folder.
    var folderSummary: String {
        guard FileManager.default.fileExists(atPath: notesRoot.path) else {
            return "Filaway will create this folder."
        }
        switch existingNoteCount {
        case 0: return "Empty — a good place to start."
        case 1: return "1 Markdown note is already here. Filaway adopts it as it is."
        default: return "\(existingNoteCount) Markdown notes are already here. Filaway adopts them as they are."
        }
    }

    /// Runs the `NSOpenPanel` of FR-7.1: directories only, and the user may
    /// create one on the spot.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your notes folder"
        panel.prompt = "Choose"
        panel.message = "Filaway keeps plain Markdown files here. Any folder works, "
            + "including one that already has notes in it."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: notesRoot.path)
            ? notesRoot
            : notesRoot.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adoptFolder(url)
    }

    /// The half of ``chooseFolder()`` that has no panel in it — the smoke driver
    /// calls this directly.
    func adoptFolder(_ url: URL) {
        notesRoot = url.standardizedFileURL
        refreshFolderSummary()
    }

    private func refreshFolderSummary() {
        existingNoteCount = OnboardingModel.countMarkdownFiles(in: notesRoot)
    }

    /// Counts `.md` files one and two levels deep — the Library's own depth cap.
    /// Deliberately shallow: this is a reassurance, not an index.
    private static func countMarkdownFiles(in root: URL) -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return 0 }
        guard let enumerator = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            if enumerator.level > PathRules.maxFolderDepth + 1 {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == PathRules.noteExtension else { continue }
            count += 1
            if count >= 9_999 { break }
        }
        return count
    }

    // MARK: - Step 2: connect the AI (Figure 3)

    /// Figure 3's privacy sentence, verbatim (FR-6.3).
    static let privacyStatement =
        "Your AI organizes notes and powers search. Notes stay on your Mac; "
        + "only note text being organized is sent to the provider."

    /// Typing after a rejection clears the message, so the field never argues
    /// with what is in it.
    func keyFieldEdited() {
        guard keyPhase != .validating, keyPhase != .valid else { return }
        keyPhase = .idle
    }

    /// Figure 3's two cards. Choosing one drops the other's verdict, so the
    /// footer never enables Continue on a connection the user has moved away
    /// from.
    func selectProvider(_ kind: AIProviderKind) {
        guard kind != provider else { return }
        provider = kind
    }

    /// The local card's field.
    func ollamaURLEdited(_ text: String) { ollama.urlEdited(text) }
    func selectOllamaModel(_ tag: String) { ollama.selectModel(tag) }
    func testOllama() async { await ollama.test() }
    func refreshOllamaModels() async { await ollama.refreshModels() }

    var canValidateKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && keyPhase != .validating
    }

    /// Validates the typed key and, only if it validates, stores it in the
    /// Keychain (FR-6.1 — the rule itself lives in `AIConnectionManager`).
    func validateKey() async {
        let entered = apiKey
        guard !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        keyPhase = .validating
        switch await connection.connect(apiKey: entered) {
        case .success:
            keyPhase = .valid
            apiKey = ""
            status = await connection.status
            // Connecting answers the question the gentle prompt asks.
            settings.aiConnectionSkipped = false
        case let .failure(error):
            keyPhase = .failed(error.description)
            status = await connection.status
        }
    }

    /// "Skip for now" (FR-7.1). The app stays fully usable; a quiet prompt in
    /// the sidebar keeps the offer open (never a modal — FR-6.4).
    func skipAI() {
        settings.aiConnectionSkipped = true
        advance()
    }

    /// `true` once *this flow's* chosen provider is known to work — a validated
    /// key for Claude, a daemon that answered and has the tag for Ollama.
    var isConnected: Bool {
        switch provider {
        case .claude: return status == .connected
        case .ollama: return ollama.isConnected
        }
    }

    /// FR-7.1: step 2 never blocks — "Skip for now" is always there — but
    /// Continue must not imply a connection that was never made. Claude's card
    /// has always let Continue through (a key can be added later in Settings);
    /// the local card gates on the test, because an unreachable daemon is a
    /// setup problem the user can fix *here*, in seconds.
    var canContinue: Bool {
        guard step == .connectAI, provider == .ollama else { return true }
        return ollama.isConnected
    }

    // MARK: - Navigation

    var canGoBack: Bool { step != .welcome }

    func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return finish() }
        step = next
    }

    func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Ends the flow: the folder becomes the library root, the preference that
    /// keeps this window from ever appearing again is set, and the presenter is
    /// told to let the app through.
    func finish() {
        guard !isFinished else { return }

        // Create the folder before bookmarking it — a bookmark to a path that
        // does not exist is not a bookmark.
        let library = Library(root: notesRoot, supportRoot: AppSettings.supportRoot)
        do {
            try library.prepareDirectories()
        } catch {
            Log.app.error("could not prepare the chosen notes folder: \(String(describing: error), privacy: .public)")
        }
        AppSettings.setNotesRoot(notesRoot)

        // FR-6.5: the chosen backend, and where the local daemon is.
        settings.aiProvider = provider
        if let configuration = ollama.configuration {
            settings.ollamaBaseURL = configuration.baseURL
            settings.ollamaModel = configuration.model
        }

        // A connection that never validated must not leave "skipped" false, or
        // the gentle prompt would never appear. Ollama counts: a daemon that
        // answered and has the model is a working AI with no key at all.
        if isConnected { settings.aiConnectionSkipped = false }
        else { settings.aiConnectionSkipped = true }

        settings.onboardingCompleted = true
        settings.flush()
        AppSettings.flush()
        isFinished = true
        Log.app.info("onboarding completed; library root chosen")
        onFinish?()
    }
}
