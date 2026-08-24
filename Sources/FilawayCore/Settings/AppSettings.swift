import Foundation

/// Every user-facing preference of FR-8.1, in one typed, observable place.
///
/// Backed by `UserDefaults` — the suite is injected, so tests run against a
/// throwaway domain and `Tools/smoke.sh` can relaunch the app against persisted
/// state and then delete the whole plist (`FILAWAY_DEFAULTS_SUITE`).
///
/// Three properties of the design matter:
///
/// * **Typed, clamped accessors.** Nothing above this reads a raw defaults key,
///   and no out-of-range value can be stored: `idleInterval` is clamped into
///   ``idleIntervalRange`` on the way in *and* on the way out, so a plist edited
///   by hand cannot make the organizer fire every 300 minutes.
/// * **Per-library where it should be.** Excluded folders (FR-4.5) are relative
///   paths inside one notes folder, so they are keyed by ``Library/key``: point
///   the app at a different root and it does not inherit the previous library's
///   exclusions. Everything else is global to the app.
/// * **Live change notifications, Combine-free.** ``observe(_:)`` and
///   ``changes()`` let the Organizer, `SessionTracker` and the `Indexer` pick up
///   mode, interval and exclusion edits without a restart and without
///   `FilawayCore` importing Combine or SwiftUI.
///
/// ```swift
/// let settings = AppSettings(defaults: .standard, libraryKey: library.key)
/// settings.idleInterval = 42          // stored as 15 — the ceiling
/// let token = settings.observe { key in if key == .idleInterval { rearm() } }
/// ```
public final class AppSettings: @unchecked Sendable {

    /// Which preference changed. Observers switch over this rather than
    /// re-reading everything.
    public enum Key: String, Sendable, Hashable, CaseIterable {
        case organizationMode
        case idleInterval
        case semanticSearchEnabled
        case excludedFolders
        case organizeModel
        case searchModel
        case advancedModelOverride
        case notesRootBookmark
        case onboardingCompleted
        case aiConnectionSkipped
        case pasteIntelligenceEnabled
        case usageMonthStart
        case aiProvider
        case ollamaBaseURL
        case ollamaModel
    }

    /// Cancels an ``AppSettings/observe(_:)`` registration. Dropping it is
    /// enough — `deinit` unregisters.
    public final class Observation: Sendable {
        private let cancel: @Sendable () -> Void
        init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
        deinit { cancel() }
        /// Unregisters early.
        public func invalidate() { cancel() }
    }

    // MARK: - Storage

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var observers: [UUID: @Sendable (Key) -> Void] = [:]
    private var _libraryKey: String

    /// - Parameters:
    ///   - defaults: the backing suite. Inject a throwaway one in tests.
    ///   - libraryKey: ``Library/key`` of the open notes folder — the scope of
    ///     the per-library values.
    public init(defaults: UserDefaults = .standard, libraryKey: String = "") {
        self.defaults = defaults
        _libraryKey = libraryKey
    }

    /// The library the per-library accessors read and write.
    ///
    /// Changing it (M4-01's "change notes folder") re-points ``excludedFolders``
    /// without touching the previous library's stored list.
    public var libraryKey: String {
        get { lock.withLock { _libraryKey } }
        set {
            lock.withLock { _libraryKey = newValue }
            notify(.excludedFolders)
        }
    }

    // MARK: - Defaults key names

    /// The raw `UserDefaults` key names. `internal` on purpose: everything
    /// outside goes through the typed accessors.
    enum DefaultsKey {
        static let organizationMode = "organize.mode"
        static let idleIntervalMinutes = "organize.idleMinutes"
        static let semanticSearchEnabled = "search.semanticEnabled"
        static let organizeModel = "ai.model.organize"
        static let searchModel = "ai.model.search"
        static let advancedModelOverride = "ai.model.advancedOverride"
        static let notesRootBookmark = "library.rootBookmark"
        static let onboardingCompleted = "onboarding.completed"
        static let aiConnectionSkipped = "ai.connectionSkipped"
        static let pasteIntelligenceEnabled = "editor.pasteIntelligence"
        static let usageMonthStart = "ai.usageMonthStart"
        static let aiProvider = "ai.provider"
        static let ollamaBaseURL = "ai.ollama.baseURL"
        static let ollamaModel = "ai.ollama.model"

        static func excludedFolders(_ libraryKey: String) -> String { "ai.excludedFolders.\(libraryKey)" }
    }

    // MARK: - Organization (FR-4.2, FR-8.1)

    /// Ask before filing (default) or file automatically.
    public var organizationMode: OrganizationMode {
        get {
            defaults.string(forKey: DefaultsKey.organizationMode)
                .flatMap(OrganizationMode.init(rawValue:)) ?? Self.defaultOrganizationMode
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.organizationMode)
            notify(.organizationMode)
        }
    }

    /// Minutes of writing inactivity that end a session (FR-3.1, Figure 4's
    /// "Auto-organize after idle"). Always inside ``idleIntervalRange``.
    public var idleInterval: Int {
        get {
            guard defaults.object(forKey: DefaultsKey.idleIntervalMinutes) != nil else {
                return Self.defaultIdleInterval
            }
            return Self.clampIdleInterval(defaults.integer(forKey: DefaultsKey.idleIntervalMinutes))
        }
        set {
            defaults.set(Self.clampIdleInterval(newValue), forKey: DefaultsKey.idleIntervalMinutes)
            notify(.idleInterval)
        }
    }

    /// ``idleInterval`` as a `TimeInterval`, which is what the session timer wants.
    public var idleIntervalSeconds: TimeInterval { TimeInterval(idleInterval) * 60 }

    // MARK: - Search (FR-5.1, FR-8.1)

    /// Semantic search on/off. Keyword search is never affected (FR-5.5).
    public var semanticSearchEnabled: Bool {
        get {
            guard defaults.object(forKey: DefaultsKey.semanticSearchEnabled) != nil else {
                return Self.defaultSemanticSearchEnabled
            }
            return defaults.bool(forKey: DefaultsKey.semanticSearchEnabled)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.semanticSearchEnabled)
            notify(.semanticSearchEnabled)
        }
    }

    // MARK: - Excluded folders (FR-4.5) — per library

    /// Relative folder paths never sent to the provider, for the current
    /// ``libraryKey``. Normalised, de-duplicated and sorted on write; the value
    /// feeds `ExclusionFilter` unchanged.
    public var excludedFolders: [String] {
        get { excludedFolders(libraryKey: libraryKey) }
        set { setExcludedFolders(newValue, libraryKey: libraryKey) }
    }

    public func excludedFolders(libraryKey: String) -> [String] {
        defaults.stringArray(forKey: DefaultsKey.excludedFolders(libraryKey)) ?? []
    }

    public func setExcludedFolders(_ folders: [String], libraryKey: String) {
        let cleaned = Self.normalizeExclusions(folders)
        let key = DefaultsKey.excludedFolders(libraryKey)
        if cleaned.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(cleaned, forKey: key)
        }
        notify(.excludedFolders)
    }

    /// Adds or removes one folder from the current library's exclusions.
    public func setFolderExcluded(_ folderPath: String, _ excluded: Bool) {
        var current = Set(excludedFolders)
        let normalized = Self.normalizeFolder(folderPath)
        guard !normalized.isEmpty else { return }
        if excluded { current.insert(normalized) } else { current.remove(normalized) }
        excludedFolders = Array(current)
    }

    public func isFolderExcluded(_ folderPath: String) -> Bool {
        excludedFolders.contains(Self.normalizeFolder(folderPath))
    }

    // MARK: - Models (FR-6.2)

    /// Model used for organization plans. `claude-sonnet-5` unless the user
    /// picked something else under Advanced.
    public var organizeModel: AIModel {
        get { storedModel(DefaultsKey.organizeModel) ?? .defaultOrganize }
        set {
            defaults.set(newValue.id, forKey: DefaultsKey.organizeModel)
            notify(.organizeModel)
        }
    }

    /// Model used for search answer extraction. `claude-haiku-4-5` by default.
    public var searchModel: AIModel {
        get { storedModel(DefaultsKey.searchModel) ?? .defaultSearch }
        set {
            defaults.set(newValue.id, forKey: DefaultsKey.searchModel)
            notify(.searchModel)
        }
    }

    /// `true` while the Advanced disclosure's model pickers are in charge.
    /// When `false`, ``effectiveOrganizeModel`` / ``effectiveSearchModel``
    /// ignore whatever is stored and use the house defaults.
    public var advancedModelOverride: Bool {
        get { defaults.bool(forKey: DefaultsKey.advancedModelOverride) }
        set {
            defaults.set(newValue, forKey: DefaultsKey.advancedModelOverride)
            notify(.advancedModelOverride)
        }
    }

    /// What the organizer should actually send.
    ///
    /// Under Ollama the model is ``ollamaModel`` — the Advanced override is a
    /// Claude-only concept (FR-6.2, FR-6.5).
    public var effectiveOrganizeModel: AIModel {
        switch aiProvider {
        case .ollama: return ollamaModel
        case .claude: return advancedModelOverride ? organizeModel : .defaultOrganize
        }
    }

    /// What search answer extraction should actually send.
    public var effectiveSearchModel: AIModel {
        switch aiProvider {
        case .ollama: return ollamaModel
        case .claude: return advancedModelOverride ? searchModel : .defaultSearch
        }
    }

    // MARK: - Provider (FR-6.5, NFR-5)

    /// Which provider the organizer and the answer card talk to. Claude unless
    /// the user picked the local model; `FILAWAY_AI_PROVIDER` overrides both
    /// (`AIProviderKind.fromEnvironment`) and is applied by the app's factory,
    /// not here — this is the stored preference.
    public var aiProvider: AIProviderKind {
        get {
            guard let raw = defaults.string(forKey: DefaultsKey.aiProvider),
                  let kind = AIProviderKind(rawValue: raw) else { return .claude }
            return kind
        }
        set {
            defaults.set(newValue.rawValue, forKey: DefaultsKey.aiProvider)
            notify(.aiProvider)
        }
    }

    /// The Ollama daemon. Stored only when it is a valid base URL
    /// (`OllamaConfiguration.isValidBaseURL` — plain `http` on loopback only);
    /// an invalid one is ignored and the previous value stays.
    public var ollamaBaseURL: URL {
        get {
            guard let raw = defaults.string(forKey: DefaultsKey.ollamaBaseURL),
                  let url = URL(string: raw), OllamaConfiguration.isValidBaseURL(url)
            else { return OllamaConfiguration.defaultBaseURL }
            return url
        }
        set {
            guard OllamaConfiguration.isValidBaseURL(newValue) else { return }
            defaults.set(newValue.absoluteString, forKey: DefaultsKey.ollamaBaseURL)
            notify(.ollamaBaseURL)
        }
    }

    /// The Ollama model tag (`llama3.1:8b` by default). Blank resets to the
    /// default.
    public var ollamaModel: AIModel {
        get { storedModel(DefaultsKey.ollamaModel) ?? OllamaConfiguration.defaultModel }
        set {
            let id = newValue.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty { defaults.removeObject(forKey: DefaultsKey.ollamaModel) }
            else { defaults.set(id, forKey: DefaultsKey.ollamaModel) }
            notify(.ollamaModel)
        }
    }

    /// The provider's connection settings as the factory wants them.
    public var ollamaConfiguration: OllamaConfiguration {
        OllamaConfiguration(baseURL: ollamaBaseURL, model: ollamaModel)
    }

    /// Resets both pickers to the house defaults and turns the override off.
    public func resetModelsToDefaults() {
        defaults.removeObject(forKey: DefaultsKey.organizeModel)
        defaults.removeObject(forKey: DefaultsKey.searchModel)
        defaults.set(false, forKey: DefaultsKey.advancedModelOverride)
        notify(.organizeModel)
        notify(.searchModel)
        notify(.advancedModelOverride)
    }

    // MARK: - Notes folder (FR-7.1, FR-8.1)

    /// Security-scoped bookmark for the notes folder, or `nil` while the app is
    /// still on the `~/Notes` default (NFR-5: the root need not be on the boot
    /// volume). M4-01's picker writes it; M4-02's "Change…" replaces it.
    public var notesRootBookmark: Data? {
        get { defaults.data(forKey: DefaultsKey.notesRootBookmark) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: DefaultsKey.notesRootBookmark)
            } else {
                defaults.removeObject(forKey: DefaultsKey.notesRootBookmark)
            }
            notify(.notesRootBookmark)
        }
    }

    // MARK: - Onboarding (FR-7.1)

    /// `false` until the first-run flow has been walked to the end (or skipped
    /// out of). The launch gate in `AppDelegate` reads it; nothing else should.
    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: DefaultsKey.onboardingCompleted) }
        set {
            defaults.set(newValue, forKey: DefaultsKey.onboardingCompleted)
            notify(.onboardingCompleted)
        }
    }

    /// `true` once the user has walked past "Connect your AI" without a key.
    /// Drives the persistent, gentle prompt rather than a modal nag.
    public var aiConnectionSkipped: Bool {
        get { defaults.bool(forKey: DefaultsKey.aiConnectionSkipped) }
        set {
            defaults.set(newValue, forKey: DefaultsKey.aiConnectionSkipped)
            notify(.aiConnectionSkipped)
        }
    }

    // MARK: - Editor (FR-2.4)

    /// Paste intelligence: offer to wrap a pasted command or snippet in a code
    /// block. On by default; the offer is a transient affordance, never a modal,
    /// so the switch exists for people who want *no* interruption at all.
    public var pasteIntelligenceEnabled: Bool {
        get {
            guard defaults.object(forKey: DefaultsKey.pasteIntelligenceEnabled) != nil else {
                return Self.defaultPasteIntelligenceEnabled
            }
            return defaults.bool(forKey: DefaultsKey.pasteIntelligenceEnabled)
        }
        set {
            defaults.set(newValue, forKey: DefaultsKey.pasteIntelligenceEnabled)
            notify(.pasteIntelligenceEnabled)
        }
    }

    // MARK: - Usage (FR-6.6)

    /// Start of the month the usage line is reporting. The ledger is the source
    /// of truth for the numbers; this only exists so the UI can tell that the
    /// month rolled over and refresh without polling.
    public var usageMonthStart: Date? {
        get {
            let stored = defaults.double(forKey: DefaultsKey.usageMonthStart)
            return stored > 0 ? Date(timeIntervalSince1970: stored) : nil
        }
        set {
            if let newValue {
                defaults.set(newValue.timeIntervalSince1970, forKey: DefaultsKey.usageMonthStart)
            } else {
                defaults.removeObject(forKey: DefaultsKey.usageMonthStart)
            }
            notify(.usageMonthStart)
        }
    }

    // MARK: - Change notifications

    /// Registers a change handler. Keep the returned token alive for as long as
    /// the handler should run.
    ///
    /// Handlers are called synchronously on whichever thread performed the
    /// write, outside the lock, so a handler may read `self` freely.
    public func observe(_ handler: @escaping @Sendable (Key) -> Void) -> Observation {
        let id = UUID()
        lock.withLock { observers[id] = handler }
        return Observation { [weak self] in
            self?.lock.withLock { _ = self?.observers.removeValue(forKey: id) }
        }
    }

    /// Every subsequent change, as a stream. One stream per subscriber;
    /// cancelling the iterating task unsubscribes.
    public func changes() -> AsyncStream<Key> {
        let (stream, continuation) = AsyncStream<Key>.makeStream(bufferingPolicy: .unbounded)
        let token = observe { key in continuation.yield(key) }
        continuation.onTermination = { _ in token.invalidate() }
        return stream
    }

    private func notify(_ key: Key) {
        let handlers = lock.withLock { Array(observers.values) }
        for handler in handlers { handler(key) }
    }

    // MARK: - Maintenance

    /// Forces preferences to disk. Called on the terminate path, where the
    /// process may exit before the periodic flush.
    public func flush() {
        defaults.synchronize()
    }

    /// Restores every preference this type owns to its default, for the current
    /// library. Used by tests and by "Reset settings" in a later milestone.
    public func resetToDefaults() {
        for key in [
            DefaultsKey.organizationMode, DefaultsKey.idleIntervalMinutes,
            DefaultsKey.semanticSearchEnabled, DefaultsKey.organizeModel,
            DefaultsKey.searchModel, DefaultsKey.advancedModelOverride,
            DefaultsKey.notesRootBookmark, DefaultsKey.aiConnectionSkipped,
            DefaultsKey.onboardingCompleted, DefaultsKey.pasteIntelligenceEnabled,
            DefaultsKey.usageMonthStart, DefaultsKey.excludedFolders(libraryKey),
        ] {
            defaults.removeObject(forKey: key)
        }
        for key in Key.allCases { notify(key) }
    }

    // MARK: - Defaults and limits

    public static let defaultOrganizationMode = OrganizationMode.askBeforeFiling
    /// Figure 4's "3 min".
    public static let defaultIdleInterval = 3
    /// FR-3.1's tuning range. One minute is the smallest interval that is not
    /// effectively "after every pause"; fifteen is past the point where a
    /// session stops resembling one piece of work.
    public static let idleIntervalRange = 1 ... 15
    public static let defaultSemanticSearchEnabled = true
    /// FR-2.4 is a SHOULD and the offer is cheap to ignore, so it ships on.
    public static let defaultPasteIntelligenceEnabled = true

    public static func clampIdleInterval(_ minutes: Int) -> Int {
        min(max(minutes, idleIntervalRange.lowerBound), idleIntervalRange.upperBound)
    }

    /// Folder paths, normalised, de-duplicated, sorted, with empties dropped.
    static func normalizeExclusions(_ folders: [String]) -> [String] {
        var seen: Set<String> = []
        for folder in folders {
            let normalized = normalizeFolder(folder)
            guard !normalized.isEmpty else { continue }
            seen.insert(normalized)
        }
        return seen.sorted()
    }

    /// ``PathRules/normalize(_:)`` plus a trim: a whitespace-only string is a
    /// path with one component as far as `PathRules` is concerned, and a folder
    /// named `"  "` is never what the user meant.
    static func normalizeFolder(_ folderPath: String) -> String {
        PathRules.normalize(folderPath.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func storedModel(_ key: String) -> AIModel? {
        guard let id = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !id.isEmpty else { return nil }
        return AIModel(id)
    }
}

/// Disambiguating alias for the app target.
///
/// `FilawayApp` has its own `AppSettings` — window frame, sidebar width,
/// last-open note — which shadows this one inside that module, and the obvious
/// escape hatch does not work: `FilawayCore.AppSettings` resolves `FilawayCore`
/// to the *enum* of that name (`FilawayCore.version`, `.subsystem`) before it
/// resolves the module. So the app spells this type `CoreSettings`.
public typealias CoreSettings = AppSettings

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
