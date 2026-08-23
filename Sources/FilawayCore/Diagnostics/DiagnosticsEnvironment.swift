import Foundation

/// Everything ``DiagnosticsExporter`` needs from outside the process, behind
/// one injectable value.
///
/// The live implementation shells out (`log show`, `ditto`) and reads
/// `~/Library/Logs/DiagnosticReports`. The tests hand over a fabricated crash
/// report and a fabricated log excerpt instead, so the NFR-4 assertions run in
/// milliseconds, need no logging permission, and can plant a sentinel exactly
/// where a real leak would appear.
public struct DiagnosticsEnvironment: Sendable {
    /// Marketing version (`CFBundleShortVersionString`).
    public var appVersion: String
    /// Build number (`CFBundleVersion`), when the caller has a bundle.
    public var buildVersion: String
    /// `macOS 26.1 (25B75)` and the like.
    public var osVersion: String
    /// Where crash reports live. Every `Filaway*` file in them is a candidate.
    public var crashReportDirectories: [URL]
    /// Runs a tool and returns its standard output, or `nil` if it could not be
    /// run at all. Standard error is folded in — a failure message is itself
    /// diagnostic.
    public var run: @Sendable (_ launchPath: String, _ arguments: [String], _ timeout: TimeInterval) -> String?
    public var now: @Sendable () -> Date

    public init(
        appVersion: String = FilawayCore.version,
        buildVersion: String = "",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        crashReportDirectories: [URL] = DiagnosticsEnvironment.defaultCrashReportDirectories,
        run: @escaping @Sendable (String, [String], TimeInterval) -> String? = DiagnosticsEnvironment.runProcess,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.osVersion = osVersion
        self.crashReportDirectories = crashReportDirectories
        self.run = run
        self.now = now
    }

    /// The real thing.
    public static let live = DiagnosticsEnvironment()

    /// Both places macOS has put `.ips` crash reports.
    public static var defaultCrashReportDirectories: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return [
            home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
            URL(fileURLWithPath: "/Library/Logs/DiagnosticReports", isDirectory: true),
        ]
    }

    /// Spawns a tool, waits up to `timeout`, and returns what it said.
    ///
    /// Deliberately blocking: it is called from an actor that is already off
    /// the main thread, and the bounded wait is what keeps a wedged `log show`
    /// from hanging an export.
    public static let runProcess: @Sendable (String, [String], TimeInterval) -> String? = { launchPath, arguments, timeout in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "could not run \(launchPath): \(error)"
        }
        // Read on a second thread: a pipe that fills up deadlocks a process
        // that is only waited on.
        let collected = Collector()
        let reader = Thread {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            collected.set(data)
        }
        reader.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            _ = try? pipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        while !collected.isSet, Date() < deadline.addingTimeInterval(2) {
            usleep(20_000)
        }
        return String(decoding: collected.value, as: UTF8.self)
    }

    /// Tiny locked box, so the reader thread can hand its bytes back.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data: Data?

        func set(_ value: Data) {
            lock.lock()
            defer { lock.unlock() }
            data = value
        }

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return data != nil
        }

        var value: Data {
            lock.lock()
            defer { lock.unlock() }
            return data ?? Data()
        }
    }
}
