import Foundation

// MARK: - What the session produced

/// The `baseline → current` change for one note in a session.
///
/// The baseline is the text the AI has already had a chance to file
/// (``OrganizedBaseline``), so ``addedText`` is *new material only*: a session
/// that appends three lines to a 50 KB note sends three lines as the delta, and
/// the full text only as context.
public struct SessionDelta: Sendable, Hashable {
    public var noteID: NoteID
    public var title: String
    public var relativePath: String
    public var folderPath: String
    /// The organized baseline this delta was computed against.
    public var baselineText: String
    /// The note as it stands now, after the autosave flush.
    public var currentText: String
    /// The lines that are in ``currentText`` and were not in ``baselineText``.
    public var addedText: String
    /// `true` when the AI has never seen this note.
    public var isNewNote: Bool
    /// `true` when the note still carries the placeholder title (FR-4.1's
    /// "retitle an untitled note").
    public var isUntitled: Bool

    public init(
        noteID: NoteID,
        title: String,
        relativePath: String,
        baselineText: String,
        currentText: String
    ) {
        self.noteID = noteID
        self.title = title
        self.relativePath = relativePath
        folderPath = PathRules.folderPath(of: relativePath)
        self.baselineText = baselineText
        self.currentText = currentText
        addedText = TextDelta.added(from: baselineText, to: currentText)
        isNewNote = baselineText.isEmpty
        isUntitled = title == PathRules.untitled || title.lowercased().hasPrefix("untitled")
    }

    /// `true` when there is new material worth spending a request on.
    ///
    /// Deleting text, reflowing whitespace or reverting an edit all leave
    /// nothing to file, and FR-6.2 says the user pays per token — so those
    /// sessions are skipped rather than sent.
    public var hasEffectiveChange: Bool {
        !addedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// FR-4.4's *raw session text*: everything the user wrote in this session,
    /// verbatim, and nothing that was already on disk before it.
    ///
    /// One note gives its ``addedText`` unadorned; several get a `## <title>`
    /// heading each so the Activity window's disclosure says which note a
    /// paragraph came from. Returns `nil` when nothing was added, which is the
    /// same thing as "there was no session worth recording".
    public static func rawSessionText(of deltas: [SessionDelta]) -> String? {
        let written = deltas.filter(\.hasEffectiveChange)
        guard !written.isEmpty else { return nil }
        if written.count == 1 { return written[0].addedText }
        return written
            .map { "## \($0.title)\n\n\($0.addedText)" }
            .joined(separator: "\n\n")
    }
}

/// A line-level "what is new here" diff.
///
/// Deliberately not a full diff algorithm: the organizer only needs the *added*
/// material, and a common-prefix/common-suffix scan gets that exactly right for
/// the shape of edit a writing session produces (typing at the end, inserting a
/// block in the middle) and harmlessly conservative for the rest — a
/// rearrangement reports more text as new, never less.
public enum TextDelta {
    /// The lines present in `to` but not in the unchanged head and tail it
    /// shares with `from`.
    public static func added(from old: String, to new: String) -> String {
        guard !new.isEmpty else { return "" }
        guard !old.isEmpty else { return new }
        if old == new { return "" }

        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldLines.count - prefix,
              suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }
        let addedLines = newLines[prefix ..< (newLines.count - suffix)]
        return addedLines.joined(separator: "\n")
    }
}

// MARK: - Candidates

/// A ranked merge target: a note the session material might already belong to
/// (FR-4.6's "prefer existing folders/notes").
public struct OrganizeCandidate: Sendable, Hashable {
    public var noteID: NoteID
    public var score: Double

    public init(noteID: NoteID, score: Double) {
        self.noteID = noteID
        self.score = score
    }
}

/// What the finder is asked to rank against.
public struct CandidateQuery: Sendable, Hashable {
    /// The new material from the session — usually the deltas concatenated.
    public var text: String
    /// Titles of the session's own notes, which often name the subject better
    /// than the body does.
    public var titles: [String]
    /// The session's notes — never their own merge targets.
    public var excluding: Set<NoteID>
    public var limit: Int

    public init(text: String, titles: [String] = [], excluding: Set<NoteID> = [], limit: Int = 6) {
        self.text = text
        self.titles = titles
        self.excluding = excluding
        self.limit = limit
    }
}

/// Finds the notes worth showing the model as merge targets.
///
/// Behind a protocol because M3-08 swaps the naive implementation below for the
/// hybrid keyword+embedding ranker without the organizer noticing (plan §3
/// M3-08). The context it is handed has already been through
/// ``ExclusionFilter``, so an excluded note cannot be returned.
public protocol CandidateFinder: Sendable {
    func candidates(for query: CandidateQuery, in context: OrganizeContext) async throws -> [OrganizeCandidate]
}

/// The Phase-1 stand-in: word overlap between the session text and each note's
/// title, folder and tags.
///
/// No index, no embeddings, no bodies — it only needs what a
/// ``LibrarySnapshot`` already carries, so it works before M3 exists and costs
/// nothing. Title matches count double, because a note titled `curl` is a far
/// better merge target for curl material than one that merely lives in
/// `Commands`.
public struct TitleOverlapCandidateFinder: CandidateFinder {
    /// Words too common to say anything about topic.
    public static let stopWords: Set<String> = [
        "the", "and", "for", "with", "this", "that", "from", "into", "note", "notes",
        "have", "has", "was", "were", "are", "you", "your", "all", "out", "not",
        "but", "can", "will", "just", "then", "than", "when", "what", "how", "why",
        "add", "added", "new", "use", "using", "used", "get", "got", "run", "ran",
    ]
    /// Only run when the session text is at least this long, so a two-word
    /// session does not drag in half the library.
    public var minimumScore: Double

    public init(minimumScore: Double = 0.04) {
        self.minimumScore = minimumScore
    }

    public func candidates(for query: CandidateQuery, in context: OrganizeContext) async throws -> [OrganizeCandidate] {
        let queryWords = Self.words(in: query.text + "\n" + query.titles.joined(separator: "\n"))
        guard !queryWords.isEmpty else { return [] }

        var scored: [(candidate: OrganizeCandidate, note: NoteSummary)] = []
        for note in context.notes where !query.excluding.contains(note.id) {
            let titleWords = Self.words(in: note.title)
            let contextWords = Self.words(in: note.folderPath.replacingOccurrences(of: "/", with: " "))
                .union(Self.words(in: note.tags.joined(separator: " ")))
            let titleHits = Double(titleWords.intersection(queryWords).count)
            let contextHits = Double(contextWords.subtracting(titleWords).intersection(queryWords).count)
            let denominator = Double(max(titleWords.count + contextWords.count, 1))
            let score = (2 * titleHits + contextHits) / (denominator + 2)
            guard score >= minimumScore else { continue }
            scored.append((OrganizeCandidate(noteID: note.id, score: score), note))
        }

        scored.sort { left, right in
            if left.candidate.score != right.candidate.score { return left.candidate.score > right.candidate.score }
            if left.note.modified != right.note.modified { return left.note.modified > right.note.modified }
            return left.note.relativePath < right.note.relativePath
        }
        return scored.prefix(max(0, query.limit)).map(\.candidate)
    }

    static func words(in text: String) -> Set<String> {
        var out: Set<String> = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3, !stopWords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }
}

// MARK: - The library, as the organizer reads it

/// Read access to the library for the organize pipeline.
///
/// One protocol rather than a direct `NoteStore` dependency: the organizer must
/// be testable with no files on disk, and the app is free to serve the snapshot
/// from `MetadataStore` (cheap) and the bodies from `NoteStore` (accurate).
public protocol OrganizeLibrarySource: Sendable {
    /// The library right now. Called after the autosave flush.
    func snapshot() async throws -> LibrarySnapshot
    /// A note's Markdown body, without front-matter. `nil` when the note is
    /// gone.
    func body(of noteID: NoteID) async throws -> String?
}

// MARK: - The built context

/// Everything one organize request needs: the prompt text, the validation
/// context it was built against, and what it cost.
public struct OrganizeRequestContext: Sendable {
    public var sessionID: SessionID
    /// The filtered library the plan is validated against (FR-4.5 already
    /// applied) and the source of the compare-and-swap preconditions.
    public var context: OrganizeContext
    public var deltas: [SessionDelta]
    /// The rendered user message.
    public var promptText: String
    /// Merge targets that survived the token budget, best first.
    public var candidateIDs: [NoteID]
    /// `bytes / 4` — see ``OrganizeContextBuilder/estimatedTokens(of:)``.
    public var estimatedPromptTokens: Int
    /// What had to be dropped to fit, in the order it was dropped. Empty is the
    /// normal case; the golden tests assert on it.
    public var truncations: [String]
    /// The text each session note had when the request was built. This is what
    /// a baseline advances to — never the text at apply time, which may already
    /// include the plan's own edits.
    public var snapshotTexts: [NoteID: String]

    public init(
        sessionID: SessionID,
        context: OrganizeContext,
        deltas: [SessionDelta],
        promptText: String,
        candidateIDs: [NoteID],
        estimatedPromptTokens: Int,
        truncations: [String],
        snapshotTexts: [NoteID: String]
    ) {
        self.sessionID = sessionID
        self.context = context
        self.deltas = deltas
        self.promptText = promptText
        self.candidateIDs = candidateIDs
        self.estimatedPromptTokens = estimatedPromptTokens
        self.truncations = truncations
        self.snapshotTexts = snapshotTexts
    }

    /// The raw session text to file with the Activity event (FR-4.4).
    public var sessionText: String? { SessionDelta.rawSessionText(of: deltas) }
}

/// Builds the user half of an organize request (M2-06).
///
/// ## What goes in
///
/// 1. The session: for each touched note, its full current text and the new
///    material from this session, marked separately.
/// 2. The library: folders (depth ≤ 2) and note titles with their ids —
///    FR-4.6 cannot prefer an existing note the model was never shown.
/// 3. Candidates: a handful of notes that look like merge targets, each with
///    its first ~20 lines, from an injected ``CandidateFinder``.
///
/// Excluded folders (FR-4.5) are gone before any of that: ``OrganizeContext``
/// runs ``ExclusionFilter`` over the snapshot, so an excluded note has no path
/// into the tree, the candidates or the body map — and the excluded folder
/// *names* are never rendered either, because naming a folder tells the
/// provider it exists.
///
/// ## The token budget
///
/// The target is ``tokenBudget`` (default 6 000) estimated input tokens, at a
/// deliberately crude four bytes per token — a stable over-estimate for prose
/// and code, and one that costs nothing to compute. When the render is over
/// budget it is rebuilt with less, in this order:
///
/// 1. **Candidate previews** shrink from 20 lines to 10, then to 5.
/// 2. **Candidates** are dropped from the lowest-ranked up, to a floor of one.
/// 3. **The library note list** collapses to folders plus a count.
/// 4. **Session note bodies** are truncated *around the delta*: the new material
///    is always sent verbatim, because it is the thing being filed and because
///    `moveSegment` requires a byte-exact copy.
///
/// Candidates go first because they are the most speculative part of the
/// prompt: losing one costs a possible merge, while losing session text costs
/// the plan itself.
public struct OrganizeContextBuilder: Sendable {
    public var excludedFolders: [String]
    public var maxCandidates: Int
    public var candidatePreviewLines: Int
    public var tokenBudget: Int
    /// Stamped into the prompt so a recorded request says which prompt made it
    /// (spec §9 prompt versioning).
    public var promptVersion: PromptVersion
    /// Rough tokens per byte of UTF-8. Four is the usual English figure.
    public static let bytesPerToken = 4

    public init(
        excludedFolders: [String] = [],
        maxCandidates: Int = 6,
        candidatePreviewLines: Int = 20,
        tokenBudget: Int = 6_000,
        promptVersion: PromptVersion = .organize
    ) {
        self.excludedFolders = excludedFolders
        self.maxCandidates = maxCandidates
        self.candidatePreviewLines = candidatePreviewLines
        self.tokenBudget = tokenBudget
        self.promptVersion = promptVersion
    }

    public static func estimatedTokens(of text: String) -> Int {
        (text.utf8.count + bytesPerToken - 1) / bytesPerToken
    }

    /// Builds the context for one session.
    ///
    /// - Parameters:
    ///   - deltas: one per touched note, already filtered to the ones with an
    ///     effective change.
    ///   - snapshot: the library *after* the autosave flush.
    ///   - mode: shown to the model only as a framing hint; it never changes
    ///     what the model is allowed to propose.
    public func build(
        sessionID: SessionID,
        endedAt: Date,
        reason: SessionEndReason,
        deltas: [SessionDelta],
        snapshot: LibrarySnapshot,
        mode: OrganizeMode,
        source: any OrganizeLibrarySource,
        candidateFinder: any CandidateFinder
    ) async throws -> OrganizeRequestContext {
        let sessionIDs = Set(deltas.map(\.noteID))
        var bodies: [NoteID: String] = [:]
        for delta in deltas { bodies[delta.noteID] = delta.currentText }

        let context = OrganizeContext(
            snapshot: snapshot,
            excludedFolders: excludedFolders,
            bodies: bodies
        )

        let query = CandidateQuery(
            text: deltas.map(\.addedText).joined(separator: "\n"),
            titles: deltas.map(\.title),
            excluding: sessionIDs,
            limit: maxCandidates
        )
        let ranked = try await candidateFinder.candidates(for: query, in: context)
        // The finder is injected, so belt and braces: nothing outside the
        // filtered context, and never a session note.
        let allowed = ranked.filter { context.note(id: $0.noteID) != nil && !sessionIDs.contains($0.noteID) }

        var previews: [NoteID: [String]] = [:]
        for candidate in allowed {
            guard let body = try await source.body(of: candidate.noteID) else { continue }
            previews[candidate.noteID] = body.components(separatedBy: "\n")
        }
        let candidates = allowed.filter { previews[$0.noteID] != nil }

        var plan = RenderPlan(
            previewLines: candidatePreviewLines,
            candidateCount: candidates.count,
            includeNoteList: true,
            sessionBodyLines: nil
        )
        var truncations: [String] = []
        var text = render(
            plan: plan,
            sessionID: sessionID,
            endedAt: endedAt,
            reason: reason,
            deltas: deltas,
            context: context,
            candidates: candidates,
            previews: previews,
            mode: mode
        )

        for step in RenderPlan.reductionLadder(from: plan) {
            guard Self.estimatedTokens(of: text) > tokenBudget else { break }
            plan = step.plan
            truncations.append(step.label)
            text = render(
                plan: plan,
                sessionID: sessionID,
                endedAt: endedAt,
                reason: reason,
                deltas: deltas,
                context: context,
                candidates: candidates,
                previews: previews,
                mode: mode
            )
        }

        let kept = Array(candidates.prefix(plan.candidateCount)).map(\.noteID)
        return OrganizeRequestContext(
            sessionID: sessionID,
            context: context,
            deltas: deltas,
            promptText: text,
            candidateIDs: kept,
            estimatedPromptTokens: Self.estimatedTokens(of: text),
            truncations: truncations,
            snapshotTexts: bodies
        )
    }

    // MARK: - Rendering

    /// The knobs the budget ladder turns.
    struct RenderPlan: Sendable, Hashable {
        var previewLines: Int
        var candidateCount: Int
        var includeNoteList: Bool
        /// `nil` = whole body; otherwise the number of lines kept around the
        /// delta.
        var sessionBodyLines: Int?

        struct Step: Sendable {
            var plan: RenderPlan
            var label: String
        }

        /// Ordered reductions, cheapest loss first.
        static func reductionLadder(from start: RenderPlan) -> [Step] {
            var steps: [Step] = []
            var plan = start
            for lines in [10, 5] where plan.previewLines > lines {
                plan.previewLines = lines
                steps.append(Step(plan: plan, label: "candidate previews trimmed to \(lines) lines"))
            }
            while plan.candidateCount > 1 {
                plan.candidateCount -= 1
                steps.append(Step(plan: plan, label: "dropped the lowest-ranked candidate"))
            }
            if plan.candidateCount > 0 {
                plan.candidateCount = 0
                steps.append(Step(plan: plan, label: "dropped all candidates"))
            }
            if plan.includeNoteList {
                plan.includeNoteList = false
                steps.append(Step(plan: plan, label: "library note titles collapsed to folders"))
            }
            for lines in [200, 80, 30] {
                plan.sessionBodyLines = lines
                steps.append(Step(plan: plan, label: "session note bodies truncated to \(lines) lines"))
            }
            return steps
        }
    }

    func render(
        plan: RenderPlan,
        sessionID: SessionID,
        endedAt: Date,
        reason: SessionEndReason,
        deltas: [SessionDelta],
        context: OrganizeContext,
        candidates: [OrganizeCandidate],
        previews: [NoteID: [String]],
        mode: OrganizeMode
    ) -> String {
        var out: [String] = []

        out.append("# Session")
        out.append("Prompt: \(promptVersion)")
        out.append("Ended: \(ISO8601.string(from: endedAt)) (\(reason.rawValue))")
        out.append("Mode: \(mode.rawValue)")
        out.append("Notes written in this session: \(deltas.count)")
        out.append("")

        for delta in deltas {
            out.append("## Session note: \(delta.title)")
            out.append("id: \(delta.noteID.uuidString)")
            out.append("path: \(delta.relativePath)")
            out.append("status: \(delta.isNewNote ? "new — never filed" : "already filed, added to in this session")")
            if delta.isUntitled { out.append("untitled: yes — needs a title") }
            out.append("")
            out.append("New in this session:")
            out.append(fence(delta.addedText))
            if delta.addedText != delta.currentText {
                out.append("Whole note as it stands now:")
                out.append(fence(body(of: delta, lines: plan.sessionBodyLines)))
            }
            out.append("")
        }

        out.append("# Library")
        let folders = context.folderPaths.filter { PathRules.depth(ofFolder: $0) <= PathRules.maxFolderDepth }
        out.append(folders.isEmpty ? "Folders: none yet (the library is flat)" : "Folders:")
        for folder in folders.sorted() { out.append("- \(folder)") }
        if plan.includeNoteList {
            out.append("Notes:")
            for note in context.notes.sorted(by: { $0.relativePath < $1.relativePath }) {
                let tags = note.tags.isEmpty ? "" : " tags=\(note.tags.joined(separator: ","))"
                out.append("- \(note.relativePath) (id=\(note.id.uuidString))\(tags)")
            }
        } else {
            out.append("Notes: \(context.notes.count) (list omitted to fit the request budget)")
        }
        out.append("")

        let shown = Array(candidates.prefix(plan.candidateCount))
        if !shown.isEmpty {
            out.append("# Candidate notes for merging")
            out.append("These already exist and may be where the new material belongs.")
            out.append("")
            for candidate in shown {
                guard let note = context.note(id: candidate.noteID) else { continue }
                out.append("## Candidate: \(note.relativePath)")
                out.append("id: \(note.id.uuidString)")
                let lines = previews[candidate.noteID] ?? []
                let head = lines.prefix(plan.previewLines)
                out.append("First \(head.count) lines:")
                out.append(fence(head.joined(separator: "\n")))
                if lines.count > head.count { out.append("(\(lines.count - head.count) more lines not shown)") }
                out.append("")
            }
        }

        out.append("# Your task")
        out.append("""
        File the new material from this session. Call `organization_plan` once. \
        Prefer the folders and notes above over new ones; maximum folder depth is \
        \(PathRules.maxFolderDepth). If nothing needs filing, return an empty action list.
        """)

        return out.joined(separator: "\n")
    }

    private func body(of delta: SessionDelta, lines limit: Int?) -> String {
        guard let limit else { return delta.currentText }
        let lines = delta.currentText.components(separatedBy: "\n")
        guard lines.count > limit else { return delta.currentText }
        // Keep the tail: a writing session almost always appends, and the delta
        // itself is rendered verbatim above regardless.
        let kept = lines.suffix(limit)
        return "…(\(lines.count - kept.count) earlier lines omitted)…\n" + kept.joined(separator: "\n")
    }

    /// Wraps text in a fence the model will not confuse with the note's own
    /// Markdown.
    private func fence(_ text: String) -> String {
        "<<<\n\(text)\n>>>"
    }
}
