import AppKit

/// The chrome that floats over a fenced code block (spec Figure 1, FR-2.2):
/// a small language tag and a `Copy` button that appears on hover.
///
/// It is a plain subview of the text view, so it scrolls with the text; the
/// text view repositions it whenever layout, scroll or content changes.
final class CodeBlockAccessoryView: NSView {

    private let languageLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var resetWorkItem: DispatchWorkItem?

    /// Index of the code block this accessory currently represents.
    var blockIndex: Int = 0

    /// Invoked when the user clicks `Copy`; returns `true` if the copy happened.
    var onCopy: ((Int) -> Bool)?

    /// Diagnostics for the headless smoke check (no screen, no mouse).
    var isCopyButtonVisible: Bool { !copyButton.isHidden && !isHidden }
    var languageText: String { languageLabel.isHidden ? "" : languageLabel.stringValue }

    var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            copyButton.isHidden = !isHovered
        }
    }

    init(theme: MarkdownTheme) {
        super.init(frame: .zero)
        wantsLayer = true

        languageLabel.font = theme.accessoryFont
        languageLabel.textColor = theme.secondaryText
        languageLabel.alignment = .right
        languageLabel.lineBreakMode = .byTruncatingTail

        copyButton.font = theme.accessoryFont
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .mini
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.isHidden = true
        copyButton.setButtonType(.momentaryPushIn)
        copyButton.toolTip = "Copy this code block"
        copyButton.setAccessibilityLabel("Copy code block")

        addSubview(languageLabel)
        addSubview(copyButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(language: String?, theme: MarkdownTheme) {
        languageLabel.stringValue = language ?? ""
        languageLabel.isHidden = (language ?? "").isEmpty
        languageLabel.font = theme.accessoryFont
        copyButton.font = theme.accessoryFont
        layoutParts()
    }

    /// Places the accessory at the top-right of `blockRect` (view coordinates).
    func position(in blockRect: NSRect) {
        layoutParts()
        let width = bounds.width
        let height = bounds.height
        let x = blockRect.maxX - width - 8
        let y = blockRect.minY + 5
        frame = NSRect(x: x, y: y, width: width, height: height)
    }

    private func layoutParts() {
        copyButton.sizeToFit()
        languageLabel.sizeToFit()
        let gap: CGFloat = 6
        let labelWidth = languageLabel.isHidden ? 0 : languageLabel.frame.width
        let buttonWidth = copyButton.frame.width
        let height = max(copyButton.frame.height, languageLabel.frame.height)
        let width = labelWidth + (labelWidth > 0 ? gap : 0) + buttonWidth
        setFrameSize(NSSize(width: width, height: height))
        languageLabel.frame = NSRect(
            x: 0, y: (height - languageLabel.frame.height) / 2,
            width: labelWidth, height: languageLabel.frame.height
        )
        copyButton.frame = NSRect(
            x: labelWidth + (labelWidth > 0 ? gap : 0),
            y: (height - copyButton.frame.height) / 2,
            width: buttonWidth, height: copyButton.frame.height
        )
    }

    /// The same code path the mouse uses, so headless smoke checks exercise it.
    @objc func performCopy() {
        copyClicked()
    }

    @objc private func copyClicked() {
        let copied = onCopy?(blockIndex) ?? false
        guard copied else { return }
        copyButton.title = "Copied"
        copyButton.sizeToFit()
        layoutParts()
        resetWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copyButton.title = "Copy"
            self?.copyButton.sizeToFit()
            self?.layoutParts()
        }
        resetWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}
