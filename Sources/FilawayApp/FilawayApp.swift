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

        // Headless smoke check (plan §8): report the windows we opened, then
        // quit. Lets CI and a locked screen verify the shell without XCTest UI.
        if ProcessInfo.processInfo.environment["FILAWAY_SMOKE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for window in NSApp.windows where window.contentView != nil {
                    print("SMOKE window title=\"\(window.title)\" visible=\(window.isVisible) size=\(Int(window.frame.width))x\(Int(window.frame.height))")
                }
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Placeholder two-pane shell (spec Fig 1); filled in by M1-09.
struct ShellView: View {
    var body: some View {
        NavigationSplitView {
            Text("Recents / Library")
                .foregroundStyle(.secondary)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240)
        } detail: {
            Text("Editor")
                .foregroundStyle(.secondary)
        }
    }
}
