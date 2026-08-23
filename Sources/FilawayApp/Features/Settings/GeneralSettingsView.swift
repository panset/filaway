import AppKit
import FilawayCore
import SwiftUI

/// Settings → General (FR-8.1).
///
/// M2-11 ships the read-only half: where the notes live, and where the derived
/// database lives. Changing the folder means closing one library and opening
/// another — that is M4-02's job, so the button is present and disabled with a
/// tooltip rather than absent, which would leave the pane looking unfinished.
struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("Notes folder") {
                SettingsRow(
                    title: "Location",
                    detail: "Your notes are plain Markdown files. Open the folder in any editor and read everything."
                ) {
                    HStack(spacing: 8) {
                        Text(model.notesRootDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Change…") {}
                            .disabled(true)
                            .help("Choosing a different notes folder arrives with onboarding (M4).")
                            .accessibilityHint("Not available yet")
                    }
                }

                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppSettings.notesRoot])
                    }
                    .controlSize(.small)
                }
            }

            Section("Index") {
                SettingsRow(
                    title: "Rebuild index",
                    detail: "The search index and embeddings are derived data — rebuilding never touches a note."
                ) {
                    Button("Rebuild…") {}
                        .disabled(true)
                        .help("The reindex command arrives with semantic search (FR-5.4, M4).")
                        .accessibilityHint("Not available yet")
                }
            }

            Section {
                PrivacyStatementView(notesPath: model.notesRootDisplayPath)
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings → Activity (FR-4.4) — the access point for the log.
///
/// A placeholder on purpose: the Activity log's own milestone owns the list
/// view, and this pane is where it lands.
struct ActivitySettingsView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Activity log")
                .font(.headline)
            Text("Everything the AI has filed, with Undo, arrives here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Activity log. Everything the AI has filed, with Undo, arrives here.")
    }
}
