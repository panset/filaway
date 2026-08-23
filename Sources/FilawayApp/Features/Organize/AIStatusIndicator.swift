import FilawayCore
import SwiftUI

/// The toolbar status indicator of FR-6.4 / M2-09.
///
/// Degradation is meant to be *visible and quiet*: no modal alert, no repeated
/// prompt, nothing that stops a keystroke. The whole report is one pill:
///
/// | State | Pill |
/// |---|---|
/// | working | `AI ready` |
/// | sessions waiting out an outage | `AI queued · 2` |
/// | no network / API unreachable | `AI offline` |
/// | 401/403 | `Key invalid` |
/// | rate limited | `AI paused` |
/// | no key yet | `AI off` |
///
/// Clicking it opens Settings → AI. That scene is M2-11's, so this calls a hook
/// (``OrganizeCoordinator/onOpenAISettings``) which posts
/// `.filawayOpenAISettings`; when M2-11's exportable `AIStatusPill` lands, this
/// view is the thing to delete — the coordinator's `status` and
/// `queuedSessionCount` are already the inputs it wants.
struct AIStatusIndicator: View {
    let status: AIStatus
    let queuedCount: Int
    var onOpenSettings: () -> Void

    var body: some View {
        Button(action: onOpenSettings) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint("Opens the AI settings")
    }

    var label: String {
        if queuedCount > 0, !status.isUsable() { return "AI queued · \(queuedCount)" }
        switch status {
        case .connected: return queuedCount > 0 ? "AI queued · \(queuedCount)" : "AI ready"
        case .notConfigured: return "AI off"
        case .invalidKey: return "Key invalid"
        case .offline: return "AI offline"
        case .rateLimited: return "AI paused"
        case .error: return "AI unavailable"
        }
    }

    private var symbol: String {
        switch status {
        case .connected: return queuedCount > 0 ? "clock.arrow.circlepath" : "sparkles"
        case .notConfigured: return "sparkles"
        case .invalidKey: return "key.slash"
        case .offline: return "wifi.slash"
        case .rateLimited: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch status {
        case .connected: return queuedCount > 0 ? .orange : .secondary
        case .notConfigured: return .secondary
        case .invalidKey, .error: return .orange
        case .offline, .rateLimited: return .orange
        }
    }

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

extension Notification.Name {
    /// Posted when the user clicks the AI status pill. Settings (M2-11) observes
    /// it and opens its AI tab; until then nothing does, and the click is inert
    /// rather than broken.
    static let filawayOpenAISettings = Notification.Name("com.tejaspanse.filaway.openAISettings")
    /// Posted by the Activity menu item; the window scene observes it.
    static let filawayShowActivity = Notification.Name("com.tejaspanse.filaway.showActivity")
}
