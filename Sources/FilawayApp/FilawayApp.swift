import AppKit
import FilawayCore
import SwiftUI

@main
struct FilawayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Filaway") {
            ShellView()
        }
        .defaultSize(width: 1000, height: 680)
    }
}

/// SwiftPM executables launch without a bundle when run directly, which leaves
/// the process as an accessory with no menu bar and no key window. Forcing
/// `.regular` + `activate` makes both `swift run` and the assembled
/// `build/Filaway.app` come to the front.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.app.info("Filaway \(FilawayCore.version, privacy: .public) launched")

        // Headless smoke check (plan §8): drive the real editor code paths,
        // print what happened, then quit with a non-zero status on failure.
        // Lets CI and a locked screen verify the shell without XCTest UI.
        if ProcessInfo.processInfo.environment["FILAWAY_SMOKE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let failures = EditorSmokeCheck.run()
                fflush(stdout)
                exit(failures == 0 ? 0 : 1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Two-pane shell (spec Fig 1). The sidebar is still the M1-09 placeholder; the
/// detail pane is the real editor (M1-10) on an in-memory sample note until
/// storage (M1-03) lands.
struct ShellView: View {
    @StateObject private var editor = MarkdownEditorController()
    @State private var title = SampleNote.title
    @State private var markdown = SampleNote.markdown

    var body: some View {
        NavigationSplitView {
            Text("Recents / Library")
                .foregroundStyle(.secondary)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            NoteEditorView(
                title: $title,
                markdown: $markdown,
                createdAt: SampleNote.createdAt,
                controller: editor,
                onTitleCommit: { newTitle in
                    // M1-09/M1-11 rename the file here.
                    Log.app.debug("title committed (\(newTitle.count, privacy: .public) chars)")
                },
                onTextChange: { _ in
                    // M1-11 autosave hooks in here (750 ms debounce).
                    EditorCallbackLog.recordTextChange()
                },
                onEditorActivity: { activity in
                    // M2-03 session tracker hooks in here.
                    EditorCallbackLog.record(activity)
                }
            )
        }
    }
}
