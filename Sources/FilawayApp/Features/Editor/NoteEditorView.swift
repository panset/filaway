import AppKit
import SwiftUI

/// The editor pane of Figure 1: date stamp, title field, body.
///
/// The caller owns the note. Renaming on commit (title → filename) is the
/// shell's job (M1-09/M1-11); this view only reports it.
struct NoteEditorView: View {

    @Binding var title: String
    /// The note's Markdown source.
    @Binding var markdown: String
    /// Creation date, shown as the date stamp.
    var createdAt: Date
    var controller: MarkdownEditorController

    /// Fired when the title field is committed (Return) or loses focus.
    var onTitleCommit: ((String) -> Void)?
    var onTextChange: ((String) -> Void)?
    var onEditorActivity: ((EditorActivity) -> Void)?

    @FocusState private var titleFocused: Bool
    @State private var committedTitle: String = ""

    private var theme: MarkdownTheme { MarkdownTheme.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, theme.textLeading)
                .padding(.top, 16)

            MarkdownEditorView(
                text: $markdown,
                controller: controller,
                onTextChange: onTextChange,
                onEditorActivity: onEditorActivity
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { committedTitle = title }
    }

    /// Date stamp + title, aligned with the body text's container inset.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Self.dateStamp(createdAt))
                .font(.system(size: theme.dateStampFont.pointSize))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
                .accessibilityLabel("Created \(Self.dateStamp(createdAt))")

            TextField("Untitled note", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: theme.titleFont.pointSize, weight: .semibold))
                .focused($titleFocused)
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .accessibilityLabel("Note title")
                .padding(.bottom, 10)
        }
    }

    private func commitTitle() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != committedTitle else { return }
        committedTitle = trimmed
        onTitleCommit?(trimmed)
    }

    /// "August 22, 2026 · 9:41", as in Figure 1.
    static func dateStamp(_ date: Date) -> String {
        let day = DateFormatter()
        day.dateStyle = .long
        day.timeStyle = .none
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(day.string(from: date)) · \(time.string(from: date))"
    }
}
