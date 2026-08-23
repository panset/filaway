import Foundation

/// Deterministic corpus generator for benchmarks and scale tests (NFR-2).
///
/// Lives in `FilawayCore` rather than the bench target so `swift test` can use
/// it too. It writes files directly instead of going through ``NoteStore``: the
/// point is to produce a realistic tree quickly, not to exercise the write path.
///
/// M1-07 extends this with the richer keyword/retrieval corpora; the shape here
/// is deliberately the one the search work will build on — headings, prose, and
/// fenced shell/code blocks, since those are what FR-5.2 answers with.
public enum SyntheticCorpus {
    /// Generates `noteCount` notes under `library.root`.
    ///
    /// - Parameters:
    ///   - noteCount: how many `.md` files to write.
    ///   - folderCount: top-level folders; every third one also gets a subfolder,
    ///     so the tree exercises both allowed depths.
    ///   - approximateBytes: rough size of each note's body. NFR-2's "5,000 notes
    ///     / 50 MB" corresponds to about 10,000.
    ///   - frontMatterFraction: share of notes written with an `id`, as if
    ///     Filaway had already saved them.
    ///   - seed: fixed seed keeps runs comparable.
    /// - Returns: the relative paths written, in creation order.
    @discardableResult
    public static func generate(
        noteCount: Int,
        into library: Library,
        folderCount: Int = 12,
        approximateBytes: Int = 2_048,
        frontMatterFraction: Double = 0.7,
        seed: UInt64 = 0x5EED_1234_ABCD_0001,
        fileManager: FileManager = .default
    ) throws -> [String] {
        var random = SplitMix64(seed: seed)
        try fileManager.createDirectory(at: library.root, withIntermediateDirectories: true)

        var folders: [String] = [""]
        for index in 0 ..< folderCount {
            let top = topics[index % topics.count] + (index >= topics.count ? " \(index / topics.count + 1)" : "")
            folders.append(top)
            if index % 3 == 0 { folders.append("\(top)/\(subtopics[index % subtopics.count])") }
        }
        for folder in folders where !folder.isEmpty {
            try fileManager.createDirectory(at: library.url(for: folder), withIntermediateDirectories: true)
        }

        var written: [String] = []
        written.reserveCapacity(noteCount)
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0 ..< noteCount {
            let folder = folders[Int(random.next() % UInt64(folders.count))]
            let title = "\(verbs[Int(random.next() % UInt64(verbs.count))]) \(nouns[Int(random.next() % UInt64(nouns.count))]) \(index)"
            let path = PathRules.relativePath(folder: folder, title: PathRules.sanitizeTitle(title))
            var text = ""
            if Double(random.next() % 1000) / 1000.0 < frontMatterFraction {
                var frontMatter = FrontMatter()
                frontMatter.id = NoteID()
                frontMatter.created = start.addingTimeInterval(Double(index) * 137)
                if index % 4 == 0 { frontMatter.tags = [topics[index % topics.count].lowercased()] }
                text += frontMatter.serialized()
            }
            text += body(title: title, targetBytes: approximateBytes, random: &random)
            try Data(text.utf8).write(to: library.url(for: path))
            written.append(path)
        }
        return written
    }

    private static func body(title: String, targetBytes: Int, random: inout SplitMix64) -> String {
        var text = "# \(title)\n\n"
        while text.utf8.count < targetBytes {
            switch random.next() % 5 {
            case 0:
                text += "## \(nouns[Int(random.next() % UInt64(nouns.count))].capitalized)\n\n"
            case 1:
                text += "```sh\n\(commands[Int(random.next() % UInt64(commands.count))])\n```\n\n"
            case 2:
                text += "- [ ] \(verbs[Int(random.next() % UInt64(verbs.count))]) the \(nouns[Int(random.next() % UInt64(nouns.count))])\n"
            default:
                text += sentences[Int(random.next() % UInt64(sentences.count))] + "\n\n"
            }
        }
        return text
    }

    private static let topics = [
        "Commands", "Meetings", "Ideas", "Reading", "Projects", "Snippets",
        "Debugging", "Infra", "Design", "Research", "Journal", "Recipes",
    ]
    private static let subtopics = ["Docker", "Postgres", "Swift", "Networking", "Weekly", "Archive"]
    private static let verbs = ["fetch", "retry", "cache", "profile", "migrate", "sketch", "review", "trim", "index"]
    private static let nouns = ["documents", "tokens", "queries", "sessions", "vectors", "layouts", "budgets", "digests"]
    private static let commands = [
        "curl -sS -H 'Accept: application/json' https://example.com/api/documents | jq '.items[]'",
        "docker compose up -d --build && docker compose logs -f app",
        "psql -h localhost -U filaway -c 'select count(*) from notes;'",
        "swift build -c release && swift test --parallel",
        "rsync -avh --delete ./build/ deploy@host:/srv/app/",
    ]
    private static let sentences = [
        "The tricky part is that the token budget is shared across the whole session.",
        "Remember to check the retry policy before blaming the network.",
        "This only reproduces when the cache is cold and the index is stale.",
        "Ranking improved once recency stopped dominating the score.",
        "Keep the fallback path offline-safe; the answer card can degrade.",
    ]
}

/// Small, fast, deterministic PRNG. Not for anything security-related.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
