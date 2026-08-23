import ArgumentParser
import FilawayCore
import Foundation

/// `filaway-bench launch --library ~/Notes` — NFR-1's "cold launch to editable
/// under 2 s", measured (M4-07).
///
/// XCTest's `XCTApplicationLaunchMetric` needs Xcode, which this machine does
/// not have (plan §8), so the app stamps every stage of launch against the
/// kernel's exec time (`LaunchClock` → ``LaunchTimer``) and prints them under
/// `FILAWAY_TIMING=1`. This launches the assembled bundle N times against a
/// given notes folder, scrapes those lines, and reports the p50 of each stage.
///
/// ```
/// filaway-bench launch --library /tmp/five-thousand --runs 5
/// filaway-bench launch --notes 5000 --runs 5            # generate one first
/// ```
///
/// **What "cold" means here.** Not a reboot: the first run against a support
/// folder that has no database in it, which is what a user's first launch on
/// an existing notes folder actually is (scan + migrate + rebuild). `--warm`
/// keeps the database between runs, which is every launch after that. Both are
/// reported, because they are different budgets: the cold one includes the
/// whole metadata rebuild.
///
/// **A locked screen changes what is measurable.** macOS gives a launched app
/// no window while the session is locked, so SwiftUI never builds the scene and
/// `windowVisible` / `shellAppeared` / `editorReady` are never marked. The
/// driver opens the library itself in that case (`SmokeDriver
/// .openLibraryIfTheSceneDidNot`), so `dbOpen` and `libraryOpen` — the two
/// stages that scale with library size, and the whole of what M4-07 is about —
/// are still measured. Stages that never arrive are reported as `—` rather
/// than as zero.
struct LaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "launch",
        abstract: "Measure app launch to first sidebar paint on a real library (NFR-1, M4-07)."
    )

    @Option(help: "Notes folder to launch against. Generated if absent.")
    var library: String?

    @Option(name: .shortAndLong, help: "Notes to generate when --library is absent.")
    var notes = 0

    @Option(help: "Approximate body size per generated note, in bytes.")
    var bytes = 2_048

    @Option(help: "How many launches to time.")
    var runs = 5

    @Option(help: "The app bundle's executable.")
    var app = "build/Filaway.app/Contents/MacOS/Filaway"

    @Flag(help: "Keep the derived database between runs (a second-and-later launch).")
    var warm = false

    @Option(help: "Seconds to wait for a launch to reach its last stage.")
    var timeout = 90.0

    @Option(help: "Fail when the p50 to the first sidebar paint reaches this many ms (NFR-1 is 2000).")
    var budgetMillis = 2_000.0

    @Flag(help: "Keep a generated corpus and print its path.")
    var keep = false

    mutating func run() async throws {
        let executable = URL(fileURLWithPath: app)
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ValidationError("no app at \(executable.path) — run `make app` first")
        }

        var generated: URL?
        let notesRoot: URL
        if let library {
            notesRoot = URL(fileURLWithPath: (library as NSString).expandingTildeInPath)
        } else {
            guard notes > 0 else {
                throw ValidationError("pass --library <path> or --notes <n>")
            }
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("filaway-launch-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("Notes", isDirectory: true)
            let start = Date()
            try SyntheticCorpus.generate(
                noteCount: notes,
                into: Library(root: root, supportRoot: root.deletingLastPathComponent()
                    .appendingPathComponent("Support", isDirectory: true)),
                approximateBytes: bytes
            )
            print("corpus:   \(notes) notes generated in \(format(Date().timeIntervalSince(start)))")
            notesRoot = root
            generated = root.deletingLastPathComponent()
        }
        defer {
            if let generated, !keep { try? FileManager.default.removeItem(at: generated) }
        }

        let noteCount = (try? FileManager.default.subpathsOfDirectory(atPath: notesRoot.path))?
            .count(where: { $0.hasSuffix(".md") }) ?? 0
        print("# filaway-bench launch — NFR-1 cold launch to editable")
        print("")
        print("library:  \(notesRoot.path) — \(noteCount) notes")
        print("mode:     \(warm ? "warm (database kept between runs)" : "cold (database discarded before each run)")")
        print("runs:     \(runs)")
        print("")

        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("filaway-launch-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let suite = "com.tejaspanse.filaway.launchbench.\(UUID().uuidString.prefix(8))"
        defer { _ = try? shell("/usr/bin/defaults", ["delete", suite]) }

        var perStage: [String: [Double]] = [:]
        var sceneArrived = false
        for run in 1 ... max(1, runs) {
            if !warm { try? FileManager.default.removeItem(at: support) }
            let stages = try await measure(
                executable: executable, notesRoot: notesRoot, support: support, suite: suite
            )
            guard !stages.isEmpty else {
                print("run \(run):    no [timing] lines — the app printed nothing before the timeout")
                continue
            }
            if stages["windowVisible"] != nil { sceneArrived = true }
            for (label, milliseconds) in stages { perStage[label, default: []].append(milliseconds) }
            let rendered = LaunchTimer.launchStages
                .compactMap { label in stages[label].map { "\(label) \(Int($0.rounded())) ms" } }
                .joined(separator: " · ")
            print("run \(run):    \(rendered)")
        }

        print("")
        print("stage                p50        min        max        n")
        for label in LaunchTimer.launchStages {
            guard let values = perStage[label], !values.isEmpty else {
                print("\(pad(label, 20)) \(pad("—", 10))\(pad("—", 10))\(pad("—", 10))0")
                continue
            }
            print("\(pad(label, 20)) "
                + pad(millis(percentile(values.map { $0 / 1000 }, 0.5) * 1000), 10)
                + pad(millis(values.min() ?? 0), 10)
                + pad(millis(values.max() ?? 0), 10)
                + "\(values.count)")
        }

        if !sceneArrived {
            print("")
            print("note:     no window this session (locked screen or no Aqua session) — "
                + "`windowVisible`, `shellAppeared` and `editorReady` are BLOCKED(env), "
                + "`dbOpen`/`libraryOpen` are real. See docs/verification/M4-perf.md.")
        }

        guard let paint = perStage["libraryOpen"], !paint.isEmpty else {
            print("")
            print("SKIP      no libraryOpen mark — nothing to gate on")
            return
        }
        let p50 = percentile(paint.map { $0 / 1000 }, 0.5) * 1000
        print("")
        if p50 < budgetMillis {
            print("PASS      first sidebar paint p50 \(millis(p50)) < \(Int(budgetMillis)) ms (NFR-1)")
        } else {
            print("FAIL      first sidebar paint p50 \(millis(p50)) reaches the "
                + "\(Int(budgetMillis)) ms budget (NFR-1)")
            throw ExitCode.failure
        }
        if keep, let generated { print("corpus kept at \(generated.path)") }
    }

    // MARK: - One launch

    /// Launches the app, reads its stdout until the last stage or the timeout,
    /// then terminates it. Returns `label -> milliseconds since exec`.
    private func measure(
        executable: URL, notesRoot: URL, support: URL, suite: String
    ) async throws -> [String: Double] {
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["FILAWAY_TIMING"] = "1"
        environment["FILAWAY_NOTES_ROOT"] = notesRoot.path
        environment["FILAWAY_SUPPORT_ROOT"] = support.path
        environment["FILAWAY_DEFAULTS_SUITE"] = suite
        // A phase, so `SmokeDriver` opens the library even when the scene never
        // arrives; `2` is the relaunch phase, which only reads. Replay so no
        // launch can reach the network (ADR-035).
        environment["FILAWAY_SMOKE"] = "2"
        environment["FILAWAY_AI_MODE"] = "replay"
        environment["FILAWAY_AI_FIXTURES"] = "Tests/Fixtures/ai-recordings"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        var stages: [String: Double] = [:]
        var buffer = Data()
        let handle = pipe.fileHandleForReading
        // The last stage that can arrive: with a window it is `editorReady`,
        // without one it is `libraryOpen`.
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex ..< newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex ... newline)
                if let stage = Self.parse(line) { stages[stage.label] = stage.milliseconds }
            }
            if stages["editorReady"] != nil { break }
            // No scene, so `editorReady` will never come: the library paint is
            // the end of what this session can measure. Give the process a beat
            // to print anything queued behind it, then stop.
            if stages["libraryOpen"] != nil, stages["shellAppeared"] == nil { break }
        }

        process.terminate()
        // A terminate the app answers with its FR-2.3 flush; do not wait long.
        let killDeadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < killDeadline { usleep(50_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        try? handle.close()
        return stages
    }

    /// `"[timing] libraryOpen          +404 ms"` → `("libraryOpen", 404)`.
    static func parse(_ line: String) -> (label: String, milliseconds: Double)? {
        guard line.hasPrefix("[timing]") else { return nil }
        let fields = line.dropFirst("[timing]".count)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2, fields[1].hasPrefix("+"),
              let milliseconds = Double(fields[1].dropFirst())
        else { return nil }
        return (String(fields[0]), milliseconds)
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private func millis(_ value: Double) -> String {
        value < 1_000
            ? String(format: "%.0f ms", value)
            : String(format: "%.2f s", value / 1_000)
    }

    @discardableResult
    private func shell(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
