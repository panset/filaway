import AppKit
import FilawayCore

/// What the editor reports to the session tracker (M2-03 needs keystrokes,
/// selection changes and scrolling to keep a session alive — FR-3.1).
enum EditorActivity: Equatable {
    case typing
    case selection
    case scroll
}

/// The styled-Markdown-source text view.
///
/// The text storage **is** the Markdown: nothing is ever inserted, removed or
/// transformed for display. Everything visual is an attribute run computed by
/// `MarkdownHighlighter` plus two pieces of custom drawing — the fenced-code
/// background and the hover `Copy` accessory (FR-2.1, FR-2.2).
final class MarkdownTextView: NSTextView, @preconcurrency NSTextStorageDelegate {

    // MARK: State

    let highlighter = MarkdownHighlighter()
    var theme = MarkdownTheme.current

    var onActivity: ((EditorActivity) -> Void)?
    /// Fired after every character-level change, with the full Markdown source.
    var onTextChange: ((String) -> Void)?

    /// `true` when the view is applying its own attribute runs (guards the
    /// storage-delegate re-entrancy).
    private var isApplyingAttributes = false
    /// Set while the shell pushes text in, so we do not echo it back out.
    private(set) var isProgrammaticChange = false

    private var accessories: [CodeBlockAccessoryView] = []
    private var blockRects: [(index: Int, rect: NSRect, language: String?)] = []
    private var hoveredBlock: Int?
    private var hoverTrackingArea: NSTrackingArea?
    private var decorationsNeedUpdate = true

    /// `true` when TextKit 2 is driving layout (the default; see docs/decisions.md).
    var usesTextKit2: Bool { textLayoutManager != nil }

    // MARK: Setup

    func configureAsMarkdownEditor() {
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isContinuousSpellCheckingEnabled = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        insertionPointColor = theme.accent
        textContainerInset = NSSize(width: theme.textInset, height: 14)
        textContainer?.lineFragmentPadding = theme.lineFragmentPadding
        defaultParagraphStyle = theme.baseParagraphStyle
        font = theme.bodyFont
        textColor = theme.text
        typingAttributes = theme.baseAttributes
        setAccessibilityLabel("Note body, Markdown source")
        textStorage?.delegate = self
    }

    // MARK: Text plumbing

    /// Replaces the whole document without reporting the change back to the
    /// shell (used when switching notes).
    func setMarkdown(_ markdown: String) {
        guard markdown != string else { return }
        isProgrammaticChange = true
        let selection = selectedRange()
        string = markdown
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        isProgrammaticChange = false
        rehighlightAll()
    }

    /// Full re-parse and re-attribution. Cheap enough for note switches and
    /// appearance/text-size changes; never used on the keystroke path.
    func rehighlightAll() {
        guard let storage = textStorage else { return }
        let result = highlighter.setText(storage.string)
        apply(result, to: storage)
        invalidateDecorations()
    }

    func textStorage(
        _ storage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // A programmatic whole-document swap is re-parsed once by
        // `setMarkdown` instead of incrementally here.
        guard editedMask.contains(.editedCharacters),
              !isApplyingAttributes, !isProgrammaticChange else { return }
        let oldLength = editedRange.length - delta
        guard oldLength >= 0, editedRange.upperBound <= storage.length else {
            let result = highlighter.setText(storage.string)
            apply(result, to: storage)
            invalidateDecorations()
            return
        }
        let oldRange = NSRange(location: editedRange.location, length: oldLength)
        instrumentation.highlightMilliseconds += measure {
            let replacement = (storage.string as NSString).substring(with: editedRange)
            let result = highlighter.replace(range: oldRange, with: replacement)
            apply(result, to: storage)
        }
        instrumentation.highlightCount += 1
        invalidateDecorations()
    }

    private func apply(_ result: MarkdownHighlightResult, to storage: NSTextStorage) {
        let clamped = clamp(result.invalidatedRange, to: storage.length)
        guard clamped.length > 0 || storage.length == 0 else { return }
        isApplyingAttributes = true
        storage.setAttributes(theme.baseAttributes, range: clamped)
        for span in result.spans {
            let range = clamp(span.range, to: storage.length)
            guard range.length > 0 else { continue }
            storage.addAttributes(theme.attributes(for: span.style), range: range)
        }
        isApplyingAttributes = false
    }

    private func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let location = min(max(range.location, 0), length)
        let end = min(max(range.upperBound, location), length)
        return NSRange(location: location, length: end - location)
    }

    override func didChangeText() {
        super.didChangeText()
        if !isProgrammaticChange { onTextChange?(string) }
        invalidateDecorations()
    }

    // MARK: Activity reporting (M2-03)

    override func keyDown(with event: NSEvent) {
        super.keyDown(with: event)
        onActivity?(.typing)
    }

    /// Covers typing, paste, dictation and IME commits — anything that reaches
    /// the text through AppKit's insertion path, including programmatic
    /// `MarkdownEditorController.insertText`.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        onActivity?(.typing)
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isProgrammaticChange { onActivity?(.selection) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipViewDidScroll),
            name: NSView.boundsDidChangeNotification, object: clipView
        )
    }

    @objc private func clipViewDidScroll() {
        onActivity?(.scroll)
        updateDecorations()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Checkbox toggling (FR-2.1)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if toggleTask(atCharacterIndex: index) { return }
        super.mouseDown(with: event)
    }

    /// Flips `- [ ]` ↔ `- [x]` **in the Markdown source** when `index` lands on
    /// the checkbox. Registered with the undo manager like any typed edit.
    @discardableResult
    func toggleTask(atCharacterIndex index: Int) -> Bool {
        guard let storage = textStorage else { return false }
        let nsString = storage.string as NSString
        guard index >= 0, index <= nsString.length else { return false }
        let lineRange = nsString.lineRange(for: NSRange(location: min(index, max(0, nsString.length - 1)), length: 0))
        let line = nsString.substring(with: lineRange)
        guard let marker = MarkdownHighlighter.taskMarker(inLine: line) else { return false }
        let absolute = NSRange(location: lineRange.location + marker.location, length: marker.length)
        guard index >= absolute.location, index <= absolute.upperBound else { return false }
        let replacement = MarkdownHighlighter.toggledTaskMarker(isChecked: marker.isChecked)
        guard shouldChangeText(in: absolute, replacementString: replacement) else { return false }
        storage.replaceCharacters(in: absolute, with: replacement)
        didChangeText()
        onActivity?(.typing)
        return true
    }

    // MARK: Code blocks (FR-2.2)

    var codeBlocks: [MarkdownCodeBlock] { highlighter.codeBlocks }

    /// The code inside a fenced block, fences excluded and trailing newlines
    /// trimmed so a pasted command does not execute itself.
    func codeText(at index: Int) -> String? {
        let blocks = highlighter.codeBlocks
        guard blocks.indices.contains(index), let storage = textStorage else { return nil }
        let range = clamp(blocks[index].contentRange, to: storage.length)
        guard range.length > 0 else { return "" }
        let text = (storage.string as NSString).substring(with: range)
        return String(text.reversed().drop { $0 == "\n" || $0 == "\r" }.reversed())
    }

    @discardableResult
    func copyCodeBlock(at index: Int) -> Bool {
        guard let code = codeText(at: index) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(code, forType: .string)
    }

    /// Inserts an empty fenced block at the insertion point (or wraps the
    /// selection) and leaves the caret inside it.
    func insertCodeBlock(language: String? = nil) {
        guard let storage = textStorage else { return }
        let nsString = storage.string as NSString
        let selection = clamp(selectedRange(), to: nsString.length)
        let selected = nsString.substring(with: selection)
        let needsLeadingNewline = selection.location > 0
            && nsString.character(at: selection.location - 1) != 0x0A
        let body = selected.isEmpty ? "" : (selected.hasSuffix("\n") ? selected : selected + "\n")
        let opening = "```" + (language ?? "") + "\n"
        let replacement = (needsLeadingNewline ? "\n" : "") + opening + body + "```\n"
        guard shouldChangeText(in: selection, replacementString: replacement) else { return }
        storage.replaceCharacters(in: selection, with: replacement)
        didChangeText()
        let caret = selection.location + (needsLeadingNewline ? 1 : 0) + (opening as NSString).length
            + (body as NSString).length
        setSelectedRange(NSRange(location: min(caret, (string as NSString).length), length: 0))
        onActivity?(.typing)
    }

    /// Scrolls `range` into view and optionally selects it — the shell uses this
    /// for "open note scrolled to match" (FR-5.x).
    func scrollTo(range: NSRange, select: Bool) {
        let clamped = clamp(range, to: (string as NSString).length)
        if select {
            setSelectedRange(clamped)
        }
        scrollRangeToVisible(clamped)
        invalidateDecorations()
    }

    // MARK: Decoration: code-block background + accessories

    private func invalidateDecorations() {
        decorationsNeedUpdate = true
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.updateDecorations() }
    }

    override func layout() {
        super.layout()
        updateDecorations()
    }

    /// Recomputes the rect of every code block that is currently on screen and
    /// repositions the pooled accessory views over them.
    private func updateDecorations() {
        instrumentation.decorationCount += 1
        instrumentation.decorationMilliseconds += measure { updateDecorationsUncounted() }
    }

    private func updateDecorationsUncounted() {
        guard window != nil else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        // Only blocks near the viewport: computing a rect forces layout, so
        // touching every block would make a 1 MB note O(document) per relayout.
        let window = visibleCharacterRange().map {
            NSRange(location: max(0, $0.location - 4_000), length: $0.length + 8_000)
        } ?? NSRange(location: 0, length: (string as NSString).length)
        var rects: [(index: Int, rect: NSRect, language: String?)] = []
        for entry in highlighter.codeBlocks(overlapping: window) {
            guard let rect = blockRect(for: entry.block.range) else { continue }
            guard rect.intersects(visible.insetBy(dx: 0, dy: -400)) else { continue }
            rects.append((entry.index, rect, entry.block.language))
        }
        let changed = rects.map(\.rect) != blockRects.map(\.rect)
            || rects.map(\.index) != blockRects.map(\.index)
        blockRects = rects
        decorationsNeedUpdate = false
        if changed { needsDisplay = true }
        layoutAccessories()
    }

    private func layoutAccessories() {
        while accessories.count < blockRects.count {
            let accessory = CodeBlockAccessoryView(theme: theme)
            accessory.onCopy = { [weak self] index in self?.copyCodeBlock(at: index) ?? false }
            addSubview(accessory)
            accessories.append(accessory)
        }
        for (slot, accessory) in accessories.enumerated() {
            guard slot < blockRects.count else {
                accessory.isHidden = true
                continue
            }
            let entry = blockRects[slot]
            accessory.isHidden = false
            accessory.blockIndex = entry.index
            accessory.configure(language: entry.language, theme: theme)
            accessory.position(in: entry.rect)
            accessory.isHovered = (hoveredBlock == entry.index)
        }
    }

    /// Character range TextKit 2 currently has laid out for the viewport.
    /// `nil` under TextKit 1 or before the first layout pass.
    private func visibleCharacterRange() -> NSRange? {
        guard let layoutManager = textLayoutManager,
              let content = layoutManager.textContentManager,
              let viewport = layoutManager.textViewportLayoutController.viewportRange
        else { return nil }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        guard start != NSNotFound, end != NSNotFound, end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Union of the layout fragments covering `range`, widened to the text
    /// container, in view coordinates.
    private func blockRect(for range: NSRange) -> NSRect? {
        guard let container = textContainer else { return nil }
        let origin = textContainerOrigin
        var union: NSRect?

        if let layoutManager = textLayoutManager, let content = layoutManager.textContentManager {
            // TextKit 2 path.
            guard let start = content.location(content.documentRange.location, offsetBy: range.location),
                  let end = content.location(start, offsetBy: range.length),
                  let textRange = NSTextRange(location: start, end: end)
            else { return nil }
            layoutManager.ensureLayout(for: textRange)
            layoutManager.enumerateTextLayoutFragments(
                from: textRange.location, options: [.ensuresLayout]
            ) { fragment in
                guard fragment.rangeInElement.location.compare(textRange.endLocation) == .orderedAscending
                else { return false }
                let frame = fragment.layoutFragmentFrame
                union = union.map { $0.union(frame) } ?? frame
                return true
            }
        } else if let layoutManager = layoutManager {
            // TextKit 1 fallback (kept so a downgrade stays a one-line change).
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            union = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        }

        guard var rect = union else { return nil }
        rect = rect.offsetBy(dx: origin.x, dy: origin.y)
        rect.origin.x = origin.x
        rect.size.width = max(container.size.width, 1)
        return rect.insetBy(dx: 0, dy: -2)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if decorationsNeedUpdate { updateDecorations() }
        guard !blockRects.isEmpty else { return }
        theme.codeBackground.setFill()
        theme.codeBorder.setStroke()
        for entry in blockRects where entry.rect.intersects(rect) {
            let path = NSBezierPath(
                roundedRect: entry.rect.insetBy(dx: 1, dy: 0),
                xRadius: theme.codeBlockCornerRadius,
                yRadius: theme.codeBlockCornerRadius
            )
            path.fill()
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateHover(at: NSPoint(x: -1, y: -1))
    }

    /// Exposed for the headless smoke check, which has no mouse.
    func setHoveredBlock(_ index: Int?) {
        guard hoveredBlock != index else { return }
        hoveredBlock = index
        layoutAccessories()
    }

    private func updateHover(at point: NSPoint) {
        let hit = blockRects.first { $0.rect.contains(point) }?.index
        setHoveredBlock(hit)
    }

    // MARK: Instrumentation

    /// Cheap always-on counters so the headless smoke check can attribute
    /// typing latency (plan §5 risk #1) without a profiler.
    struct Instrumentation {
        var highlightMilliseconds = 0.0
        var highlightCount = 0
        var decorationMilliseconds = 0.0
        var decorationCount = 0
    }

    private(set) var instrumentation = Instrumentation()

    func resetInstrumentation() { instrumentation = Instrumentation() }

    private func measure(_ body: () -> Void) -> Double {
        let start = DispatchTime.now()
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    // MARK: Diagnostics (headless verification, plan §8)

    /// Laid-out rects of the code blocks currently near the viewport, plus the
    /// state of their hover accessories.
    struct CodeBlockDecoration {
        var index: Int
        var rect: NSRect
        var accessoryFrame: NSRect
        var language: String
        var isCopyButtonVisible: Bool
    }

    func codeBlockDecorations() -> [CodeBlockDecoration] {
        updateDecorations()
        return blockRects.enumerated().compactMap { slot, entry in
            guard slot < accessories.count else { return nil }
            let accessory = accessories[slot]
            return CodeBlockDecoration(
                index: entry.index,
                rect: entry.rect,
                accessoryFrame: accessory.frame,
                language: accessory.languageText,
                isCopyButtonVisible: accessory.isCopyButtonVisible
            )
        }
    }

    /// Renders the view off-screen and samples one pixel. The only way to prove
    /// the fenced-code background actually draws when there is no screen to
    /// capture.
    func sampleRenderedColor(at point: NSPoint) -> NSColor? {
        let area = NSRect(
            x: 0, y: max(0, point.y - 40),
            width: max(bounds.width, 1), height: 80
        ).intersection(bounds)
        guard area.width > 1, area.height > 1,
              let rep = bitmapImageRepForCachingDisplay(in: area) else { return nil }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cacheDisplay(in: area, to: rep)
        }
        // The rep is in *pixels*; on Retina that is 2× the point size.
        let scaleX = CGFloat(rep.pixelsWide) / area.width
        let scaleY = CGFloat(rep.pixelsHigh) / area.height
        let x = Int((point.x - area.minX) * scaleX)
        let y = Int((point.y - area.minY) * scaleY) // NSTextView is flipped: y grows downward
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)
    }

    // MARK: Appearance / text size

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Re-reads the system text size and re-applies every attribute.
    func refreshTheme() {
        theme = MarkdownTheme.current
        textContainerInset = NSSize(width: theme.textInset, height: 14)
        typingAttributes = theme.baseAttributes
        insertionPointColor = theme.accent
        rehighlightAll()
    }
}
