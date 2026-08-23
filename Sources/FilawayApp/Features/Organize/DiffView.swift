import AppKit
import FilawayCore
import SwiftUI

/// A unified diff, coloured (FR-4.3's "show a diff of what changed").
///
/// The source is `ActivityLog.diff(for:)`, which diffs each note's **body** —
/// front matter is stripped, because an `id:` appearing on first save is not a
/// change the user made. Rendered as monospaced lines with a green/red wash and
/// the `+`/`-` marker kept, so it reads the same to a colour-blind user and
/// copies out as a real patch.
struct NoteDiffView: View {
    let diff: NoteDiff
    var onReveal: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if diff.diff.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        Text(hunk.header)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.vertical, 2)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            lineView(line)
                        }
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(diff.title)
                    .font(.callout.weight(.semibold))
                Text(pathLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let onReveal {
                Button("Reveal in Library", action: onReveal)
                    .controlSize(.small)
                    .accessibilityLabel("Reveal \(diff.title) in the Library")
            }
        }
    }

    private var pathLine: String {
        if diff.created { return "new note · \(diff.afterPath ?? "")" }
        if diff.trashed { return "moved to the Trash · was \(diff.beforePath ?? "")" }
        if diff.wasRelocated { return "\(diff.beforePath ?? "") → \(diff.afterPath ?? "")" }
        return diff.afterPath ?? diff.beforePath ?? ""
    }

    private var emptyMessage: String {
        if diff.created { return "Created with this content." }
        if diff.trashed { return "Moved to the Trash with its text intact." }
        if diff.wasRelocated { return "Only the location changed; the text is identical." }
        return "No textual change."
    }

    private var accessibilitySummary: String {
        "\(diff.title): \(diff.diff.insertedLineCount) lines added, \(diff.diff.deletedLineCount) removed"
    }

    @ViewBuilder
    private func lineView(_ line: DiffLine) -> some View {
        Text("\(String(line.kind.marker))\(line.text)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(color(for: line.kind))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 0.5)
            .background(background(for: line.kind))
    }

    private func color(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .insert: return .green
        case .delete: return .red
        case .context: return .primary
        }
    }

    private func background(for kind: DiffLine.Kind) -> Color {
        switch kind {
        case .insert: return Color.green.opacity(0.10)
        case .delete: return Color.red.opacity(0.10)
        case .context: return .clear
        }
    }
}
