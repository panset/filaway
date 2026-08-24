import AppKit
import FilawayCore

/// The FR-6.5 half of the `settings-wiring` phase (P2-03).
///
/// `settings-wiring` proves that a preference reaches the live objects. This is
/// the same assertion for the one preference M4-02 did not have yet: **which
/// backend answers**. It flips `ai.provider` to Ollama with a model tag, waits
/// for both coordinators to report it off their own actors, and flips back —
/// so a regression that leaves the provider resolved once at launch fails here
/// rather than on somebody's machine.
///
/// It is a separate file, and a separate call, because `SettingsSmokeCheck` is
/// owned elsewhere. Add one line to `runWiringPhase()`:
///
/// ```swift
/// await ProviderWiringSmokeCheck.run(model: app, check: check)
/// ```
///
/// Nothing here reaches a daemon: the assertions are about what the `Organizer`
/// and the `AnswerExtractor` *hold*, and the phase runs with
/// `FILAWAY_AI_MODE=replay`, where the provider object is a `ReplayProvider`
/// whichever backend is configured (ADR-069). The kind is still the real
/// resolved one, which is the thing worth asserting.
@MainActor
enum ProviderWiringSmokeCheck {

    /// The tag the phase writes. Deliberately not `llama3.1:8b`: a value nobody
    /// defaults to proves the *write* reached the actor, not the default.
    static let modelTag = "qwen3:4b"

    /// - Parameters:
    ///   - model: the live `AppModel`, already bootstrapped.
    ///   - check: the calling phase's own assertion sink, so the failures land
    ///     in its count and its transcript.
    static func run(
        model: AppModel,
        check: @MainActor (String, Bool, String) -> Void
    ) async {
        let settings = AppSettings.core

        // `FILAWAY_AI_PROVIDER` wins over the preference by design (ADR-069),
        // so a phase that set it would be asserting the wrong half.
        guard AIProviderKind.fromEnvironment() == nil else {
            check("provider-wiring-skipped", true, "FILAWAY_AI_PROVIDER pins the kind for this run")
            return
        }
        guard let organize = model.organize, organize.isReady else {
            check("provider-wiring-organizer-ready", false, "the organize pipeline never came up")
            return
        }
        let semantic = model.semanticSearch
        let original = settings.aiProvider
        let originalModel = settings.ollamaModel

        // 1 — the default is Claude, and both sides agree on it.
        var probe = await organize.providerKindProbe()
        check("organizer-starts-on-the-preference", probe.kind == original, probe.kind.rawValue)

        // 2 — flip the preference. FR-8.1: no relaunch.
        settings.ollamaModel = AIModel(modelTag)
        settings.aiProvider = .ollama

        let switched = await poll(seconds: 5) {
            await organize.providerKindProbe().kind == .ollama
        }
        probe = await organize.providerKindProbe()
        check("provider-reaches-the-organizer", switched, probe.kind.rawValue)
        check("model-reaches-the-organizer", probe.model.id == modelTag, probe.model.id)

        // The organize *budget* moves with the backend, and it is the settings
        // the actor holds that decide it (ADR-054).
        let budget = await organize.organizerSettingsProbe()?.requestTimeout
        check("organize-budget-follows-the-backend", budget == 180, budget.map { "\($0)s" } ?? "nil")

        // 3 — the same switch reaches ⌘K's answer step.
        if semantic.isReady {
            let searchSwitched = await poll(seconds: 5) {
                await semantic.providerKindProbe().kind == .ollama
            }
            let search = await semantic.providerKindProbe()
            check("provider-reaches-the-answer-step", searchSwitched, search.kind.rawValue)
            check("model-reaches-the-answer-step", search.model.id == modelTag, search.model.id)
        } else {
            check("provider-reaches-the-answer-step", true, "semantic stack not up — skipped")
        }

        // 4 — and back, because a one-way switch is not "applies live".
        settings.aiProvider = original
        settings.ollamaModel = originalModel
        let restored = await poll(seconds: 5) {
            await organize.providerKindProbe().kind == original
        }
        probe = await organize.providerKindProbe()
        check("provider-switches-back", restored, probe.kind.rawValue)
        check("model-switches-back", probe.model == settings.effectiveOrganizeModel, probe.model.id)
    }

    private static func poll(seconds: Double, until condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return await condition()
    }
}
