import Foundation

/// The storage-layout rules of DS-1: `<root>/<Folder>/<Sub>/<Title>.md`, the
/// filename stem *is* the title, the Library is at most two folders deep, and
/// nothing but `.md` files and folders ever lands in the user's tree.
///
/// Every path handled by `FilawayCore` above the `URL` layer is a *relative
/// path*: POSIX-style, `/`-separated, NFC-normalised, no leading or trailing
/// slash. `""` is the library root.
public enum PathRules {
    /// The only file extension Filaway writes or indexes.
    public static let noteExtension = "md"

    /// Library depth cap (plan §1, "Library depth ≤ 2").
    public static let maxFolderDepth = 2

    /// Title given to a note the user has not named yet.
    public static let untitled = "Untitled note"

    /// Longest title Filaway will produce, in UTF-8 bytes. APFS allows 255 bytes
    /// per component; the headroom covers `.md` and a ` 999` collision suffix.
    public static let maxTitleBytes = 200

    // MARK: - Normalisation

    /// Canonical relative-path form: NFC, `/`-separated, no empty components,
    /// no `.`/`..`, no leading or trailing slash.
    public static func normalize(_ path: String) -> String {
        components(path).joined(separator: "/")
    }

    /// Splits a relative path into its non-empty components, dropping `.`
    /// segments and resolving `..` conservatively (a `..` that would escape the
    /// root is dropped, never followed).
    public static func components(_ path: String) -> [String] {
        var out: [String] = []
        for raw in path.precomposedStringWithCanonicalMapping.split(separator: "/", omittingEmptySubsequences: true) {
            let piece = String(raw)
            if piece == "." { continue }
            if piece == ".." {
                if !out.isEmpty { out.removeLast() }
                continue
            }
            out.append(piece)
        }
        return out
    }

    /// `true` when the relative path names a Markdown file Filaway manages.
    public static func isNotePath(_ path: String) -> Bool {
        guard let last = components(path).last else { return false }
        return (last as NSString).pathExtension.lowercased() == noteExtension
            && !((last as NSString).deletingPathExtension.isEmpty)
    }

    /// Folder containing a note (`"Commands/curl.md"` → `"Commands"`).
    public static func folderPath(of relativePath: String) -> String {
        var parts = components(relativePath)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    /// Title of a note = its filename stem (`"Commands/curl.md"` → `"curl"`).
    public static func title(of relativePath: String) -> String {
        guard let last = components(relativePath).last else { return "" }
        return (last as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
    }

    /// Last component of a folder path (`""` for the root).
    public static func name(of folderPath: String) -> String {
        components(folderPath).last ?? ""
    }

    /// Parent of a folder path; `nil` for the root.
    public static func parent(of folderPath: String) -> String? {
        var parts = components(folderPath)
        guard !parts.isEmpty else { return nil }
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    /// Number of folder levels: root is `0`, `"A"` is `1`, `"A/B"` is `2`.
    public static func depth(ofFolder folderPath: String) -> Int {
        components(folderPath).count
    }

    /// `folder` + `"<title>.md"`.
    public static func relativePath(folder: String, title: String) -> String {
        let folder = normalize(folder)
        let file = "\(title).\(noteExtension)"
        return folder.isEmpty ? file : "\(folder)/\(file)"
    }

    // MARK: - Sanitising

    /// Makes an arbitrary string safe to use as a filename stem on macOS.
    ///
    /// `/` and `:` are illegal (Finder swaps them), control characters and
    /// newlines are removed, runs of whitespace collapse, leading dots are
    /// stripped so notes never become hidden files, and the result is clamped to
    /// `maxTitleBytes`. An empty result becomes ``untitled``.
    public static func sanitizeTitle(_ raw: String) -> String {
        var out = String()
        out.reserveCapacity(raw.count)
        var lastWasSpace = false
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            let replacement: Character?
            switch scalar {
            case "/", ":", "\\":
                replacement = "-"
            case "\n", "\r", "\t":
                replacement = " "
            default:
                if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format {
                    replacement = nil
                } else if scalar == " " {
                    replacement = " "
                } else {
                    replacement = Character(scalar)
                }
            }
            guard let character = replacement else { continue }
            if character == " " {
                if lastWasSpace || out.isEmpty { continue }
                lastWasSpace = true
            } else {
                lastWasSpace = false
            }
            out.append(character)
        }

        while let first = out.first, first == " " || first == "." { out.removeFirst() }
        while let last = out.last, last == " " || last == "." { out.removeLast() }
        out = clamp(out, toUTF8Bytes: maxTitleBytes)
        while let last = out.last, last == " " || last == "." { out.removeLast() }
        return out.isEmpty ? untitled : out
    }

    /// Sanitises every component of a folder path and enforces the depth cap.
    ///
    /// - Throws: ``StorageError/folderTooDeep(_:)`` when the path has more than
    ///   ``maxFolderDepth`` components.
    public static func sanitizeFolderPath(_ raw: String) throws -> String {
        let parts = components(raw).map(sanitizeTitle)
        guard parts.count <= maxFolderDepth else {
            throw StorageError.folderTooDeep(raw)
        }
        return parts.joined(separator: "/")
    }

    /// Truncates on a character boundary so the UTF-8 encoding fits `limit` bytes.
    static func clamp(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var out = text
        while out.utf8.count > limit, !out.isEmpty { out.removeLast() }
        return out
    }

    /// `"Title"`, `"Title 2"`, `"Title 3"`, … — the collision ladder used by
    /// note creation, rename and move.
    public static func suffixed(_ title: String, _ attempt: Int) -> String {
        guard attempt > 1 else { return title }
        let suffix = " \(attempt)"
        return clamp(title, toUTF8Bytes: maxTitleBytes - suffix.utf8.count) + suffix
    }
}
