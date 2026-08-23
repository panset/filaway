import Foundation

/// Builds the M3-07 development corpus: ~62 hand-curated "golden" notes that
/// the query set points at, plus deterministic distractors that share their
/// vocabulary without answering anything.
///
/// ```
/// filaway-bench corpus generate --seed 20260823
/// ```
///
/// The distractors are the interesting half of the design. A corpus of nothing
/// but answers measures nothing: every query has one plausible target and even
/// a bag-of-words baseline scores 100%. So the distractors talk *about* curl,
/// rebasing, pods and certificates — in meetings, reading notes, half-finished
/// ideas — and carry bland commands (`make build`, `git status`) that no query
/// asks for. Retrieval has to separate "the note that mentions the topic" from
/// "the note that contains the command".
public enum DevCorpusGenerator {
    /// The instant the committed corpus and query set are written against.
    ///
    /// Thursday 20 August 2026, 12:00 UTC. Midday so that a ±8 h time-zone
    /// difference between this machine and a CI runner cannot move a note onto
    /// a different calendar day, which would silently change what "yesterday"
    /// means (FR-5.3).
    public static let referenceNow = Date(timeIntervalSince1970: 1_787_227_200)

    public static let defaultSeed: UInt64 = 2_026_08_23

    /// Golden notes plus `distractors` filler, sorted by path.
    public static func generate(
        seed: UInt64 = defaultSeed,
        distractors: Int = 240,
        now: Date = referenceNow
    ) -> [CorpusNote] {
        var notes = DevCorpusContent.golden.map { golden in
            CorpusNote(
                relativePath: golden.relativePath,
                created: now.addingTimeInterval(-Double(golden.day) * 86_400 - 3_600),
                modified: now.addingTimeInterval(-Double(golden.day) * 86_400),
                tags: golden.tags,
                isGolden: true,
                body: golden.body
            )
        }
        var random = SplitMix64(seed: seed)
        var used = Set(notes.map(\.relativePath))
        var index = 0
        while notes.count - DevCorpusContent.golden.count < distractors {
            index += 1
            let note = distractor(index: index, random: &random, now: now)
            guard !used.contains(note.relativePath) else { continue }
            used.insert(note.relativePath)
            notes.append(note)
        }
        return notes.sorted { $0.relativePath < $1.relativePath }
    }

    // MARK: - Distractors

    private static func distractor(
        index: Int, random: inout SplitMix64, now: Date
    ) -> CorpusNote {
        let folder = pick(distractorFolders, &random)
        let topic = pick(topics, &random)
        let title = pick(titleTemplates, &random)
            .replacingOccurrences(of: "{topic}", with: topic)
            .replacingOccurrences(of: "{n}", with: String(index))
        let path = PathRules.relativePath(folder: folder, title: PathRules.sanitizeTitle(title))

        var body = "# \(title)\n\n"
        let blocks = 3 + Int(random.next() % 4)
        for block in 0 ..< blocks {
            switch random.next() % 10 {
            case 0 where block > 0:
                body += "## \(pick(sectionHeadings, &random))\n\n"
                body += sentence(topic: topic, &random) + "\n\n"
            case 1 where block > 0:
                body += "```sh\n\(pick(blandCommands, &random))\n```\n\n"
            case 2 where block > 0:
                body += "- [ ] \(pick(actionItems, &random).replacingOccurrences(of: "{topic}", with: topic))\n"
                body += "- [ ] \(pick(actionItems, &random).replacingOccurrences(of: "{topic}", with: topic))\n\n"
            default:
                var first = sentence(topic: topic, &random)
                var second = sentence(topic: topic, &random)
                // Two draws from an eighteen-sentence pool collide often, and
                // a paragraph that says the same thing twice reads as broken
                // rather than as filler.
                var attempts = 0
                while second == first, attempts < 4 {
                    second = sentence(topic: topic, &random)
                    attempts += 1
                }
                if second == first { first = "" }
                body += (first.isEmpty ? "" : first + " ") + second + "\n\n"
            }
        }

        // 1–170 days back, so distractors populate every date range a temporal
        // query can name and a hard filter never leaves the golden note alone
        // in its window.
        let day = 1 + Int(random.next() % 170)
        let modified = now.addingTimeInterval(-Double(day) * 86_400 - Double(random.next() % 7_200))
        return CorpusNote(
            relativePath: path,
            created: modified.addingTimeInterval(-Double(random.next() % 20) * 86_400),
            modified: modified,
            tags: random.next() % 3 == 0 ? [tag(for: topic)] : [],
            isGolden: false,
            body: body
        )
    }

    /// `"the deploy pipeline"` -> `"deploy-pipeline"`; a tag with an article
    /// and spaces in it is not something anyone would have typed.
    private static func tag(for topic: String) -> String {
        topic.replacingOccurrences(of: "the ", with: "")
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
    }

    private static func sentence(topic: String, _ random: inout SplitMix64) -> String {
        pick(sentences, &random)
            .replacingOccurrences(of: "{topic}", with: topic)
            .replacingOccurrences(of: "{Topic}", with: topic.prefix(1).uppercased() + topic.dropFirst())
    }

    private static func pick(_ pool: [String], _ random: inout SplitMix64) -> String {
        pool[Int(random.next() % UInt64(pool.count))]
    }

    // MARK: - Vocabulary

    private static let distractorFolders = [
        "", "", "Reading", "Ideas", "Journal", "Projects/filaway", "Projects/website",
        "Meetings/2026-05", "Meetings/2026-06", "Meetings/2026-07", "Meetings/2026-08",
        "Commands/curl", "Commands/git", "Commands/docker", "Commands/k8s", "Commands/shell",
        "Snippets/toolchain", "Snippets/data", "Snippets/media", "Snippets/system",
        "Debugging/network", "Debugging/build", "Debugging/database", "Infra/ssh", "Infra/certs",
    ]

    private static let topics = [
        "staging", "the gateway", "the indexer", "the search panel", "the deploy pipeline",
        "the vector store", "the token budget", "the container image", "the release branch",
        "the certificate rotation", "the log pipeline", "the onboarding guide", "the chunker",
        "the answer card", "the sidebar", "the autosave loop", "the api client", "the cluster",
    ]

    private static let titleTemplates = [
        "Notes on {topic}", "{topic} — open questions", "Thinking about {topic}",
        "Weekly review {n}", "Reading: {topic}", "Idea: a better {topic}",
        "Standup {n}", "Scratch {n}", "Follow-ups on {topic}", "Untitled {n}",
        "Retro: {topic}", "Draft — {topic} rewrite", "Questions for the platform team {n}",
    ]

    private static let sectionHeadings = [
        "Open questions", "What I tried", "Next", "Background", "Decisions", "Leftovers",
    ]

    private static let actionItems = [
        "ask the platform team about {topic}",
        "write up what changed in {topic}",
        "check whether {topic} still needs the workaround",
        "book time to look at {topic} properly",
        "reply to the thread about {topic}",
    ]

    /// Deliberately boring. These share vocabulary with the golden notes — the
    /// same tools, the same nouns — without being an answer to any query.
    private static let blandCommands = [
        "make build",
        "swift test --parallel",
        "git status --short",
        "docker compose ps",
        "kubectl get deploy -n prod",
        "npm run lint",
        "make smoke",
        "open build/Filaway.app",
        "curl -sS https://example.com/health",
        "ls -la ~/Notes",
        "brew update",
        "tail -n 50 build.log",
    ]

    private static let sentences = [
        "{Topic} came up again and nobody could remember what we decided last time.",
        "The tricky part with {topic} is that it only misbehaves when the machine is loaded.",
        "I keep meaning to write down how {topic} is actually wired, and keep not doing it.",
        "Someone asked about {topic} in the channel and the answer was longer than it should be.",
        "The docs for {topic} describe the version before last, which cost me an hour.",
        "Reading back through this, most of the confusion around {topic} is naming.",
        "We agreed to revisit {topic} once the migration is finished, so probably never.",
        "There is a curl invocation somewhere in my history that would settle this about {topic}.",
        "The staging environment lies about {topic}, so measure on the real cluster.",
        "Every time the token expires I go looking for the same thing about {topic}.",
        "Rebasing this branch was fine; it is {topic} that made the review painful.",
        "The container starts, the pod is ready, and {topic} is still wrong.",
        "Certificates, tokens and clock skew: three explanations for the same symptom in {topic}.",
        "I want a note that just holds the command, not an essay about {topic}.",
        "Logs from the deploy are useless here — nothing about {topic} is written out at all.",
        "Half of this is going to be wrong in a month, like everything about {topic}.",
        "Worth benchmarking before touching {topic}; the last guess was off by an order of magnitude.",
        "The thing I actually needed was two directories up, filed under {topic}.",
    ]
}
