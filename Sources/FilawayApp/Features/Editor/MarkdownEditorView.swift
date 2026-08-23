import AppKit
import FilawayCore
import SwiftUI

/// Imperative handle on a live ``MarkdownEditorView``.
///
/// SwiftUI owns the text (a `Binding<String>`); everything the shell needs to
/// *do* to the editor — scroll to a search match, insert a code block, take
/// focus — goes through this. Create one with `@StateObject` (or hold it
/// yourself) and pass it to the view.
@MainActor
final class MarkdownEditorController: ObservableObject {

    fileprivate weak var textView: MarkdownTextView?

    /// The controller of the most recently created editor. Used by the headless
    /// `FILAWAY_SMOKE=1` hook, which has no view hierarchy to search.
    private(set) static weak var mostRecent: MarkdownEditorController?

    init() {}

    fileprivate func attach(_ textView: MarkdownTextView) {
        self.textView = textView
        MarkdownEditorController.mostRecent = self
    }

    // MARK: Document

    /// The Markdown source exactly as stored — never a rendered form.
    var text: String { textView?.string ?? "" }

    var selectedRange: NSRange { textView?.selectedRange() ?? NSRange(location: 0, length: 0) }

    /// `true` when TextKit 2 is driving layout.
    var usesTextKit2: Bool { textView?.usesTextKit2 ?? false }

    /// Attributes at a character index — for tests and the smoke hook.
    func attributes(at index: Int) -> [NSAttributedString.Key: Any] {
        guard let storage = textView?.textStorage, index >= 0, index < storage.length else { return [:] }
        return storage.attributes(at: index, effectiveRange: nil)
    }

    // MARK: Actions

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Scrolls `range` into view, selecting it by default: "open note scrolled
    /// to match".
    func scrollTo(range: NSRange, select: Bool = true) {
        textView?.scrollTo(range: range, select: select)
    }

    /// Convenience for search: scrolls to the first occurrence of `match`.
    @discardableResult
    func scrollTo(match: String, select: Bool = true) -> Bool {
        guard let textView, !match.isEmpty else { return false }
        let found = (textView.string as NSString).range(
            of: match, options: [.caseInsensitive, .diacriticInsensitive]
        )
        guard found.location != NSNotFound else { return false }
        textView.scrollTo(range: found, select: select)
        return true
    }

    /// Inserts a fenced code block at the insertion point (or wraps the
    /// selection) and leaves the caret inside it.
    func insertCodeBlock(language: String? = nil) {
        textView?.insertCodeBlock(language: language)
    }

    /// Inserts text at the insertion point through the normal typing path
    /// (undoable, fires `onTextChange`).
    func insertText(_ string: String) {
        guard let textView else { return }
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    /// Flips a `- [ ]` / `- [x]` checkbox at a character index. Returns `false`
    /// if that index is not on a checkbox.
    @discardableResult
    func toggleTask(atCharacterIndex index: Int) -> Bool {
        textView?.toggleTask(atCharacterIndex: index) ?? false
    }

    // MARK: Code blocks

    var codeBlocks: [MarkdownCodeBlock] { textView?.codeBlocks ?? [] }

    func codeText(at index: Int) -> String? { textView?.codeText(at: index) }

    /// Puts a block's code (fences excluded) on the general pasteboard — the
    /// exact path the hover `Copy` button uses.
    @discardableResult
    func copyCodeBlock(at index: Int) -> Bool {
        textView?.copyCodeBlock(at: index) ?? false
    }

    /// Shows/hides the hover accessory without a mouse (smoke checks, tests).
    func setHoveredCodeBlock(_ index: Int?) {
        textView?.setHoveredBlock(index)
    }

    /// Re-reads system text size / appearance and re-applies every attribute.
    func refreshTheme() { textView?.refreshTheme() }

    // MARK: Diagnostics

    /// Time spent highlighting vs decorating since the last reset.
    var instrumentation: MarkdownTextView.Instrumentation {
        textView?.instrumentation ?? MarkdownTextView.Instrumentation()
    }

    func resetInstrumentation() { textView?.resetInstrumentation() }

    /// Laid-out code-block rects and the state of their hover accessories.
    func codeBlockDecorations() -> [MarkdownTextView.CodeBlockDecoration] {
        textView?.codeBlockDecorations() ?? []
    }

    /// Samples one pixel of the rendered editor (headless verification).
    func sampleRenderedColor(at point: NSPoint) -> NSColor? {
        textView?.sampleRenderedColor(at: point)
    }

    /// Forces light/dark on the editor alone, so a headless check can prove the
    /// palette works in both. `nil` restores the system appearance.
    func overrideAppearance(_ appearance: NSAppearance?) {
        textView?.appearance = appearance
        textView?.needsDisplay = true
    }
}

/// SwiftUI wrapper around ``MarkdownTextView``.
///
/// ```swift
/// MarkdownEditorView(text: $note.body, controller: controller)
///     .onEditorActivity { session.noteActivity($0) }
/// ```
struct MarkdownEditorView: NSViewRepresentable {

    /// The Markdown source. This binding is the file's bytes, verbatim.
    @Binding var text: String
    /// Imperative handle; optional.
    var controller: MarkdownEditorController?
    var isEditable: Bool = true
    /// Called on every character-level change (M1-11 autosave hooks in here).
    var onTextChange: ((String) -> Void)?
    /// Called on keystroke, selection change and scroll (M2-03 session tracker).
    var onEditorActivity: ((EditorActivity) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder

        // TextKit 2. See docs/decisions.md ADR-004.
        let textView = MarkdownTextView(usingTextLayoutManager: true)
        textView.configureAsMarkdownEditor()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isEditable = isEditable
        textView.isSelectable = true

        textView.onTextChange = { [weak coordinator = context.coordinator] newText in
            coordinator?.textChanged(newText)
        }
        textView.onActivity = { [weak coordinator = context.coordinator] activity in
            coordinator?.parent.onEditorActivity?(activity)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        controller?.attach(textView)
        textView.setMarkdown(text)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? MarkdownTextView else { return }
        controller?.attach(textView)
        textView.isEditable = isEditable
        // Only push text in when it really changed elsewhere (note switch,
        // external file change) — never echo our own keystrokes back.
        if textView.string != text {
            textView.setMarkdown(text)
        }
    }

    @MainActor
    final class Coordinator {
        var parent: MarkdownEditorView
        weak var textView: MarkdownTextView?

        init(_ parent: MarkdownEditorView) { self.parent = parent }

        func textChanged(_ newText: String) {
            parent.text = newText
            parent.onTextChange?(newText)
        }
    }
}

extension MarkdownEditorView {
    /// Fluent form of the activity callback.
    func onEditorActivity(_ handler: @escaping (EditorActivity) -> Void) -> MarkdownEditorView {
        var copy = self
        copy.onEditorActivity = handler
        return copy
    }

    /// Fluent form of the text-change callback.
    func onTextChange(_ handler: @escaping (String) -> Void) -> MarkdownEditorView {
        var copy = self
        copy.onTextChange = handler
        return copy
    }
}
