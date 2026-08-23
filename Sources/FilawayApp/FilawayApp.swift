import AppKit
import FilawayCore
import SwiftUI

@main
struct FilawayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("Filaway") {
            ShellView(model: model)
        }
        .defaultSize(width: 1000, height: 680)
        .commands { AppCommands(model: model) }

        // Settings → General / AI / Activity, ⌘, (M2-11, FR-8.1).
        Settings {
            SettingsRootView(model: SettingsModel.shared)
        }
    }
}

/// Menu bar + shortcuts (FR-1.3, FR-1.4, NFR-6).
struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Note") { model.newNote() }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .toolbar) {
            Button("Search…") { model.focusSearch() }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Focus Sidebar") { model.focusSidebar() }
                .keyboardShortcut("1", modifiers: .command)
            Button("Focus Editor") { model.focusEditor() }
                .keyboardShortcut("2", modifiers: .command)
        }
        CommandGroup(after: .saveItem) {
            Button("Save Now") { Task { await model.flushNow(trigger: .manual) } }
                .keyboardShortcut("s", modifiers: .command)
            Button("Reveal Notes Folder in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([model.library.root])
            }
        }
    }
}

/// SwiftPM executables launch without a bundle when run directly, which leaves
/// the process as an accessory with no menu bar and no key window. Forcing
/// `.regular` + `activate` makes both `swift run` and the assembled
/// `build/Filaway.app` come to the front.
///
/// Also owns the AppKit-level flush points of FR-2.3 (resign active, terminate)
/// and the `didBecomeActive` stat-scan of DS-4.
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Log.app.info("Filaway \(FilawayCore.version, privacy: .public) launched")
        LaunchClock.mark("didFinishLaunching")

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AppModel.shared.reconcile() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AppModel.shared.flushNow(trigger: .appResignActive) }
        }

        // Headless smoke check (plan §8): drive the real code paths, print what
        // happened, then quit with a non-zero status on failure. Lets CI and a
        // locked screen verify the shell without XCTest UI.
        if let phase = ProcessInfo.processInfo.environment["FILAWAY_SMOKE"], phase != "0" {
            if SettingsSmokeCheck.handles(phase: phase) {
                SettingsSmokeCheck.start(phase: phase)
            } else {
                SmokeDriver.start(phase: phase)
            }
        }
    }

    /// FR-2.3: nothing typed may be lost on quit.
    ///
    /// The main thread has to block here until the last buffer is on disk, and
    /// a blocked main thread cannot run main-actor work — neither
    /// `.terminateLater` (AppKit waits in a private run-loop mode) nor pumping
    /// the run loop helps, because the main dispatch queue will not drain
    /// reentrantly. `terminateFlushTask()` therefore does the writing on a
    /// detached task that touches only actors, and this waits on a semaphore.
    /// Bounded by a deadline so a wedged write can never block quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true

        let flush = MainActor.assumeIsolated { AppModel.shared.terminateFlushTask() }
        var finished = true
        if let flush {
            let done = DispatchSemaphore(value: 0)
            Task.detached(priority: .userInitiated) {
                _ = await flush.value
                done.signal()
            }
            finished = done.wait(timeout: .now() + Self.terminateFlushBudget) == .success
        }
        if !finished {
            Log.app.error("terminate flush did not finish within \(Self.terminateFlushBudget, privacy: .public)s")
        }
        if AppSettings.isSmokeRun {
            print("SMOKE \(finished ? "ok  " : "FAIL") terminate-flush-finished")
            fflush(stdout)
        }
        return .terminateNow
    }

    /// How long quitting may wait for the last write.
    private static let terminateFlushBudget: TimeInterval = 5

    func applicationWillTerminate(_ notification: Notification) {
        SmokeDriver.applicationWillTerminate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Launch-timing instrumentation (NFR-1: cold launch to editable < 2 s).
///
/// Measured from the kernel's own process start time rather than from the first
/// Swift statement, so the numbers include dyld and AppKit bring-up.
enum LaunchClock {
    nonisolated(unsafe) private(set) static var marks: [(String, Double)] = []

    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1e6)
    }()

    static func mark(_ label: String) {
        marks.append((label, max(0, Date().timeIntervalSince(processStart) * 1000)))
    }

    static var summary: String {
        marks.map { String(format: "%@=%.0fms", $0.0, $0.1) }.joined(separator: " ")
    }
}
