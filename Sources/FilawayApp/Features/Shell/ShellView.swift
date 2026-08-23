import AppKit
import FilawayCore
import SwiftUI

/// The two-pane window of Figure 1 (FR-1.1): sidebar left, editor right, a
/// toolbar carrying New Note and the unified search field.
///
/// System colors and materials only, so light and dark both come for free
/// (NFR-6/7).
struct ShellView: View {

    @ObservedObject var model: AppModel
    @StateObject private var editor = MarkdownEditorController()
    @FocusState private var searchFocused: Bool
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    /// Read once per launch: `navigationSplitViewColumnWidth` only honours its
    /// ideal at first layout (FR-1.5).
    private let initialSidebarWidth = AppSettings.sidebarWidth

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(
                    min: AppSettings.sidebarMinWidth,
                    ideal: initialSidebarWidth,
                    max: AppSettings.sidebarMaxWidth
                )
                .background(WidthReporter { AppSettings.sidebarWidth = $0 })
        } detail: {
            detail
        }
        // The ⌘K panel hangs off the whole window, not the detail pane, so it
        // lands under the toolbar's centred search field (Figure 2b, ADR-025).
        .overlay(alignment: .top) { searchOverlay }
        .navigationTitle(model.openNote?.title ?? "Filaway")
        .toolbar { toolbar }
        .background(WindowAccessor(onWindow: configure(window:)))
        .task {
            LaunchClock.mark("shellAppeared")
            await model.bootstrap()
            LaunchClock.mark("editorReady")
        }
        .onChange(of: model.focusEditorRequest) { _, _ in
            DispatchQueue.main.async { editor.focus() }
        }
        .onChange(of: model.focusSearchRequest) { _, _ in
            searchFocused = true
            // ⌘K selects what is already in the field, like every other macOS
            // search field, so the next keystroke replaces the old query.
            DispatchQueue.main.async { SearchFieldSelection.selectAllInFocusedField() }
        }
        .onChange(of: model.focusSidebarRequest) { _, _ in
            searchFocused = false
            FirstResponder.focusSidebar()
        }
        .onChange(of: model.reveal) { _, request in
            guard let request else { return }
            // Switching notes rebuilds the editor (`.id(open.id)`); one turn of
            // the run loop lets the new text view attach and lay out before we
            // scroll it.
            DispatchQueue.main.async {
                editor.focus()
                editor.scrollTo(range: request.range, select: request.selects)
            }
        }
    }

    // MARK: - ⌘K panel (Figure 2b, FR-1.3, FR-5.1)

    private var searchOverlay: some View {
        SearchOverlay(coordinator: model.search) { searchFocused = false }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        ZStack(alignment: .top) {
            if let open = model.openNote {
                NoteEditorView(
                    title: $model.editorTitle,
                    markdown: $model.editorText,
                    createdAt: open.created,
                    controller: editor,
                    onTitleCommit: { model.commitTitle($0) },
                    onTextChange: { text in
                        EditorCallbackLog.recordTextChange()
                        model.editorTextChanged(text)
                    },
                    onEditorActivity: { activity in
                        EditorCallbackLog.record(activity)
                        // FR-3.1: scrolling and selecting sustain a session.
                        model.editorActivityHappened(activity)
                    }
                )
                // A fresh editor per note: resets scroll, selection and the
                // title field's committed value on every switch.
                .id(open.id)
            } else {
                welcome
            }

            if let banner = model.banner {
                BannerView(banner: banner) { model.dismissBanner() }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // The organization card (Figure 2a) is bottom-trailing so it never
        // covers the caret or fights the top banner — ADR-036.
        .overlay(alignment: .bottomTrailing) {
            if let organize = model.organize {
                OrganizationCardStack(coordinator: organize)
                    .sheet(item: Binding(
                        get: { organize.editingCard },
                        set: { organize.editingCard = $0 }
                    )) { card in
                        EditPlanSheet(
                            card: card,
                            library: model.planLibrary,
                            onApply: { organize.accept(card, editedPlan: $0) },
                            onCancel: {}
                        )
                    }
                    .sheet(item: Binding(
                        get: { organize.changesCard },
                        set: { organize.changesCard = $0 }
                    )) { card in
                        ChangesSheetLoader(card: card, model: model, coordinator: organize)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.banner)
        .navigationSplitViewColumnWidth(min: 420, ideal: 720)
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text(model.noteCount == 0 ? "Start writing" : "No note selected")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("⌘N makes a new note. Everything is saved as Markdown in \(model.library.root.path).")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("New Note") { model.newNote() }
                .keyboardShortcut("n", modifiers: .command)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                NSApp.keyWindow?.firstResponder?.tryToPerform(
                    #selector(NSSplitViewController.toggleSidebar(_:)), with: nil
                )
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Hide or show the sidebar")
            .accessibilityLabel("Toggle Sidebar")
        }

        ToolbarItem(placement: .principal) {
            SearchFieldView(coordinator: model.search, isFocused: $searchFocused)
        }

        // FR-6.4: degradation is one quiet pill, never an alert.
        ToolbarItem(placement: .status) {
            if let organize = model.organize {
                AIStatusIndicatorHost(coordinator: organize)
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.newNote()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("New Note (⌘N)")
            .accessibilityLabel("New Note")
        }
    }

    // MARK: - Window (FR-1.5, FR-2.3)

    private func configure(window: NSWindow) {
        LaunchClock.mark("windowVisible")
        window.setFrameAutosaveName(AppSettings.windowFrameAutosaveName)
        window.tabbingMode = .disallowed
        WindowFlushObserver.shared.observe(window: window, model: model)
    }
}

/// Observes the coordinator so the pill redraws when the status moves.
struct AIStatusIndicatorHost: View {
    @ObservedObject var coordinator: OrganizeCoordinator

    var body: some View {
        AIStatusIndicator(
            status: coordinator.status,
            queuedCount: coordinator.queuedSessionCount,
            onOpenSettings: { coordinator.onOpenAISettings?() }
        )
    }
}

/// Loads the diff for a card before showing the sheet — `ActivityLog.diff(for:)`
/// is a database read, and a sheet body cannot await.
struct ChangesSheetLoader: View {
    let card: OrganizeCoordinator.Card
    @ObservedObject var model: AppModel
    let coordinator: OrganizeCoordinator
    @State private var diffs: [NoteDiff] = []

    var body: some View {
        ViewChangesSheet(
            card: card,
            library: model.planLibrary,
            diffs: diffs,
            onReveal: { model.select(noteID: $0) }
        )
        .task {
            guard let eventID = card.eventID, let activity = coordinator.activity else { return }
            diffs = (try? await activity.diff(for: eventID)) ?? []
        }
    }
}

/// The non-blocking conflict/status strip (DS-4).
struct BannerView: View {
    var banner: AppModel.Banner
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: banner.symbol)
                .foregroundStyle(banner.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
            Text(banner.text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(banner.text)
    }
}

/// Flushes the autosave buffer when the window stops being key (FR-2.3).
@MainActor
final class WindowFlushObserver {
    static let shared = WindowFlushObserver()
    private var observed = Set<ObjectIdentifier>()

    func observe(window: NSWindow, model: AppModel) {
        guard observed.insert(ObjectIdentifier(window)).inserted else { return }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { _ in
            Task { @MainActor in await model.flushNow(trigger: .windowResignKey) }
        }
    }
}
