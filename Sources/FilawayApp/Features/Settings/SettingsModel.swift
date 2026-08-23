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
    /// Library folders offered by the exclusion picker (FR-4.5).
    @Published private(set) var folders: [String] = []
    @Published private(set) var isRefreshing = false

    private var statusTask: Task<Void, Never>?

    init(
        settings: CoreSettings? = nil,
        connection: AIConnectionManager? = nil
    ) {
        let library = Library(root: AppSettings.notesRoot, supportRoot: AppSettings.supportRoot)
        self.settings = settings ?? CoreSettings(defaults: AppSettings.defaults, libraryKey: library.key)
        self.connection = connection ?? SettingsModel.makeConnection(library: library)
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
    private static func makeConnection(library: Library) -> AIConnectionManager {
        if AppSettings.isSmokeRun {
            return AIConnectionManager(secrets: InMemorySecretStore(), ledger: try? AIUsageLedger(library: library))
        }
        return AIConnectionManager(library: library)
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

    /// Called when the window appears: re-check the stored key and reload the
    /// usage line, so neither is stale.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        hasStoredKey = await connection.hasStoredKey
        if hasStoredKey {
            _ = await connection.refresh()
        } else {
            status = await connection.status
        }
        models = await connection.models
        usage = await connection.monthlyUsage()
        reloadFolders()
    }

    /// Validates and stores a key. Returns `nil` on success, the error otherwise.
    func connect(apiKey: String) async -> AIError? {
        switch await connection.connect(apiKey: apiKey) {
        case let .success(models):
            self.models = models
            hasStoredKey = true
            status = await connection.status
            usage = await connection.monthlyUsage()
            return nil
        case let .failure(error):
            status = await connection.status
            return error
        }
    }

    func disconnect() async {
        await connection.disconnect()
        models = []
        hasStoredKey = false
        status = await connection.status
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

    /// "Claude · connected" and friends (Figure 4).
    var connectionTitle: String {
        switch status {
        case .connected: return "Claude · connected"
        case .notConfigured: return "Claude · not connected"
        case .invalidKey: return "Claude · invalid key"
        case .offline: return "Claude · offline"
        case .rateLimited: return "Claude · rate limited"
        case .error: return "Claude · unavailable"
        }
    }

    /// The model the connection card names, honouring the Advanced override.
    var connectionModelName: String { settings.effectiveOrganizeModel.id }

    /// FR-6.6's line: "This month: ~N requests · ~M tokens".
    var usageSummary: String? {
        guard let usage else { return nil }
        guard usage.requests > 0 else { return "This month: no requests yet" }
        return "This month: ~\(usage.requests.formatted()) request"
            + (usage.requests == 1 ? "" : "s")
            + " · ~\(usage.totalTokens.formatted()) tokens"
    }

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
