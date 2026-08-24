import FilawayCore
import SwiftUI

/// The two AI-connection controls that Figure 3 (onboarding) and Figure 4
/// (Settings → AI) both contain, in one place so they cannot drift.
///
/// Onboarding itself is **AppKit**, not SwiftUI — it runs in a modal window
/// before the SwiftUI scene exists, and an `NSHostingView` laid out at that
/// point tears down SwiftUI's AttributeGraph (ADR-049). So what is shared here
/// is the wording and the state machine, and `OnboardingWindowController` draws
/// the same two cards with `NSView`s.

/// FR-6.5 / Figure 3's second option: present, disabled, badged "Soon".
///
/// Shared by onboarding (Figure 3) and Settings → AI (Figure 4) so the two can
/// never drift.
struct LocalModelOptionRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local model (Ollama)")
                    .font(.headline)
                Text("Fully private · coming in v2")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("Soon")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quaternary, in: Capsule())
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Local model, Ollama. Fully private, coming in version 2. Not available yet.")
    }
}

/// The one line under a key field: nothing, a spinner, Figure 3's
/// "✓ Key valid · stored in macOS Keychain", or why the key was rejected.
///
/// Shared by onboarding step 2 and the Settings "Change…" sheet.
struct KeyValidationStatusLine: View {
    let phase: OnboardingModel.KeyPhase

    var body: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .validating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking the key…").foregroundStyle(.secondary)
            }
            .font(.callout)
            .accessibilityLabel("Checking the key")
        case .valid:
            Label("Key valid · stored in macOS Keychain", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
                .accessibilityLabel("Key valid, stored in the macOS Keychain")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Key rejected. \(message)")
        }
    }
}
