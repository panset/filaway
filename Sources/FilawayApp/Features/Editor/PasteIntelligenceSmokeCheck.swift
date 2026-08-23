import AppKit
import FilawayCore

/// Headless end-to-end check for M4-03 (plan §8: no Xcode ⇒ no XCTest UI tests).
///
/// Phase `paste`: create a note, open it, put a `curl` line on the real
/// pasteboard, run the real ⌘V path (`NSTextView.paste`), and assert that the
/// text landed verbatim, that the affordance appeared, that `Wrap` produced a
/// fenced block with the right language tag, and that one ⌘Z takes the document
/// back to the plain paste. Then paste a sentence and assert nothing is offered.
///
/// ```
/// FILAWAY_SMOKE=paste FILAWAY_NOTES_ROOT=/tmp/x build/Filaway.app/Contents/MacOS/Filaway
/// ```
@MainActor
enum PasteIntelligenceSmokeCheck {

    private static var failures = 0

    private static let command = #"curl -H "Auth: Bearer $TOK" https://api.st.app/v2/docs"#
    private static let prose = "The 401 only happens after the bearer token rotates."

    static func handles(phase: String) -> Bool { phase == "paste" }

    static func start(phase: String) {
        Task { @MainActor in
            await settle(seconds: 1.0)
            await run()
        }
    }

    private static func run() async {
        let model = AppModel.shared
        print("SMOKE info root=\(AppSettings.notesRoot.path)")
        print("SMOKE info paste-intelligence-enabled=\(AppSettings.core.pasteIntelligenceEnabled)")

        _ = await poll(seconds: 15) { model.isLoaded && model.store != nil }
        for window in NSApp.windows where window.contentView != nil {
            print("SMOKE window title=\"\(window.title)\" visible=\(window.isVisible) "
                + "size=\(Int(window.frame.width))x\(Int(window.frame.height))")
        }
        guard let store = model.store, let metadata = model.metadata else {
            return fail("library-open", "isLoaded=\(model.isLoaded)")
        }
        do {
            let note = try await store.createNote(inFolder: "", title: "Paste target", body: "notes:\n")
            try await metadata.apply([.added(note.summary)])
            await model.refreshSidebarNow()
            await model.open(noteID: note.id)
            await settle(seconds: 0.5)
        } catch {
            return fail("note-created", String(describing: error))
        }
        guard let editor = MarkdownEditorController.mostRecent else {
            return fail("editor-attached", "no MarkdownEditorView")
        }

        // 1 — a command reaches the document verbatim and raises the offer.
        editor.scrollTo(range: NSRange(location: (editor.text as NSString).length, length: 0), select: false)
        put(command)
        editor.paste()
        await settle(seconds: 0.3)
        check("paste-landed-verbatim", editor.text.contains(command),
              String(editor.text.suffix(70)).debugDescription)
        check("classified-as-shell", editor.pasteSuggestion?.kind == .shellCommand(language: "bash"),
              String(describing: editor.pasteSuggestion?.kind))
        check("affordance-visible", editor.isPasteAffordanceVisible, editor.pasteAffordanceText)
        check("affordance-names-the-language", editor.pasteAffordanceText.contains("bash"),
              editor.pasteAffordanceText)

        // 2 — Wrap fences it, with the language tag, and withdraws the offer.
        let before = editor.text
        check("wrap-clicked", editor.wrapPastedText())
        await settle(seconds: 0.2)
        check("wrapped-in-fence", editor.text.contains("```bash\n\(command)\n```"),
              String(editor.text.suffix(90)).debugDescription)
        check("wrap-is-one-code-block", editor.codeBlocks.count == 1, "\(editor.codeBlocks.count)")
        check("wrapped-code-text-is-the-command", editor.codeText(at: 0) == command,
              editor.codeText(at: 0)?.debugDescription ?? "nil")
        check("affordance-withdrawn-after-wrap", !editor.isPasteAffordanceVisible)

        // 3 — one undo step, back to the plain paste (FR-2.4 must be reversible).
        editor.undo()
        await settle(seconds: 0.2)
        check("undo-restores-the-plain-paste", editor.text == before,
              String(editor.text.suffix(70)).debugDescription)

        // 4 — prose is never offered.
        editor.dismissPasteAffordance()
        editor.scrollTo(range: NSRange(location: (editor.text as NSString).length, length: 0), select: false)
        put("\n" + prose)
        editor.paste()
        await settle(seconds: 0.3)
        check("prose-pasted", editor.text.contains(prose))
        check("prose-offers-nothing", editor.pasteSuggestion == nil,
              String(describing: editor.pasteSuggestion?.kind))
        check("no-affordance-for-prose", !editor.isPasteAffordanceVisible)

        // 5 — the FR-8.1 switch turns the whole thing off.
        AppSettings.core.pasteIntelligenceEnabled = false
        put("\ndocker run --rm -it alpine sh")
        editor.paste()
        await settle(seconds: 0.3)
        check("disabled-offers-nothing", editor.pasteSuggestion == nil)
        AppSettings.core.pasteIntelligenceEnabled = true

        finish()
    }

    // MARK: - Helpers

    private static func put(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures += 1 }
        print("SMOKE \(condition ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    private static func fail(_ label: String, _ detail: String = "") {
        check(label, false, detail)
        finish()
    }

    private static func finish() {
        print("SMOKE result failures=\(failures)")
        fflush(stdout)
        exit(Int32(min(failures, 120)))
    }

    private static func settle(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    private static func poll(seconds: Double, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await settle(seconds: 0.15)
        }
        return condition()
    }
}
