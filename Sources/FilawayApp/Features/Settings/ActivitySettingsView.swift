import AppKit
import FilawayCore
import SwiftUI

/// Settings → Activity (FR-4.4, FR-8.1) — the log's access point.
///
/// The full history, its diffs and Undo live in the ⌥⌘A window; duplicating
/// them inside a 560-point preferences pane would be a worse copy of a good
/// window. What belongs here is the *access point* FR-8.1 asks for: the last
/// few things Filaway did, so the pane answers "has it been filing anything?"
/// without leaving Settings, and one button to the real thing.
struct ActivitySettingsView: View {
    @StateObject private var activity = ActivityModel()
    @Environment(\.openWindow) private var openWindow

    /// Enough to recognise the last session, few enough to stay a summary.
    private static let previewCount = 5

    var body: some View {
        Form {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Activity log")
                            .font(.headline)
                        Text("Everything the AI has filed, with the before-and-after text and Undo.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Open Activity") { openActivityWindow() }
                        .accessibilityLabel("Open the Activity window")
                        .accessibilityHint("Keyboard shortcut Option Command A")
                }
                .accessibilityElement(children: .contain)
            }

            Section("Recent") {
                if activity.events.isEmpty {
                    Text(activity.isLoading
                        ? "Loading…"
                        : "Nothing has been filed yet. When Filaway organizes a writing session, it appears here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(activity.events.prefix(Self.previewCount)) { event in
                        RecentActivityRow(event: event)
                    }
                }
            }

            Section {
                Label(
                    "Raw session text is kept for 30 days so a change can be explained, then deleted.",
                    systemImage: "clock.arrow.circlepath"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            activity.attach(to: AppModel.shared.organize)
            await activity.reload()
        }
    }

    /// ⌥⌘A's window. `openWindow` addresses the `Window` scene by id; the
    /// notification is the fallback for a build where the scene has not been
    /// created yet.
    private func openActivityWindow() {
        openWindow(id: ActivityWindowID.value)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// One line of the Settings preview: when, what, and whether it still stands.
private struct RecentActivityRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.plan?.summary ?? event.summary)
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RelativeTime.label(for: event.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if event.undoneBy != nil {
                Text("undone")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(event.plan?.summary ?? event.summary)
        .accessibilityValue(
            "\(RelativeTime.label(for: event.timestamp))\(event.undoneBy != nil ? ", undone" : "")"
        )
    }

    private var symbol: String {
        switch event.kind {
        case .applied: return "sparkles"
        case .undone: return "arrow.uturn.backward"
        case .proposedDismissed: return "xmark.circle"
        case .external: return "square.and.pencil"
        }
    }
}
