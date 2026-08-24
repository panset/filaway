import FilawayCore
import SwiftUI

/// The "Change…" sheet of Figure 4, and the same control onboarding's step 2
/// reuses (Figure 3): paste a key → validate → confirm it went to the Keychain.
///
/// Validation is `GET /v1/models`, which costs nothing (plan §1 amendment 4).
/// The key is only written after that call succeeds, so a typo cannot
/// disconnect a working install — that rule lives in `AIConnectionManager`; the
/// sheet only reports what it decided.
struct APIKeySheet: View {
    @ObservedObject var model: SettingsModel
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    /// The same four-state line onboarding step 2 shows (``KeyValidationStatusLine``).
    @State private var phase: OnboardingModel.KeyPhase = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect your AI")
                .font(.title3.weight(.semibold))
            Text("Your API key organizes notes and powers semantic search. "
                + "It is stored in the macOS Keychain and never written to a file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Claude API key")
                .onSubmit { validate() }
                .onChange(of: key) { _, _ in if phase != .validating { phase = .idle } }
                .disabled(phase == .validating)

            KeyValidationStatusLine(phase: phase)
                .frame(minHeight: 18)

            HStack {
                if model.hasStoredKey {
                    Button("Remove key", role: .destructive) {
                        Task {
                            await model.disconnect()
                            dismiss()
                        }
                    }
                    .accessibilityHint("Deletes the stored key from the Keychain. Capture and keyword search keep working.")
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Validate & Save", action: validate)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase == .validating)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func validate() {
        let entered = key
        guard !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        phase = .validating
        Task {
            if let error = await model.connect(apiKey: entered) {
                phase = .failed(error.description)
            } else {
                phase = .valid
                key = ""
                // Long enough to read the Keychain confirmation, short enough
                // not to feel like a stall.
                try? await Task.sleep(nanoseconds: 900_000_000)
                dismiss()
            }
        }
    }
}
