import Foundation

/// The one gate every byte in a diagnostics export passes through (NFR-4).
///
/// NFR-4 is *zero-content telemetry*: a bundle the user mails to support must
/// carry no note text, no note title, no path inside the notes root, no prompt
/// and no API key. Two of those are structural — the exporter simply never
/// reads a note or a prompt — but crash reports and OSLog excerpts are written
/// by other people's code, so they get scrubbed rather than trusted:
///
/// | In | Out |
/// |---|---|
/// | `/Users/ada/Notes/Commands/curl.md` | `<notes-root>/…` |
/// | `/Users/ada/Library/Logs/…` | `~/Library/Logs/…` |
/// | `sk-ant-api03-…` | `<redacted-key>` |
/// | `/Users/ada` (another account's home) | `/Users/<user>` |
///
/// The notes-root rule collapses the *whole* remainder of the path, not just
/// the prefix: `<notes-root>/Commands/curl.md` would still name a folder and a
/// title the user typed.
public struct DiagnosticsRedactor: Sendable {
    /// Absolute paths replaced with `<notes-root>`, longest first so a nested
    /// root cannot be masked by its parent.
    public var notesRoots: [String]
    /// The user's home directory, replaced with `~`.
    public var homeDirectory: String?
    /// Literal secrets — an API key the caller happens to hold. Never logged,
    /// never stored; only ever compared against.
    public var secrets: [String]
    /// Account names, replaced only where they are a path component
    /// (`/Users/<name>`) — see ``redact(_:)``.
    public var userNames: [String]

    public static let notesRootPlaceholder = "<notes-root>"
    public static let secretPlaceholder = "<redacted-key>"

    public init(
        notesRoots: [String] = [],
        homeDirectory: String? = NSHomeDirectory(),
        secrets: [String] = [],
        userNames: [String] = []
    ) {
        self.notesRoots = notesRoots
        self.homeDirectory = homeDirectory
        self.secrets = secrets
        self.userNames = userNames
    }

    /// Builds a redactor for one library, including the `/private` spelling of
    /// its root that macOS hands back for `/tmp` and `/var`.
    public static func forLibrary(_ library: Library, secrets: [String] = []) -> DiagnosticsRedactor {
        var roots: Set<String> = []
        for path in [library.root.path, library.root.standardizedFileURL.path] {
            roots.insert(path)
            roots.insert(path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : "/private" + path)
        }
        let home = NSHomeDirectory()
        var names: [String] = []
        let account = NSUserName()
        if !account.isEmpty, account.count > 2 { names.append(account) }
        let full = NSFullUserName()
        if !full.isEmpty, full.count > 2, full != account { names.append(full) }
        return DiagnosticsRedactor(
            notesRoots: roots.sorted { $0.count > $1.count },
            homeDirectory: home,
            secrets: secrets.filter { $0.count >= 8 },
            userNames: names
        )
    }

    /// Scrubs one string. Cheap enough to run over a whole log excerpt.
    public func redact(_ text: String) -> String {
        var out = text
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: Self.secretPlaceholder)
        }
        // Anything that looks like an Anthropic key, whether or not we hold it.
        out = Self.replacing(Self.apiKeyPattern, in: out, with: Self.secretPlaceholder)
        for root in notesRoots where !root.isEmpty {
            out = out.replacingOccurrences(of: root, with: Self.notesRootPlaceholder)
        }
        // Collapse whatever followed the root: folder names and note titles are
        // user text too (NFR-4).
        out = Self.replacing(Self.underRootPattern, in: out, with: Self.notesRootPlaceholder + "/…")
        if let homeDirectory, !homeDirectory.isEmpty {
            out = out.replacingOccurrences(of: homeDirectory, with: "~")
            let alternate = homeDirectory.hasPrefix("/private/")
                ? String(homeDirectory.dropFirst("/private".count))
                : "/private" + homeDirectory
            out = out.replacingOccurrences(of: alternate, with: "~")
        }
        // Only as a *path component*. A bare substring replacement would maul
        // any text the account name happens to occur in — including the bundle
        // id, when the developer's account name is their own surname.
        for name in userNames where !name.isEmpty {
            out = out.replacingOccurrences(of: "/Users/\(name)", with: "/Users/<user>")
            out = out.replacingOccurrences(of: "/home/\(name)", with: "/home/<user>")
        }
        return out
    }

    /// `true` when `text` still contains something the export must not carry.
    /// Used by the exporter's own self-check before it seals the zip.
    public func leaks(_ text: String) -> Bool {
        if secrets.contains(where: { !$0.isEmpty && text.contains($0) }) { return true }
        return notesRoots.contains { !$0.isEmpty && text.contains($0) }
    }

    private static func replacing(_ pattern: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let pattern else { return text }
        return pattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: NSRegularExpression.escapedTemplate(for: template)
        )
    }

    private static let apiKeyPattern = try? NSRegularExpression(pattern: "sk-ant-[A-Za-z0-9_-]{8,}")

    private static let underRootPattern = try? NSRegularExpression(
        pattern: NSRegularExpression.escapedPattern(for: notesRootPlaceholder) + "(/[^\\s\"',;:)\\]}]*)+"
    )
}
