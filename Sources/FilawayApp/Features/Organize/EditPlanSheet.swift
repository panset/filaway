import FilawayCore
import SwiftUI

/// FR-4.2's **Edit** — the third button on an ask-mode card.
///
/// The user cannot write a plan here, only correct one: include or exclude each
/// action, send it to a different folder or a different note, and fix a proposed
/// title. That keeps the closed action set closed (FR-4.1) — there is no way in
/// this sheet to produce an action the model could not have produced.
///
/// **Apply** hands the rewritten plan to ``Organizer/accept(_:plan:)``, which
/// re-runs `PlanValidator` against a *fresh* snapshot and keeps the original
/// compare-and-swap preconditions, so an edit cannot smuggle a note past the
/// CAS. A rejected edit comes back as a banner, not as a lost plan.
struct EditPlanSheet: View {
    let card: OrganizeCoordinator.Card
    let library: PlanPresentation.Library
    var onApply: (OrganizationPlan) -> Void
    var onCancel: () -> Void

    @State private var rows: [Row] = []
    @Environment(\.dismiss) private var dismiss

    /// One editable action.
    struct Row: Identifiable {
        let id: Int
        let original: PlanAction
        var include = true
        /// `createNote` title, `retitleNote` new title, or a `moveSegment`
        /// destination's new-note title.
        var title: String
        /// Destination folder, where the action has one.
        var folderPath: String
        /// Destination or subject note, where the action has one.
        var noteID: NoteID?

        var kind: PlanAction.Kind { original.kind }
        var editsTitle: Bool {
            switch original {
            case .createNote, .retitleNote: return true
            case let .moveSegment(move): return move.destination.existingNoteRef == nil
            default: return false
            }
        }

        var editsFolder: Bool {
            switch original {
            case .createNote, .moveNote, .createFolder: return true
            case let .moveSegment(move): return move.destination.existingNoteRef == nil
            default: return false
            }
        }

        var editsNote: Bool {
            switch original {
            case .appendToNote: return true
            case let .moveSegment(move): return move.destination.existingNoteRef != nil
            default: return false
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                Text("This plan has no actions.")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach($rows) { $row in
                            rowView($row)
                            Divider()
                        }
                    }
                }
            }
            footer
        }
        .frame(width: 560, height: 460)
        .onAppear(perform: build)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Edit this plan")
                .font(.headline)
            Text(card.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowView(_ row: Binding<Row>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: row.include) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PlanPresentation.describe(row.wrappedValue.original, in: library))
                        if let detail = PlanPresentation.detail(row.wrappedValue.original) {
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: PlanPresentation.symbol(for: row.wrappedValue.kind))
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityLabel("Include: \(PlanPresentation.describe(row.wrappedValue.original, in: library))")

            if row.wrappedValue.include {
                controls(row)
                    .padding(.leading, 22)
                    .disabled(!row.wrappedValue.include)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func controls(_ row: Binding<Row>) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
            if row.wrappedValue.editsTitle {
                GridRow {
                    Text("Title").foregroundStyle(.secondary)
                    TextField("Title", text: row.title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Proposed title")
                }
            }
            if row.wrappedValue.editsFolder {
                GridRow {
                    Text("Folder").foregroundStyle(.secondary)
                    Picker("Folder", selection: row.folderPath) {
                        ForEach(library.folders, id: \.path) { folder in
                            Text(folder.label).tag(folder.path)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Destination folder")
                }
            }
            if row.wrappedValue.editsNote {
                GridRow {
                    Text("Note").foregroundStyle(.secondary)
                    NotePicker(notes: library.notes, selection: row.noteID)
                }
            }
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Text("^[\(rows.filter(\.include).count) action](inflect: true) will be applied.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button("Apply") {
                onApply(edited())
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(rows.allSatisfy { !$0.include })
        }
        .padding(16)
    }

    // MARK: - Model

    private func build() {
        guard rows.isEmpty, let plan = card.plan else { return }
        rows = plan.actions.enumerated().map { index, action in
            Row(
                id: index,
                original: action,
                title: Self.title(of: action),
                folderPath: Self.folderPath(of: action),
                noteID: Self.noteID(of: action, in: library)
            )
        }
    }

    private func edited() -> OrganizationPlan {
        var plan = card.plan ?? OrganizationPlan(summary: card.summary, actions: [])
        plan.actions = rows.filter(\.include).map(\.rebuilt)
        return plan
    }

    static func title(of action: PlanAction) -> String {
        switch action {
        case let .createNote(create): return create.title
        case let .retitleNote(retitle): return retitle.newTitle
        case let .moveSegment(move):
            if case let .newNote(title, _, _) = move.destination { return title }
            return ""
        default: return ""
        }
    }

    static func folderPath(of action: PlanAction) -> String {
        switch action {
        case let .createNote(create): return create.folderPath
        case let .moveNote(move): return move.toFolderPath
        case let .createFolder(folder): return folder.path
        case let .moveSegment(move):
            if case let .newNote(_, folderPath, _) = move.destination { return folderPath }
            return ""
        default: return ""
        }
    }

    static func noteID(of action: PlanAction, in library: PlanPresentation.Library) -> NoteID? {
        switch action {
        case let .appendToNote(append): return library.note(append.target)?.id
        case let .moveSegment(move): return move.destination.existingNoteRef.flatMap { library.note($0)?.id }
        default: return nil
        }
    }
}

extension EditPlanSheet.Row {
    /// The action as the user left it. Every branch produces the *same* case it
    /// started as — the sheet edits targets, never kinds.
    var rebuilt: PlanAction {
        switch original {
        case var .createNote(create):
            create.title = title.isEmpty ? create.title : title
            create.folderPath = folderPath
            return .createNote(create)

        case var .appendToNote(append):
            if let noteID { append.target = .id(noteID) }
            return .appendToNote(append)

        case .createFolder:
            return .createFolder(CreateFolderAction(path: folderPath))

        case var .moveNote(move):
            move.toFolderPath = folderPath
            return .moveNote(move)

        case var .retitleNote(retitle):
            retitle.newTitle = title.isEmpty ? retitle.newTitle : title
            return .retitleNote(retitle)

        case .tagNote:
            return original

        case var .moveSegment(move):
            switch move.destination {
            case .existingNote:
                if let noteID { move.destination = .existingNote(.id(noteID)) }
            case let .newNote(originalTitle, _, tags):
                move.destination = .newNote(
                    title: title.isEmpty ? originalTitle : title,
                    folderPath: folderPath,
                    tags: tags
                )
            }
            return .moveSegment(move)
        }
    }
}

/// A searchable note list — "change the target note" without a 5,000-row menu.
private struct NotePicker: View {
    let notes: [NoteSummary]
    @Binding var selection: NoteID?
    @State private var query = ""

    private var matches: [NoteSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = trimmed.isEmpty ? notes : notes.filter { $0.title.lowercased().contains(trimmed) }
        return Array(pool.prefix(50))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search notes by title", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search notes by title")
            if !query.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(matches) { note in
                            Button {
                                selection = note.id
                                query = ""
                            } label: {
                                HStack {
                                    Text(note.title)
                                    Spacer()
                                    Text(note.folderPath.isEmpty ? "Library" : note.folderPath)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
            if let selection, let note = notes.first(where: { $0.id == selection }) {
                Label(note.relativePath, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
