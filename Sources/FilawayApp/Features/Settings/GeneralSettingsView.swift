import AppKit
import FilawayCore
import SwiftUI

/// Settings → General (FR-8.1, FR-5.4, FR-2.4).
///
/// Three sections: where the notes live and how to point Filaway somewhere else
/// (M4-02), the editor's paste offer, and the derived index with its rebuild
/// command. Everything the pane changes goes through `AppSettings` or
/// `AppModel`; the view owns only the file picker and the confirmation.
struct GeneralSettingsView: View {
    @ObservedObject var model: SettingsModel
    /// The rebuild's progress line comes straight off the indexer's status
    /// stream (FR-5.4), so the row moves while the work runs.
    @ObservedObject private var semantic = AppModel.shared.semanticSearch

    @State private var pendingFolder: URL?

    var body: some View {
        Form {
            notesFolderSection
            editingSection
            indexSection

            Section {
                PrivacyStatementView(notesPath: model.notesRootDisplayPath)
            }
        }
        .formStyle(.grouped)
        // FR-8.1's one destructive-sounding action, made unsurprising: the
        // dialog says in its own words that no file moves.
        .confirmationDialog(
            "Read notes from “\(pendingFolder?.lastPathComponent ?? "")”?",
            isPresented: Binding(get: { pendingFolder != nil }, set: { if !$0 { pendingFolder = nil } }),
            titleVisibility: .visible
        ) {
            Button("Open This Folder") {
                guard let folder = pendingFolder else { return }
                pendingFolder = nil
                Task { await model.changeNotesFolder(to: folder) }
            }
            Button("Cancel", role: .cancel) { pendingFolder = nil }
        } message: {
            Text("Filaway will close the current library and read this folder instead. "
                + "**Nothing is moved or copied** — your existing notes stay exactly where they are, "
                + "and pointing Filaway back at them later restores everything.")
        }
    }

    // MARK: - Notes folder

    private var notesFolderSection: some View {
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
                        .accessibilityHidden(true)
                    if model.isChangingLibrary {
                        ProgressView().controlSize(.small)
                    }
                    Button("Change…") { chooseFolder() }
                        .disabled(model.isChangingLibrary)
                        .accessibilityLabel("Change notes folder")
                        .accessibilityHint("Opens a different folder. No files are moved.")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Notes folder location")
            .accessibilityValue(model.notesRootDisplayPath)

            HStack {
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppSettings.notesRoot])
                }
                .controlSize(.small)
                .accessibilityLabel("Show the notes folder in Finder")
            }
        }
    }

    /// A plain `NSOpenPanel`, not `.fileImporter`: onboarding uses the same one
    /// (ADR-037), and the security-scoped bookmark `AppSettings.setNotesRoot`
    /// writes has to come from a URL the user chose in a real panel (NFR-5).
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder Filaway should read your notes from."
        panel.directoryURL = AppSettings.notesRoot
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL != AppSettings.notesRoot.standardizedFileURL else { return }
        pendingFolder = url
    }

    // MARK: - Editing

    private var editingSection: some View {
        Section("Editing") {
            SettingsRow(
                title: "Paste intelligence",
                detail: "When something you paste looks like a shell command or code, "
                    + "offer to wrap it in a code block (⌘⇧K). The text is always pasted first."
            ) {
                // NFR-6: `.accessibilityLabel` goes *before* `.labelsHidden()`.
                // The other order leaves AppKit's `PlatformSwitch` with no name
                // at all, and VoiceOver then announces a bare "switch" — proved
                // by the `a11y` smoke phase's tree walk.
                Toggle("Paste intelligence", isOn: model.pasteIntelligenceEnabled)
                    .accessibilityLabel("Offer to wrap pasted commands in a code block")
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
        }
    }

    // MARK: - Index (FR-5.4)

    private var indexSection: some View {
        Section("Search index") {
            SettingsRow(
                title: "Rebuild index",
                detail: "The search index and embeddings are derived data — rebuilding never touches a note."
            ) {
                HStack(spacing: 8) {
                    if let fraction = semantic.indexStatus.fraction, model.isRebuildingIndex {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .frame(width: 110)
                    } else if model.isRebuildingIndex {
                        ProgressView().controlSize(.small)
                    }
                    Button("Rebuild…") { Task { await model.rebuildIndex() } }
                        .disabled(model.isRebuildingIndex || !semantic.isReady)
                        .accessibilityLabel("Rebuild the search index")
                        .accessibilityHint(semantic.isReady
                            ? "Throws away the semantic index and builds it again from your notes"
                            : "The index is still starting up")
                }
            }
            .accessibilityValue(indexStatusLine ?? "")

            if let line = indexStatusLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Index status. \(line)")
            }
        }
    }

    /// One line for the three things the pane can honestly say about the index:
    /// what it is doing, what it just did, and which embedder it is using.
    private var indexStatusLine: String? {
        switch semantic.indexStatus {
        case let .reindexing(completed, total):
            return "Rebuilding — \(completed) of \(total) notes."
        case let .indexing(completed, total):
            return "Indexing — \(completed) of \(total) notes."
        case .idle:
            if let summary = model.lastRebuildSummary { return summary }
            return semantic.embedderDescription.map { "Embeddings: \($0)." }
        }
    }
}
