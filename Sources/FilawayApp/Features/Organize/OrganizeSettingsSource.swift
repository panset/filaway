import Foundation
import FilawayCore

/// The Settings values the organize pipeline needs (FR-8.1), behind the
/// smallest protocol that can carry them.
///
/// M2-12 wired the pipeline before M2-11's `AppSettings` existed, so the
/// coordinator read a UserDefaults stand-in through this protocol. **M4-02
/// closed that seam**: ``CoreOrganizeSettings`` is now the default and reads
/// `CoreSettings` — the same typed, clamped, observable store the Settings
/// window writes — so a change in Settings reaches `SessionTracker` and
/// `Organizer` live, with no relaunch (see `OrganizeCoordinator.observeSettings`).
///
/// | Value | Source | Meaning |
/// |---|---|---|
/// | `organizationMode` | `CoreSettings.organizationMode` | FR-4.2's two modes |
/// | `idleIntervalMinutes` | `CoreSettings.idleInterval` | FR-3.1, clamped to 1–15 |
/// | `excludedFolders` | `CoreSettings.excludedFolders` | FR-4.5, per library |
/// | `model` | `CoreSettings.effectiveOrganizeModel` | FR-6.2's house default / override |
/// | `providerKind` | `FILAWAY_AI_PROVIDER` → `CoreSettings.aiProvider` | FR-6.5's backend (ADR-069) |
/// | `ollamaConfiguration` | `CoreSettings.ollamaBaseURL` / `.ollamaModel` | where the local daemon is |
protocol OrganizeSettingsSource: Sendable {
    var organizationMode: OrganizeMode { get }
    /// Minutes. `SessionConfiguration` clamps it to FR-3.1's 1–15.
    var idleIntervalMinutes: Double { get }
    var excludedFolders: [String] { get }
    /// What the organizer should actually send (FR-6.2 — the *effective* model,
    /// never the picker's stored value).
    var model: AIModel { get }
    /// Which backend the request goes to (FR-6.5, ADR-069). The environment
    /// wins over the preference so a smoke phase or a bench run can pin it.
    var providerKind: AIProviderKind { get }
    /// Where the local daemon is, when ``providerKind`` is `.ollama`.
    var ollamaConfiguration: OllamaConfiguration { get }
}

extension OrganizeSettingsSource {
    var model: AIModel { .defaultOrganize }
    var providerKind: AIProviderKind { AIProviderKind.fromEnvironment() ?? .claude }
    var ollamaConfiguration: OllamaConfiguration { OllamaConfiguration() }

    var sessionConfiguration: SessionConfiguration {
        SessionConfiguration(idleInterval: idleIntervalMinutes * 60)
    }

    /// Everything the organizer takes, with the defaults for the values
    /// Settings does not expose.
    var organizerSettings: OrganizerSettings {
        OrganizerSettings(
            mode: organizationMode,
            model: model,
            providerKind: providerKind,
            excludedFolders: excludedFolders
        )
    }
}

/// FR-8.1's real store (M4-02).
///
/// Reads `CoreSettings` fresh on every access, so the value is never a snapshot
/// taken at launch — the organizer and the tracker are re-configured from it
/// whenever `observe(_:)` fires.
///
/// `CoreSettings` is `@unchecked Sendable` (an `NSLock` around its observer
/// table), which is what lets this value type cross into the detached tasks
/// that talk to the `Organizer` and `SessionTracker` actors.
struct CoreOrganizeSettings: OrganizeSettingsSource {
    let settings: CoreSettings

    init(_ settings: CoreSettings) {
        self.settings = settings
    }

    /// FR-8.1's `OrganizationMode` and the organizer's `OrganizeMode` are the
    /// same two states named for their two audiences — one for a picker, one
    /// for a state machine. This is the only place they meet.
    var organizationMode: OrganizeMode {
        settings.organizationMode == .autoFile ? .auto : .ask
    }

    var idleIntervalMinutes: Double { Double(settings.idleInterval) }
    var excludedFolders: [String] { settings.excludedFolders }
    var model: AIModel { settings.effectiveOrganizeModel }

    /// ADR-069's resolution order: `FILAWAY_AI_PROVIDER` → the preference →
    /// Claude. The environment is first so a bench run, a smoke phase or a
    /// developer can pin a backend without writing the user's preferences.
    var providerKind: AIProviderKind {
        AIProviderKind.fromEnvironment() ?? settings.aiProvider
    }

    var ollamaConfiguration: OllamaConfiguration { settings.ollamaConfiguration }
}

/// Fixed values, for the smoke driver and previews.
struct FixedOrganizeSettings: OrganizeSettingsSource {
    var organizationMode: OrganizeMode = .ask
    var idleIntervalMinutes: Double = 3
    var excludedFolders: [String] = []
    var model: AIModel = .defaultOrganize
    var providerKind: AIProviderKind = .claude
    var ollamaConfiguration = OllamaConfiguration()
}
