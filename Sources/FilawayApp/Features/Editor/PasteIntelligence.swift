import AppKit
import FilawayCore

/// A pending "Wrap in code block?" offer (FR-2.4).
struct PasteSuggestion: Equatable {
    /// What the classifier decided.
    var kind: PasteKind
    /// The range the paste occupied when it landed. Adjusted only by the wrap.
    var range: NSRange
    /// Fence tag, if the language is known.
    var language: String? { kind.fenceLanguage }
}

/// The paste half of M4-03: classify what just landed, and — when it looks like
/// a command or code — offer to fence it.
///
/// Three rules shape this:
///
/// * **The paste always lands as typed.** The offer is applied *after* the text
///   is in the document, never instead of it. If the offer is ignored, nothing
///   happened; if the app crashes between the two, the user's text is safe.
/// * **The offer is transient and silent.** A bar over the editor with two
///   buttons and a ⌘⇧K equivalent — no modal, no sheet, no beep. It withdraws on
///   the next edit, on a selection change, on a note switch, or after
///   ``dismissAfter`` seconds.
/// * **The wrap is one undo step.** `shouldChangeText` + `didChangeText` around
///   a single `replaceCharacters` gives AppKit exactly one undoable edit, so ⌘Z
///   returns to the plain paste and a second ⌘Z removes it.
///
/// The classifier itself is in `FilawayCore` (`CodeLikePasteClassifier`) and has
/// no AppKit in it, which is what makes the interesting half of this feature
/// unit-testable.
@MainActor
final class PasteIntelligenceController {

    /// What a paste looked like before AppKit inserted it.
    struct PasteContext {
        var lengthBefore: Int
        var selectionBefore: NSRange
        var caretWasInsideFence: Bool
        var pasteboardString: String?
        var pasteboardTypes: [String]
    }

    /// How long an unanswered offer stays up.
    static let dismissAfter: TimeInterval = 12

    /// The live offer, or `nil`. Read by the affordance and by the smoke check.
    private(set) var suggestion: PasteSuggestion?

    /// Reads FR-8.1's switch. Injectable so a test can force it either way.
    var isEnabled: () -> Bool = { AppSettings.core.pasteIntelligenceEnabled }

    /// Called whenever ``suggestion`` changes, so the view can lay itself out.
    var onChange: (() -> Void)?

    private var expiry: Task<Void, Never>?

    // MARK: - The paste path

    /// Snapshots the document immediately before AppKit inserts the pasteboard.
    func willPaste(in textView: NSTextView) -> PasteContext {
        let pasteboard = NSPasteboard.general
        return PasteContext(
            lengthBefore: (textView.string as NSString).length,
            selectionBefore: textView.selectedRange(),
            caretWasInsideFence: Self.isInsideFence(textView, at: textView.selectedRange().location),
            pasteboardString: pasteboard.string(forType: .string),
            pasteboardTypes: pasteboard.types?.map(\.rawValue) ?? []
        )
    }

    /// Classifies what landed and raises the offer if it is worth raising.
    func didPaste(in textView: NSTextView, context: PasteContext) {
        guard isEnabled() else { return dismiss() }
        // Pasting *into* a fenced block is already the outcome the offer wants.
        guard !context.caretWasInsideFence else { return dismiss() }

        let length = (textView.string as NSString).length
        let inserted = length - context.lengthBefore + context.selectionBefore.length
        guard inserted > 0 else { return dismiss() }
        let range = NSRange(location: context.selectionBefore.location, length: inserted)
        guard range.upperBound <= length else { return dismiss() }

        let pasted = context.pasteboardString ?? (textView.string as NSString).substring(with: range)
        let kind = CodeLikePasteClassifier.classify(pasted, pasteboardTypes: context.pasteboardTypes)
        guard kind.isCodeLike else { return dismiss() }

        suggestion = PasteSuggestion(kind: kind, range: range)
        armExpiry()
        onChange?()
    }

    // MARK: - Answering the offer

    /// Replaces the pasted range with a fenced block. One undo step.
    /// - Returns: `false` when there was no offer, or the document moved under
    ///   it (an autosave reconcile, an external edit) and the range no longer
    ///   holds what was pasted.
    @discardableResult
    func wrap(in textView: NSTextView) -> Bool {
        guard let suggestion, let storage = textView.textStorage else { return false }
        let text = storage.string as NSString
        let range = suggestion.range
        guard range.location >= 0, range.upperBound <= text.length, range.length > 0 else {
            dismiss()
            return false
        }

        let body = text.substring(with: range)
        let needsLeadingNewline = range.location > 0 && text.character(at: range.location - 1) != 0x0A
        let needsTrailingNewline = range.upperBound < text.length
            && text.character(at: range.upperBound) != 0x0A
        let fence = "```"
        let opening = fence + (suggestion.language ?? "") + "\n"
        let inner = body.hasSuffix("\n") ? body : body + "\n"
        let replacement = (needsLeadingNewline ? "\n" : "")
            + opening + inner + fence + (needsTrailingNewline ? "\n" : "")

        guard textView.shouldChangeText(in: range, replacementString: replacement) else {
            dismiss()
            return false
        }
        textView.undoManager?.setActionName("Wrap in Code Block")
        storage.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()

        // Caret just after the closing fence, where typing continues.
        let end = range.location + (replacement as NSString).length
        textView.setSelectedRange(NSRange(location: min(end, (textView.string as NSString).length), length: 0))
        dismiss()
        return true
    }

    /// Withdraws the offer. Idempotent.
    func dismiss() {
        expiry?.cancel()
        expiry = nil
        guard suggestion != nil else { return }
        suggestion = nil
        onChange?()
    }

    /// Called from `didChangeText` — an edit that is not the wrap itself means
    /// the user moved on, and a stale range must never be replaced.
    func noteDocumentChanged() {
        guard suggestion != nil else { return }
        dismiss()
    }

    // MARK: - Helpers

    private func armExpiry() {
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dismissAfter * 1e9))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// `true` when `location` sits inside a fenced block already.
    private static func isInsideFence(_ textView: NSTextView, at location: Int) -> Bool {
        guard let markdown = textView as? MarkdownTextView else { return false }
        return markdown.codeBlocks.contains { NSLocationInRange(location, $0.range) }
    }
}
