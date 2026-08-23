import AppKit
import FilawayCore
import SwiftUI

/// The toolbar status pill of FR-6.4 — "clear, non-nagging".
///
/// Not wired into the shell here: the toolbar belongs to `ShellView`, and M2-11
/// has no business rewriting it. Drop it in with one line when the shell is next
/// touched:
///
/// ```swift
/// ToolbarItem(placement: .status) { AIStatusPill(status: model.status) }
/// ```
///
/// It draws nothing at all when the AI is connected and healthy: a working
/// connection is the expected state, and a badge that is always lit is a badge
/// nobody reads. `alwaysVisible` overrides that for Settings and onboarding.
struct AIStatusPill: View {
    let status: AIStatus
    var alwaysVisible = false
    /// Opens Settings → AI. Defaults to the standard Settings action.
    var action: (() -> Void)?

    var body: some View {
        if status == .connected, !alwaysVisible {
            EmptyView()
        } else {
            Button {
                if let action { action() } else { SettingsWindow.open() }
            } label: {
                Label {
                    Text(shortLabel)
                } icon: {
                    Image(systemName: symbol)
                }
                .font(.callout)
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .help(status.label)
            .accessibilityLabel(status.label)
            .accessibilityHint("Opens AI settings")
        }
    }

    private var shortLabel: String {
        switch status {
        case .connected: return "AI"
        case .notConfigured: return "Connect AI"
        case .invalidKey: return "Key rejected"
        case .offline: return "AI offline"
        case .rateLimited: return "Rate limited"
        case .error: return "AI unavailable"
        }
    }

    private var symbol: String {
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
        case .connected: return .secondary
        case .invalidKey, .error: return .orange
        case .notConfigured, .offline, .rateLimited: return .secondary
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
    /// - Returns: `false` when nothing could be found to invoke — which the
    ///   smoke driver asserts against.
    @discardableResult
    static func open() -> Bool {
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
