import Foundation
import FilawayCore

/// Drives ``AutosaveScheduler`` against `NoteStore` (FR-2.3, NFR-3).
///
/// The scheduler decides *what* and *when*; this owns the timer, performs the
/// writes, and routes conflicts through
/// `LibraryWatcher.resolveExternalChange` (ADR-010). Kept deliberately thin —
/// every rule worth testing lives in Core.
@MainActor
final class AutosaveController {

    let scheduler: AutosaveScheduler

    private let store: NoteStore
    private let watcher: LibraryWatcher
    private var timer: Timer?
    /// Keystrokes recorded on the main actor but not yet handed to the
    /// scheduler actor. Without this, a burst typed in the same run-loop turn
    /// as ⌘Q would still be in flight when the terminate flush ran, and would
    /// be lost (NFR-3).
    private var pending: [NoteID: (path: String, text: String)] = [:]
    private var pendingOrder: [NoteID] = []
    private var schedulerDirty: Set<NoteID> = []

    /// A buffer reached disk. Carries the fresh summary so the sidebar can
    /// re-sort Recents without a scan.
    var onSaved: ((NoteSummary, AutosaveTrigger) -> Void)?
    /// An external edit was preserved beside the note (ADR-010): the argument
    /// is the copy's relative path.
    var onConflictCopy: ((String) -> Void)?
    /// A write failed. The buffer stays dirty and will be retried.
    var onFailure: ((NoteID, Error) -> Void)?
    /// The dirty set changed — drives the sidebar's "Now · editing" row.
    var onDirtyChanged: ((Set<NoteID>) -> Void)?

    init(
        store: NoteStore,
        watcher: LibraryWatcher,
        debounce: TimeInterval = AutosaveScheduler.defaultDebounce
    ) {
        self.store = store
        self.watcher = watcher
        self.scheduler = AutosaveScheduler(debounce: debounce)
    }

    // MARK: - Input

    /// Every `onTextChange` from the editor lands here. Records the buffer
    /// synchronously, then hands it to the scheduler.
    func textChanged(noteID: NoteID, relativePath: String, text: String) {
        if pending[noteID] == nil { pendingOrder.append(noteID) }
        pending[noteID] = (relativePath, text)
        onDirtyChanged?(dirtyNoteIDs)
        Task { [weak self] in
            guard let self, let deadline = await self.drainPending() else { return }
            self.arm(for: deadline)
        }
    }

    /// Every note with unwritten text, whether or not the scheduler has seen it
    /// yet. Drives the sidebar's "Now · editing" row.
    var dirtyNoteIDs: Set<NoteID> { schedulerDirty.union(pending.keys) }

    /// Moves the main-actor buffers into the scheduler. Returns the earliest
    /// debounce deadline, if any.
    @discardableResult
    private func drainPending() async -> Date? {
        guard !pending.isEmpty else { return nil }
        let batch = pendingOrder.compactMap { id in pending[id].map { (id, $0) } }
        pending.removeAll()
        pendingOrder.removeAll()
        var earliest: Date?
        for (id, entry) in batch {
            let deadline = await scheduler.bufferChanged(
                noteID: id, relativePath: entry.path, text: entry.text
            )
            earliest = earliest.map { min($0, deadline) } ?? deadline
        }
        await publishDirty()
        return earliest
    }

    /// The note was renamed or moved — redirect the pending write.
    func noteRelocated(noteID: NoteID, to relativePath: String) {
        Task { [scheduler] in await scheduler.noteRelocated(noteID: noteID, to: relativePath) }
    }

    /// The note is gone; discard its buffer without writing.
    func discard(noteID: NoteID) {
        pending.removeValue(forKey: noteID)
        pendingOrder.removeAll { $0 == noteID }
        Task { [scheduler] in
            await scheduler.drop(noteID: noteID)
            await self.publishDirty()
        }
    }

    func isDirty(_ noteID: NoteID) -> Bool { dirtyNoteIDs.contains(noteID) }

    // MARK: - Flush points

    /// Note switch, window resign key, app resign active, terminate — and
    /// `flushNow()` for the session tracker (M2-03) and the smoke driver.
    func flushNow(trigger: AutosaveTrigger = .manual) async {
        timer?.invalidate()
        timer = nil
        await drainPending()
        let jobs = await scheduler.flushAll(trigger: trigger)
        await perform(jobs)
    }

    /// Flushes one note — used when the selection moves off it.
    func flush(noteID: NoteID, trigger: AutosaveTrigger) async {
        await drainPending()
        guard let job = await scheduler.flush(noteID: noteID, trigger: trigger) else { return }
        await perform([job])
    }

    /// Terminate-time flush that never touches the main actor.
    ///
    /// `applicationShouldTerminate` has to *block* the main thread until every
    /// buffer is on disk, and a blocked main thread can neither run main-actor
    /// jobs nor drain the main dispatch queue reentrantly. So the pending
    /// buffers are snapshotted synchronously here and the writes run on a
    /// detached task that only ever touches actors (`AutosaveScheduler`,
    /// `NoteStore`, `LibraryWatcher`). See ADR-014.
    func terminateFlush() -> Task<Int, Never> {
        timer?.invalidate()
        timer = nil
        let seeds = pendingOrder.compactMap { id in
            pending[id].map { PendingEdit(noteID: id, relativePath: $0.path, text: $0.text) }
        }
        pending.removeAll()
        pendingOrder.removeAll()
        let scheduler = self.scheduler
        let store = self.store
        let watcher = self.watcher
        return Task.detached(priority: .userInitiated) {
            for seed in seeds {
                await scheduler.bufferChanged(
                    noteID: seed.noteID, relativePath: seed.relativePath, text: seed.text
                )
            }
            var written = 0
            for job in await scheduler.flushAll(trigger: .terminate) {
                do {
                    if job.needsConflictResolution {
                        _ = try await watcher.resolveExternalChange(
                            noteID: job.noteID, inMemoryText: job.text
                        )
                    } else {
                        _ = try await store.save(body: job.text, to: job.relativePath)
                    }
                    await scheduler.finish(job)
                    written += 1
                } catch {
                    Log.app.error("terminate flush failed: \(String(describing: error), privacy: .public)")
                }
            }
            return written
        }
    }

    /// A keystroke burst captured on the main actor, safe to hand to a
    /// detached task.
    private struct PendingEdit: Sendable {
        let noteID: NoteID
        let relativePath: String
        let text: String
    }

    /// The watcher reported an external change for `noteID`.
    ///
    /// - Returns: `true` when the buffer was dirty, meaning the conflict rule
    ///   ran and the caller must **not** reload the editor from disk. `false`
    ///   means "clean — go ahead and reload".
    @discardableResult
    func externalChangeSeen(noteID: NoteID) async -> Bool {
        await drainPending()
        guard await scheduler.externalChangeSeen(noteID: noteID) else { return false }
        await flush(noteID: noteID, trigger: .externalChange)
        return true
    }

    // MARK: - Writing

    private func perform(_ jobs: [AutosaveJob]) async {
        for job in jobs {
            do {
                let summary: NoteSummary
                if job.needsConflictResolution {
                    // ADR-010: the buffer wins, the external bytes are kept
                    // beside the note with a fresh identity.
                    let resolution = try await watcher.resolveExternalChange(
                        noteID: job.noteID, inMemoryText: job.text
                    )
                    summary = resolution.note
                    if let copy = resolution.externalCopyPath {
                        onConflictCopy?(copy)
                    }
                } else {
                    summary = try await store.save(body: job.text, to: job.relativePath)
                }
                await scheduler.finish(job)
                onSaved?(summary, job.trigger)
            } catch {
                Log.app.error("autosave failed: \(String(describing: error), privacy: .public)")
                await scheduler.fail(job)
                onFailure?(job.noteID, error)
            }
        }
        await publishDirty()
        if let deadline = await scheduler.nextDeadline() { arm(for: deadline) }
    }

    private func publishDirty() async {
        schedulerDirty = await scheduler.dirtyNoteIDs()
        onDirtyChanged?(dirtyNoteIDs)
    }

    // MARK: - Timer

    private func arm(for deadline: Date) {
        let interval = max(0.01, deadline.timeIntervalSinceNow)
        if let timer, timer.isValid, timer.fireDate <= deadline { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.fire() }
        }
        // .common so autosave keeps ticking while a menu or a scroll is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func fire() async {
        timer = nil
        await drainPending()
        let jobs = await scheduler.jobsDue(at: Date())
        await perform(jobs)
    }
}
