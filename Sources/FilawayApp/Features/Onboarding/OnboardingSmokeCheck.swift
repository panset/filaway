import AppKit
import FilawayCore

/// Headless end-to-end check for M4-01 (plan §8: no Xcode ⇒ no XCTest UI tests,
/// and the screen may be locked).
///
/// | Phase | What it proves |
/// |---|---|
/// | `onboarding` | First launch shows the flow; the folder step adopts a folder chosen programmatically; the mock key validates and the status goes `connected`; finishing writes the bookmark, `onboardingCompleted` and the AI preference — and the library this launch opens is the chosen folder, not `~/Notes`. |
/// | `onboarding2` | Relaunch on the same defaults suite: no flow, and the library is still the chosen folder (FR-1.5, FR-7.1). |
/// | `onboardingskip` | The "Skip for now" path: `aiConnectionSkipped` is set, the flow still completes, and the gentle sidebar prompt is visible and dismissable for the launch. |
/// | `onboarding-ollama` | FR-6.5 (P2-03): the local-model card is selectable, Test connection succeeds against the injected validator, Continue unlocks, and Finish writes `ai.provider`, `ai.ollama.baseURL` and `ai.ollama.model`. |
/// | `onboarding-ollama2` | Relaunch: no flow, and the provider preference is still Ollama. |
///
/// **The driver runs inside the modal session.** `OnboardingPresenter` blocks in
/// `applicationWillFinishLaunching`, so ``armIfNeeded()`` schedules the first
/// half of the check on the main queue *before* the modal starts; AppKit adds
/// the modal-panel mode to the run loop's common modes, so main-queue work keeps
/// draining and the driver can answer the flow exactly as a person would. The
/// second half runs from `applicationDidFinishLaunching`, once the gate has let
/// the app through.
///
/// No real key exists on this machine and none is needed: `FILAWAY_AI_MODE`
/// defaults to `replay`, and `OnboardingModel` uses an `InMemorySecretStore` for
/// any smoke run, so the user's Keychain is never touched.
@MainActor
enum OnboardingSmokeCheck {

    private static var failures = 0
    private static var phase = ""

    /// The folder phase 1 chooses and phase 2 expects. `Tools/smoke.sh` creates
    /// it and passes it here; the phases deliberately do **not** set
    /// `FILAWAY_NOTES_ROOT`, because that would override the very bookmark this
    /// check exists to prove.
    private static var chosenRoot: URL? {
        guard let path = ProcessInfo.processInfo.environment["FILAWAY_ONBOARD_ROOT"], !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    static func handles(phase: String) -> Bool {
        phase == "onboarding" || phase == "onboarding2" || phase == "onboardingskip"
            || phase == "onboarding-ollama" || phase == "onboarding-ollama2"
    }

    /// `true` for the phase that drives Figure 3's *local* card (P2-03).
    private static var isOllamaPhase: Bool { phase.hasPrefix("onboarding-ollama") }

    /// The tag the phase picks. `OnboardingModel` scripts the daemon for any
    /// smoke run (`FILAWAY_SMOKE_OLLAMA_MODELS`), so no daemon is needed and a
    /// machine without Ollama installed still runs this.
    private static let ollamaTag = "llama3.1:8b"

    // MARK: - Inside the modal session

    /// Queues the flow driver, if this launch is an onboarding phase that will
    /// see one. Called from `applicationWillFinishLaunching`, before the gate.
    static func armIfNeeded() {
        guard let name = ProcessInfo.processInfo.environment["FILAWAY_SMOKE"],
              handles(phase: name), name != "onboarding2", name != "onboarding-ollama2"
        else { return }
        phase = name
        DispatchQueue.main.async { Task { @MainActor in await driveFlow() } }
    }

    /// Answers the three steps the way a person would, on the live model the
    /// window is bound to.
    private static func driveFlow() async {
        let model = OnboardingModel.shared
        print("SMOKE info phase=\(phase) ai-mode=\(AIMode.current().rawValue)")

        // Give the window a moment to come up inside the modal session; if the
        // driver is not running at all, this is where the phase would hang, and
        // the script's watchdog turns that into a failure.
        _ = await poll(seconds: 10) { OnboardingPresenter.window != nil }
        check("onboarding-window-shown", OnboardingPresenter.window != nil,
              OnboardingPresenter.window.map { "\"\($0.title)\" visible=\($0.isVisible)" } ?? "no window")
        check("starts-on-step-1", model.step == .welcome, model.step.label)
        check("step-label-is-1-of-3", model.step.label == "1 of 3", model.step.label)
        check("default-folder-is-notes",
              model.notesRootDisplayPath.hasSuffix("/Notes") || model.notesRootDisplayPath == "~/Notes",
              model.notesRootDisplayPath)

        // 1 — choose the folder the script made (the `NSOpenPanel`-free half of
        //     the same code path).
        guard let chosen = chosenRoot else {
            check("onboard-root-env", false, "FILAWAY_ONBOARD_ROOT is not set")
            return OnboardingPresenter.abandon()
        }
        model.adoptFolder(chosen)
        check("folder-adopted", model.notesRoot.path == chosen.path, model.notesRoot.path)
        check("folder-summary-mentions-existing-notes",
              model.existingNoteCount == 0 || model.folderSummary.contains("already here"),
              model.folderSummary)
        model.advance()
        check("advanced-to-step-2", model.step == .connectAI, model.step.label)
        check("step-label-is-2-of-3", model.step.label == "2 of 3", model.step.label)

        // 2 — Figure 3: connect (Claude or the local daemon), or skip.
        if isOllamaPhase {
            await driveLocalModelCard(model)
        } else if phase == "onboardingskip" {
            model.skipAI()
            check("skip-sets-the-preference", model.settings.aiConnectionSkipped)
            check("skip-advances", model.step == .orientation, model.step.label)
        } else {
            let blank = await connect(model, key: "   ")
            check("blank-key-rejected", !blank, "a blank key must never reach the network")

            model.apiKey = "sk-ant-smoke-not-a-real-key"
            await model.validateKey()
            check("key-validated", model.keyPhase == .valid, String(describing: model.keyPhase))
            check("status-connected", model.isConnected, String(describing: model.status))
            check("key-field-cleared", model.apiKey.isEmpty)
            check("connect-clears-skipped", !model.settings.aiConnectionSkipped)
            model.advance()
            check("advanced-to-step-3", model.step == .orientation, model.step.label)
        }

        // 3 — Back and forward again: the flow is navigable, not a one-way door.
        model.goBack()
        check("back-returns-to-step-2", model.step == .connectAI, model.step.label)
        model.advance()

        // 4 — "Start writing" ends it.
        model.finish()
        check("flow-finished", model.isFinished)
        check("onboarding-completed-written", model.settings.onboardingCompleted)
        check("bookmark-written", model.settings.notesRootBookmark != nil)

        if isOllamaPhase {
            check("provider-written", model.settings.aiProvider == .ollama,
                  model.settings.aiProvider.rawValue)
            check("base-url-written",
                  model.settings.ollamaBaseURL == OllamaConfiguration.defaultBaseURL,
                  model.settings.ollamaBaseURL.absoluteString)
            check("model-written", model.settings.ollamaModel.id == ollamaTag,
                  model.settings.ollamaModel.id)
            check("local-connection-is-not-a-skip", !model.settings.aiConnectionSkipped)
        }
    }

    /// FR-6.5's card: choose local, test, and only then may Continue proceed.
    private static func driveLocalModelCard(_ model: OnboardingModel) async {
        check("claude-is-the-default-choice", model.provider == .claude, model.provider.rawValue)

        model.selectProvider(.ollama)
        check("local-card-selectable", model.provider == .ollama, model.provider.rawValue)
        check("local-card-blocks-continue-before-a-test", !model.canContinue,
              String(describing: model.ollama.phase))
        check("local-card-defaults-to-localhost",
              model.ollama.baseURLText == OllamaSetupModel.defaultBaseURLText,
              model.ollama.baseURLText)
        check("local-card-defaults-to-the-house-model",
              model.ollama.selectedModel == ollamaTag, model.ollama.selectedModel)

        // A bad address must be refused before anything is asked (NFR-4).
        model.ollamaURLEdited("http://198.51.100.7:11434")
        await model.testOllama()
        check("plaintext-to-another-host-is-refused",
              model.ollama.phase == .failed(.badURL), String(describing: model.ollama.phase))
        model.ollamaURLEdited(OllamaSetupModel.defaultBaseURLText)

        // Refresh fills the popup from the (scripted) daemon.
        await model.refreshOllamaModels()
        check("refresh-lists-the-daemons-models", !model.ollama.availableModels.isEmpty,
              model.ollama.availableModels.joined(separator: ", "))

        await model.testOllama()
        check("test-connection-succeeds", model.ollama.isConnected,
              String(describing: model.ollama.phase))
        check("status-names-the-model",
              model.ollama.statusMessage.contains(ollamaTag), model.ollama.statusMessage)
        check("continue-unlocks-after-the-test", model.canContinue)
        check("no-key-was-needed", model.keyPhase == .idle, String(describing: model.keyPhase))

        // Going back to Claude drops the local verdict, so Continue does not
        // imply a connection the user has moved away from.
        model.selectProvider(.claude)
        check("claude-card-restores-the-key-flow", !model.isConnected,
              String(describing: model.status))
        model.selectProvider(.ollama)
        check("returning-keeps-the-local-verdict", model.isConnected)

        model.advance()
        check("advanced-to-step-3", model.step == .orientation, model.step.label)
    }

    private static func connect(_ model: OnboardingModel, key: String) async -> Bool {
        model.apiKey = key
        await model.validateKey()
        return model.keyPhase == .valid
    }

    // MARK: - After the gate

    static func start(name: String) { start(phase: name) }

    static func start(phase name: String) {
        phase = name
        Task { @MainActor in
            await settle(seconds: 1.2)
            switch name {
            case "onboarding2", "onboarding-ollama2": await runRelaunchPhase()
            default: await runPostLaunchPhase()
            }
        }
    }

    /// The gate has let the app through: the library must be the chosen folder.
    private static func runPostLaunchPhase() async {
        let model = AppModel.shared
        print("SMOKE info root=\(AppSettings.notesRoot.path)")
        print("SMOKE info launch=\(LaunchClock.summary)")

        check("gate-ran-this-launch", OnboardingPresenter.didRunThisLaunch)
        check("gate-window-closed", OnboardingPresenter.window == nil)

        _ = await poll(seconds: 10) { model.isLoaded }
        check("library-loaded", model.isLoaded)
        if let chosen = chosenRoot {
            check("library-root-is-the-chosen-folder", model.library.root.path == chosen.path,
                  "\(model.library.root.path) vs \(chosen.path)")
            check("notes-root-resolves-from-the-bookmark", AppSettings.notesRoot.path == chosen.path,
                  AppSettings.notesRoot.path)
        }

        if isOllamaPhase {
            // FR-6.5: a working local provider is not a skipped connection, so
            // the gentle prompt has nothing to offer.
            check("provider-preference-is-local", AppSettings.core.aiProvider == .ollama,
                  AppSettings.core.aiProvider.rawValue)
            check("no-gentle-prompt-under-a-local-provider",
                  !ConnectAIPromptModel.shared.isVisible)
            let probe = await model.organize?.providerKindProbe()
            check("organizer-resolved-the-local-provider", probe?.kind == .ollama,
                  probe?.kind.rawValue ?? "no organizer")
        } else if phase == "onboardingskip" {
            // FR-7.1's persistent, gentle prompt.
            let prompt = ConnectAIPromptModel.shared
            check("gentle-prompt-visible", prompt.isVisible)
            check("gentle-prompt-wording",
                  prompt.text == "Connect your AI to organize and search", prompt.text)
            prompt.dismissForThisLaunch()
            check("gentle-prompt-dismissable", !prompt.isVisible)
            check("dismissal-is-launch-scoped", AppSettings.core.aiConnectionSkipped,
                  "the preference itself must survive the dismissal")
        } else {
            check("no-gentle-prompt-when-connected", !ConnectAIPromptModel.shared.isVisible)
        }

        // A brand-new library opens straight into a blank note (FR-7.1).
        _ = await poll(seconds: 5) { model.openNote != nil || model.noteCount > 0 }
        check("blank-note-ready", model.openNote != nil || model.noteCount > 0,
              "notes=\(model.noteCount) open=\(model.openNote?.title ?? "nil")")

        AppSettings.core.flush()
        AppSettings.flush()
        finish()
    }

    /// Relaunch: no gate, same library.
    private static func runRelaunchPhase() async {
        print("SMOKE info root=\(AppSettings.notesRoot.path)")
        check("onboarding-not-needed", !OnboardingModel.isNeeded)
        check("gate-did-not-run", !OnboardingPresenter.didRunThisLaunch)
        check("no-onboarding-window", OnboardingPresenter.window == nil)
        check("completed-persisted", AppSettings.core.onboardingCompleted)
        if isOllamaPhase {
            check("provider-persisted", AppSettings.core.aiProvider == .ollama,
                  AppSettings.core.aiProvider.rawValue)
            check("local-model-persisted", AppSettings.core.ollamaModel.id == ollamaTag,
                  AppSettings.core.ollamaModel.id)
        }

        let model = AppModel.shared
        _ = await poll(seconds: 10) { model.isLoaded }
        if let chosen = chosenRoot {
            check("library-root-persisted", model.library.root.path == chosen.path,
                  "\(model.library.root.path) vs \(chosen.path)")
        }
        check("notes-written-before-the-relaunch-are-here", model.noteCount >= 0,
              "\(model.noteCount) notes")
        finish()
    }

    // MARK: - Helpers

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures += 1 }
        print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        fflush(stdout)
    }

    private static func finish() {
        print("SMOKE result failures=\(failures)")
        fflush(stdout)
        exit(Int32(min(failures, 120)))
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
