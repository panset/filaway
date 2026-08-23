import FilawayCore
import SwiftUI

/// The left column of Figure 1 (FR-1.2): **Recents** on top — title plus a
/// relative timestamp, "Now · editing" for the note being written, purely
/// chronological and never AI-reordered — and **✦ Library** below, a collapsible
/// folder tree at most two levels deep.
///
/// A single `List` carries both sections so arrow keys walk the whole sidebar
/// (NFR-6). Selection is a ``SidebarItem`` because a note can appear twice.
struct SidebarView: View {

    @ObservedObject var model: AppModel

    /// A name prompt for New Folder / Rename. Deliberately the only dialog in
    /// the sidebar — ⌘N never shows one (FR-1.4).
    struct NamePrompt: Identifiable {
        enum Kind {
            case newFolder(parent: String)
            case renameFolder(Folder)
            case renameNote(NoteSummary)
        }
        let id = UUID()
        var kind: Kind
        var title: String
        var value: String
    }

    @State private var prompt: NamePrompt?
    @State private var promptText = ""
    @State private var dropTarget: String?

    var body: some View {
        List(selection: selectionBinding) {
            recentsSection
            librarySection
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .overlay { if model.isLoaded && model.noteCount == 0 { emptyState } }
        .accessibilityLabel("Notes sidebar")
        .alert(prompt?.title ?? "", isPresented: promptPresented) {
            TextField("Name", text: $promptText)
            Button("Cancel", role: .cancel) { prompt = nil }
            Button("OK") { commitPrompt() }
        }
    }

    // MARK: - Recents (FR-1.2)

    @ViewBuilder
    private var recentsSection: some View {
        if !model.recents.isEmpty {
            Section("Recents") {
                ForEach(model.recents) { recent in
                    row(for: recent.note, subtitle: subtitle(for: recent))
                        .tag(SidebarItem.recent(recent.id))
                }
            }
        }
    }

    private func subtitle(for recent: RecentNote) -> String {
        let isBeingEdited = model.dirtyNoteIDs.contains(recent.id)
            || (model.openNote?.id == recent.id && recent.sortDate.timeIntervalSinceNow > -60)
        return isBeingEdited ? RelativeTime.editingLabel : RelativeTime.label(for: recent.sortDate)
    }

    // MARK: - Library (FR-1.2)

    @ViewBuilder
    private var librarySection: some View {
        Section {
            if let tree = model.tree {
                ForEach(tree.subfolders) { folder in
                    folderDisclosure(folder)
                }
                // Notes that live at the root, below the folders.
                ForEach(tree.notes) { note in
                    row(for: note, subtitle: nil)
                        .tag(SidebarItem.library(note.id))
                }
            }
        } header: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Library")
            }
            .accessibilityLabel("Library, AI-managed folder tree")
            .contextMenu {
                Button("New Folder…") { showNewFolder(in: "") }
                Button("New Note") { model.newNote() }
            }
        }
    }

    /// The tree is at most two levels deep (`PathRules.maxFolderDepth`), so it
    /// is written out rather than recursed — SwiftUI cannot infer an opaque
    /// return type for a view that contains itself.
    @ViewBuilder
    private func folderDisclosure(_ folder: Folder) -> some View {
        DisclosureGroup(isExpanded: expansion(of: folder.path)) {
            ForEach(folder.subfolders) { child in
                subfolderDisclosure(child)
            }
            ForEach(folder.notes) { note in
                row(for: note, subtitle: nil)
                    .tag(SidebarItem.library(note.id))
            }
        } label: {
            folderLabel(folder)
        }
    }

    @ViewBuilder
    private func subfolderDisclosure(_ folder: Folder) -> some View {
        DisclosureGroup(isExpanded: expansion(of: folder.path)) {
            ForEach(folder.notes) { note in
                row(for: note, subtitle: nil)
                    .tag(SidebarItem.library(note.id))
            }
        } label: {
            folderLabel(folder)
        }
    }

    private func folderLabel(_ folder: Folder) -> some View {
        Label(folder.name, systemImage: "folder")
            .accessibilityLabel("Folder \(folder.name), \(folder.notes.count) notes")
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(dropTarget == folder.path ? Color.accentColor.opacity(0.18) : .clear)
                    .padding(.horizontal, -4)
            )
            .dropDestination(for: String.self) { paths, _ in
                drop(paths, into: folder.path)
            } isTargeted: { targeted in
                if targeted {
                    dropTarget = folder.path
                } else if dropTarget == folder.path {
                    dropTarget = nil
                }
            }
            .contextMenu { folderMenu(folder) }
    }

    // MARK: - Rows

    private func row(for note: NoteSummary, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(note.title)
                .lineLimit(1)
                .font(.system(size: 13, weight: model.openNote?.id == note.id ? .semibold : .regular))
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.map { "\(note.title), \($0)" } ?? note.title)
        .draggable(note.relativePath)
        .contextMenu { noteMenu(note) }
    }

    // MARK: - Context menus

    @ViewBuilder
    private func noteMenu(_ note: NoteSummary) -> some View {
        Button("New Note") { model.newNote(inFolder: note.folderPath) }
        Button("Rename…") {
            prompt = NamePrompt(kind: .renameNote(note), title: "Rename Note", value: note.title)
            promptText = note.title
        }
        Menu("Move to…") {
            ForEach(model.moveDestinations, id: \.path) { destination in
                Button(destination.label) { model.moveNote(note, toFolder: destination.path) }
                    .disabled(destination.path == note.folderPath)
            }
        }
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.library.url(for: note.relativePath)])
        }
        Button("Delete", role: .destructive) { model.deleteNote(note) }
    }

    @ViewBuilder
    private func folderMenu(_ folder: Folder) -> some View {
        Button("New Note") { model.newNote(inFolder: folder.path) }
        if PathRules.depth(ofFolder: folder.path) < PathRules.maxFolderDepth {
            Button("New Folder…") { showNewFolder(in: folder.path) }
        }
        Button("Rename…") {
            prompt = NamePrompt(kind: .renameFolder(folder), title: "Rename Folder", value: folder.name)
            promptText = folder.name
        }
        Divider()
        Button("Delete", role: .destructive) { model.deleteFolder(folder) }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No notes yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Press ⌘N to start writing.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .allowsHitTesting(false)
    }

    private var footer: some View {
        HStack {
            Text(model.noteCount == 1 ? "1 note" : "\(model.noteCount) notes")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                model.newNote()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .help("New Note (⌘N)")
            .accessibilityLabel("New Note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Plumbing

    /// `List` writes selection directly; the model reacts by loading the note.
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: { model.selection },
            set: { newValue in
                model.selection = newValue
                // AppKit is mid-update inside its own table delegate; loading a
                // note from here would be a reentrant edit.
                DispatchQueue.main.async { model.selectionChanged(to: newValue) }
            }
        )
    }

    private func expansion(of path: String) -> Binding<Bool> {
        Binding(
            get: { model.expandedFolders.contains(path) },
            set: { model.toggleFolder(path, expanded: $0) }
        )
    }

    private var promptPresented: Binding<Bool> {
        Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } })
    }

    private func showNewFolder(in parent: String) {
        prompt = NamePrompt(kind: .newFolder(parent: parent), title: "New Folder", value: "")
        promptText = ""
    }

    private func commitPrompt() {
        guard let prompt else { return }
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch prompt.kind {
        case let .newFolder(parent): model.createFolder(named: name, in: parent)
        case let .renameFolder(folder): model.renameFolder(folder, to: name)
        case let .renameNote(note): model.renameNote(note, to: name)
        }
        self.prompt = nil
    }

    private func drop(_ paths: [String], into folder: String) -> Bool {
        dropTarget = nil
        var moved = false
        for path in paths {
            guard let note = model.note(atRelativePath: path) else { continue }
            model.moveNote(note, toFolder: folder)
            moved = true
        }
        return moved
    }
}
