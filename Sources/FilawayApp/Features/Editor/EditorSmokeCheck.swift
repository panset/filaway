import AppKit
import FilawayCore

/// Headless end-to-end check for the editor (plan §8: no Xcode ⇒ no XCTest UI
/// tests, and the screen may be locked).
///
/// Runs the *real* code paths — the same methods the keyboard and the hover
/// `Copy` button call — against the live view hierarchy, prints one line per
/// step, and reports the number of failures.
///
/// ```
/// FILAWAY_SMOKE=1 build/Filaway.app/Contents/MacOS/Filaway
/// ```
enum EditorSmokeCheck {

    @MainActor
    static func run() -> Int {
        var failures = 0

        func check(_ label: String, _ condition: Bool, _ detail: String = "") {
            let status = condition ? "ok  " : "FAIL"
            if !condition { failures += 1 }
            print("SMOKE \(status) \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        for window in NSApp.windows where window.contentView != nil {
            print("SMOKE window title=\"\(window.title)\" visible=\(window.isVisible) "
                + "size=\(Int(window.frame.width))x\(Int(window.frame.height))")
        }

        guard let editor = MarkdownEditorController.mostRecent else {
            print("SMOKE FAIL editor — no MarkdownEditorView was created")
            return 1
        }

        print("SMOKE info textkit=\(editor.usesTextKit2 ? 2 : 1) "
            + "chars=\(editor.text.utf16.count) codeBlocks=\(editor.codeBlocks.count)")

        // 1 — the storage is the Markdown source, byte for byte.
        check("source-is-markdown", editor.text == SampleNote.markdown)

        // 2 — programmatic typing through the normal insertion path.
        let appended = "\nsmoke test line with **bold**\n"
        editor.scrollTo(range: NSRange(location: (editor.text as NSString).length, length: 0))
        editor.insertText(appended)
        check(
            "insert-text", editor.text.hasSuffix(appended),
            "tail=\(String(editor.text.suffix(30)).debugDescription)"
        )

        // 3 — checkbox toggle edits the source, not a rendered layer.
        let nsText = editor.text as NSString
        let taskRange = nsText.range(of: "- [ ] rotate the staging token")
        check("find-checkbox", taskRange.location != NSNotFound)
        if taskRange.location != NSNotFound {
            let bracketIndex = taskRange.location + 2
            let toggled = editor.toggleTask(atCharacterIndex: bracketIndex)
            check("toggle-checkbox", toggled)
            check(
                "checkbox-source-now-checked",
                (editor.text as NSString).range(of: "- [x] rotate the staging token").location != NSNotFound
            )
            // Toggling back must restore the original text exactly.
            _ = editor.toggleTask(atCharacterIndex: bracketIndex)
            check(
                "checkbox-toggles-back",
                (editor.text as NSString).range(of: "- [ ] rotate the staging token").location != NSNotFound
            )
            _ = editor.toggleTask(atCharacterIndex: bracketIndex)
        }

        // 4 — hover + Copy on the first fenced block, then read the pasteboard.
        let blocks = editor.codeBlocks
        check("code-blocks-found", blocks.count >= 2, "count=\(blocks.count)")
        if let first = blocks.first {
            print("SMOKE info block0 language=\(first.language ?? "none") "
                + "range=\(first.location)..<\(first.location + first.length) closed=\(first.isClosed)")
            check("block0-language", first.language == "bash")
        }
        NSPasteboard.general.clearContents()
        editor.setHoveredCodeBlock(0)
        let copied = editor.copyCodeBlock(at: 0)
        check("copy-button-action", copied)
        let pasteboard = NSPasteboard.general.string(forType: .string) ?? "<empty>"
        print("SMOKE pasteboard=\(pasteboard.debugDescription)")
        check(
            "pasteboard-has-code-without-fences",
            pasteboard == "curl -H \"Auth: Bearer $TOK\" https://api.st.app/v2/docs"
        )

        // 5 — a second block copies its own code (language tag differs).
        if blocks.count > 1 {
            NSPasteboard.general.clearContents()
            _ = editor.copyCodeBlock(at: 1)
            let second = NSPasteboard.general.string(forType: .string) ?? ""
            check("copy-second-block", second.hasPrefix("let response = try await"), second.debugDescription)
        }

        // 6 — styling actually landed on the text storage.
        let headingRange = (editor.text as NSString).range(of: "## Follow-ups")
        if headingRange.location != NSNotFound {
            let headingFont = editor.attributes(at: headingRange.location + 3)[.font] as? NSFont
            let bodyFont = MarkdownTheme.current.bodyFont
            check(
                "heading-is-larger",
                (headingFont?.pointSize ?? 0) > bodyFont.pointSize,
                "heading=\(headingFont?.pointSize ?? 0) body=\(bodyFont.pointSize)"
            )
            let markerColor = editor.attributes(at: headingRange.location)[.foregroundColor] as? NSColor
            check("heading-marker-dimmed", markerColor == NSColor.tertiaryLabelColor)
        }
        if let first = blocks.first {
            let codeFont = editor.attributes(at: first.contentLocation)[.font] as? NSFont
            check("code-is-monospaced", codeFont?.isFixedPitch == true, codeFont?.fontName ?? "nil")
        }
        let boldRange = (editor.text as NSString).range(of: "bold")
        if boldRange.location != NSNotFound {
            let font = editor.attributes(at: boldRange.location)[.font] as? NSFont
            let isBold = font.map {
                NSFontManager.shared.traits(of: $0).contains(.boldFontMask)
            } ?? false
            check("bold-is-bold", isBold, font?.fontName ?? "nil")
        }

        // 7 — the code-block background and hover accessory really laid out and
        // drew (there is no screen to capture, so sample the rendered pixels).
        editor.setHoveredCodeBlock(0)
        let decorations = editor.codeBlockDecorations()
        check("code-block-laid-out", !decorations.isEmpty, "count=\(decorations.count)")
        if let first = decorations.first(where: { $0.index == 0 }) {
            print(String(
                format: "SMOKE info block0 rect=(%.0f,%.0f %.0fx%.0f) accessory=(%.0f,%.0f %.0fx%.0f) tag=%@",
                first.rect.origin.x, first.rect.origin.y, first.rect.width, first.rect.height,
                first.accessoryFrame.origin.x, first.accessoryFrame.origin.y,
                first.accessoryFrame.width, first.accessoryFrame.height,
                first.language
            ))
            check("block-rect-non-empty", first.rect.width > 100 && first.rect.height > 10)
            check("language-tag-shown", first.language == "bash")
            check("copy-visible-on-hover", first.isCopyButtonVisible)
            check(
                "accessory-inside-block",
                first.rect.insetBy(dx: -2, dy: -2).contains(first.accessoryFrame.origin)
            )

            let insideBlock = NSPoint(x: first.rect.maxX - 20, y: first.rect.midY)
            let outsideBlock = NSPoint(x: first.rect.midX, y: max(0, first.rect.minY - 24))
            let blockColor = editor.sampleRenderedColor(at: insideBlock)
            let pageColor = editor.sampleRenderedColor(at: outsideBlock)
            print("SMOKE info pixel inBlock=\(describe(blockColor)) outsideBlock=\(describe(pageColor))")
            check(
                "code-background-drawn",
                blockColor != nil && pageColor != nil && !nearlyEqual(blockColor!, pageColor!),
                "the fenced block must not render as plain page background"
            )
        }
        editor.setHoveredCodeBlock(nil)
        let unhovered = editor.codeBlockDecorations().first { $0.index == 0 }
        check("copy-hidden-without-hover", unhovered?.isCopyButtonVisible == false)

        // 7b — the same must hold in both appearances (NFR-6/7).
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            editor.overrideAppearance(NSAppearance(named: appearance))
            guard let block = editor.codeBlockDecorations().first(where: { $0.index == 0 })
            else { continue }
            let inside = editor.sampleRenderedColor(
                at: NSPoint(x: block.rect.maxX - 20, y: block.rect.midY)
            )
            let page = editor.sampleRenderedColor(
                at: NSPoint(x: block.rect.midX, y: max(0, block.rect.minY - 24))
            )
            print("SMOKE info \(name) inBlock=\(describe(inside)) page=\(describe(page))")
            check(
                "code-background-visible-\(name)",
                inside != nil && page != nil && !nearlyEqual(inside!, page!)
            )
        }
        editor.overrideAppearance(nil)

        // 8 — insertCodeBlock() API the shell/toolbar will call.
        let blocksBefore = editor.codeBlocks.count
        editor.scrollTo(range: NSRange(location: (editor.text as NSString).length, length: 0))
        editor.insertCodeBlock(language: "sh")
        check("insert-code-block", editor.codeBlocks.count == blocksBefore + 1,
              "before=\(blocksBefore) after=\(editor.codeBlocks.count)")
        check("inserted-block-language", editor.codeBlocks.last?.language == "sh")

        // 9 — scrollTo(match:) for "open note scrolled to match".
        check("scroll-to-match", editor.scrollTo(match: "token expires hourly"))
        check("scroll-selected-match",
              (editor.text as NSString).substring(with: editor.selectedRange) == "token expires hourly")

        // 10 — end-to-end typing latency on a 50 KB note (plan §5 risk #1).
        // Full stack: text storage edit + incremental highlight + attribute
        // application + TextKit 2 layout invalidation.
        let filler = String(
            repeating: "Some prose with **bold** and `code`.\n\n```sh\nls -la\n```\n\n- [ ] task\n\n",
            count: 720
        )
        editor.scrollTo(range: NSRange(location: (editor.text as NSString).length, length: 0), select: false)
        let pasteStart = DispatchTime.now()
        editor.insertText(filler)
        let pasteMs = Double(DispatchTime.now().uptimeNanoseconds - pasteStart.uptimeNanoseconds) / 1e6
        var samples: [Double] = []
        editor.resetInstrumentation()
        for _ in 0 ..< 200 {
            let start = DispatchTime.now()
            editor.insertText("x")
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6)
        }
        let sorted = samples.sorted()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let p95 = sorted[Int(Double(sorted.count) * 0.95)]
        print(String(
            format: "SMOKE perf 50KB note (%d chars): paste %.1f ms | keystroke mean %.3f ms, "
                + "p95 %.3f ms, max %.3f ms, blocks %d",
            (editor.text as NSString).length, pasteMs, mean, p95, sorted.last ?? 0,
            editor.codeBlocks.count
        ))
        let counters = editor.instrumentation
        print(String(
            format: "SMOKE perf breakdown: highlight+attributes %.3f ms/keystroke (%d passes), "
                + "decorations %.3f ms/pass (%d passes)",
            counters.highlightCount > 0
                ? counters.highlightMilliseconds / Double(counters.highlightCount) : 0,
            counters.highlightCount,
            counters.decorationCount > 0
                ? counters.decorationMilliseconds / Double(counters.decorationCount) : 0,
            counters.decorationCount
        ))
        check("typing-latency-50kb", p95 < 8.0, String(format: "p95 %.3f ms", p95))

        // Steady-state cost of the decoration pass (code-block rects + hover
        // accessories), which runs at most once per run-loop turn.
        editor.resetInstrumentation()
        for _ in 0 ..< 20 { _ = editor.codeBlockDecorations() }
        let steady = editor.instrumentation
        let steadyMs = steady.decorationCount > 0
            ? steady.decorationMilliseconds / Double(steady.decorationCount) : 0
        print(String(format: "SMOKE perf decorations steady-state %.3f ms/pass", steadyMs))
        check("decoration-pass-under-a-frame", steadyMs < 8.0, String(format: "%.3f ms", steadyMs))

        print("SMOKE result failures=\(failures)")
        return failures
    }

    private static func describe(_ color: NSColor?) -> String {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return "nil" }
        return String(format: "#%02X%02X%02X",
                      Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
                      Int(rgb.blueComponent * 255))
    }

    private static func nearlyEqual(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let a = lhs.usingColorSpace(.sRGB), let b = rhs.usingColorSpace(.sRGB) else {
            return false
        }
        return abs(a.redComponent - b.redComponent) < 0.008
            && abs(a.greenComponent - b.greenComponent) < 0.008
            && abs(a.blueComponent - b.blueComponent) < 0.008
    }
}
