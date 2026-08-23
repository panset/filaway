import FilawayCore
import SwiftUI

/// FR-4.2's **View changes** — for a plan that has been applied, and for one
/// that has only been proposed.
///
/// * **Applied** (auto mode, or Accept, or any Activity row): the real thing —
///   `ActivityLog.diff(for:)`, a unified diff per affected note, straight from
///   the before/after images the journal wrote. Every note has "Reveal in
///   Library".
/// * **Proposed** (ask mode): there are no images yet, because nothing has
///   touched the disk — that is the whole promise of ask mode. Rather than
///   fabricate a diff by simulating the applier (a second implementation of
///   apply, and the one place a bug would be invisible), it shows the plan's
///   actions as a structured preview and says plainly that the diff arrives
///   once the change is applied.
struct ViewChangesSheet: View {
    let card: OrganizeCoordinator.Card
    let library: PlanPresentation.Library
    var diffs: [NoteDiff]
    var onReveal: (NoteID) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if card.isProposal {
                        proposedPreview
                    } else if diffs.isEmpty {
                        Text("No before-and-after text was recorded for this change.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(diffs) { diff in
                            NoteDiffView(diff: diff) { onReveal(diff.noteID) }
                        }
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 640, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(card.isProposal ? "What this would change" : "What changed")
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
    private var proposedPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((card.plan?.actions ?? []).enumerated()), id: \.offset) { _, action in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: PlanPresentation.symbol(for: action.kind))
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(PlanPresentation.describe(action, in: library))
                        if let detail = PlanPresentation.detail(action) {
                            Text(detail)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Label(
                "Nothing has been written yet. Accept the card to apply it — the line-by-line diff appears in Activity (⌥⌘A) afterwards.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}
