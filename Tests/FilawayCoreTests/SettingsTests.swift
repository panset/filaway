import Foundation
import Testing

@testable import FilawayCore

/// A throwaway `UserDefaults` suite, removed when the test ends.
///
/// Every settings test gets its own domain, so nothing here can read or write
/// the developer's real preferences and the suites cannot collide when the
/// tests run in parallel.
final class TempDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init(_ label: String = "settings") {
        suiteName = "com.tejaspanse.filaway.tests.\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func settings(libraryKey: String = "libA") -> AppSettings {
        AppSettings(defaults: defaults, libraryKey: libraryKey)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@Suite("Settings — defaults and clamping")
struct AppSettingsDefaultsTests {

    @Test("an untouched store reports the documented defaults (Figure 4)")
    func defaults() {
        let temp = TempDefaults("defaults")
        let settings = temp.settings()

        #expect(settings.organizationMode == .askBeforeFiling)
        #expect(settings.idleInterval == 3)
        #expect(settings.idleIntervalSeconds == 180)
        #expect(settings.semanticSearchEnabled == true)
        #expect(settings.excludedFolders.isEmpty)
        #expect(settings.organizeModel == .sonnet5)
        #expect(settings.searchModel == .haiku45)
        #expect(settings.advancedModelOverride == false)
        #expect(settings.notesRootBookmark == nil)
        #expect(settings.aiConnectionSkipped == false)
        #expect(settings.usageMonthStart == nil)
    }

    @Test("the idle interval is clamped into 1…15 on the way in and out")
    func clamping() {
        let temp = TempDefaults("clamp")
        let settings = temp.settings()

        settings.idleInterval = 0
        #expect(settings.idleInterval == 1)
        settings.idleInterval = -30
        #expect(settings.idleInterval == 1)
        settings.idleInterval = 99
        #expect(settings.idleInterval == 15)
        settings.idleInterval = 7
        #expect(settings.idleInterval == 7)

        // A plist edited by hand cannot escape the range either.
        temp.defaults.set(600, forKey: AppSettings.DefaultsKey.idleIntervalMinutes)
        #expect(settings.idleInterval == 15)
        #expect(AppSettings.clampIdleInterval(4) == 4)
    }

    @Test("semantic search stays on unless it is explicitly turned off")
    func semanticDefaultIsSticky() {
        let temp = TempDefaults("semantic")
        let settings = temp.settings()

        #expect(settings.semanticSearchEnabled, "the default must not be `false` by omission")
        settings.semanticSearchEnabled = false
        #expect(!settings.semanticSearchEnabled)
        settings.semanticSearchEnabled = true
        #expect(settings.semanticSearchEnabled)
    }

    @Test("the advanced override gates which model is actually sent")
    func modelOverride() {
        let temp = TempDefaults("models")
        let settings = temp.settings()

        settings.organizeModel = .opus5
        settings.searchModel = .sonnet46
        #expect(settings.organizeModel == .opus5, "the picker keeps the choice…")
        #expect(settings.effectiveOrganizeModel == .sonnet5, "…but the default is what ships until Advanced is on")
        #expect(settings.effectiveSearchModel == .haiku45)

        settings.advancedModelOverride = true
        #expect(settings.effectiveOrganizeModel == .opus5)
        #expect(settings.effectiveSearchModel == .sonnet46)

        settings.resetModelsToDefaults()
        #expect(settings.advancedModelOverride == false)
        #expect(settings.organizeModel == .defaultOrganize)
        #expect(settings.searchModel == .defaultSearch)
    }
}

@Suite("Settings — excluded folders (FR-4.5)")
struct AppSettingsExclusionTests {

    @Test("exclusions are normalised, de-duplicated and sorted")
    func normalization() {
        let temp = TempDefaults("exclusions")
        let settings = temp.settings()

        settings.excludedFolders = ["/Personal/", "Personal", "", "  ", "Work/Confidential"]
        #expect(settings.excludedFolders == ["Personal", "Work/Confidential"])
        #expect(settings.isFolderExcluded("Personal"))
        #expect(settings.isFolderExcluded("/Personal"))
        #expect(!settings.isFolderExcluded("Personal notes"), "folder boundaries, not prefixes")
    }

    @Test("toggling one folder leaves the rest alone")
    func toggling() {
        let temp = TempDefaults("toggle")
        let settings = temp.settings()

        settings.setFolderExcluded("Personal", true)
        settings.setFolderExcluded("Commands", true)
        #expect(settings.excludedFolders == ["Commands", "Personal"])

        settings.setFolderExcluded("Commands", false)
        #expect(settings.excludedFolders == ["Personal"])

        settings.setFolderExcluded("", true)
        #expect(settings.excludedFolders == ["Personal"], "the library root is not excludable")

        settings.setFolderExcluded("Personal", false)
        #expect(settings.excludedFolders.isEmpty)
    }

    @Test("exclusions are per library, and re-pointing the key switches lists")
    func perLibrary() {
        let temp = TempDefaults("perlibrary")
        let settings = temp.settings(libraryKey: "libA")

        settings.excludedFolders = ["Personal"]
        settings.setExcludedFolders(["Work"], libraryKey: "libB")

        #expect(settings.excludedFolders == ["Personal"])
        #expect(settings.excludedFolders(libraryKey: "libB") == ["Work"])

        settings.libraryKey = "libB"
        #expect(settings.excludedFolders == ["Work"], "another notes folder never inherits the previous one's list")

        settings.libraryKey = "libC"
        #expect(settings.excludedFolders.isEmpty)
    }

    @Test("the stored list feeds ExclusionFilter unchanged")
    func feedsFilter() {
        let temp = TempDefaults("filter")
        let settings = temp.settings()
        settings.excludedFolders = ["Personal", "Work/Confidential"]

        let filter = ExclusionFilter(excludedFolders: settings.excludedFolders)
        #expect(filter.isExcluded(path: "Personal/Salary.md"))
        #expect(filter.isExcluded(path: "Work/Confidential/Deal.md"))
        #expect(!filter.isExcluded(path: "Work/Notes.md"))
    }
}

@Suite("Settings — persistence and change notifications")
struct AppSettingsPersistenceTests {

    @Test("every key round-trips through the defaults suite")
    func roundTrip() {
        let temp = TempDefaults("roundtrip")
        let bookmark = Data("a-bookmark".utf8)

        do {
            let settings = temp.settings()
            settings.organizationMode = .autoFile
            settings.idleInterval = 11
            settings.semanticSearchEnabled = false
            settings.excludedFolders = ["Personal"]
            settings.advancedModelOverride = true
            settings.organizeModel = .opus5
            settings.searchModel = .sonnet46
            settings.notesRootBookmark = bookmark
            settings.aiConnectionSkipped = true
            settings.usageMonthStart = Date(timeIntervalSince1970: 1_754_006_400)
            settings.flush()
        }

        // A second instance over the same suite is the relaunch this simulates.
        let reopened = temp.settings()
        #expect(reopened.organizationMode == .autoFile)
        #expect(reopened.idleInterval == 11)
        #expect(reopened.semanticSearchEnabled == false)
        #expect(reopened.excludedFolders == ["Personal"])
        #expect(reopened.advancedModelOverride == true)
        #expect(reopened.organizeModel == .opus5)
        #expect(reopened.searchModel == .sonnet46)
        #expect(reopened.notesRootBookmark == bookmark)
        #expect(reopened.aiConnectionSkipped == true)
        #expect(reopened.usageMonthStart == Date(timeIntervalSince1970: 1_754_006_400))
    }

    @Test("an unreadable stored value falls back to the default")
    func garbageFallsBack() {
        let temp = TempDefaults("garbage")
        temp.defaults.set("nonsense", forKey: AppSettings.DefaultsKey.organizationMode)
        temp.defaults.set("", forKey: AppSettings.DefaultsKey.organizeModel)

        let settings = temp.settings()
        #expect(settings.organizationMode == .askBeforeFiling)
        #expect(settings.organizeModel == .defaultOrganize)
    }

    @Test("resetToDefaults clears the current library only")
    func reset() {
        let temp = TempDefaults("reset")
        let settings = temp.settings(libraryKey: "libA")
        settings.organizationMode = .autoFile
        settings.idleInterval = 12
        settings.excludedFolders = ["Personal"]
        settings.setExcludedFolders(["Work"], libraryKey: "libB")

        settings.resetToDefaults()
        #expect(settings.organizationMode == .askBeforeFiling)
        #expect(settings.idleInterval == 3)
        #expect(settings.excludedFolders.isEmpty)
        #expect(settings.excludedFolders(libraryKey: "libB") == ["Work"])
    }

    @Test("observers see exactly the key that changed")
    func observers() {
        let temp = TempDefaults("observe")
        let settings = temp.settings()
        let seen = Locked<[AppSettings.Key]>([])

        let token = settings.observe { key in seen.mutate { $0.append(key) } }
        settings.idleInterval = 5
        settings.organizationMode = .autoFile
        settings.excludedFolders = ["Personal"]
        #expect(seen.value == [.idleInterval, .organizationMode, .excludedFolders])

        token.invalidate()
        settings.idleInterval = 6
        #expect(seen.value.count == 3, "an invalidated token stops delivering")
    }

    @Test("the change stream delivers live edits")
    func changeStream() async {
        let temp = TempDefaults("stream")
        let settings = temp.settings()
        var iterator = settings.changes().makeAsyncIterator()

        settings.semanticSearchEnabled = false
        settings.idleInterval = 9

        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first == .semanticSearchEnabled)
        #expect(second == .idleInterval)
    }
}

/// Minimal mutex for test bookkeeping shared with a `@Sendable` handler.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) { storage = value }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&storage)
    }
}

@Suite("AppSettings — provider (P2-02 seam)")
struct AppSettingsProviderTests {
    private func fresh() -> AppSettings {
        let suite = "filaway.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return AppSettings(defaults: defaults, libraryKey: "lib")
    }

    @Test("Claude is the default and the Advanced override stays Claude-only")
    func defaults() {
        let s = fresh()
        #expect(s.aiProvider == .claude)
        #expect(s.ollamaBaseURL == OllamaConfiguration.defaultBaseURL)
        #expect(s.ollamaModel == .defaultOllama)
        #expect(s.effectiveOrganizeModel == .defaultOrganize)

        s.aiProvider = .ollama
        #expect(s.effectiveOrganizeModel == .defaultOllama)
        #expect(s.effectiveSearchModel == .defaultOllama)
        s.advancedModelOverride = true
        s.organizeModel = .opus5
        #expect(s.effectiveOrganizeModel == .defaultOllama, "the override is a Claude concept")
        s.aiProvider = .claude
        #expect(s.effectiveOrganizeModel == .opus5)
    }

    @Test("Ollama URL and model persist, an invalid URL is ignored, blank model resets")
    func ollamaValues() {
        let s = fresh()
        let seen = Locked<[AppSettings.Key]>([])
        let token = s.observe { key in seen.mutate { $0.append(key) } }
        defer { token.invalidate() }

        s.ollamaBaseURL = URL(string: "http://127.0.0.1:11435")!
        #expect(s.ollamaBaseURL.absoluteString == "http://127.0.0.1:11435")
        s.ollamaBaseURL = URL(string: "http://example.com:11434")!
        #expect(s.ollamaBaseURL.absoluteString == "http://127.0.0.1:11435", "plain http off loopback is rejected")
        s.ollamaBaseURL = URL(string: "https://ollama.example.com")!
        #expect(s.ollamaBaseURL.host == "ollama.example.com")

        s.ollamaModel = AIModel("qwen3:8b")
        #expect(s.ollamaModel.id == "qwen3:8b")
        #expect(s.ollamaConfiguration == OllamaConfiguration(baseURL: s.ollamaBaseURL, model: AIModel("qwen3:8b")))
        s.ollamaModel = AIModel("  ")
        #expect(s.ollamaModel == .defaultOllama)

        #expect(seen.value.contains(.ollamaBaseURL))
        #expect(seen.value.contains(.ollamaModel))
        s.aiProvider = .ollama
        #expect(seen.value.last == .aiProvider)
    }
}
