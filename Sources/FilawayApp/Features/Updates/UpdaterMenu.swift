import AppKit
import FilawayCore
import Sparkle
import SwiftUI

// M4-04 — "Check for Updates…" (spec §9: shipping fixes needs an update
// mechanism). Sparkle 2 is a hard link-time dependency of the app target, but a
// *soft* runtime one: a build with no `SUFeedURL` / `SUPublicEDKey` in its
// Info.plist — every local `make app` until the user has Sparkle keys and a
// published appcast — must still launch, and the menu item must simply be
// disabled with an explanation rather than starting an updater that would log
// "You must specify the URL of the appcast" and fail. That is the whole reason
// for `UpdaterProviding`: the unconfigured case is a real implementation, not an
// error path. See ADR-042.

/// The app's view of "can I update myself?".
///
/// Two implementations: ``SparkleUpdaterProvider`` when the bundle carries a
/// feed URL and a public EdDSA key, ``UnconfiguredUpdaterProvider`` otherwise.
@MainActor
protocol UpdaterProviding: AnyObject {
    /// `nil` when updates work in this build; otherwise the reason they do not,
    /// worded for a tooltip.
    var unavailableReason: String? { get }

    /// False while Sparkle is busy with a check it started itself.
    var canCheckForUpdates: Bool { get }

    /// Starts a user-initiated check. Sparkle owns all the UI from here.
    func checkForUpdates()

    /// Called once at launch, after the menu exists.
    func start()

    /// Notified when `canCheckForUpdates` changes, so the menu item can redraw.
    var onChange: (() -> Void)? { get set }
}

// MARK: - Sparkle

/// Wraps `SPUStandardUpdaterController`, which owns the updater, the standard
/// user driver (the "A new version is available" window) and the scheduled
/// check timer.
@MainActor
final class SparkleUpdaterProvider: NSObject, UpdaterProviding {
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?
    private var started = false

    var onChange: (() -> Void)?
    var unavailableReason: String? { nil }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    /// `startingUpdater: false` — starting is deferred to ``start()`` so the
    /// scheduled-check timer never runs during a `FILAWAY_SMOKE` phase.
    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
        )
        super.init()
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
        Log.app.info("Sparkle updater started, feed configured")
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

// MARK: - No feed in this build

/// Stands in when the bundle has no Sparkle configuration. Everything answers
/// "no", and the menu item's tooltip says why.
@MainActor
final class UnconfiguredUpdaterProvider: UpdaterProviding {
    var onChange: (() -> Void)?
    let unavailableReason: String? = "Updates not configured in this build"
    let canCheckForUpdates = false
    func checkForUpdates() {}
    func start() {}
}

// MARK: - Controller

/// The single object the menu item observes.
///
/// Picks its provider from the Info.plist at first use: both `SUFeedURL` and
/// `SUPublicEDKey` must be present and non-empty. `Tools/make_app.sh` writes
/// `SUFeedURL` always and `SUPublicEDKey` only when
/// `Tools/release.env`/`$SPARKLE_PUBLIC_KEY` supplies one, so an ordinary local
/// build lands in the unconfigured branch by construction.
@MainActor
final class UpdaterController: ObservableObject {
    static let shared = UpdaterController()

    private let provider: UpdaterProviding

    /// Enables the menu item.
    @Published private(set) var canCheckForUpdates: Bool

    /// Tooltip text — the reason updates are off, or the standard hint.
    let help: String

    /// True when this bundle can actually reach an appcast.
    var isConfigured: Bool { provider.unavailableReason == nil }

    init(provider: UpdaterProviding? = nil) {
        let resolved = provider ?? Self.makeProvider()
        self.provider = resolved
        canCheckForUpdates = resolved.canCheckForUpdates
        help = resolved.unavailableReason ?? "Check whether a newer version of Filaway is available"
        resolved.onChange = { [weak self] in
            guard let self else { return }
            canCheckForUpdates = self.provider.canCheckForUpdates
        }
        // Self-starting, so `FilawayApp.swift` gains exactly one line (the
        // `UpdaterCommands()` entry) and `AppDelegate` gains none. Whichever of
        // the two happens second wins; `startIfPossible` is idempotent.
        if NSApp?.isRunning == true {
            Task { @MainActor [weak self] in self?.startIfPossible() }
        }
        launchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.startIfPossible() }
        }
    }

    private var launchObserver: (any NSObjectProtocol)?

    /// A no-op when unconfigured, and skipped entirely in smoke runs so no
    /// phase ever hits the network.
    func startIfPossible() {
        guard !AppSettings.isSmokeRun else {
            Log.app.debug("smoke run: Sparkle updater not started")
            return
        }
        provider.start()
        canCheckForUpdates = provider.canCheckForUpdates
    }

    func checkForUpdates() {
        provider.checkForUpdates()
    }

    private static func makeProvider() -> UpdaterProviding {
        guard let feed = Self.infoString("SUFeedURL"), URL(string: feed) != nil,
              Self.infoString("SUPublicEDKey") != nil
        else {
            Log.app.info("no SUFeedURL/SUPublicEDKey in the bundle; updates disabled")
            return UnconfiguredUpdaterProvider()
        }
        return SparkleUpdaterProvider()
    }

    private static func infoString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `make_app.sh` leaves the key out rather than empty, but a template
        // that was never substituted would still be here.
        guard !trimmed.isEmpty, !trimmed.hasPrefix("@") else { return nil }
        return trimmed
    }
}

// MARK: - Menu

/// The one menu item, in the app menu under "About Filaway" — where every other
/// Mac app puts it. `FilawayApp.swift` adds this with a single line inside
/// `AppCommands.body`.
struct UpdaterCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesMenuItem() }
    }
}

struct CheckForUpdatesMenuItem: View {
    @ObservedObject private var updater = UpdaterController.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
            .help(updater.help)
            .accessibilityLabel("Check for Updates")
    }
}
