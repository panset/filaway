import Foundation
import FilawayCore

/// The three Settings values the organize pipeline needs (FR-8.1), behind the
/// smallest protocol that can carry them.
///
/// M2-11 owns Settings; M2-12 owns the wiring, and the two landed in parallel.
/// So the coordinator reads through this instead of reaching for a type that
/// did not exist yet. The default implementation is UserDefaults-backed and
/// uses the **same keys** Settings writes, so swapping it for `AppSettings`
/// later is a one-line change in ``OrganizeCoordinator`` with no migration and
/// no behaviour change in between.
///
/// | Key | Type | Meaning |
/// |---|---|---|
/// | `organizationMode` | `"ask"` / `"auto"` | FR-4.2's two modes |
/// | `idleInterval` | minutes | FR-3.1, clamped to 1–15 by `SessionConfiguration` |
/// | `excludedFolders` | `[String]` | FR-4.5, folder paths relative to the library |
protocol OrganizeSettingsSource: Sendable {
    var organizationMode: OrganizeMode { get }
    /// Minutes. `SessionConfiguration` clamps it to FR-3.1's 1–15.
    var idleIntervalMinutes: Double { get }
    var excludedFolders: [String] { get }
}

extension OrganizeSettingsSource {
    var sessionConfiguration: SessionConfiguration {
        SessionConfiguration(idleInterval: idleIntervalMinutes * 60)
    }

    /// Everything the organizer takes, with the defaults for the values
    /// Settings does not expose yet.
    var organizerSettings: OrganizerSettings {
        OrganizerSettings(mode: organizationMode, excludedFolders: excludedFolders)
    }
}

/// The stand-in until Settings lands: the same defaults domain the rest of the
/// shell uses (`FILAWAY_DEFAULTS_SUITE` in smoke runs), read fresh every time so
/// a change in Settings is picked up without a notification.
struct UserDefaultsOrganizeSettings: OrganizeSettingsSource {
    static let modeKey = "organizationMode"
    static let idleIntervalKey = "idleInterval"
    static let excludedFoldersKey = "excludedFolders"

    /// `UserDefaults` is thread-safe but not `Sendable`-annotated; the box is
    /// what lets this value cross an actor boundary without a warning.
    private let box: @Sendable () -> UserDefaults
    var defaults: UserDefaults { box() }

    init(defaults: @autoclosure @escaping @Sendable () -> UserDefaults = AppSettings.defaults) {
        box = defaults
    }

    var organizationMode: OrganizeMode {
        defaults.string(forKey: Self.modeKey).flatMap(OrganizeMode.init(rawValue:)) ?? .ask
    }

    var idleIntervalMinutes: Double {
        let stored = defaults.double(forKey: Self.idleIntervalKey)
        return stored > 0 ? stored : SessionConfiguration.defaultIdleInterval / 60
    }

    var excludedFolders: [String] {
        defaults.stringArray(forKey: Self.excludedFoldersKey) ?? []
    }
}

/// Fixed values, for the smoke driver and previews.
struct FixedOrganizeSettings: OrganizeSettingsSource {
    var organizationMode: OrganizeMode = .ask
    var idleIntervalMinutes: Double = 3
    var excludedFolders: [String] = []
}
