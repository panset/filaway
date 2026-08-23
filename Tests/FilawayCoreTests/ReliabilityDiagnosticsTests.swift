import Foundation
import Testing

@testable import FilawayCore

/// M4-08 — Help ▸ Export Diagnostics… must be safe to send to a stranger
/// (NFR-4: zero-content telemetry).
///
/// The whole suite is built around one sentinel string. It is planted
/// everywhere a leak could realistically start — a note's body, a note's
/// *filename*, a folder name in Settings, an OSLog line, a crash report — and
/// then every file in the produced zip is read back and searched for it. If any
/// of those routes ever opens up, this fails.
@Suite("Diagnostics export (NFR-4)")
struct ReliabilityDiagnosticsTests {
    /// Unlikely to occur by accident, easy to spot in a failure message.
    static let sentinel = "ZQ7-CONFIDENTIAL-PATIENT-NOTES-ZQ7"
    static let fakeKey = "sk-ant-api03-thisisnotarealkeybutitlookslikeone"

    // MARK: - Fixture

    struct Fixture {
        let temp: TempLibrary
        let settings: AppSettings
        let defaultsSuite: String
        let crashDirectory: URL
        let logOutput: String

        var library: Library { temp.library }
    }

    static func makeFixture() async throws -> Fixture {
        let temp = try TempLibrary()
        // 1. The sentinel as note *content*.
        try await temp.store.createFolder("\(sentinel) folder")
        try await temp.store.save(body: "\(sentinel) in the body\n", to: "\(sentinel) folder/Diary.md")
        // 2. The sentinel as a note *title*, which is also its filename (DS-1).
        try await temp.store.save(body: "harmless\n", to: "\(sentinel).md")

        // 3. The sentinel as a user-chosen setting.
        let suite = "filaway-diagnostics-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults, libraryKey: temp.library.key)
        settings.setExcludedFolders(["\(sentinel) folder"], libraryKey: temp.library.key)
        settings.organizationMode = .autoFile
        settings.idleInterval = 7

        // 4. The sentinel inside a crash report someone else wrote, as a full
        //    absolute path — the realistic shape of a leak.
        let crashDirectory = temp.base.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: crashDirectory, withIntermediateDirectories: true)
        let report = """
        {"app_name":"Filaway","timestamp":"2026-08-22 09:41:00.00 +0100",
         "bundleID":"com.tejaspanse.filaway",
         "lastExceptionBacktrace":"reading \(temp.library.root.path)/\(sentinel) folder/Diary.md",
         "openFiles":["\(temp.library.root.path)/\(sentinel).md"],
         "user":"\(NSUserName())",
         "leakedKey":"\(fakeKey)"}
        """
        try Data(report.utf8).write(
            to: crashDirectory.appendingPathComponent("Filaway-2026-08-22-094100.ips")
        )
        // A crash report for a different app, which must not be swept up.
        try Data("{\"app_name\":\"Mail\"}".utf8).write(
            to: crashDirectory.appendingPathComponent("Mail-2026-08-22-094100.ips")
        )

        // 5. The sentinel in the log excerpt, as a path and as bare text.
        let logOutput = """
        2026-08-22 09:41:00.111 Db Filaway[123:456] [com.tejaspanse.filaway:store] saved <private>
        2026-08-22 09:41:00.222 Er Filaway[123:456] [com.tejaspanse.filaway:organize] \
        could not read \(temp.library.root.path)/\(sentinel) folder/Diary.md
        2026-08-22 09:41:00.333 Df Filaway[123:456] [com.tejaspanse.filaway:ai] \
        request failed with key \(fakeKey)
        """
        return Fixture(
            temp: temp,
            settings: settings,
            defaultsSuite: suite,
            crashDirectory: crashDirectory,
            logOutput: logOutput
        )
    }

    static func makeExporter(_ fixture: Fixture) -> DiagnosticsExporter {
        let logOutput = fixture.logOutput
        let environment = DiagnosticsEnvironment(
            appVersion: "0.1.0",
            buildVersion: "1234",
            osVersion: "macOS 26.1 (test)",
            crashReportDirectories: [fixture.crashDirectory],
            run: { launchPath, arguments, timeout in
                // `ditto` is the real thing — the archive has to be a real zip.
                if launchPath.hasSuffix("ditto") {
                    return DiagnosticsEnvironment.runProcess(launchPath, arguments, timeout)
                }
                return logOutput
            },
            now: { Date(timeIntervalSince1970: 1_756_000_000) }
        )
        return DiagnosticsExporter(
            library: fixture.library, settings: fixture.settings, environment: environment
        )
    }

    /// Unpacks a zip and hands back `name -> contents`.
    static func unzip(_ archive: URL, into base: URL) throws -> [String: String] {
        let destination = base.appendingPathComponent("unzipped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = DiagnosticsEnvironment.runProcess(
            "/usr/bin/ditto", ["-x", "-k", archive.path, destination.path], 60
        )
        var out: [String: String] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: destination, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return out }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let data = FileManager.default.contents(atPath: url.path) ?? Data()
            let relative = String(url.path.dropFirst(destination.path.count + 1))
            out[relative] = String(decoding: data, as: UTF8.self)
        }
        return out
    }

    // MARK: - The one that matters

    @Test("No file in the exported zip contains the sentinel, anywhere")
    func exportCarriesNoUserContent() async throws {
        let fixture = try await Self.makeFixture()
        defer { UserDefaults.standard.removeSuite(named: fixture.defaultsSuite) }
        let exporter = Self.makeExporter(fixture)
        let destination = fixture.temp.base.appendingPathComponent("diagnostics.zip")

        let export = try await exporter.export(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(export.byteCount > 0)

        let files = try Self.unzip(destination, into: fixture.temp.base)
        #expect(!files.isEmpty, "the archive should not be empty")
        for (name, contents) in files {
            #expect(!contents.contains(Self.sentinel), "\(name) leaked the sentinel")
            #expect(!contents.contains(Self.fakeKey), "\(name) leaked an API key")
            #expect(
                !contents.contains(fixture.library.root.path),
                "\(name) leaked an absolute path into the notes root"
            )
        }
        // And it is not empty because everything was dropped.
        #expect(export.dropped.isEmpty, "files were dropped by the leak sweep: \(export.dropped)")
    }

    @Test("The bundle still contains the things a bug report needs")
    func exportIsActuallyUseful() async throws {
        let fixture = try await Self.makeFixture()
        defer { UserDefaults.standard.removeSuite(named: fixture.defaultsSuite) }
        // A database with rows in it, so the counts are worth reading.
        let metadata = try MetadataStore(library: fixture.library)
        try await metadata.rebuild(from: fixture.temp.store.scan(settleWindow: 0))
        let activity = try ActivityLog(library: fixture.library)
        _ = try await activity.begin(
            kind: .applied, status: .applied, summary: "s",
            sessionText: Self.sentinel, at: Date(timeIntervalSince1970: 1_755_000_000)
        )

        let destination = fixture.temp.base.appendingPathComponent("diagnostics.zip")
        let export = try await Self.makeExporter(fixture).export(to: destination)
        let files = try Self.unzip(destination, into: fixture.temp.base)
        let byName = Dictionary(uniqueKeysWithValues: files.map { (URL(fileURLWithPath: $0.key).lastPathComponent, $0.value) })

        let versions = try #require(byName["versions.txt"])
        #expect(versions.contains("0.1.0"))
        #expect(versions.contains("macOS 26.1 (test)"))
        #expect(versions.contains(fixture.library.key))

        let database = try #require(byName["database.txt"])
        #expect(database.contains("filaway.sqlite"))
        #expect(database.contains("table notes:"))
        #expect(database.contains("table activity_events: 1 row(s)"))
        // Schema, yes. Rows, never — the session text above is in that table.
        #expect(database.contains("CREATE TABLE"))
        #expect(!database.contains(Self.sentinel))

        let settings = try #require(byName["settings.txt"])
        #expect(settings.contains("organizationMode        autoFile"))
        #expect(settings.contains("idleInterval (minutes)  7"))
        #expect(settings.contains("excludedFolders         1 folder(s)"), "count only, never the names")

        let log = try #require(byName["oslog.txt"])
        #expect(log.contains("com.tejaspanse.filaway"))
        #expect(log.contains("<private>"), "the log's own privacy annotations survive the copy")
        #expect(log.contains(DiagnosticsRedactor.notesRootPlaceholder))

        #expect(files.keys.contains { $0.hasSuffix("Filaway-2026-08-22-094100.ips") })
        #expect(!files.keys.contains { $0.contains("Mail-2026") }, "another app's crash report is not ours to send")
        #expect(byName["README.txt"]?.contains("deliberately NOT") == true)
    }

    @Test("Crash reports older than 30 days are left behind")
    func oldCrashReportsAreNotCollected() async throws {
        let fixture = try await Self.makeFixture()
        defer { UserDefaults.standard.removeSuite(named: fixture.defaultsSuite) }
        let stale = fixture.crashDirectory.appendingPathComponent("Filaway-ancient.ips")
        try Data("{\"app_name\":\"Filaway\"}".utf8).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_756_000_000 - 400 * 86_400)],
            ofItemAtPath: stale.path
        )

        let destination = fixture.temp.base.appendingPathComponent("diagnostics.zip")
        _ = try await Self.makeExporter(fixture).export(to: destination)
        let files = try Self.unzip(destination, into: fixture.temp.base)
        #expect(!files.keys.contains { $0.contains("ancient") })
        #expect(files.keys.contains { $0.contains("094100") })
    }

    @Test("An export works with no database, no settings and no crash reports at all")
    func exportDegradesGracefully() async throws {
        let temp = try TempLibrary()
        let exporter = DiagnosticsExporter(
            library: temp.library,
            settings: nil,
            environment: DiagnosticsEnvironment(
                crashReportDirectories: [temp.base.appendingPathComponent("nowhere")],
                run: { launchPath, arguments, timeout in
                    launchPath.hasSuffix("ditto")
                        ? DiagnosticsEnvironment.runProcess(launchPath, arguments, timeout)
                        : nil
                }
            )
        )
        let destination = temp.base.appendingPathComponent("diagnostics.zip")
        let export = try await exporter.export(to: destination)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(export.warnings.count >= 2, "a partial bundle should say what is missing")
        #expect(export.entries.contains("README.txt"))
    }

    @Test("A quarantined database is named in the bundle, because it explains an empty history")
    func exportNamesQuarantinedDatabases() async throws {
        let fixture = try await Self.makeFixture()
        defer { UserDefaults.standard.removeSuite(named: fixture.defaultsSuite) }
        try FileManager.default.createDirectory(
            at: fixture.library.supportDirectory, withIntermediateDirectories: true
        )
        try Data(repeating: 0x11, count: 2_048).write(to: fixture.library.databaseURL)
        let store = try MetadataStore(library: fixture.library)
        #expect(await store.recoveredFromCorruption != nil)

        let destination = fixture.temp.base.appendingPathComponent("diagnostics.zip")
        _ = try await Self.makeExporter(fixture).export(to: destination)
        let files = try Self.unzip(destination, into: fixture.temp.base)
        let database = try #require(files.first { $0.key.hasSuffix("database.txt") }?.value)
        #expect(database.contains("quarantined databases"))
        #expect(database.contains("filaway.sqlite.corrupt-"))
    }

    // MARK: - The redactor on its own

    @Test("The redactor collapses everything under the notes root, not just the prefix")
    func redactorCollapsesPathsUnderTheRoot() {
        let redactor = DiagnosticsRedactor(
            notesRoots: ["/Users/ada/Notes"],
            homeDirectory: "/Users/ada",
            secrets: [],
            userNames: ["ada"]
        )
        let out = redactor.redact("could not open /Users/ada/Notes/Debugging/Auth API debug.md (ENOENT)")
        #expect(out.contains("<notes-root>/…"))
        #expect(!out.contains("Debugging"))
        #expect(!out.contains("Auth API debug"))
        #expect(out.contains("(ENOENT)"), "the diagnostic part of the line survives")
    }

    @Test("The redactor masks anything key-shaped, held or not")
    func redactorMasksKeys() {
        let redactor = DiagnosticsRedactor(notesRoots: [], homeDirectory: nil)
        let out = redactor.redact("Authorization: \(Self.fakeKey) failed")
        #expect(!out.contains(Self.fakeKey))
        #expect(out.contains(DiagnosticsRedactor.secretPlaceholder))
    }

    @Test("The redactor replaces the home directory with a tilde")
    func redactorMasksHome() {
        let redactor = DiagnosticsRedactor(
            notesRoots: [], homeDirectory: "/Users/ada", secrets: [], userNames: []
        )
        #expect(redactor.redact("/Users/ada/Library/Logs/x") == "~/Library/Logs/x")
    }

    @Test("An account name is masked in a path but left alone in ordinary text")
    func redactorMasksAccountNamesOnlyInPaths() {
        // Regression: the developer's account name is a substring of the bundle
        // id, and a bare replacement turned `com.tejaspanse.filaway` into
        // `com.<user>.filaway` in every log line.
        let redactor = DiagnosticsRedactor(
            notesRoots: [], homeDirectory: nil, secrets: [], userNames: ["tejaspanse"]
        )
        let out = redactor.redact("[com.tejaspanse.filaway:store] opened /Users/tejaspanse/x")
        #expect(out.contains("com.tejaspanse.filaway"))
        #expect(out.contains("/Users/<user>/x"))
    }

    @Test("The suggested filename is stable and ends in .zip")
    func suggestedFileName() {
        let name = DiagnosticsExporter.suggestedFileName(at: Date(timeIntervalSince1970: 1_756_000_000))
        #expect(name.hasPrefix("Filaway-diagnostics-"))
        #expect(name.hasSuffix(".zip"))
        #expect(!name.contains(":"), "a colon is a path separator in the Finder")
    }
}
