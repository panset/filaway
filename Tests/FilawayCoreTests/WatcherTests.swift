import Foundation
import Testing

@testable import FilawayCore

@Suite("Live FSEvents watcher (DS-4)", .tags(.fsevents), .serialized)
struct WatcherTests {
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

        // Create.
        try temp.writeExternal("hello\n", to: "live.md")
        #expect(await waitUntil { await metadata.noteCountOrZero() == 1 }, "create was not seen")

        // Edit.
        try temp.writeExternal("hello again\n", to: "live.md")
        #expect(await waitUntil {
            (try? await metadata.note(relativePath: "live.md"))??.contentHash == Hashing.sha256Hex("hello again\n")
        }, "edit was not seen")

        // Move.
        try temp.makeExternalFolder("Commands")
        try temp.moveExternal("live.md", to: "Commands/live.md")
        #expect(await waitUntil {
            (try? await metadata.note(relativePath: "Commands/live.md")) ?? nil != nil
        }, "move was not seen")
        #expect(try await metadata.noteCount() == 1, "the move must not duplicate the note")

        // Delete.
        try temp.removeExternal("Commands/live.md")
        #expect(await waitUntil { await metadata.noteCountOrZero() == 0 }, "delete was not seen")

        let changes = await collector.snapshot()
        await collector.detach()
        #expect(changes.contains { if case .added = $0 { return $0.relativePath == "live.md" } else { return false } })
        #expect(changes.contains { if case .removed = $0 { return true } else { return false } })
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

        let note = try await temp.store.createNote(title: "quiet")
        for index in 0 ..< 5 {
            try await temp.store.save(body: "revision \(index)\n", to: note.relativePath)
        }
        #expect(await waitUntil { await metadata.noteCountOrZero() == 1 })
        // Give the stream a moment to deliver anything it was going to deliver.
        try await Task.sleep(nanoseconds: 700_000_000)

        let noisy = await collector.snapshot().filter {
            if case .folderAdded = $0 { return false } else { return true }
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
