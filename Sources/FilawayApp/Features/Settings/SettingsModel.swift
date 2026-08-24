import AppKit
import FilawayCore
import SwiftUI

// `CoreSettings` is `FilawayCore.AppSettings` under a name this module can
// reach: the shell's own `AppSettings` shadows it here, and `FilawayCore.` as a
// qualifier finds the enum of that name rather than the module. The alias is
// declared in Core, next to the type.

/// The view model behind the Settings window (M2-11 / M4-02, Figure 4).
///
/// It owns nothing: `AppSettings` is the source of truth for preferences and
/// `AIConnectionManager` for the connection. What lives here is the SwiftUI
/// plumbing Core deliberately does not have — `ObservableObject`, `Binding`s
/// that write straight through, and the mirrored async state (status, models,
/// usage) pulled off the actor.
///
/// Preferences are *not* mirrored into `@Published` properties. A binding reads
/// and writes `AppSettings` directly and announces the change, so the window can
/// never drift from what another part of the app just stored.
@MainActor
final class SettingsModel: ObservableObject {

    /// The instance the Settings scene, the toolbar pill and onboarding share.
    static let shared = SettingsModel()

    let settings: CoreSettings
    let connection: AIConnectionManager

    /// The connection state Figure 4's card draws.
    @Published private(set) var status: AIStatus = .notConfigured
    /// Models the last successful validation reported (FR-6.2's override list).
    @Published private(set) var models: [AIModelInfo] = []
    /// This month's billed requests and tokens (FR-6.6); `nil` hides the line.
    @Published private(set) var usage: AIUsageTotals?
    @Published private(set) var hasStoredKey = false
    /// `true` when the *selected* provider has everything it needs — a key for
    /// Claude, a pulled model for Ollama (FR-6.5, P2-02).
    @Published private(set) var isConfigured = false
    /// `true` while **Test connection** is talking to the local daemon.
    @Published private(set) var isTestingLocal = false
    /// The Base URL field's live text. Edited freely; only a valid loopback or
    /// `https` URL is ever committed to `AppSettings` (NFR-4's rule).
    @Published var ollamaBaseURLText = OllamaConfiguration.defaultBaseURL.absoluteString
    /// Library folders offered by the exclusion picker (FR-4.5).
    @Published private(set) var folders: [String] = []
    @Published private(set) var isRefreshing = false
    /// `true` while ``changeNotesFolder(to:)`` is closing one library and
    /// opening another (FR-8.1, M4-02).
    @Published private(set) var isChangingLibrary = false
    /// `true` while a full reindex is running (FR-5.4). The button is disabled
    /// and the row shows ``SemanticSearchCoordinator/indexStatus`` instead.
    @Published private(set) var isRebuildingIndex = false
    /// What the last rebuild did — "4,182 chunks from 512 notes".
    @Published private(set) var lastRebuildSummary: String?

    private var statusTask: Task<Void, Never>?

    init(
        settings: CoreSettings? = nil,
        connection: AIConnectionManager? = nil
    ) {
        let library = Library(root: AppSettings.notesRoot, supportRoot: AppSettings.supportRoot)
        self.settings = settings ?? CoreSettings(defaults: AppSettings.defaults, libraryKey: library.key)
        self.connection = connection ?? SettingsModel.makeConnection(
            library: library, settings: self.settings
        )
        ollamaBaseURLText = self.settings.ollamaBaseURL.absoluteString
        statusTask = Task { [weak self] in
            guard let manager = self?.connection else { return }
            for await status in await manager.statusChanges() {
                await MainActor.run { self?.status = status }
            }
        }
    }

    deinit { statusTask?.cancel() }

    /// A smoke run must never touch the real Keychain — an unsigned bundle can
    /// prompt, and a scripted run has no business writing the user's credential.
    private static func makeConnection(library: Library, settings: CoreSettings) -> AIConnectionManager {
        AIConnectionManager(
            secrets: AppSettings.isSmokeRun ? InMemorySecretStore() : KeychainStore(),
            ledger: try? AIUsageLedger(library: library),
            kind: settings.aiProvider,
            ollama: settings.ollamaConfiguration,
            providerFactory: AIConnectionManager.defaultProviderFactory(mode: AIMode.appMode())
        )
    }

    // MARK: - Bindings

    /// A binding that reads and writes ``settings`` directly.
    func binding<Value>(
        _ get: @escaping (CoreSettings) -> Value,
        _ set: @escaping (CoreSettings, Value) -> Void
    ) -> Binding<Value> {
        Binding(
            get: { [settings] in get(settings) },
            set: { [weak self] newValue in
                guard let self else { return }
                objectWillChange.send()
                set(settings, newValue)
            }
        )
    }

    var organizationMode: Binding<OrganizationMode> {
        binding({ $0.organizationMode }, { $0.organizationMode = $1 })
    }

    var idleInterval: Binding<Int> {
        binding({ $0.idleInterval }, { $0.idleInterval = $1 })
    }

    var semanticSearchEnabled: Binding<Bool> {
        binding({ $0.semanticSearchEnabled }, { $0.semanticSearchEnabled = $1 })
    }

    /// FR-2.4's switch (M4-03).
    var pasteIntelligenceEnabled: Binding<Bool> {
        binding({ $0.pasteIntelligenceEnabled }, { $0.pasteIntelligenceEnabled = $1 })
    }

    var advancedModelOverride: Binding<Bool> {
        binding({ $0.advancedModelOverride }, { $0.advancedModelOverride = $1 })
    }

    var organizeModel: Binding<String> {
        binding({ $0.organizeModel.id }, { $0.organizeModel = AIModel($1) })
    }

    var searchModel: Binding<String> {
        binding({ $0.searchModel.id }, { $0.searchModel = AIModel($1) })
    }

    var excludedFolders: [String] { settings.excludedFolders }

    func setFolderExcluded(_ folder: String, _ excluded: Bool) {
        objectWillChange.send()
        settings.setFolderExcluded(folder, excluded)
    }

    func resetModelsToDefaults() {
        objectWillChange.send()
        settings.resetModelsToDefaults()
    }

    // MARK: - Connection (FR-6.1, FR-6.2)

    /// Called when the window appears: re-check the selected provider and
    /// reload the usage line, so neither is stale.
    ///
    /// Claude is only asked when a key exists — a validation with nothing to
    /// validate is a wasted round trip. The local daemon is always asked,
    /// because the question it answers ("are you running?") has no cheaper
    /// source and the call never leaves the machine.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        _ = await connection.setProvider(settings.aiProvider, ollama: settings.ollamaConfiguration)
        hasStoredKey = await connection.hasStoredKey
        if settings.aiProvider == .ollama || hasStoredKey {
            _ = await connection.refresh()
        } else {
            status = await connection.status
        }
        await pullConnectionState()
        usage = await connection.monthlyUsage()
        reloadFolders()
    }

    /// Mirrors the actor's state onto the main actor after anything that could
    /// have moved it.
    private func pullConnectionState() async {
        status = await connection.status
        models = await connection.models
        hasStoredKey = await connection.hasStoredKey
        isConfigured = await connection.isConfigured
    }

    /// Validates and stores a key. Returns `nil` on success, the error otherwise.
    func connect(apiKey: String) async -> AIError? {
        switch await connection.connect(apiKey: apiKey) {
        case .success:
            await pullConnectionState()
            usage = await connection.monthlyUsage()
            return nil
        case let .failure(error):
            await pullConnectionState()
            return error
        }
    }

    func disconnect() async {
        await connection.disconnect()
        await pullConnectionState()
    }

    // MARK: - Provider selection (FR-6.5 — P2-02)

    /// Which backend the pane is showing, and the app is using.
    var aiProvider: AIProviderKind { settings.aiProvider }

    /// Figure 4's provider chooser. Writes the preference, points the
    /// connection at the new backend and re-checks it — Claude re-validates the
    /// key that was left in the Keychain all along, Ollama asks the daemon.
    func selectProvider(_ kind: AIProviderKind) async {
        guard kind != settings.aiProvider else { return }
        objectWillChange.send()
        settings.aiProvider = kind
        await refresh()
    }

    /// The Base URL field, committed on ⏎ or on losing focus.
    ///
    /// An unusable URL is *not* stored: `AppSettings.ollamaBaseURL` refuses
    /// anything but https or loopback http, so the field would silently revert.
    /// The pane says why instead (``ollamaBaseURLProblem``).
    func commitOllamaBaseURL() async {
        let trimmed = ollamaBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), OllamaConfiguration.isValidBaseURL(url) else { return }
        guard url != settings.ollamaBaseURL else { return }
        objectWillChange.send()
        settings.ollamaBaseURL = url
        await testLocalConnection()
    }

    /// Why the typed Base URL cannot be used, or `nil` when it is fine.
    var ollamaBaseURLProblem: String? {
        let trimmed = ollamaBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter the daemon's address, e.g. http://localhost:11434" }
        guard let url = URL(string: trimmed), url.scheme != nil else { return "That is not a URL." }
        return OllamaConfiguration.isValidBaseURL(url) ? nil : AIConnectionCopy.baseURLHint
    }

    /// The model tag sent to the daemon. Writing it re-checks whether it has
    /// actually been pulled.
    var ollamaModel: Binding<String> {
        Binding(
            get: { [settings] in settings.ollamaModel.id },
            set: { [weak self] newValue in
                guard let self, newValue != settings.ollamaModel.id else { return }
                objectWillChange.send()
                settings.ollamaModel = AIModel(newValue)
                Task { await self.testLocalConnection() }
            }
        )
    }

    /// **Test connection** — and the Refresh button next to the model picker.
    /// `GET /api/tags`, no key, nothing leaving the machine (ADR-068).
    func testLocalConnection() async {
        guard !isTestingLocal else { return }
        isTestingLocal = true
        defer { isTestingLocal = false }
        _ = await connection.setProvider(settings.aiProvider, ollama: settings.ollamaConfiguration)
        _ = await connection.connectLocal()
        await pullConnectionState()
        usage = await connection.monthlyUsage()
    }

    /// Tags the picker offers: whatever `/api/tags` reported, plus whatever is
    /// stored, so a model that has not been pulled yet stays selectable (and
    /// keeps saying how to pull it) instead of vanishing from its own picker.
    func availableOllamaModelIDs() -> [String] {
        var ids = models.map(\.id)
        let stored = settings.ollamaModel.id
        if !ids.contains(stored) { ids.insert(stored, at: 0) }
        return ids
    }

    // MARK: - Notes folder (FR-8.1, FR-7.1 — M4-02)

    /// Opens the library at `url`. **Nothing is moved.**
    ///
    /// The confirmation the caller shows says so in as many words, because
    /// "Change…" next to a folder path is otherwise read as "move my notes
    /// there". What actually happens is in ``AppModel/reopenLibrary(at:)``: the
    /// current library is flushed and closed, the bookmark is replaced, and the
    /// folder at `url` is opened with its own database, its own exclusions and
    /// its own restored state.
    ///
    /// - Returns: `false` when macOS refused to bookmark the folder, which is
    ///   the only way this fails without an exception.
    @discardableResult
    func changeNotesFolder(to url: URL) async -> Bool {
        guard !isChangingLibrary else { return false }
        isChangingLibrary = true
        defer { isChangingLibrary = false }
        await AppModel.shared.reopenLibrary(at: url)
        objectWillChange.send()
        reloadFolders()
        return AppSettings.notesRoot.standardizedFileURL == url.standardizedFileURL
    }

    /// FR-5.4's "rebuild the search index", from Settings → General.
    ///
    /// The index is derived data — chunks and embeddings — so this can never
    /// touch a note. Progress comes from `Indexer.statusStream()` by way of
    /// ``SemanticSearchCoordinator/indexStatus``; this only owns the
    /// disabled-while-running flag and the sentence at the end.
    func rebuildIndex() async {
        guard !isRebuildingIndex else { return }
        isRebuildingIndex = true
        defer { isRebuildingIndex = false }
        let report = await AppModel.shared.semanticSearch.rebuildAll()
        guard let report else {
            lastRebuildSummary = "The semantic index is not available in this build."
            return
        }
        let chunks = report.chunksInserted + report.chunksReused
        // Plain interpolation: `^[…](inflect:)` is only expanded inside a
        // `LocalizedStringKey` literal, and this string is shown as a `String`.
        lastRebuildSummary = "Rebuilt: \(chunks) chunk\(chunks == 1 ? "" : "s") "
            + "from \(report.notesIndexed) note\(report.notesIndexed == 1 ? "" : "s")."
    }

    // MARK: - Derived display state

    /// The library folders the exclusion picker offers, newest tree first.
    func reloadFolders() {
        folders = SettingsModel.flatten(AppModel.shared.tree)
    }

    private static func flatten(_ folder: Folder?) -> [String] {
        guard let folder else { return [] }
        var out: [String] = []
        func walk(_ node: Folder) {
            for child in node.subfolders {
                out.append(child.path)
                walk(child)
            }
        }
        walk(folder)
        return out.sorted()
    }

    /// The notes root, with `~` restored — the privacy statement quotes it.
    var notesRootDisplayPath: String {
        (AppSettings.notesRoot.path as NSString).abbreviatingWithTildeInPath
    }

    /// "Claude · connected", "Ollama · offline" (Figure 4). Every sentence in
    /// this group is a pure function of the provider, the status and the model,
    /// and lives in `AIConnectionCopy` so `swift test` can hold it to it.
    var connectionTitle: String { AIConnectionCopy.title(kind: aiProvider, status: status) }

    /// The line under the title: the model for a connected Claude, and for
    /// Ollama either "Connected · <tag> · fully private" or the shell command
    /// that fixes what is wrong.
    var connectionStatusLine: String {
        AIConnectionCopy.statusLine(kind: aiProvider, status: status, model: settings.effectiveOrganizeModel)
    }

    /// The model the connection card names, honouring the Advanced override.
    var connectionModelName: String { settings.effectiveOrganizeModel.id }

    /// FR-6.3's always-visible privacy statement, which promises more under the
    /// local provider — and can.
    var privacyStatement: String {
        AIConnectionCopy.privacyStatement(kind: aiProvider, notesPath: notesRootDisplayPath)
    }

    /// FR-4.5's row detail.
    var exclusionDetail: String { AIConnectionCopy.exclusionDetail(kind: aiProvider) }

    /// FR-6.6's line: "This month: ~N requests · ~M tokens", local work at $0.
    var usageSummary: String? { AIConnectionCopy.usageSummary(kind: aiProvider, totals: usage) }

    /// The model ids the Advanced pickers offer: whatever `/v1/models` reported,
    /// falling back to the known identifiers before a key has validated, and
    /// always including whatever is currently stored.
    func availableModelIDs() -> [String] {
        var ids = models.isEmpty ? AIModel.known.map(\.id) : models.map(\.id)
        for stored in [settings.organizeModel.id, settings.searchModel.id] where !ids.contains(stored) {
            ids.append(stored)
        }
        return ids
    }

    func displayName(forModel id: String) -> String {
        models.first { $0.id == id }?.displayName ?? id
    }
}
