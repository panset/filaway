import AppKit
import FilawayCore

/// The first-run window (M4-01, FR-7.1) — three steps, drawn in AppKit.
///
/// **Why AppKit.** The flow runs in a modal window *before* SwiftUI has built
/// the app's scene, because the folder it asks about decides which library
/// `AppModel` opens (ADR-049). An `NSHostingView` laid out at that point trips
/// an AttributeGraph precondition and aborts the process — reproducibly, with or
/// without the smoke driver. AppKit has no such ordering requirement, and the
/// editor and its accessories are AppKit already, so this is house style rather
/// than an exception.
///
/// System colors and materials only, so light and dark come free (NFR-6/7);
/// every control has an accessibility label, and the whole flow is walkable with
/// ⇥ and ⏎ (NFR-6).
@MainActor
final class OnboardingWindowController {

    private let model: OnboardingModel
    let window: NSWindow

    private let titleLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let contentBox = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let continueButton = NSButton(title: "Continue", target: nil, action: nil)
    private let skipButton = NSButton(title: "Skip for now", target: nil, action: nil)

    /// Step 1's live pieces.
    private let folderPathLabel = NSTextField(labelWithString: "")
    private let folderSummaryLabel = NSTextField(wrappingLabelWithString: "")

    /// Step 2's live pieces (Figure 3).
    private let keyField = NSSecureTextField()
    private let validateButton = NSButton(title: "Validate", target: nil, action: nil)
    private let keyStatusLabel = NSTextField(labelWithString: "")
    private let keyStatusIcon = NSImageView()
    private let claudeCheckmark = NSImageView()

    private var stepViews: [OnboardingModel.Step: NSView] = [:]

    // MARK: - Construction

    init(model: OnboardingModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            // Titled with no close or zoom: this is a gate, not a document.
            // ⌘Q still quits — a modal session does not block terminate.
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // `close()` on a programmatically created `NSWindow` releases it, and
        // this controller holds it with a strong `let`. Once the main scene
        // exists, the over-release lands in AppKit's window-close animation
        // during the next CA transaction flush and takes the process with it
        // (EXC_BAD_ACCESS in `-[_NSWindowTransformAnimation dealloc]`). ARC owns
        // this window, not AppKit.
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Filaway"
        window.isMovableByWindowBackground = true
        window.setAccessibilityLabel("Filaway setup")
        window.contentView = makeContentView()
        model.onStateChange = { [weak self] in self?.render() }
        render()
    }

    private func makeContentView() -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        root.autoresizingMask = [.width, .height]

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        stepLabel.font = .preferredFont(forTextStyle: .callout)
        stepLabel.textColor = .secondaryLabelColor

        let header = NSStackView(views: [titleLabel, NSView(), stepLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.edgeInsets = NSEdgeInsets(top: 18, left: 28, bottom: 18, right: 28)

        contentBox.translatesAutoresizingMaskIntoConstraints = false

        backButton.target = self
        backButton.action = #selector(backTapped)
        backButton.bezelStyle = .rounded
        backButton.setAccessibilityLabel("Back")

        continueButton.target = self
        continueButton.action = #selector(continueTapped)
        continueButton.bezelStyle = .rounded
        continueButton.keyEquivalent = "\r"

        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.bezelStyle = .rounded
        skipButton.setAccessibilityLabel("Skip connecting the AI for now")
        skipButton.toolTip = "The app works without a key: capture and keyword search. "
            + "You can connect later in Settings."

        let footerSpacer = NSView()
        let footer = NSStackView(views: [skipButton, footerSpacer, backButton, continueButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.edgeInsets = NSEdgeInsets(top: 16, left: 28, bottom: 16, right: 28)
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [header, separator(), contentBox, separator(), footer])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            contentBox.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        return root
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - Rendering

    /// Redraws everything that depends on model state. Cheap — three steps, a
    /// handful of labels — and it means there is exactly one path from state to
    /// pixels.
    private func render() {
        titleLabel.stringValue = stepTitle
        stepLabel.stringValue = model.step.label
        stepLabel.setAccessibilityLabel("Step \(model.step.label)")

        let view = stepView(for: model.step)
        if contentBox.subviews.first !== view {
            contentBox.subviews.forEach { $0.removeFromSuperview() }
            view.translatesAutoresizingMaskIntoConstraints = false
            contentBox.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentBox.leadingAnchor, constant: 28),
                view.trailingAnchor.constraint(equalTo: contentBox.trailingAnchor, constant: -28),
                view.topAnchor.constraint(equalTo: contentBox.topAnchor, constant: 22),
                view.bottomAnchor.constraint(lessThanOrEqualTo: contentBox.bottomAnchor, constant: -22),
            ])
        }

        folderPathLabel.stringValue = model.notesRootDisplayPath
        folderPathLabel.setAccessibilityLabel("Notes folder \(model.notesRootDisplayPath)")
        folderSummaryLabel.stringValue = model.folderSummary

        renderKeyStatus()
        claudeCheckmark.isHidden = !model.isConnected
        validateButton.isEnabled = model.canValidateKey
        keyField.isEnabled = model.keyPhase != .validating
        if keyField.stringValue != model.apiKey { keyField.stringValue = model.apiKey }

        backButton.isEnabled = model.canGoBack
        continueButton.title = model.step == .orientation ? "Start writing" : "Continue"
        continueButton.setAccessibilityLabel(continueButton.title)
        skipButton.isHidden = !(model.step == .connectAI && !model.isConnected)
    }

    private var stepTitle: String {
        switch model.step {
        case .welcome: return "Welcome to Filaway"
        case .connectAI: return "Connect your AI"
        case .orientation: return "You're set"
        }
    }

    private func stepView(for step: OnboardingModel.Step) -> NSView {
        if let existing = stepViews[step] { return existing }
        let view: NSView
        switch step {
        case .welcome: view = makeWelcomeStep()
        case .connectAI: view = makeConnectStep()
        case .orientation: view = makeOrientationStep()
        }
        stepViews[step] = view
        return view
    }

    // MARK: - Step 1: the notes folder

    private func makeWelcomeStep() -> NSView {
        let pitch = makeIconRow(
            symbol: "sparkles",
            title: "Filaway",
            detail: "Write it down and forget it. An AI files each writing session for you, "
                + "and you find things again by asking in plain language.",
            symbolSize: 26
        )

        let heading = NSTextField(labelWithString: "Your notes folder")
        heading.font = .preferredFont(forTextStyle: .headline)

        let folderIcon = NSImageView(image: symbol("folder"))
        folderIcon.contentTintColor = .secondaryLabelColor
        folderIcon.setAccessibilityHidden(true)
        folderPathLabel.lineBreakMode = .byTruncatingMiddle
        folderPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let chooseButton = NSButton(title: "Choose…", target: self, action: #selector(chooseTapped))
        chooseButton.bezelStyle = .rounded
        chooseButton.setAccessibilityLabel("Choose a different notes folder")

        let row = NSStackView(views: [folderIcon, folderPathLabel, NSView(), chooseButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let boxed = card(row)

        folderSummaryLabel.font = .preferredFont(forTextStyle: .callout)
        folderSummaryLabel.textColor = .secondaryLabelColor

        let footnote = NSTextField(wrappingLabelWithString:
            "Notes are ordinary Markdown files. Open the folder in any editor, back it up, "
            + "sync it — Filaway never hides anything from you.")
        footnote.font = .preferredFont(forTextStyle: .callout)
        footnote.textColor = .secondaryLabelColor

        return column([pitch, heading, boxed, folderSummaryLabel, footnote], spacing: 14)
    }

    // MARK: - Step 2: Figure 3

    private func makeConnectStep() -> NSView {
        let privacy = NSTextField(wrappingLabelWithString: OnboardingModel.privacyStatement)
        privacy.font = .preferredFont(forTextStyle: .callout)
        privacy.textColor = .secondaryLabelColor
        privacy.setAccessibilityLabel("Privacy. \(OnboardingModel.privacyStatement)")

        // — Claude API card
        let icon = NSImageView(image: symbol("cloud"))
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityHidden(true)
        let name = NSTextField(labelWithString: "Claude API")
        name.font = .preferredFont(forTextStyle: .headline)
        let blurb = NSTextField(labelWithString: "Best quality · needs API key")
        blurb.font = .preferredFont(forTextStyle: .subheadline)
        blurb.textColor = .secondaryLabelColor
        claudeCheckmark.image = symbol("checkmark.circle.fill")
        claudeCheckmark.contentTintColor = .systemGreen
        claudeCheckmark.isHidden = true
        claudeCheckmark.setAccessibilityLabel("Connected")

        let titles = column([name, blurb], spacing: 2)
        let head = NSStackView(views: [icon, titles, NSView(), claudeCheckmark])
        head.orientation = .horizontal
        head.spacing = 12
        head.alignment = .centerY

        keyField.placeholderString = "sk-ant-…"
        keyField.target = self
        keyField.action = #selector(validateTapped)
        keyField.delegate = keyFieldDelegate
        keyField.setAccessibilityLabel("Claude API key")
        validateButton.target = self
        validateButton.action = #selector(validateTapped)
        validateButton.bezelStyle = .rounded
        validateButton.setAccessibilityLabel("Validate and store the key")

        let entry = NSStackView(views: [keyField, validateButton])
        entry.orientation = .horizontal
        entry.spacing = 8
        keyField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        keyStatusIcon.setAccessibilityHidden(true)
        keyStatusLabel.font = .preferredFont(forTextStyle: .callout)
        let status = NSStackView(views: [keyStatusIcon, keyStatusLabel])
        status.orientation = .horizontal
        status.spacing = 6
        status.alignment = .centerY

        let claudeStack = column([head, entry, status], spacing: 10)
        claudeStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        let claudeCard = card(claudeStack)
        claudeCard.setAccessibilityLabel("Claude API. Best quality, needs an API key.")

        return column([privacy, claudeCard, makeLocalModelCard()], spacing: 16)
    }

    /// FR-6.5 / Figure 3's second option: present, disabled, badged "Soon".
    private func makeLocalModelCard() -> NSView {
        let icon = NSImageView(image: symbol("desktopcomputer"))
        icon.contentTintColor = .tertiaryLabelColor
        icon.setAccessibilityHidden(true)
        let name = NSTextField(labelWithString: "Local model (Ollama)")
        name.font = .preferredFont(forTextStyle: .headline)
        name.textColor = .secondaryLabelColor
        let blurb = NSTextField(labelWithString: "Fully private · coming in v2")
        blurb.font = .preferredFont(forTextStyle: .subheadline)
        blurb.textColor = .tertiaryLabelColor

        let badge = BadgeLabel(text: "Soon")

        let row = NSStackView(views: [icon, column([name, blurb], spacing: 2), NSView(), badge])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)

        let boxed = card(row, emphasis: 0.25)
        boxed.setAccessibilityElement(true)
        boxed.setAccessibilityRole(.group)
        boxed.setAccessibilityLabel(
            "Local model, Ollama. Fully private, coming in version 2. Not available yet."
        )
        return boxed
    }

    private func renderKeyStatus() {
        switch model.keyPhase {
        case .idle:
            keyStatusLabel.stringValue = ""
            keyStatusIcon.image = nil
        case .validating:
            keyStatusLabel.stringValue = "Checking the key…"
            keyStatusLabel.textColor = .secondaryLabelColor
            keyStatusIcon.image = symbol("ellipsis.circle")
            keyStatusIcon.contentTintColor = .secondaryLabelColor
        case .valid:
            keyStatusLabel.stringValue = "Key valid · stored in macOS Keychain"
            keyStatusLabel.textColor = .systemGreen
            keyStatusIcon.image = symbol("checkmark.circle.fill")
            keyStatusIcon.contentTintColor = .systemGreen
        case let .failed(message):
            keyStatusLabel.stringValue = message
            keyStatusLabel.textColor = .systemOrange
            keyStatusIcon.image = symbol("exclamationmark.triangle.fill")
            keyStatusIcon.contentTintColor = .systemOrange
        }
        keyStatusLabel.setAccessibilityLabel(keyStatusLabel.stringValue)
    }

    // MARK: - Step 3: orientation

    private func makeOrientationStep() -> NSView {
        let intro = NSTextField(labelWithString: "Three things and you know the whole app.")
        intro.font = .preferredFont(forTextStyle: .callout)
        intro.textColor = .secondaryLabelColor

        let rows = [
            makeIconRow(
                symbol: "sidebar.left",
                title: "Recents, then Library",
                detail: "The sidebar keeps what you touched most recently at the top, and the AI's "
                    + "folder tree below it. Recents is always chronological — nothing reorders it "
                    + "behind your back."
            ),
            makeIconRow(
                symbol: "magnifyingglass",
                title: "⌘K asks anything",
                detail: "Search from anywhere. Type a few letters for a keyword match, or ask for "
                    + "“the curl command for staging docs” once the AI is connected. ↑ ↓ move, "
                    + "⏎ opens the note at the matching line."
            ),
            makeIconRow(
                symbol: "sparkles",
                title: "Filed after each session",
                detail: "Stop typing for a few minutes and Filaway files what you wrote — into a "
                    + "folder, or merged into the note it belongs with. It asks first until you "
                    + "tell it not to, and every move is undoable."
            ),
        ]
        return column([intro] + rows, spacing: 18)
    }

    // MARK: - Actions

    @objc private func chooseTapped() { model.chooseFolder() }
    @objc private func backTapped() { model.goBack() }
    @objc private func skipTapped() { model.skipAI() }

    @objc private func continueTapped() {
        model.advance()
    }

    @objc private func validateTapped() {
        model.apiKey = keyField.stringValue
        Task { await model.validateKey() }
    }

    /// Keeps the model's copy of the key in step with the field, so `Validate`
    /// enables itself as soon as there is something to validate.
    private lazy var keyFieldDelegate = KeyFieldDelegate { [weak self] text in
        guard let self else { return }
        model.apiKey = text
        model.keyFieldEdited()
        validateButton.isEnabled = model.canValidateKey
    }

    private final class KeyFieldDelegate: NSObject, NSTextFieldDelegate {
        private let onChange: (String) -> Void
        init(onChange: @escaping (String) -> Void) { self.onChange = onChange }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            onChange(field.stringValue)
        }
    }

    // MARK: - Small builders

    private func symbol(_ name: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage()
    }

    private func column(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func card(_ content: NSView, emphasis: CGFloat = 0.5) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(emphasis * 0.4).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        content.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            content.topAnchor.constraint(equalTo: box.topAnchor),
            content.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func makeIconRow(
        symbol name: String, title: String, detail: String, symbolSize: CGFloat = 17
    ) -> NSView {
        let icon = NSImageView(image: symbol(name))
        icon.contentTintColor = .controlAccentColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .light)
        icon.setAccessibilityHidden(true)
        icon.widthAnchor.constraint(equalToConstant: max(26, symbolSize + 6)).isActive = true

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .preferredFont(forTextStyle: .headline)
        let detailField = NSTextField(wrappingLabelWithString: detail)
        detailField.font = .preferredFont(forTextStyle: .callout)
        detailField.textColor = .secondaryLabelColor

        let text = column([titleField, detailField], spacing: 3)
        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(title). \(detail)")
        return row
    }
}

/// A small capsule label — Figure 3's "Soon".
private final class BadgeLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        wantsLayer = true
        label.stringValue = text
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.4).cgColor
    }
}
