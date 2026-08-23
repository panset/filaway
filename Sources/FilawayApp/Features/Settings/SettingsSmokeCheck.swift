import AppKit
import FilawayCore

/// Headless end-to-end check for Settings (plan §8: no Xcode ⇒ no XCTest UI
/// tests, and the screen may be locked).
///
/// Four phases, registered from `AppDelegate` alongside `SmokeDriver`'s:
///
/// | Phase | What it proves |
/// |---|---|
/// | `settings` | ⌘, opens the window; mode, interval, exclusions and the semantic toggle write through `AppSettings`; the interval clamps; `AIConnectionManager.connect` walks `notConfigured → connected → notConfigured` against the replay/mock provider. |
/// | `settings2` | Relaunch on the same defaults suite: every one of those preferences came back (FR-8.1, FR-1.5). |
/// | `settings-wiring` | M4-02: a preference reaching the *objects* — mode and model to the `Organizer` actor, the idle interval to `SessionTracker`, an exclusion to both the organizer and the index (already-indexed chunks purged), the semantic switch to ⌘K's Ask mode, and `Rebuild index` completing. |
/// | `a11y` | M4-06: a walk of the live accessibility tree — no actionable control and no visible image without a label — plus light and dark captures. |
///
/// No real key exists on this machine and none is needed: `FILAWAY_AI_MODE`
/// defaults to `replay`, and `SettingsModel` swaps in an `InMemorySecretStore`
/// for any smoke run, so the user's Keychain is never touched.
@MainActor
enum SettingsSmokeCheck {

    private static var failures = 0

    /// Values phase 1 writes and phase 2 reads back.
    private static let idleMinutes = 7
    private static let excluded = ["Personal", "Work/Confidential"]
    /// The folder `Tools/smoke.sh` seeds for the `settings-wiring` phase, so
    /// there is something indexed to purge (FR-4.5).
    private static let excludedFolder = "Personal"

    static func handles(phase: String) -> Bool {
        phase == "settings" || phase == "settings2" || phase == "settings-wiring" || phase == "a11y"
    }

    static func start(phase: String) {
        Task { @MainActor in
            await settle(seconds: 1.0)
            switch phase {
            case "settings2": await runRelaunchPhase()
            case "settings-wiring": await runWiringPhase()
            case "a11y": await runAccessibilityPhase()
            default: await runSetupPhase()
            }
        }
    }

    // MARK: - Phase: settings

    private static func runSetupPhase() async {
        let model = SettingsModel.shared
        let settings = model.settings
        header()

        // 1 — ⌘, opens the Settings scene. The scene graph may still be
        //     settling, so the action is retried until the window appears.
        var opened = false
        _ = await poll(seconds: 8) {
            opened = SettingsWindow.open() || opened
            return SettingsWindow.window != nil
        }
        check("settings-action-handled", opened)
        for window in NSApp.windows where window.contentView != nil {
            print("SMOKE window title=\"\(window.title)\" visible=\(window.isVisible) "
                + "size=\(Int(window.frame.width))x\(Int(window.frame.height))")
        }
        check("settings-window-opened", SettingsWindow.window != nil,
              SettingsWindow.window.map { "\"\($0.title)\" visible=\($0.isVisible)" } ?? "no settings window")
        check("settings-window-is-visible", SettingsWindow.window?.isVisible == true)
        capture(SettingsWindow.window, named: "settings-ai")

        // 2 — a fresh suite shows Figure 4's defaults.
        check("default-mode-is-ask", settings.organizationMode == .askBeforeFiling,
              settings.organizationMode.rawValue)
        check("default-idle-is-3", settings.idleInterval == 3, "\(settings.idleInterval)")
        check("default-semantic-is-on", settings.semanticSearchEnabled)
        check("default-exclusions-empty", settings.excludedFolders.isEmpty)
        check("default-model-is-sonnet-5", settings.effectiveOrganizeModel == .defaultOrganize,
              settings.effectiveOrganizeModel.id)

        // 3 — every Figure 4 row writes through, and the interval clamps.
        model.organizationMode.wrappedValue = .autoFile
        model.idleInterval.wrappedValue = idleMinutes
        model.semanticSearchEnabled.wrappedValue = false
        for folder in excluded { model.setFolderExcluded(folder, true) }
        model.advancedModelOverride.wrappedValue = true
        model.organizeModel.wrappedValue = AIModel.opus5.id

        check("mode-written", settings.organizationMode == .autoFile)
        check("idle-written", settings.idleInterval == idleMinutes, "\(settings.idleInterval)")
        check("semantic-written", !settings.semanticSearchEnabled)
        check("exclusions-written", settings.excludedFolders == excluded.sorted(),
              settings.excludedFolders.joined(separator: ", "))
        check("override-selects-opus", settings.effectiveOrganizeModel == .opus5,
              settings.effectiveOrganizeModel.id)

        model.idleInterval.wrappedValue = 99
        check("idle-clamps-high", settings.idleInterval == 15, "\(settings.idleInterval)")
        model.idleInterval.wrappedValue = 0
        check("idle-clamps-low", settings.idleInterval == 1, "\(settings.idleInterval)")
        model.idleInterval.wrappedValue = idleMinutes

        // 4 — a live observer sees the change, which is how the Organizer and
        //     the Indexer pick edits up without a restart.
        var observed: [CoreSettings.Key] = []
        let token = settings.observe { key in
            MainActor.assumeIsolated { observed.append(key) }
        }
        model.semanticSearchEnabled.wrappedValue = true
        check("observer-fired", observed == [.semanticSearchEnabled],
              observed.map(\.rawValue).joined(separator: ", "))
        token.invalidate()
        model.semanticSearchEnabled.wrappedValue = false

        // 5 — the connection state machine, against the replay/mock provider.
        await model.refresh()
        check("status-starts-not-connected", model.status == .notConfigured, model.status.label)
        check("no-stored-key", !model.hasStoredKey)

        let blank = await model.connect(apiKey: "   ")
        check("blank-key-rejected", blank != nil, blank.map(\.description) ?? "accepted a blank key")
        check("blank-key-not-stored", !model.hasStoredKey)

        let error = await model.connect(apiKey: "sk-ant-smoke-not-a-real-key")
        check("connect-succeeded", error == nil, error?.description ?? "")
        check("status-is-connected", model.status == .connected, model.status.label)
        check("models-listed", !model.models.isEmpty, "\(model.models.count) models")
        check("key-stored", model.hasStoredKey)
        check("card-title", model.connectionTitle == "Claude · connected", model.connectionTitle)

        await model.disconnect()
        check("status-back-to-not-connected", model.status == .notConfigured, model.status.label)
        check("key-removed", !model.hasStoredKey)

        // 6 — FR-6.3's privacy statement quotes the real root.
        check("privacy-path-is-real-root",
              model.notesRootDisplayPath.hasSuffix(AppSettings.notesRoot.lastPathComponent),
              model.notesRootDisplayPath)

        settings.flush()
        AppSettings.flush()
        finish()
    }

    // MARK: - Phase: settings2 (relaunch, FR-1.5 / FR-8.1)

    private static func runRelaunchPhase() async {
        let settings = SettingsModel.shared.settings
        header()

        check("mode-persisted", settings.organizationMode == .autoFile, settings.organizationMode.rawValue)
        check("idle-persisted", settings.idleInterval == idleMinutes, "\(settings.idleInterval)")
        check("semantic-persisted", !settings.semanticSearchEnabled)
        check("exclusions-persisted", settings.excludedFolders == excluded.sorted(),
              settings.excludedFolders.joined(separator: ", "))
        check("model-override-persisted", settings.effectiveOrganizeModel == .opus5,
              settings.effectiveOrganizeModel.id)
        check("key-did-not-persist", !(await SettingsModel.shared.connection.hasStoredKey),
              "the smoke run uses an in-memory secret store")

        // The exclusions belong to *this* library and nobody else's.
        check("exclusions-are-per-library",
              settings.excludedFolders(libraryKey: "some-other-library").isEmpty)

        finish()
    }

    // MARK: - Phase: settings-wiring (M4-02 — FR-8.1 "changes apply live")

    /// The half `settings` cannot see: a preference reaching the *objects*.
    ///
    /// `settings` proves the Figure 4 rows write through to `AppSettings`.
    /// This proves that the `Organizer` actor, the `SessionTracker`, ⌘K and the
    /// semantic index each hear about it without a relaunch — which is the
    /// whole of M4-02's wiring, and none of it is visible from `UserDefaults`.
    ///
    /// Needs a real library (the organizer is built by `bootstrap()`), so the
    /// phase opens one itself rather than waiting for a scene that a locked
    /// screen will never build.
    private static func runWiringPhase() async {
        let app = AppModel.shared
        let model = SettingsModel.shared
        let settings = model.settings
        header()

        await app.bootstrap()
        _ = await poll(seconds: 20) { app.isLoaded }
        check("library-open", app.isLoaded)
        _ = await poll(seconds: 20) { app.organize?.isReady == true }
        guard let organize = app.organize, organize.isReady else {
            check("organizer-ready", false, "the organize pipeline never came up")
            finish()
            return
        }
        check("organizer-ready", true)

        // 1 — FR-4.2's mode reaches the actor that will act on it.
        model.organizationMode.wrappedValue = .autoFile
        var probed = await pollProbe(seconds: 5) { await organize.organizerSettingsProbe()?.mode == .auto }
        check("mode-reaches-the-organizer", probed,
              (await organize.organizerSettingsProbe()?.mode.rawValue) ?? "no organizer")
        model.organizationMode.wrappedValue = .askBeforeFiling
        probed = await pollProbe(seconds: 5) { await organize.organizerSettingsProbe()?.mode == .ask }
        check("mode-change-is-live", probed)

        // 2 — FR-3.1's idle interval reaches the session timer, in seconds.
        model.idleInterval.wrappedValue = 9
        probed = await pollProbe(seconds: 5) {
            await organize.sessionConfigurationProbe()?.idleInterval == 9 * 60
        }
        check("idle-reaches-the-tracker", probed,
              (await organize.sessionConfigurationProbe().map { "\($0.idleInterval)s" }) ?? "no tracker")

        // 3 — FR-6.2: the *effective* model, not the picker's stored value.
        model.advancedModelOverride.wrappedValue = true
        model.organizeModel.wrappedValue = AIModel.opus5.id
        probed = await pollProbe(seconds: 5) { await organize.organizerSettingsProbe()?.model == .opus5 }
        check("model-override-reaches-the-organizer", probed,
              (await organize.organizerSettingsProbe()?.model.id) ?? "")
        model.resetModelsToDefaults()
        probed = await pollProbe(seconds: 5) {
            await organize.organizerSettingsProbe()?.model == .defaultOrganize
        }
        check("model-reset-is-live", probed)

        // 4 — FR-4.5's exclusions reach the organizer.
        model.setFolderExcluded(excludedFolder, true)
        probed = await pollProbe(seconds: 5) {
            await organize.organizerSettingsProbe()?.excludedFolders == [excludedFolder]
        }
        check("exclusion-reaches-the-organizer", probed,
              (await organize.organizerSettingsProbe()?.excludedFolders.joined(separator: ", ")) ?? "")

        // 5 — FR-4.5's other half: what was already indexed is purged.
        let semantic = app.semanticSearch
        _ = await poll(seconds: 60) { semantic.isReady }
        check("semantic-stack-ready", semantic.isReady, semantic.embedderDescription ?? "no embedder")
        if semantic.isReady, let metadata = app.metadata {
            // Un-exclude first so the rebuild has something to index there.
            model.setFolderExcluded(excludedFolder, false)
            await settle(seconds: 0.3)
            let report = await semantic.rebuildAll()
            check("rebuild-index-completes", report != nil,
                  report.map { "\($0.notesIndexed) notes, \($0.chunksInserted) chunks" } ?? "no report")
            let before = (try? await metadata.chunkCount(inFolder: excludedFolder)) ?? 0
            check("excluded-folder-was-indexed", before > 0, "\(before) chunks")

            model.setFolderExcluded(excludedFolder, true)
            let purged = await pollProbe(seconds: 20) {
                ((try? await metadata.chunkCount(inFolder: excludedFolder)) ?? -1) == 0
            }
            let after = (try? await metadata.chunkCount(inFolder: excludedFolder)) ?? -1
            check("excluding-purges-indexed-chunks", purged, "\(after) chunks left")
            let elsewhere = (try? await metadata.chunkCount()) ?? 0
            check("purge-left-the-rest-alone", elsewhere > 0, "\(elsewhere) chunks in the library")
        }

        // 6 — FR-8.1's semantic switch: Ask disappears and the indexer parks.
        check("ask-available-while-on", app.search.isAskAvailable)
        app.search.setMode(.semantic)
        check("ask-mode-entered", app.search.mode == .semantic, app.search.mode.rawValue)
        model.semanticSearchEnabled.wrappedValue = false
        await settle(seconds: 0.4)
        check("ask-hidden-when-off", !app.search.isAskAvailable)
        check("ask-mode-left-when-off", app.search.mode == .keyword, app.search.mode.rawValue)
        app.search.setMode(.semantic)
        check("ask-cannot-be-re-entered", app.search.mode == .keyword)
        model.semanticSearchEnabled.wrappedValue = true
        _ = await poll(seconds: 5) { app.search.isAskAvailable }
        check("ask-returns-when-on", app.search.isAskAvailable)

        settings.flush()
        AppSettings.flush()
        finish()
    }

    // MARK: - Phase: a11y (M4-06 — NFR-6, NFR-7)

    /// Walks the live accessibility tree and objects to anything VoiceOver
    /// could not announce, then renders the panes in both appearances.
    ///
    /// This is what plan §8 leaves us instead of XCTest UI tests: the tree is
    /// ordinary AppKit, and a `Settings` window is built by SwiftUI whether or
    /// not the screen is unlocked. The main window needs a scene, so it is
    /// audited when one exists and reported as skipped when it does not.
    private static func runAccessibilityPhase() async {
        header()
        auditTheAuditor()
        var opened = false
        _ = await poll(seconds: 8) {
            opened = SettingsWindow.open(tab: .general) || opened
            return SettingsWindow.window != nil
        }
        check("settings-window-opened", SettingsWindow.window != nil)

        for tab in SettingsRootView.Tab.allCases {
            SettingsTabSelection.shared.tab = tab
            // One turn of the run loop for SwiftUI to build the pane, plus a
            // beat for the async `.task` rows (Activity reads the log).
            await settle(seconds: 1.2)
            audit(SettingsWindow.window, named: "settings-\(tab.rawValue)")
            capture(SettingsWindow.window, named: "settings-\(tab.rawValue)")
        }

        // NFR-7: both appearances, captured for a human to look at later. The
        // walk itself is appearance-independent, so it runs once.
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await settle(seconds: 0.8)
            capture(SettingsWindow.window, named: "settings-\(name)")
            if let main = mainWindow() { capture(main, named: "main-\(name)") }
        }
        NSApp.appearance = nil

        if let main = mainWindow() {
            audit(main, named: "main-window")
            // The ⌘K panel is an overlay on the same window, so opening it
            // brings the search field, the mode toggle, the rows and the answer
            // card into the same tree.
            AppModel.shared.focusSearch()
            await settle(seconds: 1.0)
            audit(main, named: "search-panel")
            capture(main, named: "search-panel")
            AppModel.shared.search.close()
        } else {
            print("SMOKE info main-window-skipped — no scene (a locked screen builds no WindowGroup)")
        }

        finish()
    }

    /// A negative control, run before the real panes.
    ///
    /// "Zero findings" is only worth printing if the walk can produce one, and
    /// a check that has silently stopped looking is worse than no check. So the
    /// phase first audits a window it *knows* is broken — one bare button with
    /// no label, one labelled — and insists on exactly one finding.
    private static func auditTheAuditor() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        // A window created in code is `isReleasedWhenClosed` by default, and
        // ARC is also holding this one: closing it would free it twice.
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
        let bare = NSButton(frame: NSRect(x: 10, y: 10, width: 60, height: 24))
        bare.title = ""
        bare.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        let labelled = NSButton(frame: NSRect(x: 90, y: 10, width: 60, height: 24))
        labelled.title = ""
        labelled.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        labelled.setAccessibilityLabel("Labelled control")
        content.addSubview(bare)
        content.addSubview(labelled)
        window.contentView = content

        let report = AccessibilityAudit.audit(window: window, named: "self-check")
        check("a11y-walk-finds-an-unlabelled-button", report.findings.count == 1,
              "\(report.findings.count) findings over \(report.actionableChecked) controls")
        check("a11y-walk-accepts-a-labelled-button", report.actionableChecked >= 2,
              "\(report.actionableChecked) controls")
        window.orderOut(nil)
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.contentView != nil && $0 !== SettingsWindow.window && $0.title == "Filaway" }
    }

    /// Runs one accessibility walk and turns its findings into `check` lines —
    /// one per unlabelled control, so a regression names itself.
    @discardableResult
    private static func audit(_ window: NSWindow?, named name: String) -> AccessibilityAudit.Report {
        let report = AccessibilityAudit.audit(window: window, named: name)
        print("SMOKE info a11y-\(name) elements=\(report.elementsVisited) "
            + "controls=\(report.controlsChecked) actionable=\(report.actionableChecked) "
            + "images=\(report.imagesChecked) findings=\(report.findings.count) "
            + "roles[\(report.roleSummary)]")
        // An empty tree is not a pass — it means the walk found nothing to walk.
        check("a11y-\(name)-tree-non-empty", report.elementsVisited > 1, "\(report.elementsVisited) elements")
        for finding in report.findings {
            print("SMOKE FAIL a11y-\(name)-unlabelled — \(finding.description)")
        }
        check("a11y-\(name)-every-control-labelled", report.isClean,
              "\(report.findings.count) unlabelled")
        return report
    }

    // MARK: - Helpers

    private static func header() {
        print("SMOKE info root=\(AppSettings.notesRoot.path)")
        print("SMOKE info ai-mode=\(AIMode.current().rawValue)")
    }

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures += 1 }
        print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func finish() {
        print("SMOKE result failures=\(failures)")
        fflush(stdout)
        exit(Int32(min(failures, 120)))
    }

    /// Writes the window's rendered contents to `$FILAWAY_SMOKE_SHOTS/<name>.png`.
    ///
    /// `screencapture` needs screen-recording permission and a live session,
    /// neither of which a scripted run on a locked screen has (plan §8). Caching
    /// the view's own bitmap needs neither, so a layout regression can still be
    /// looked at by a human when they ask for it.
    private static func capture(_ window: NSWindow?, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["FILAWAY_SMOKE_SHOTS"], !directory.isEmpty,
              let view = window?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: url)
        print("SMOKE info shot=\(url.path)")
    }

    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private static func poll(seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await settle(seconds: 0.15)
        }
        return condition()
    }

    /// ``poll(seconds:until:)`` for a condition that has to await an actor —
    /// every probe on `OrganizeCoordinator` and `MetadataStore` does.
    private static func pollProbe(
        seconds: Double, until condition: @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            await settle(seconds: 0.15)
        }
        return await condition()
    }
}
