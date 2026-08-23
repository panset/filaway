import FilawayCore
import SwiftUI

/// The organization card of spec Figure 2a (FR-4.2, FR-6.4).
///
/// ```text
///                       ┌──────────────────────────────────────────┐
///                       │ ✦  Session organized                     │
///                       │    Code block merged into Commands /     │
///                       │    curl. Token note appended to Auth      │
///                       │    API debug.                            │
///                       │                  Undo   ·  View changes  │
///                       └──────────────────────────────────────────┘
/// ```
///
/// **Where it sits.** Bottom-trailing of the editor pane, stacked newest at the
/// bottom. Two reasons over a top banner: the top strip already belongs to the
/// conflict/status `BannerView` — "the file changed under you" and "the AI has
/// a suggestion" are different enough to deserve different places — and the
/// caret is usually in the upper half of the pane, where a top banner would
/// cover the words the card is talking about. It never takes focus and it never
/// blocks a keystroke (FR-6.4's "no modal alerts").
///
/// **Ask vs auto** (FR-4.2). Ask mode is a question — *Organize this session?*
/// — with **Accept**, **Edit** and **Dismiss**, and it waits as long as it takes.
/// Auto mode is a statement — *Session organized* — with **Undo** and
/// **View changes**, and it fades after
/// ``OrganizeCoordinator/autoDismissInterval``; Undo stays reachable in the
/// Activity window (⌥⌘A) for at least the last ten events.
struct OrganizationCardView: View {
    let card: OrganizeCoordinator.Card
    var onAccept: () -> Void
    var onEdit: () -> Void
    var onDismiss: () -> Void
    var onUndo: () -> Void
    var onViewChanges: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
                .font(.system(size: 13, weight: .medium))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(card.title)
                    .font(.callout.weight(.semibold))
                Text(card.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let warning = card.warnings.first {
                    Label(warning.detail, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                buttons
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 12, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.accessibilityLabel)
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 8) {
            if card.isProposal {
                Button("Accept", action: onAccept)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Accept this organization plan")
                Button("Edit…", action: onEdit)
                    .accessibilityLabel("Edit this organization plan")
                Button("Dismiss", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Dismiss this organization plan")
            } else {
                Button("Undo", action: onUndo)
                    .accessibilityLabel("Undo this organization")
                Button("View changes", action: onViewChanges)
                    .accessibilityLabel("View the changes this organization made")
                Spacer(minLength: 0)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide this message")
            }
        }
        .controlSize(.small)
    }
}

/// The queue of cards, bottom-trailing in the editor pane. Several sessions can
/// finish while the user reads one, and none of them may be lost — so they
/// stack rather than replace each other.
struct OrganizationCardStack: View {
    @ObservedObject var coordinator: OrganizeCoordinator

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(coordinator.cards) { card in
                OrganizationCardView(
                    card: card,
                    onAccept: { coordinator.accept(card) },
                    onEdit: { coordinator.editingCard = card },
                    onDismiss: { card.isProposal ? coordinator.dismiss(card) : coordinator.remove(card) },
                    onUndo: { coordinator.undo(card) },
                    onViewChanges: { coordinator.changesCard = card }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.2), value: coordinator.cards)
    }
}
