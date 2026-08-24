import Foundation
import GRDB

/// What one export produced.
public struct DiagnosticsExport: Sendable, Hashable {
    /// The zip the user chose in the save panel.
    public var url: URL
    /// Paths inside the archive, relative to its top folder.
    public var entries: [String]
    /// Things that could not be collected — a missing crash-report directory,
    /// a `log show` that needed permission. Never fatal: a partial bundle is
    /// worth more than none.
    public var warnings: [String]
    /// Files dropped because the redactor still found something in them after
    /// scrubbing. Zero, always, unless something upstream changed (NFR-4).
    public var dropped: [String]
    public var byteCount: Int

    public init(
        url: URL,
        entries: [String] = [],
        warnings: [String] = [],
        dropped: [String] = [],
        byteCount: Int = 0
    ) {
        self.url = url
        self.entries = entries
        self.warnings = warnings
        self.dropped = dropped
        self.byteCount = byteCount
    }
}

public enum DiagnosticsError: Error, CustomStringConvertible {
    case couldNotStage(String)
    case couldNotArchive(String)

    public var description: String {
        switch self {
        case let .couldNotStage(detail): "Could not build the diagnostics bundle (\(detail))."
        case let .couldNotArchive(detail): "Could not write the diagnostics archive (\(detail))."
        }
    }
}

/// Help ▸ **Export Diagnostics…** — a zip a user can attach to a bug report
/// without attaching their notes (plan §1 "Crash/diagnostics", NFR-4).
///
/// ## What goes in
///
/// | Entry | Contents |
/// |---|---|
/// | `README.txt` | what this bundle is, and the list of what is deliberately absent |
/// | `versions.txt` | app, build, macOS, database schema version |
/// | `settings.txt` | every FR-8.1 preference **except** anything the user typed |
/// | `database.txt` | `sqlite_master` DDL and a row count per table — no rows |
/// | `support-directory.txt` | file names and sizes under Application Support |
/// | `oslog.txt` | `log show --predicate 'subsystem == "com.tejaspanse.filaway"' --last 1d` |
/// | `crash-reports/` | `Filaway*` reports from the last 30 days |
///
/// ## What never goes in (NFR-4)
///
/// Note text, note titles, any path under the notes root, prompts, model
/// responses, session text, the API key. The first six are structural — the
/// exporter never opens a note, never reads `activity_events`, never touches
/// `PromptLibrary`. The rest is enforced by ``DiagnosticsRedactor``, which runs
/// over every text file that came from somewhere else (crash reports, the log
/// excerpt) **and** over everything this type writes itself, followed by a
/// leak self-check that drops a file rather than ship it.
///
/// ```swift
/// let exporter = DiagnosticsExporter(library: library, settings: settings)
/// let export = try await exporter.export(to: chosenURL)
/// ```
public actor DiagnosticsExporter {
    /// FR-4.4's window, reused: 30 days of crash reports.
    public static let crashReportWindow: TimeInterval = 30 * 24 * 60 * 60
    /// How long `log show` may take before the export gives up on it.
    public static let logTimeout: TimeInterval = 20

    private let library: Library
    private let settings: AppSettings?
    private let environment: DiagnosticsEnvironment
    private let redactor: DiagnosticsRedactor
    private let fileManager = FileManager.default
    private let log = Log.make("diagnostics")

    public init(
        library: Library,
        settings: AppSettings? = nil,
        environment: DiagnosticsEnvironment = .live,
        redactor: DiagnosticsRedactor? = nil
    ) {
        self.library = library
        self.settings = settings
        self.environment = environment
        self.redactor = redactor ?? DiagnosticsRedactor.forLibrary(library)
    }

    /// Collects everything and writes the zip at `destination`.
    ///
    /// An existing file at `destination` is replaced — the save panel has
    /// already asked the user about that.
    @discardableResult
    public func export(to destination: URL) throws -> DiagnosticsExport {
        let now = environment.now()
        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("filaway-diagnostics-\(UUID().uuidString)", isDirectory: true)
        let folderName = "Filaway-diagnostics-\(Self.stamp(now))"
        let bundle = staging.appendingPathComponent(folderName, isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
        } catch {
            throw DiagnosticsError.couldNotStage("\(error)")
        }

        var warnings: [String] = []
        var entries: [String] = []

        write(versionsText(), to: bundle, named: "versions.txt", entries: &entries)
        write(settingsText(), to: bundle, named: "settings.txt", entries: &entries)
        write(databaseText(warnings: &warnings), to: bundle, named: "database.txt", entries: &entries)
        write(supportDirectoryText(), to: bundle, named: "support-directory.txt", entries: &entries)
        write(logExcerpt(warnings: &warnings), to: bundle, named: "oslog.txt", entries: &entries)
        copyCrashReports(into: bundle, now: now, entries: &entries, warnings: &warnings)
        // Written last so it can name what actually made it in.
        write(readmeText(now: now, entries: entries), to: bundle, named: "README.txt", entries: &entries)

        let dropped = sweepForLeaks(in: bundle)
        if !dropped.isEmpty {
            warnings.append("\(dropped.count) file(s) were left out because they still contained library paths")
            entries.removeAll { dropped.contains($0) }
        }

        try archive(bundle, to: destination)
        let size = (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
        log.notice("""
        exported diagnostics: \(entries.count, privacy: .public) entries, \
        \(warnings.count, privacy: .public) warning(s)
        """)
        return DiagnosticsExport(
            url: destination,
            entries: entries.sorted(),
            warnings: warnings,
            dropped: dropped.sorted(),
            byteCount: size ?? 0
        )
    }

    /// The default filename for the save panel.
    public nonisolated static func suggestedFileName(at now: Date = Date()) -> String {
        "Filaway-diagnostics-\(stamp(now)).zip"
    }

    // MARK: - Sections

    private func readmeText(now: Date, entries: [String]) -> String {
        """
        Filaway diagnostics
        ===================

        Created \(ISO8601.string(from: now)) by Filaway \(environment.appVersion).

        Contents
        --------
        \(entries.sorted().map { "  \($0)" }.joined(separator: "\n"))

        What is deliberately NOT in here (NFR-4, zero-content telemetry)
        ---------------------------------------------------------------
          * the text of any note
          * the title of any note, or any folder name you created
          * any path inside your notes folder (they read \
        "\(DiagnosticsRedactor.notesRootPlaceholder)/…")
          * anything sent to or received from the AI: prompts, plans, session text
          * your API key

        The database section lists table definitions and row counts only — never
        a row. Crash reports and the log excerpt are scrubbed of your home
        directory, your account name and anything shaped like an API key before
        they are copied in.

        If you would rather check than trust: everything here is plain text.
        """
    }

    private func versionsText() -> String {
        var lines = [
            "app                 \(environment.appVersion)",
            "build               \(environment.buildVersion.isEmpty ? "(none)" : environment.buildVersion)",
            "core                \(FilawayCore.version)",
            "subsystem           \(FilawayCore.subsystem)",
            "os                  \(environment.osVersion)",
            "schema (expected)   \(DatabaseSchema.version)",
            "library key         \(library.key)",
        ]
        lines.append("notes root          \(DiagnosticsRedactor.notesRootPlaceholder) "
            + "(exists: \(fileManager.fileExists(atPath: library.root.path)))")
        return lines.joined(separator: "\n") + "\n"
    }

    private func settingsText() -> String {
        guard let settings else { return "no settings store was supplied\n" }
        // Folder names are text the user typed, so only the count travels.
        return """
        organizationMode        \(settings.organizationMode.rawValue)
        idleInterval (minutes)  \(settings.idleInterval)
        semanticSearchEnabled   \(settings.semanticSearchEnabled)
        excludedFolders         \(settings.excludedFolders.count) folder(s) — names withheld (NFR-4)
        organizeModel           \(settings.organizeModel.id)
        searchModel             \(settings.searchModel.id)
        advancedModelOverride   \(settings.advancedModelOverride)
        effectiveOrganizeModel  \(settings.effectiveOrganizeModel.id)
        effectiveSearchModel    \(settings.effectiveSearchModel.id)
        aiConnectionSkipped     \(settings.aiConnectionSkipped)
        notesRootBookmark       \(settings.notesRootBookmark == nil ? "absent" : "present")
        usageMonthStart         \(settings.usageMonthStart.map(ISO8601.string(from:)) ?? "(unset)")
        apiKey                  never included (Keychain; NFR-4)

        """
    }

    private func databaseText(warnings: inout [String]) -> String {
        var out: [String] = []
        for url in [library.databaseURL, AIUsageLedger.url(in: library)] {
            out.append("== \(url.lastPathComponent) ==")
            guard fileManager.fileExists(atPath: url.path) else {
                out.append("  (not present)\n")
                continue
            }
            let size = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            out.append("  size \(size ?? 0) bytes")
            do {
                var configuration = Configuration()
                configuration.readonly = true
                configuration.busyMode = .timeout(5)
                let queue = try DatabaseQueue(path: url.path, configuration: configuration)
                let rows = try queue.read { db -> [(String, String, String)] in
                    try Row.fetchAll(
                        db,
                        sql: "SELECT type, name, COALESCE(sql, '') FROM sqlite_master ORDER BY type, name"
                    ).map { ($0[0] as String, $0[1] as String, $0[2] as String) }
                }
                for (type, name, sql) in rows {
                    if type == "table" || type == "view" {
                        let count = (try? queue.read { db in
                            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(name)\"")
                        }) ?? nil
                        out.append("  \(type) \(name): \(count.map(String.init) ?? "?") row(s)")
                    } else {
                        out.append("  \(type) \(name)")
                    }
                    if !sql.isEmpty {
                        out.append(sql.split(separator: "\n").map { "      \($0)" }.joined(separator: "\n"))
                    }
                }
            } catch {
                out.append("  could not be read: \(error)")
                warnings.append("\(url.lastPathComponent) could not be read for the schema dump")
            }
            out.append("")
        }
        // Anything moved aside by DatabaseFile is worth naming: it is the whole
        // story behind "my Activity history is empty".
        let aside = (try? fileManager.contentsOfDirectory(atPath: library.supportDirectory.path))?
            .filter { $0.contains(".corrupt-") }
            .sorted() ?? []
        out.append("== quarantined databases ==")
        out.append(aside.isEmpty ? "  (none)" : aside.map { "  \($0)" }.joined(separator: "\n"))
        return out.joined(separator: "\n") + "\n"
    }

    private func supportDirectoryText() -> String {
        let base = library.supportDirectory
        guard let enumerator = fileManager.enumerator(
            at: base, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]
        ) else {
            return "(support directory unreadable)\n"
        }
        var lines: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            let relative = url.path.hasPrefix(base.path)
                ? String(url.path.dropFirst(base.path.count + 1))
                : url.lastPathComponent
            lines.append("  \(relative)  \(values?.fileSize ?? 0) bytes")
        }
        return (lines.isEmpty ? ["  (empty)"] : lines.sorted()).joined(separator: "\n") + "\n"
    }

    private func logExcerpt(warnings: inout [String]) -> String {
        let predicate = "subsystem == \"\(FilawayCore.subsystem)\""
        let output = environment.run(
            "/usr/bin/log",
            ["show", "--predicate", predicate, "--last", "1d", "--style", "compact", "--info"],
            Self.logTimeout
        )
        guard let output, !output.isEmpty else {
            warnings.append("no OSLog excerpt: `log show` produced nothing")
            return "(`log show` produced no output)\n"
        }
        // `log show` honours the `privacy: .private` annotations at the call
        // sites, so user text arrives as <private> and stays that way.
        return """
        $ log show --predicate '\(predicate)' --last 1d --style compact --info

        \(output)
        """
    }

    private func copyCrashReports(
        into bundle: URL,
        now: Date,
        entries: inout [String],
        warnings: inout [String]
    ) {
        let cutoff = now.addingTimeInterval(-Self.crashReportWindow)
        var copied = 0
        for directory in environment.crashReportDirectories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names.sorted() where name.hasPrefix("Filaway") {
                let source = directory.appendingPathComponent(name)
                let modified = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                guard modified >= cutoff else { continue }
                guard let data = fileManager.contents(atPath: source.path) else {
                    warnings.append("could not read a crash report")
                    continue
                }
                // Crash reports are JSON-ish text written by someone else, so
                // they get the full scrub before they are copied.
                let text = redactor.redact(String(decoding: data, as: UTF8.self))
                let folder = bundle.appendingPathComponent("crash-reports", isDirectory: true)
                try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(name)
                if (try? Data(text.utf8).write(to: target, options: .atomic)) != nil {
                    entries.append("crash-reports/\(name)")
                    copied += 1
                }
            }
        }
        if copied == 0 {
            warnings.append("no Filaway crash reports in the last 30 days (which is good news)")
        }
    }

    // MARK: - Writing, sweeping, archiving

    private func write(_ text: String, to bundle: URL, named name: String, entries: inout [String]) {
        let redacted = redactor.redact(text)
        let target = bundle.appendingPathComponent(name)
        guard (try? Data(redacted.utf8).write(to: target, options: .atomic)) != nil else { return }
        entries.append(name)
    }

    /// Last line of defence: reads back everything staged and removes any file
    /// the redactor can still find a library path or a known secret in.
    private func sweepForLeaks(in bundle: URL) -> [String] {
        guard let enumerator = fileManager.enumerator(
            at: bundle, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return [] }
        var dropped: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            guard let data = fileManager.contents(atPath: url.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            guard redactor.leaks(text) else { continue }
            let relative = url.path.hasPrefix(bundle.path)
                ? String(url.path.dropFirst(bundle.path.count + 1))
                : url.lastPathComponent
            try? fileManager.removeItem(at: url)
            dropped.append(relative)
        }
        return dropped
    }

    private func archive(_ bundle: URL, to destination: URL) throws {
        try? fileManager.removeItem(at: destination)
        try? fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let output = environment.run(
            "/usr/bin/ditto",
            ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, destination.path],
            60
        )
        guard fileManager.fileExists(atPath: destination.path) else {
            throw DiagnosticsError.couldNotArchive(output ?? "ditto produced no archive")
        }
    }

    static func stamp(_ date: Date) -> String {
        ISO8601.string(from: date)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
    }
}
