import AppKit
import FilawayCore
import SwiftUI

/// The toolbar status pill of FR-6.4 — "clear, non-nagging".
///
/// **In the toolbar since M4-02**, through ``AIStatusPillHost`` in `ShellView`,
/// fed by `AIConnectionManager.statusChanges()` folded into
/// `OrganizeCoordinator.status` plus its queue depth. It replaced
/// `AIStatusIndicator`, which said the same things in a second vocabulary.
///
/// It draws nothing at all when the AI is connected, healthy and nothing is
/// waiting: a working connection is the expected state, and a badge that is
/// always lit is a badge nobody reads. `alwaysVisible` overrides that for
/// Settings and onboarding.
///
/// | State | Pill |
/// |---|---|
/// | working, nothing queued | *(nothing)* |
/// | sessions waiting out an outage | `Queued · 2` |
/// | no network / API unreachable | `AI offline` |
/// | 401/403 | `Key rejected` |
/// | rate limited | `Rate limited` |
/// | no key yet | `Connect AI` |
struct AIStatusPill: View {
    let status: AIStatus
    /// Sessions the organizer is holding until the provider comes back
    /// (FR-6.4). Shown even while the connection itself is healthy — a queue
    /// that is draining is still something the user may want to know about.
    var queuedCount = 0
    var alwaysVisible = false
    /// Opens Settings → AI. Defaults to the standard Settings action.
    var action: (() -> Void)?

    /// NFR-6: the pill grows with the system text size instead of staying at a
    /// fixed 13 pt while everything around it moves.
    @ScaledMetric(relativeTo: .callout) private var iconSize: CGFloat = 12

    var body: some View {
        if status == .connected, queuedCount == 0, !alwaysVisible {
            EmptyView()
        } else {
            Button {
                if let action { action() } else { SettingsWindow.open() }
            } label: {
                Label {
                    Text(shortLabel)
                } icon: {
                    Image(systemName: symbol)
                        .font(.system(size: iconSize))
                }
                .font(.callout)
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(accessibilityLabel)
            // A plain interpolated `String`, not `^[…](inflect:)` markup: that
            // markup is only expanded inside a `LocalizedStringKey` literal, and
            // a `String` argument would be announced with the brackets in it.
            .accessibilityValue(queuedCount > 0
                ? "\(queuedCount) session\(queuedCount == 1 ? "" : "s") waiting"
                : "")
            .accessibilityHint("Opens AI settings")
        }
    }

    private var shortLabel: String {
        if queuedCount > 0, status == .connected || !status.isUsable() {
            return "Queued · \(queuedCount)"
        }
        switch status {
        case .connected: return "AI"
        case .notConfigured: return "Connect AI"
        case .invalidKey: return "Key rejected"
        case .offline: return "AI offline"
        case .rateLimited: return "Rate limited"
        case .error: return "AI unavailable"
        }
    }

    /// VoiceOver gets the long form: "AI" is not a sentence.
    private var accessibilityLabel: String {
        queuedCount > 0 ? "\(status.label). \(queuedCount) queued" : status.label
    }

    private var symbol: String {
        if queuedCount > 0, status == .connected { return "clock.arrow.circlepath" }
        switch status {
        case .connected: return "cloud.fill"
        case .notConfigured: return "cloud"
        case .invalidKey: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        case .rateLimited: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch status {
        case .connected: return queuedCount > 0 ? .orange : .secondary
        case .invalidKey, .error: return .orange
        case .notConfigured: return .secondary
        case .offline, .rateLimited: return .orange
        }
    }

    /// FR-6.4: every degraded state explains itself and promises nothing is
    /// lost. No modal, ever.
    private var help: String {
        switch status {
        case .connected where queuedCount > 0:
            return "\(queuedCount) session(s) waiting to be filed. Filaway retries on its own."
        case .connected:
            return "Filaway files your sessions in the background."
        case .notConfigured:
            return "Add an API key in Settings → AI to turn organizing on. Writing and search work without it."
        case .invalidKey:
            return "The API key was rejected. Sessions are kept and filed once a working key is set."
        case .offline:
            return "The API is unreachable. Sessions are queued and retried — nothing is lost."
        case let .rateLimited(until):
            return "Rate limited until \(until.formatted(date: .omitted, time: .shortened)). Queued sessions resume then."
        case let .error(message):
            return message
        }
    }
}

/// Opening the Settings scene from code.
///
/// SwiftUI offers no public API for "show my Settings window", and the two
/// documented selectors are a dead end here: on this toolchain the `Settings`
/// scene installs its menu item with SwiftUI's private `menuAction:`, so
/// `sendAction(Selector("showSettingsWindow:"))` reports success and opens
/// nothing. Performing the menu item is what ⌘, does, and it is the only
/// spelling that actually works — the selectors stay as a fallback for a
/// toolchain that wires them up.
///
/// Used by the status pill, by the gentle "connect your AI" prompt (FR-7.1) and
/// by the smoke driver.
@MainActor
enum SettingsWindow {
    /// - Parameter tab: which pane to land on. The pill, the ⌘K panel's
    ///   "connect your AI" notice and the sidebar prompt all mean **AI**;
    ///   passing `nil` leaves whichever tab was last shown (⌘, does that).
    /// - Returns: `false` when nothing could be found to invoke — which the
    ///   smoke driver asserts against.
    @discardableResult
    static func open(tab: SettingsRootView.Tab? = .ai) -> Bool {
        if let tab { SettingsTabSelection.shared.tab = tab }
        NSApp.activate(ignoringOtherApps: true)
        if let (menu, index) = menuItem() {
            menu.performActionForItem(at: index)
            return true
        }
        for name in ["showSettingsWindow:", "showPreferencesWindow:"] {
            if NSApp.sendAction(Selector((name)), to: nil, from: nil) { return true }
        }
        return false
    }

    /// Closes the `.filawayOpenAISettings` seam (M4-02).
    ///
    /// The status pill, the organizer and the ⌘K panel all post that
    /// notification rather than reaching for the Settings scene, because none
    /// of them can address it. This is the one place that listens, and it opens
    /// the window *on the AI tab* — arriving on General after clicking "Connect
    /// AI" would be a small betrayal.
    ///
    /// Called once, from `applicationDidFinishLaunching`.
    static func observeOpenRequests() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .filawayOpenAISettings, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { _ = SettingsWindow.open(tab: .ai) }
        }
    }

    private static var observer: (any NSObjectProtocol)?

    /// The app menu's "Settings…" item ("Preferences…" on older systems).
    private static func menuItem() -> (NSMenu, Int)? {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return nil }
        guard let index = appMenu.items.firstIndex(where: {
            $0.title.hasPrefix("Settings") || $0.title.hasPrefix("Preferences")
        }) else { return nil }
        return (appMenu, index)
    }

    /// The Settings window, once it exists.
    ///
    /// Reported by ``SettingsWindowAccessor`` from inside the scene rather than
    /// guessed from a title: SwiftUI titles the window after the *selected tab*
    /// ("AI", "General"), so there is nothing stable to match on.
    private(set) static weak var current: NSWindow?

    static var window: NSWindow? { current }

    static func adopt(_ window: NSWindow?) {
        guard let window else { return }
        current = window
    }
}
