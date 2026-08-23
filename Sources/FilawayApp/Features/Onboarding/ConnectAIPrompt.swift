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

    private let settings: CoreSettings
    private var observation: CoreSettings.Observation?

    init(settings: CoreSettings = AppSettings.core) {
        self.settings = settings
        observation = settings.observe { [weak self] key in
            guard key == .aiConnectionSkipped else { return }
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
    }

    /// `true` when the row should be in the sidebar footer.
    var isVisible: Bool {
        settings.aiConnectionSkipped && !isConnected && !isDismissedThisLaunch
    }

    /// The sentence the row shows.
    let text = "Connect your AI to organize and search"

    func dismissForThisLaunch() { isDismissedThisLaunch = true }

    /// Opens Settings → AI, which is where the key is entered (FR-6.2).
    func openSettings() {
        SettingsWindow.open()
    }

    /// Called by whoever learns the connection came up.
    func markConnected() {
        isConnected = true
        settings.aiConnectionSkipped = false
    }

    /// Re-reads the connection on launch, so a key entered in Settings last time
    /// silences the row without a preference write.
    func refresh(from connection: AIConnectionManager) {
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
