import AppKit
import FilawayCore

/// Headless end-to-end check for Settings (plan §8: no Xcode ⇒ no XCTest UI
/// tests, and the screen may be locked).
///
/// Two phases, registered from `AppDelegate` alongside `SmokeDriver`'s:
///
/// | Phase | What it proves |
/// |---|---|
/// | `settings` | ⌘, opens the window; mode, interval, exclusions and the semantic toggle write through `AppSettings`; the interval clamps; `AIConnectionManager.connect` walks `notConfigured → connected → notConfigured` against the replay/mock provider. |
/// | `settings2` | Relaunch on the same defaults suite: every one of those preferences came back (FR-8.1, FR-1.5). |
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

    static func handles(phase: String) -> Bool {
        phase == "settings" || phase == "settings2"
    }

    static func start(phase: String) {
        Task { @MainActor in
            await settle(seconds: 1.0)
            switch phase {
            case "settings2": await runRelaunchPhase()
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
}
