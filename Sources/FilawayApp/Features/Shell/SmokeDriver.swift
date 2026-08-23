import AppKit
import FilawayCore

/// Headless end-to-end driver for the shell (plan §8: no Xcode ⇒ no XCTest UI
/// tests, and the screen may be locked).
///
/// It drives the *real* objects — `AppModel`, `NoteStore`, the live
/// `NSTextView` — prints one line per assertion, and exits with the number of
/// failures. `Tools/smoke.sh` runs the phases in order against a throwaway
/// `FILAWAY_NOTES_ROOT`.
///
/// ```
/// FILAWAY_SMOKE=1 FILAWAY_NOTES_ROOT=/tmp/x build/Filaway.app/Contents/MacOS/Filaway
/// ```
///
/// | Phase | What it proves |
/// |---|---|
/// | `editor` | The M1-10 editor checks, now against a note read from disk. |
/// | `search` | The M1-12 ⌘K checks against a corpus seeded on disk before launch: as-you-type hits, keyboard nav, open-scrolled-to-match, fuzzy titles, recents, Escape. |
/// | `kill` / `killcheck` | Type, wait out the debounce, type again, park — the script sends SIGKILL; the relaunch proves ≤ one 750 ms burst was lost (FR-2.3, NFR-3). |
/// | `1` | Empty sidebar → ⌘N → type → autosave lands on disk → rename renames the file → an external edit reaches the sidebar → a final burst is flushed by terminate. |
/// | `2` | Relaunch on the same root restores the last note *and* the burst typed immediately before quit (FR-1.5, FR-2.3). |
@MainActor
enum SmokeDriver {

    private static var failures = 0
    private static var isDriving = false

    /// Text typed in phase 1 and asserted in both phases.
    private static let typedBody = "curl -H \"Auth: Bearer $TOK\" https://api.st.app/v2/docs\n"
    /// Typed immediately before quitting, with no time to debounce.
    private static let lastBurst = "one more line before quit\n"
    private static let renamedTitle = "Staging docs"
    private static let externalTitle = "Made outside Filaway"

    static func start(phase: String) {
        isDriving = true
        Task { @MainActor in
            // Let the scene build and `AppModel.bootstrap()` finish.
            await settle(seconds: 1.0)
            switch phase {
            case "editor": await runEditorPhase()
            case "search": await runSearchPhase()
            case "kill": await runKillPhase()
            case "killcheck": await runKillCheckPhase()
            case "2": await runRelaunchPhase()
            default: await runCapturePhase()
            }
        }
    }

    /// Called from `applicationWillTerminate` so the exit status reflects the
    /// run even when the driver quit through the real terminate path.
    static func applicationWillTerminate() {
        guard isDriving else { return }
        print("SMOKE ok   terminate-completed")
        print("SMOKE result failures=\(failures)")
        fflush(stdout)
        exit(Int32(min(failures, 120)))
    }

    // MARK: - Phase: capture (M1-14)

    private static func runCapturePhase() async {
        let model = AppModel.shared
        header()
        check("library-root-is-override", model.library.root.path == AppSettings.notesRoot.path,
              model.library.root.path)

        // 1 — a fresh ~/Notes shows an empty sidebar.
        check("sidebar-empty-on-first-launch", model.noteCount == 0 && model.recents.isEmpty,
              "notes=\(model.noteCount) recents=\(model.recents.count)")
        check("no-note-open", model.openNote == nil)

        // 2 — ⌘N: a blank untitled note, selected, focus in the body (FR-1.4).
        guard let created = await model.newNoteAsync() else {
            check("new-note", false, "createNote failed")
            return finish()
        }
        await settle(seconds: 0.2)
        check("new-note-is-untitled", model.openNote?.title == PathRules.untitled,
              model.openNote?.title ?? "nil")
        check("new-note-selected", model.selection?.noteID == created)
        check("new-note-in-recents", model.recents.first?.id == created)
        check("new-note-body-empty", model.editorText.isEmpty)

        guard let editor = MarkdownEditorController.mostRecent else {
            check("editor-attached", false, "no MarkdownEditorView")
            return finish()
        }
        check("editor-attached", true)
        check("editor-has-focus", editor.isFirstResponder)

        // 3 — type through the real insertion path, then wait out the debounce.
        editor.insertText(typedBody)
        check("typing-marks-note-dirty", model.dirtyNoteIDs.contains(created) || model.editorText == typedBody)
        check("recents-shows-editing",
              model.recents.first.map { recentSubtitleIsEditing($0.id) } ?? false)

        await settle(seconds: 1.4)  // > 750 ms debounce
        let notePath = model.library.url(for: model.openNote?.relativePath ?? "")
        let onDisk = (try? String(contentsOf: notePath, encoding: .utf8)) ?? ""
        check("autosave-wrote-file", FileManager.default.fileExists(atPath: notePath.path), notePath.lastPathComponent)
        check("autosave-file-has-text", onDisk.contains(typedBody.trimmingCharacters(in: .newlines)),
              String(onDisk.suffix(60)).debugDescription)
        check("autosave-file-has-front-matter", onDisk.hasPrefix("---\n"))
        check("note-clean-after-flush", !model.dirtyNoteIDs.contains(created))

        // 4 — retitle: DS-1 makes the filename stem the title.
        await model.commitTitleAsync(renamedTitle)
        await settle(seconds: 0.4)
        let renamedPath = model.library.url(for: model.openNote?.relativePath ?? "")
        check("rename-changed-path", renamedPath.lastPathComponent == "\(renamedTitle).md",
              renamedPath.lastPathComponent)
        check("rename-file-exists", FileManager.default.fileExists(atPath: renamedPath.path))
        check("rename-old-file-gone", !FileManager.default.fileExists(atPath: notePath.path))
        check("rename-kept-selection", model.openNote?.id == created)
        check("rename-body-survived",
              ((try? String(contentsOf: renamedPath, encoding: .utf8)) ?? "").contains("api.st.app"))

        // 5 — an external edit of a *different* note reaches the sidebar (DS-4).
        let externalURL = model.library.url(for: "\(externalTitle).md")
        try? "written by another app\n".write(to: externalURL, atomically: true, encoding: .utf8)
        let sawExternal = await poll(seconds: 15) {
            model.tree?.notes.contains { $0.title == externalTitle } ?? false
        }
        check("external-note-reached-sidebar", sawExternal, "notes=\(model.noteCount)")
        check("external-note-in-recents", model.recents.contains { $0.note.title == externalTitle })
        check("external-edit-kept-selection", model.openNote?.id == created)

        // 6 — a burst typed with no time to debounce must survive the quit.
        editor.focus()
        editor.scrollTo(range: NSRange(location: (editor.text as NSString).length, length: 0), select: false)
        editor.insertText(lastBurst)
        check("last-burst-is-dirty", model.dirtyNoteIDs.contains(created),
              "dirty=\(model.dirtyNoteIDs.count)")
        print("SMOKE info launch \(LaunchClock.summary)")
        fflush(stdout)
        // Real terminate path: applicationShouldTerminate flushes, then
        // applicationWillTerminate exits with the failure count.
        Task { @MainActor in
            await settle(seconds: 20)
            print("SMOKE FAIL terminate-completed — applicationShouldTerminate never finished")
            failures += 1
            print("SMOKE result failures=\(failures)")
            fflush(stdout)
            exit(Int32(min(failures, 120)))
        }
        NSApp.terminate(nil)
    }

    // MARK: - Phase: relaunch (FR-1.5)

    private static func runRelaunchPhase() async {
        let model = AppModel.shared
        header()
        _ = await poll(seconds: 8) { model.isLoaded && model.openNote != nil }

        check("last-note-restored", model.openNote?.title == renamedTitle,
              model.openNote?.title ?? "nil")
        check("restored-body-has-typed-text", model.editorText.contains("api.st.app"),
              String(model.editorText.prefix(60)).debugDescription)
        check("terminate-flushed-last-burst",
              model.editorText.contains(lastBurst.trimmingCharacters(in: .newlines)),
              String(model.editorText.suffix(60)).debugDescription)
        check("sidebar-restored", model.noteCount >= 2, "notes=\(model.noteCount)")
        check("external-note-still-there",
              model.tree?.notes.contains { $0.title == externalTitle } ?? false)
        check("recents-ordered-newest-first",
              model.recents.first?.id == model.openNote?.id,
              model.recents.map(\.note.title).joined(separator: ", "))
        print("SMOKE info launch \(LaunchClock.summary)")
        print("SMOKE phase=2 result failures=\(failures)")
        finish()
    }

    // MARK: - Phase: kill (FR-2.3 / NFR-3, the `kill -9` DoD row)

    /// Title and bursts shared by the `kill` and `killcheck` phases.
    static let killTitle = "Kill test"
    /// Typed, then given longer than the 750 ms debounce: must survive SIGKILL.
    static let survivingBurst = "this burst was typed well before the kill\n"
    /// Typed in the last instant: allowed to be lost, nothing else is.
    static let doomedBurst = "typed a moment before SIGKILL\n"

    /// Types, waits out the debounce, types again, then parks and prints
    /// `SMOKE ready-for-kill`. `Tools/smoke.sh` sees that line and sends
    /// SIGKILL — the app gets no terminate handler, no flush, no chance to
    /// tidy up, which is exactly the point.
    private static func runKillPhase() async {
        let model = AppModel.shared
        header()
        guard await model.newNoteAsync() != nil else {
            check("kill-new-note", false)
            return finish()
        }
        await model.commitTitleAsync(killTitle)
        await settle(seconds: 0.4)
        guard let editor = MarkdownEditorController.mostRecent else {
            check("kill-editor-attached", false)
            return finish()
        }
        editor.insertText(survivingBurst)
        // > 750 ms debounce, so this burst is on disk before the kill.
        await settle(seconds: 1.4)
        check("kill-first-burst-flushed", !model.dirtyNoteIDs.contains(model.openNote?.id ?? NoteID()))
        editor.insertText(doomedBurst)
        print("SMOKE info note=\(model.openNote?.relativePath ?? "nil")")
        print("SMOKE ready-for-kill")
        fflush(stdout)
        // Park. The script kills us; anything printed after this never happens.
        await settle(seconds: 120)
        check("kill-was-delivered", false, "the script never sent SIGKILL")
        finish()
    }

    /// Relaunch after the SIGKILL: the pre-debounce burst is on disk and the
    /// library opens cleanly after an unclean shutdown.
    private static func runKillCheckPhase() async {
        let model = AppModel.shared
        header()
        _ = await poll(seconds: 15) { model.isLoaded && model.noteCount >= 1 }
        check("library-opens-after-sigkill", model.isLoaded && model.noteCount >= 1,
              "notes=\(model.noteCount)")

        let url = model.library.url(for: "\(killTitle).md")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check("sigkill-file-exists", FileManager.default.fileExists(atPath: url.path),
              url.lastPathComponent)
        check("sigkill-kept-debounced-burst",
              text.contains(survivingBurst.trimmingCharacters(in: .newlines)),
              String(text.suffix(80)).debugDescription)
        check("sigkill-file-not-truncated", text.hasPrefix("---\n"))
        // The last burst is allowed to be lost — that is the ≤750 ms window
        // FR-2.3 buys. Reported, never asserted.
        print("SMOKE info last-burst-survived="
            + "\(text.contains(doomedBurst.trimmingCharacters(in: .newlines)))")
        check("sigkill-note-in-sidebar",
              model.tree?.notes.contains { $0.title == killTitle } ?? false)
        print("SMOKE phase=killcheck result failures=\(failures)")
        finish()
    }

    // MARK: - Phase: search (M1-12)

    /// The corpus is already on disk when the app starts (`Tools/smoke.sh`
    /// seeds it), so this also covers "a cold launch on an unknown library
    /// indexes it".
    private static func runSearchPhase() async {
        header()
        failures += await SearchSmokeCheck.run()
        print("SMOKE phase=search result failures=\(failures)")
        finish()
    }

    // MARK: - Phase: editor (M1-10 regression, now on a real note)

    private static func runEditorPhase() async {
        let model = AppModel.shared
        header()
        guard let store = model.store, let metadata = model.metadata else {
            check("library-open", false)
            return finish()
        }
        do {
            let note = try await store.createNote(inFolder: "", title: "Sample", body: SampleNote.markdown)
            try await metadata.apply([.added(note.summary)])
            await model.refreshSidebarNow()
            await model.open(noteID: note.id)
            await settle(seconds: 0.5)
        } catch {
            check("sample-note-created", false, String(describing: error))
            return finish()
        }
        check("sample-note-open", model.openNote?.title == "Sample")
        check("body-round-tripped-through-disk", model.editorText == SampleNote.markdown)
        failures += EditorSmokeCheck.run(printResult: false)
        print("SMOKE phase=editor result failures=\(failures)")
        finish()
    }

    // MARK: - Helpers

    private static func header() {
        for window in NSApp.windows where window.contentView != nil {
            print("SMOKE window title=\"\(window.title)\" visible=\(window.isVisible) "
                + "size=\(Int(window.frame.width))x\(Int(window.frame.height))")
        }
        print("SMOKE info root=\(AppSettings.notesRoot.path)")
    }

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures += 1 }
        print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func recentSubtitleIsEditing(_ id: NoteID) -> Bool {
        AppModel.shared.dirtyNoteIDs.contains(id) || AppModel.shared.openNote?.id == id
    }

    private static func finish() {
        print("SMOKE result failures=\(failures)")
        fflush(stdout)
        exit(Int32(min(failures, 120)))
    }

    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    /// Waits for an asynchronous effect (FSEvents, a reconcile) with a deadline.
    private static func poll(seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await settle(seconds: 0.15)
        }
        return condition()
    }
}
