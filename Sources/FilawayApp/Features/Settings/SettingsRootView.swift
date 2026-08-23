import AppKit
import FilawayCore
import SwiftUI

/// The Settings window (⌘,) — FR-8.1.
///
/// Three tabs, matching the spec's grouping: **General** (notes folder, index),
/// **AI** (Figure 4 in full), **Activity** (the log's access point, FR-4.4).
/// M2-11 builds the AI tab; General and Activity carry the rows M4-02 and the
/// Activity milestone finish.
struct SettingsRootView: View {
    @ObservedObject var model: SettingsModel

    /// Which tab is showing. Named so the smoke driver can select one.
    enum Tab: String, Hashable, CaseIterable {
        case general, ai, activity
    }

    @State private var tab: Tab = .ai

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)

            AISettingsView(model: model)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(Tab.ai)

            ActivitySettingsView()
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.activity)
        }
        // A grouped Form scrolls itself, so a fixed window is right here: the
        // pane never resizes as rows appear (the Advanced disclosure) and the
        // window does not grow past a comfortable reading width.
        .frame(width: 560, height: 580)
        .background(SettingsWindowAccessor())
        .task { await model.refresh() }
    }
}

/// Hands the Settings scene's `NSWindow` to ``SettingsWindow``.
///
/// SwiftUI gives no way to address that window, and titling is no help — the
/// window is named after the selected tab. A zero-size view inside the scene
/// knows it for certain.
struct SettingsWindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Tracker() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Tracker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            MainActor.assumeIsolated { SettingsWindow.adopt(window) }
        }
    }
}

/// One labelled row of a settings form, with an optional explanatory footnote.
///
/// `LabeledContent` on its own loses the footnote's alignment, and every row in
/// Figure 4 is "label on the left, control on the right, quiet detail beneath".
struct SettingsRow<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title) { content }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// FR-6.3's always-visible privacy statement, verbatim from Figure 4 with the
/// real notes-folder path substituted.
///
/// It is *not* behind a disclosure and *not* only in onboarding: the spec wants
/// it visible whenever the user is looking at the AI settings.
struct PrivacyStatementView: View {
    let notesPath: String

    private var statement: String {
        "Notes are stored on disk at \(notesPath). Nothing is uploaded except text "
            + "sent to Claude during organization and search. Excluded folders are never sent."
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(statement)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Privacy. \(statement)")
    }
}
