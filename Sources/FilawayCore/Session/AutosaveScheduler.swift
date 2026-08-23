import Foundation

/// Why a buffer is being written (FR-2.3, plan §1 "Autosave").
public enum AutosaveTrigger: String, Sendable, Equatable, CaseIterable {
    /// The debounce window elapsed after the last keystroke.
    case debounce
    /// The user selected a different note.
    case noteSwitch
    /// The window stopped being key.
    case windowResignKey
    /// The application stopped being active.
    case appResignActive
    /// The application is terminating; nothing may be left unwritten.
    case terminate
    /// `flushNow()` — the session tracker (M2-03) and the smoke driver use this.
    case manual
    /// The watcher reported an external change to a note we hold dirty.
    case externalChange
}

/// One write the caller must perform. Everything needed is captured by value,
/// so the actual `NoteStore` call happens outside the scheduler's isolation.
public struct AutosaveJob: Sendable, Equatable, Identifiable {
    public let noteID: NoteID
    public let relativePath: String
    public let text: String
    public let trigger: AutosaveTrigger
    /// The file changed underneath a dirty buffer: route this through
    /// `LibraryWatcher.resolveExternalChange(noteID:inMemoryText:)` (ADR-010)
    /// instead of a plain `save`.
    public let needsConflictResolution: Bool
    /// Buffer generation this job captured. Passed back to ``finish(_:)`` so a
    /// keystroke that lands mid-write is not mistaken for a clean buffer.
    public let revision: Int

    public var id: NoteID { noteID }

    public init(
        noteID: NoteID,
        relativePath: String,
        text: String,
        trigger: AutosaveTrigger,
        needsConflictResolution: Bool,
        revision: Int
    ) {
        self.noteID = noteID
        self.relativePath = relativePath
        self.text = text
        self.trigger = trigger
        self.needsConflictResolution = needsConflictResolution
        self.revision = revision
    }
}

/// The autosave state machine (FR-2.3, NFR-3).
///
/// It holds one dirty buffer per note and decides *what* to write and *when*;
/// it owns no timer and touches no filesystem, so every rule is exercised by
/// `swift test` with an injected `now`. The app layer
/// (`FilawayApp/Features/Editor/AutosaveController.swift`) is the thin part:
/// it arms a timer for ``nextDeadline(after:)``, performs the returned jobs
/// against `NoteStore`, and reports back with ``finish(_:)``. See ADR-022.
///
/// ```swift
/// let deadline = await scheduler.bufferChanged(noteID: id, relativePath: path, text: text)
/// // …timer fires…
/// for job in await scheduler.jobsDue(at: Date()) {
///     let summary = try await store.save(body: job.text, to: job.relativePath)
///     await scheduler.finish(job)
/// }
/// ```
public actor AutosaveScheduler {

    /// Debounce window after the last keystroke. Plan §1: 750 ms, comfortably
    /// inside FR-2.3's 2 s budget.
    public static let defaultDebounce: TimeInterval = 0.75

    public let debounce: TimeInterval

    private struct Entry {
        var relativePath: String
        var text: String
        var lastChange: Date
        var revision: Int
        var needsConflictResolution: Bool
        /// Order in which this note first became dirty — flushes preserve it.
        var sequence: Int
    }

    private var entries: [NoteID: Entry] = [:]
    private var revisionCounter = 0
    private var sequenceCounter = 0

    public init(debounce: TimeInterval = AutosaveScheduler.defaultDebounce) {
        self.debounce = max(0, debounce)
    }

    // MARK: - Input

    /// Records a keystroke burst. Returns the deadline the caller should arm a
    /// timer for.
    @discardableResult
    public func bufferChanged(
        noteID: NoteID,
        relativePath: String,
        text: String,
        at now: Date = Date()
    ) -> Date {
        revisionCounter += 1
        if var entry = entries[noteID] {
            entry.relativePath = relativePath
            entry.text = text
            entry.lastChange = now
            entry.revision = revisionCounter
            entries[noteID] = entry
        } else {
            sequenceCounter += 1
            entries[noteID] = Entry(
                relativePath: relativePath,
                text: text,
                lastChange: now,
                revision: revisionCounter,
                needsConflictResolution: false,
                sequence: sequenceCounter
            )
        }
        return now.addingTimeInterval(debounce)
    }

    /// The note moved or was retitled; keep writing to the right file.
    public func noteRelocated(noteID: NoteID, to relativePath: String) {
        entries[noteID]?.relativePath = relativePath
    }

    /// The watcher saw an external `.modified`/`.removed` for this note.
    ///
    /// - Returns: `true` when a dirty buffer exists, meaning the caller must
    ///   *not* reload from disk and the next job for this note will carry
    ///   ``AutosaveJob/needsConflictResolution``.
    @discardableResult
    public func externalChangeSeen(noteID: NoteID) -> Bool {
        guard entries[noteID] != nil else { return false }
        entries[noteID]?.needsConflictResolution = true
        return true
    }

    /// Forgets a buffer without writing it — the note was deleted, or the user
    /// discarded it.
    public func drop(noteID: NoteID) {
        entries.removeValue(forKey: noteID)
    }

    // MARK: - Output

    public func isDirty(_ noteID: NoteID) -> Bool { entries[noteID] != nil }

    public var dirtyCount: Int { entries.count }

    public func dirtyNoteIDs() -> Set<NoteID> { Set(entries.keys) }

    /// The earliest moment a debounce job becomes due, or `nil` when clean.
    public func nextDeadline() -> Date? {
        entries.values.map { $0.lastChange.addingTimeInterval(debounce) }.min()
    }

    /// Jobs whose debounce window has elapsed, oldest dirty first.
    public func jobsDue(at now: Date = Date()) -> [AutosaveJob] {
        let due = entries.filter { $0.value.lastChange.addingTimeInterval(debounce) <= now }
        return jobs(from: due, trigger: .debounce)
    }

    /// Every dirty buffer, deadline or not. The flush points of plan §1: note
    /// switch, window resign key, app resign active, terminate.
    ///
    /// Ordered by the sequence in which the notes first went dirty, so a
    /// terminate flush replays the user's editing order.
    public func flushAll(trigger: AutosaveTrigger) -> [AutosaveJob] {
        jobs(from: entries, trigger: trigger)
    }

    /// One note's buffer, deadline or not.
    public func flush(noteID: NoteID, trigger: AutosaveTrigger) -> AutosaveJob? {
        guard let entry = entries[noteID] else { return nil }
        return job(noteID: noteID, entry: entry, trigger: trigger)
    }

    // MARK: - Completion

    /// The write succeeded. The buffer is only marked clean when no keystroke
    /// landed while it was in flight — otherwise it stays dirty at the *new*
    /// text and the timer re-arms (NFR-3: never drop a burst).
    ///
    /// - Returns: `true` if the note is now clean.
    @discardableResult
    public func finish(_ job: AutosaveJob) -> Bool {
        guard let entry = entries[job.noteID] else { return true }
        guard entry.revision == job.revision else {
            // Typed during the write. Keep the newer text; the conflict flag is
            // consumed either way, the external copy was already made.
            entries[job.noteID]?.needsConflictResolution = false
            return false
        }
        entries.removeValue(forKey: job.noteID)
        return true
    }

    /// The write failed. The buffer stays dirty and keeps its conflict flag;
    /// `lastChange` is pushed forward so the caller does not spin.
    public func fail(_ job: AutosaveJob, retryAt now: Date = Date()) {
        guard entries[job.noteID] != nil else { return }
        entries[job.noteID]?.lastChange = now
    }

    // MARK: - Private

    private func jobs(from source: [NoteID: Entry], trigger: AutosaveTrigger) -> [AutosaveJob] {
        source
            .sorted { $0.value.sequence < $1.value.sequence }
            .map { job(noteID: $0.key, entry: $0.value, trigger: trigger) }
    }

    private func job(noteID: NoteID, entry: Entry, trigger: AutosaveTrigger) -> AutosaveJob {
        AutosaveJob(
            noteID: noteID,
            relativePath: entry.relativePath,
            text: entry.text,
            trigger: trigger,
            needsConflictResolution: entry.needsConflictResolution,
            revision: entry.revision
        )
    }
}
