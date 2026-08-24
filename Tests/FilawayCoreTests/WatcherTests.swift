import Foundation
import Testing

@testable import FilawayCore

/// The live-FSEvents suite (DS-4), and the only suite in the project whose
/// timing is not under its own control.
///
/// Three rules keep it deterministic rather than merely lucky (M4-08):
///
/// 1. **`.serialized`.** Two FSEvents streams racing on a loaded machine is the
///    difference between a 100 ms latency and a 3 s one.
/// 2. **A barrier before the first assertion.** `FSEventStreamStart` returning
///    `true` does not mean the stream is delivering yet, so every test writes a
///    sentinel file and waits until the watcher reports it. Anything written
///    after that is genuinely being watched.
/// 3. **Never a fixed sleep.** Waiting for something to *appear* is
///    `waitUntil`. Waiting to prove something did *not* appear is another
///    barrier: write a second sentinel and wait for it, which flushes the queue
///    past everything sent before it.
@Suite("Live FSEvents watcher (DS-4)", .tags(.fsevents), .serialized)
struct WatcherTests {
    /// Waits until the stream is actually delivering, using a file that means
    /// nothing to any assertion.
    ///
    /// - Returns: `true` when the barrier was observed.
    @discardableResult
    static func barrier(
        _ temp: TempLibrary,
        _ collector: ChangeCollector,
        _ label: String
    ) async -> Bool {
        let path = "fsevents-barrier-\(label).md"
        try? temp.writeExternal("barrier \(label)\n", to: path)
        let seen = await waitUntil(timeout: 20) {
            await collector.contains { $0.relativePath == path }
        }
        try? temp.removeExternal(path)
        _ = await waitUntil(timeout: 20) {
            await collector.contains { change in
                if case let .removed(relativePath, _) = change { return relativePath == path }
                return false
            }
        }
        return seen
    }

    @Test(
        "The live stream reports an external create, edit, move and delete",
        .enabled(if: TestEnvironment.runsFSEventsTests),
        .timeLimit(.minutes(1))
    )
    func liveStream() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata, latency: 0.1)
        let collector = ChangeCollector()
        await collector.attach(to: watcher)

        try await watcher.reconcile()
        #expect(await watcher.start(), "FSEvents stream should start")
        defer { Task { await watcher.stop() } }
        #expect(await Self.barrier(temp, collector, "live"), "the stream never started delivering")
        await collector.reset()

        // Create.
        try temp.writeExternal("hello\n", to: "live.md")
        #expect(await waitUntil(timeout: 20) { await metadata.noteCountOrZero() == 1 }, "create was not seen")

        // Edit.
        try temp.writeExternal("hello again\n", to: "live.md")
        #expect(await waitUntil(timeout: 20) {
            (try? await metadata.note(relativePath: "live.md"))??.contentHash == Hashing.sha256Hex("hello again\n")
        }, "edit was not seen")

        // Move. The old path's removal and the new path's arrival are two
        // events; asserting the count separately would race the second one.
        try temp.makeExternalFolder("Commands")
        try temp.moveExternal("live.md", to: "Commands/live.md")
        #expect(await waitUntil(timeout: 20) {
            guard (try? await metadata.note(relativePath: "Commands/live.md")) ?? nil != nil else { return false }
            return (try? await metadata.noteCount()) == 1
        }, "the move was not seen, or it duplicated the note")

        // Delete.
        try temp.removeExternal("Commands/live.md")
        #expect(await waitUntil(timeout: 20) { await metadata.noteCountOrZero() == 0 }, "delete was not seen")

        // The collector is a second actor downstream of the one that wrote the
        // database, so "the database has caught up" does not mean "the stream
        // has been drained". Wait for the change, never snapshot for it.
        #expect(await waitUntil(timeout: 20) {
            await collector.contains { if case .added = $0 { return $0.relativePath == "live.md" } else { return false } }
        }, "the create never reached the change stream")
        #expect(await waitUntil(timeout: 20) {
            await collector.contains { if case .removed = $0 { return true } else { return false } }
        }, "the delete never reached the change stream")
        await collector.detach()
    }

    @Test(
        "The store's own writes never reach the live stream",
        .enabled(if: TestEnvironment.runsFSEventsTests),
        .timeLimit(.minutes(1))
    )
    func liveEchoSuppression() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata, latency: 0.1)
        let collector = ChangeCollector()
        await collector.attach(to: watcher)
        try await watcher.reconcile()
        #expect(await watcher.start())
        defer { Task { await watcher.stop() } }
        #expect(await Self.barrier(temp, collector, "echo-open"), "the stream never started delivering")
        await collector.reset()

        let note = try await temp.store.createNote(title: "quiet")
        for index in 0 ..< 5 {
            try await temp.store.save(body: "revision \(index)\n", to: note.relativePath)
        }
        #expect(await waitUntil(timeout: 20) { await metadata.noteCountOrZero() == 1 })

        // Proving a *negative* needs a flush, not a nap: a second barrier goes
        // through the same coalescing queue, so once it arrives everything the
        // own writes could have produced has already arrived too.
        #expect(await Self.barrier(temp, collector, "echo-flush"), "the flush barrier never arrived")

        let noisy = await collector.snapshot().filter { change in
            if case .folderAdded = change { return false }
            return !change.relativePath.hasPrefix("fsevents-barrier-")
        }
        await collector.detach()
        #expect(noisy.isEmpty, "own writes leaked into the change stream: \(noisy)")
    }

    @Test("Stopping the watcher finishes its streams", .enabled(if: TestEnvironment.runsFSEventsTests))
    func stopFinishesStreams() async throws {
        let temp = try TempLibrary()
        let metadata = try temp.metadataStore()
        let watcher = temp.watcher(metadata)
        let stream = await watcher.changes()
        await watcher.stop()
        var received = 0
        for await _ in stream { received += 1 }
        #expect(received == 0)
    }
}
