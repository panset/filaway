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

/// FR-6.5 / Figure 3's two options, as one selectable card each.
///
/// Until P2-02 the local one was a disabled row badged "Soon". It is now a real
/// choice: `AIProviderKind.ollama` needs no key, no network and no account, and
/// picking it is the whole of FR-6.5. Both cards are drawn by the same view so
/// onboarding (Figure 3) and Settings → AI (Figure 4) cannot drift, and every
/// string comes from `AIConnectionCopy` so it is the same string Core tests.
struct ProviderOptionRow: View {
    let kind: AIProviderKind
    let isSelected: Bool
    /// A short line under the pitch — the live connection status in Settings,
    /// nothing in onboarding.
    var status: String?
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: kind == .claude ? "cloud.fill" : "desktopcomputer")
                    .font(.title2)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(AIConnectionCopy.chooserTitle(kind))
                        .font(.headline)
                    Text(AIConnectionCopy.chooserDetail(kind))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let status {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .padding(14)
            .background(
                isSelected ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.quaternary.opacity(0.2)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        // NFR-6: one control, one name, one value — VoiceOver announces the
        // pitch and whether this is the provider in use.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(
            "\(AIConnectionCopy.chooserTitle(kind)). \(AIConnectionCopy.chooserDetail(kind))"
        )
        .accessibilityValue(isSelected ? "Selected" + (status.map { ". \($0)" } ?? "") : "Not selected")
        .accessibilityHint("Uses this provider for organizing and search")
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
