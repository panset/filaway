import AppKit
import FilawayCore

/// Fonts, colours and paragraph metrics for the styled-Markdown-source editor.
///
/// Everything scales off ``baseSize``, which defaults to the system body text
/// size, so the editor follows the user's text-size preference (NFR-6/7). All
/// colours are dynamic (`NSColor(name:dynamicProvider:)`) so light and dark mode
/// both work without a redraw path of our own.
struct MarkdownTheme {

    var baseSize: CGFloat

    /// System body size — 13 pt by default, larger when the user raises it.
    static var systemBaseSize: CGFloat {
        NSFont.preferredFont(forTextStyle: .body).pointSize
    }

    static var current: MarkdownTheme { MarkdownTheme(baseSize: systemBaseSize) }

    init(baseSize: CGFloat = MarkdownTheme.systemBaseSize) {
        self.baseSize = max(9, baseSize)
    }

    // MARK: Fonts

    var bodyFont: NSFont { .systemFont(ofSize: baseSize) }
    var boldFont: NSFont { .systemFont(ofSize: baseSize, weight: .semibold) }
    var italicFont: NSFont {
        NSFontManager.shared.convert(bodyFont, toHaveTrait: .italicFontMask)
    }
    var boldItalicFont: NSFont {
        NSFontManager.shared.convert(boldFont, toHaveTrait: .italicFontMask)
    }
    var monoFont: NSFont { .monospacedSystemFont(ofSize: baseSize * 0.94, weight: .regular) }
    var titleFont: NSFont { .systemFont(ofSize: baseSize * 1.32, weight: .semibold) }
    var dateStampFont: NSFont { .systemFont(ofSize: baseSize * 0.85) }
    var accessoryFont: NSFont { .systemFont(ofSize: max(9, baseSize * 0.8)) }

    func headingFont(level: Int) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.62
        case 2: scale = 1.38
        case 3: scale = 1.20
        case 4: scale = 1.08
        default: scale = 1.0
        }
        return .systemFont(ofSize: (baseSize * scale).rounded(), weight: level <= 2 ? .bold : .semibold)
    }

    // MARK: Colours

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Body ink. Figure 1: `--ink` #1d1d1f.
    let text = NSColor.textColor
    /// Dimmed — but never hidden — syntax marks (`#`, `**`, backticks, fences).
    let syntaxMark = NSColor.tertiaryLabelColor
    let secondaryText = NSColor.secondaryLabelColor
    /// Figure 1 `.codeblk`: #f6f6f8 on white, a lifted grey in dark mode.
    /// Figure 1 uses #f6f6f8 on white. Dark values are deliberately *lighter*
    /// than the page (the dark text background samples at ~#282828), so the
    /// block reads as raised rather than as a hole. sRGB, not calibrated white:
    /// the calibrated grey space shifts noticeably on render.
    let codeBackground = MarkdownTheme.dynamic(
        light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.973, alpha: 1),
        dark: NSColor(srgbRed: 0.22, green: 0.22, blue: 0.23, alpha: 1)
    )
    let codeBorder = MarkdownTheme.dynamic(
        light: NSColor(srgbRed: 0.878, green: 0.878, blue: 0.898, alpha: 1),
        dark: NSColor(srgbRed: 0.32, green: 0.32, blue: 0.34, alpha: 1)
    )
    let codeText = MarkdownTheme.dynamic(
        light: NSColor(srgbRed: 0.227, green: 0.227, blue: 0.251, alpha: 1),
        dark: NSColor(srgbRed: 0.88, green: 0.88, blue: 0.90, alpha: 1)
    )
    /// Inline code gets a subtle chip behind it, as in the spec's `code` style.
    let inlineCodeBackground = MarkdownTheme.dynamic(
        light: NSColor(srgbRed: 0.941, green: 0.941, blue: 0.953, alpha: 1),
        dark: NSColor(srgbRed: 0.27, green: 0.27, blue: 0.29, alpha: 1)
    )
    let link = NSColor.linkColor
    let checkedTask = NSColor.systemGreen
    let listMarker = NSColor.secondaryLabelColor
    var accent: NSColor { .controlAccentColor }

    // MARK: Metrics

    var lineHeightMultiple: CGFloat { 1.28 }
    var paragraphSpacing: CGFloat { baseSize * 0.45 }
    /// Vertical padding reserved above/below a fenced block's background.
    var codeBlockPadding: CGFloat { 7 }
    var codeBlockCornerRadius: CGFloat { 7 }
    /// Left/right inset of the text container; the header chrome aligns to it.
    var textInset: CGFloat { 17 }
    var lineFragmentPadding: CGFloat { 5 }
    var textLeading: CGFloat { textInset + lineFragmentPadding }

    // MARK: Attribute sets

    var baseParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = paragraphSpacing
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: text,
            .paragraphStyle: baseParagraphStyle,
        ]
    }

    func headingParagraphStyle(level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.15
        style.paragraphSpacingBefore = level <= 2 ? baseSize * 0.9 : baseSize * 0.6
        style.paragraphSpacing = baseSize * 0.25
        return style
    }

    /// Code lines: tight leading, indented inside the block background.
    var codeParagraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.2
        style.paragraphSpacing = 0
        style.firstLineHeadIndent = 12
        style.headIndent = 12
        style.tailIndent = -12
        return style
    }

    /// Attributes for one highlighter span. Returned attributes are *additive*:
    /// the caller resets the range to ``baseAttributes`` first, then applies
    /// spans in order, so inline styles land on top of block styles.
    func attributes(for style: MarkdownStyle) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            return [
                .font: headingFont(level: level),
                .foregroundColor: text,
                .paragraphStyle: headingParagraphStyle(level: level),
            ]
        case .syntaxMarker:
            return [.foregroundColor: syntaxMark]
        case .bold:
            return [.font: boldFont]
        case .italic:
            return [.font: italicFont]
        case .boldItalic:
            return [.font: boldItalicFont]
        case .strikethrough:
            return [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: secondaryText,
            ]
        case .inlineCode:
            return [
                .font: monoFont,
                .foregroundColor: codeText,
                .backgroundColor: inlineCodeBackground,
            ]
        case .codeFence:
            return [
                .font: monoFont,
                .foregroundColor: syntaxMark,
                .paragraphStyle: codeParagraphStyle,
            ]
        case .codeLanguage:
            return [.font: monoFont, .foregroundColor: secondaryText]
        case .codeBlock:
            return [
                .font: monoFont,
                .foregroundColor: codeText,
                .paragraphStyle: codeParagraphStyle,
            ]
        case .listMarker:
            return [.font: boldFont, .foregroundColor: listMarker]
        case .taskMarker(let checked):
            return [
                .font: monoFont,
                .foregroundColor: checked ? checkedTask : secondaryText,
            ]
        case .blockQuote:
            return [.foregroundColor: secondaryText]
        case .thematicBreak:
            return [.foregroundColor: syntaxMark]
        case .link:
            return [.foregroundColor: link, .underlineStyle: NSUnderlineStyle.single.rawValue]
        case .linkURL:
            return [.font: monoFont, .foregroundColor: secondaryText]
        }
    }
}
