import AppKit
import FilawayCore
import SwiftUI

/// FR-7.1's "persistent gentle prompt to connect".
///
/// The spec asks for two things that pull against each other: the offer must
/// stay open (the app is *usable* without a key, but it is not the whole app),
/// and it must never nag (FR-6.4: "clear, non-nagging status"). So it is a quiet
/// row in the sidebar footer — not a modal, not a sheet, not a notification —
/// dismissable for the rest of the launch and back, once, the next time the app
/// opens.
///
/// It disappears for good the moment a key validates.
@MainActor
final class ConnectAIPromptModel: ObservableObject {

    static let shared = ConnectAIPromptModel()

    /// Set when a key is known to be good, so the row goes away without waiting
    /// for a Settings round trip.
    @Published private(set) var isConnected = false
    /// Dismissed with the × — for this launch only.
    @Published private(set) var isDismissedThisLaunch = false
    /// What the AI status pill last reported (ADR-059). `OrganizeCoordinator`
    /// pushes it; it is the only thing that knows whether the *configured*
    /// provider actually answers, key or no key.
    ///
    /// It starts `connected` for the same reason `OrganizeCoordinator.status`
    /// does: before anything has been asked, "assume it works" is the
    /// non-nagging default (FR-6.4), and the first real failure corrects it.
    @Published private(set) var aiStatus: AIStatus = .connected

    private let settings: CoreSettings
    private var observation: CoreSettings.Observation?

    init(settings: CoreSettings = AppSettings.core) {
        self.settings = settings
        observation = settings.observe { [weak self] key in
            switch key {
            // FR-6.5: switching to the local provider is a connection decision
            // too, so the row has to re-read itself when it moves.
            case .aiConnectionSkipped, .aiProvider, .ollamaBaseURL, .ollamaModel:
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            default:
                break
            }
        }
    }

    /// `true` when the row should be in the sidebar footer.
    ///
    /// **Not** "is there a stored key" (P2-03): under FR-6.5 a user can have a
    /// perfectly working AI with no key at all. The question the row asks is
    /// "does this Mac have an AI Filaway can use?", and for the local provider
    /// the answer is yes as soon as the daemon has been reached once — which is
    /// exactly what onboarding and Settings → AI record by clearing
    /// `aiConnectionSkipped`.
    var isVisible: Bool {
        guard !isConnected, !isDismissedThisLaunch else { return false }
        guard settings.aiConnectionSkipped else { return false }
        // A local provider that has already been configured is connected enough
        // for the offer to be pointless, even if the skip flag was never
        // cleared (a preference written from outside the flow, say).
        if settings.aiProvider == .ollama, isLocalProviderUsable { return false }
        return true
    }

    /// The local provider is configured **and** the pill has not said otherwise.
    ///
    /// Deliberately not a network probe of its own: the sidebar footer is not
    /// where an outage should be discovered, and the pill already says
    /// `AI offline` for that (ADR-059). What this rules out is the opposite
    /// mistake — nagging someone to "connect your AI" who has a daemon running
    /// on this very machine.
    private var isLocalProviderUsable: Bool {
        settings.ollamaConfiguration.validate() && aiStatus.isUsable()
    }

    /// The pill moved (P2-03). Wired by `AppModel` from
    /// `OrganizeCoordinator.onStatusChanged`.
    func noteAIStatus(_ status: AIStatus) {
        aiStatus = status
        if status == .connected { markConnected() }
    }

    /// The sentence the row shows.
    let text = "Connect your AI to organize and search"

    func dismissForThisLaunch() { isDismissedThisLaunch = true }

    /// Opens Settings → AI, which is where the key is entered (FR-6.2).
    func openSettings() {
        SettingsWindow.open()
    }

    /// Called by whoever learns the connection came up — a validated key, or a
    /// daemon that answered (FR-6.5).
    func markConnected() {
        isConnected = true
        settings.aiConnectionSkipped = false
    }

    /// Re-reads the connection on launch, so a key entered in Settings last time
    /// silences the row without a preference write.
    ///
    /// Under the local provider there is no key to ask about, so the manager is
    /// not consulted at all — asking it would report `notConfigured` for a
    /// perfectly working setup.
    func refresh(from connection: AIConnectionManager) {
        guard settings.aiProvider != .ollama else {
            if isLocalProviderUsable { markConnected() }
            return
        }
        Task { [weak self] in
            let status = await connection.status
            guard status == .connected else { return }
            self?.markConnected()
        }
    }
}

/// The row itself: an SF Symbol, one sentence, "Connect" and a dismiss glyph.
struct ConnectAIPromptRow: View {
    @ObservedObject var model: ConnectAIPromptModel

    var body: some View {
        if model.isVisible {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Button(model.text) { model.openSettings() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel(model.text)
                    .accessibilityHint("Opens Settings, AI")
                Spacer(minLength: 4)
                Button {
                    model.dismissForThisLaunch()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Hide until the next time Filaway opens")
                .accessibilityLabel("Hide this reminder")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.4))
            .accessibilityElement(children: .contain)
        }
    }
}
