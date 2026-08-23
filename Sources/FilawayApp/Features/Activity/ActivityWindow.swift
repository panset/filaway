import AppKit
import FilawayCore
import SwiftUI

/// FR-4.3 / FR-4.4 — the Activity window (Window ▸ Activity, ⌥⌘A).
///
/// Newest first on the left, the diff of the selected event on the right, Undo
/// above it, and the raw session text behind a disclosure. Everything comes
/// from `ActivityLog`, which is also the apply journal — so this window is
/// literally a view of what the applier promised to be able to reverse.
@MainActor
final class ActivityModel: ObservableObject {
    @Published private(set) var events: [ActivityEvent] = []
    @Published var selection: ActivityEventID?
    @Published private(set) var selected: ActivityEvent?
    @Published private(set) var diffs: [NoteDiff] = []
    @Published private(set) var sessionText: String?
    /// `nil` when Undo is available; otherwise why it is not.
    @Published private(set) var undoBlockedReason: String?
    @Published private(set) var isLoading = false

    private var activity: ActivityLog?
    private var undoService: UndoService?
    private weak var coordinator: OrganizeCoordinator?

    func attach(to coordinator: OrganizeCoordinator?) {
        guard let coordinator, self.coordinator !== coordinator else { return }
        self.coordinator = coordinator
        activity = coordinator.activity
        undoService = coordinator.undoService
    }

    var canUndo: Bool { selected != nil && undoBlockedReason == nil }

    func reload() async {
        guard let activity else { return }
        isLoading = true
        defer { isLoading = false }
        events = (try? await activity.events(limit: 100)) ?? []
        if selection == nil || !events.contains(where: { $0.id == selection }) {
            selection = events.first?.id
        }
        await loadSelection()
    }

    func loadSelection() async {
        guard let activity, let id = selection else {
            selected = nil
            diffs = []
            sessionText = nil
            undoBlockedReason = "Nothing is selected."
            return
        }
        selected = try? await activity.event(id)
        diffs = (try? await activity.diff(for: id)) ?? []
        sessionText = try? await activity.sessionText(for: id)
        undoBlockedReason = await blockedReason(for: selected)
    }

    /// FR-4.3's LIFO rule, explained rather than merely enforced: a later
    /// organization that touched the same note has to be reversed first.
    private func blockedReason(for event: ActivityEvent?) async -> String? {
        guard let event else { return "Nothing is selected." }
        guard event.kind == .applied else {
            return event.kind == .undone
                ? "This row is itself an undo — there is no redo in Filaway."
                : "Nothing was written, so there is nothing to undo."
        }
        guard event.status == .applied else { return "This change was not completed." }
        if let undoneBy = event.undoneBy, undoneBy != event.id { return "This change has already been undone." }
        guard event.isUndoable else { return "This change is too old to undo." }
        guard let activity else { return nil }
        if let later = (try? await activity.laterEvent(touching: event.noteIDs, after: event)) ?? nil {
            return "Undo “\(later.summary)” first — it touched the same notes."
        }
        return nil
    }

    func undoSelected() {
        guard let id = selection, canUndo else { return }
        coordinator?.undo(eventID: id)
        Task {
            // Give the undo a moment to write its own row, then refresh.
            try? await Task.sleep(nanoseconds: 400_000_000)
            await reload()
        }
    }
}

struct ActivityWindowView: View {
    @ObservedObject var model: AppModel
    @StateObject private var activity = ActivityModel()

    var body: some View {
        NavigationSplitView {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .navigationTitle("Activity")
        .frame(minWidth: 760, minHeight: 460)
        .task(id: model.organize == nil) {
            activity.attach(to: model.organize)
            await activity.reload()
        }
        .onChange(of: activity.selection) { _, _ in
            Task { await activity.loadSelection() }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await activity.reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .accessibilityLabel("Refresh the activity list")
            }
        }
    }

    private var list: some View {
        List(activity.events, selection: $activity.selection) { event in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: event))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if event.undoneBy != nil {
                        Text("undone")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(event.plan?.summary ?? event.summary)
                    .font(.callout)
                    .lineLimit(3)
                if let model = event.model {
                    Text("\(model)\(event.promptVersion.map { " · \($0)" } ?? "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 2)
            .tag(event.id)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(event.timestamp.formatted()): \(event.plan?.summary ?? event.summary)")
        }
        .overlay {
            if activity.events.isEmpty, !activity.isLoading {
                ContentUnavailableView(
                    "No organizations yet",
                    systemImage: "sparkles",
                    description: Text("When Filaway files a writing session, it appears here with a diff and an Undo.")
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let event = activity.selected {
            VStack(alignment: .leading, spacing: 0) {
                detailHeader(event)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(activity.diffs) { diff in
                            NoteDiffView(diff: diff) { reveal(diff.noteID) }
                        }
                        if activity.diffs.isEmpty {
                            Text("No before-and-after text was recorded for this event.")
                                .foregroundStyle(.secondary)
                        }
                        sessionTextSection
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ContentUnavailableView("Select an event", systemImage: "sidebar.left")
        }
    }

    private func detailHeader(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(event.plan?.summary ?? event.summary)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(event.timestamp.formatted(date: .long, time: .standard)) · ^[\(event.affectedNoteCount) note](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let reason = activity.undoBlockedReason, event.kind == .applied {
                    Label(reason, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Undo") { activity.undoSelected() }
                .disabled(!activity.canUndo)
                .accessibilityLabel("Undo this organization")
                .accessibilityHint(activity.undoBlockedReason ?? "Restores every note this change touched")
        }
        .padding(16)
    }

    @ViewBuilder
    private var sessionTextSection: some View {
        if let text = activity.sessionText, !text.isEmpty {
            DisclosureGroup("Raw session text") {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .font(.callout)
            .accessibilityHint("What you wrote in the session this change came from, kept for 30 days")
        }
    }

    private func symbol(for event: ActivityEvent) -> String {
        switch event.kind {
        case .applied: return "sparkles"
        case .undone: return "arrow.uturn.backward"
        case .proposedDismissed: return "xmark.circle"
        case .external: return "square.and.pencil"
        }
    }

    private func reveal(_ noteID: NoteID) {
        model.select(noteID: noteID)
        NSApp.windows.first { $0.title == "Filaway" || $0.identifier?.rawValue.contains("Filaway") == true }?
            .makeKeyAndOrderFront(nil)
    }
}
