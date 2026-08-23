import AppKit
import FilawayCore

/// The FR-7.1 launch gate: first run shows the setup flow in its own window, and
/// the main window does not exist until it is answered.
///
/// **Why its own window, run modally.** The alternative — a sheet over the main
/// window — reads well but is a lie: the window behind the sheet is already an
/// open library, on a root the user has not chosen yet. `AppModel` binds its
/// `Library` when it is constructed, so the folder question has to be answered
/// *before* anything reads `AppSettings.notesRoot`. A modal window also matches
/// how macOS gates its own first runs (Setup Assistant, Migration Assistant): a
/// plain centred window that becomes the app once it is answered. See ADR-049.
///
/// **Why it is triggered from two places.** `applicationDidFinishLaunching` runs
/// it, and so does the first read of `AppSettings.notesRoot` — whichever comes
/// first. SwiftUI decides when it builds the scene, and `applicationWill\
/// FinishLaunching` cannot be used at all (implementing it on an
/// `@NSApplicationDelegateAdaptor` delegate replaces SwiftUI's own
/// implementation and the scene is never created). Making the *reader* of the
/// answer trigger the question removes the ordering question entirely.
///
/// Nothing here is reachable after the first run: ``runIfNeeded()`` returns
/// immediately once `onboardingCompleted` is set.
@MainActor
enum OnboardingPresenter {

    /// `true` when this launch actually showed the flow. `ShellView` reads it to
    /// put the caret in a fresh note on a brand-new library.
    private(set) static var didRunThisLaunch = false

    /// The window, while it is up. Exposed for the smoke check.
    private(set) static var window: NSWindow?

    /// Guards the modal against being started from inside itself.
    private static var isRunning = false

    /// Runs the flow if it is needed. Returns when the user has finished it.
    static func runIfNeeded() {
        guard !isRunning, OnboardingModel.isNeeded, shouldGateThisLaunch else { return }
        isRunning = true
        defer { isRunning = false }
        OnboardingSmokeCheck.armIfNeeded()
        let model = OnboardingModel.shared
        LaunchClock.mark("onboardingShown")

        NSApp.setActivationPolicy(.regular)
        let window = makeWindow(for: model)
        self.window = window
        didRunThisLaunch = true

        model.onFinish = { NSApp.stopModal() }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)

        window.orderOut(nil)
        window.close()
        self.window = nil
        controller = nil
        LaunchClock.mark("onboardingDone")
    }

    /// Every smoke phase starts on a fresh defaults suite, which means every one
    /// of them looks like a first run. Only the phases that are *about* the flow
    /// may be gated by it; the rest would deadlock on a modal nobody answers.
    private static var shouldGateThisLaunch: Bool {
        guard let phase = ProcessInfo.processInfo.environment["FILAWAY_SMOKE"], phase != "0"
        else { return true }
        return OnboardingSmokeCheck.handles(phase: phase)
    }

    /// Stops the modal session without completing the flow — the quit path, and
    /// the escape hatch the smoke driver uses when a phase has seen enough.
    static func abandon() {
        guard window != nil else { return }
        NSApp.stopModal()
    }

    /// Kept alive for the duration of the modal session.
    private static var controller: OnboardingWindowController?

    private static func makeWindow(for model: OnboardingModel) -> NSWindow {
        let controller = OnboardingWindowController(model: model)
        self.controller = controller
        return controller.window
    }
}
