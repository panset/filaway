import AppKit

/// The FR-2.4 affordance: "Wrap in code block? ⌘⇧K", with Wrap and Dismiss.
///
/// A bar pinned under the top edge of the editor's viewport rather than a
/// popover at the caret. Three reasons: a popover steals key focus and this
/// offer must never interrupt typing; the pasted text is often several lines
/// tall, so "near the caret" is not one place; and a bar that does not move with
/// the text stays put while the user reads what they just pasted.
///
/// Drawn with system materials only, so light and dark both come free (NFR-6/7),
/// and every control carries an accessibility label (NFR-6).
final class PasteIntelligenceBar: NSView {

    private let label = NSTextField(labelWithString: "Wrap in code block?")
    private let shortcut = NSTextField(labelWithString: "⌘⇧K")
    private let wrapButton = NSButton(title: "Wrap", target: nil, action: nil)
    private let dismissButton = NSButton(title: "", target: nil, action: nil)
    private let background = NSVisualEffectView()

    /// Clicked `Wrap`.
    var onWrap: (() -> Void)?
    /// Clicked the dismiss glyph.
    var onDismiss: (() -> Void)?

    /// Diagnostics for the headless smoke check (plan §8).
    var isOffering: Bool { !isHidden && window != nil }
    var promptText: String { label.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(background)

        label.font = .preferredFont(forTextStyle: .callout)
        label.textColor = .labelColor
        addSubview(label)

        shortcut.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        shortcut.textColor = .secondaryLabelColor
        shortcut.setAccessibilityHidden(true)
        addSubview(shortcut)

        wrapButton.bezelStyle = .rounded
        wrapButton.controlSize = .small
        wrapButton.keyEquivalent = ""
        wrapButton.target = self
        wrapButton.action = #selector(wrapClicked)
        wrapButton.setAccessibilityLabel("Wrap the pasted text in a code block")
        addSubview(wrapButton)

        dismissButton.bezelStyle = .accessoryBarAction
        dismissButton.isBordered = false
        dismissButton.controlSize = .small
        dismissButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Dismiss"
        )
        dismissButton.contentTintColor = .tertiaryLabelColor
        dismissButton.target = self
        dismissButton.action = #selector(dismissClicked)
        dismissButton.setAccessibilityLabel("Dismiss the code block offer")
        addSubview(dismissButton)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Wrap in code block? Command shift K to wrap.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Names the language in the prompt when one was recognised, so the user
    /// knows what tag the fence will carry.
    func configure(language: String?) {
        if let language, !language.isEmpty {
            label.stringValue = "Wrap in a \(language) code block?"
        } else {
            label.stringValue = "Wrap in code block?"
        }
        setAccessibilityLabel("\(label.stringValue) Command shift K to wrap.")
        layoutParts()
    }

    /// Centres the bar horizontally in `container`, just below its top edge.
    func position(in container: NSRect) {
        layoutParts()
        let x = container.midX - bounds.width / 2
        let y = container.minY + 8
        frame = NSRect(x: x, y: y, width: bounds.width, height: bounds.height)
    }

    private func layoutParts() {
        label.sizeToFit()
        shortcut.sizeToFit()
        wrapButton.sizeToFit()
        let glyph: CGFloat = 16
        let gap: CGFloat = 8
        let padding: CGFloat = 10
        let height = max(wrapButton.frame.height, label.frame.height) + padding
        let width = padding + label.frame.width + gap + shortcut.frame.width + gap
            + wrapButton.frame.width + gap + glyph + padding
        setFrameSize(NSSize(width: width, height: height))
        background.frame = bounds

        var x = padding
        label.frame = NSRect(x: x, y: (height - label.frame.height) / 2,
                             width: label.frame.width, height: label.frame.height)
        x += label.frame.width + gap
        shortcut.frame = NSRect(x: x, y: (height - shortcut.frame.height) / 2,
                                width: shortcut.frame.width, height: shortcut.frame.height)
        x += shortcut.frame.width + gap
        wrapButton.frame = NSRect(x: x, y: (height - wrapButton.frame.height) / 2,
                                  width: wrapButton.frame.width, height: wrapButton.frame.height)
        x += wrapButton.frame.width + gap
        dismissButton.frame = NSRect(x: x, y: (height - glyph) / 2, width: glyph, height: glyph)
    }

    /// The exact path the mouse takes, so the smoke check exercises it.
    @objc func performWrap() { wrapClicked() }

    @objc private func wrapClicked() { onWrap?() }
    @objc private func dismissClicked() { onDismiss?() }
}
