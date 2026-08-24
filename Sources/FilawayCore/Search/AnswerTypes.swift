import Foundation

/// Where an answer card came from (FR-5.2, FR-5.5).
///
/// The distinction is user-visible: a card the model picked and a card the
/// offline heuristic picked are drawn the same way, but only one of them
/// requires a working provider, and the panel has to be able to say so.
public enum AnswerSource: String, Sendable, Hashable, Codable, CaseIterable {
    /// `answer.v1` picked the chunk and trimmed the snippet — whichever model
    /// served it (Claude or a local Ollama model, P2-03). The card's tint means
    /// "a model answered", not "Anthropic answered".
    case model
    /// The provider was unreachable, slow, disabled or unconfigured, and the
    /// local heuristic answered instead.
    case localHeuristic
    /// Nothing was good enough to show a card. The ranked list still stands.
    case none
}

/// How sure the answer is. Reported by the model; synthesised by the heuristic.
public enum AnswerConfidence: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: AnswerConfidence, rhs: AnswerConfidence) -> Bool { lhs.rank < rhs.rank }
}

/// Why semantic *answers* are not available, when they are not (FR-5.5, FR-6.4).
///
/// Retrieval itself never becomes unavailable — the hybrid index is local — so
/// this only ever describes the Claude step. The panel turns it into one line.
public enum SemanticUnavailable: String, Sendable, Hashable, Codable, CaseIterable {
    /// Settings → AI → Semantic search is off.
    case semanticSearchDisabled
    /// No API key has been connected yet.
    case notConfigured
    /// No provider was built at all (no embedder, no fixtures, replay with
    /// nothing to replay).
    case noProvider
    /// The network refused, or the machine is offline.
    case network
    /// 429, still inside its retry window.
    case rateLimited
    /// The call did not finish inside the answer budget (NFR-1's 5 s).
    case timedOut
    /// Anything else the provider reported — including a refusal.
    case providerError

    /// The one-line notice the ⌘K panel shows above the local list.
    ///
    /// `notConfigured` is the only one that is actionable, so it is the only
    /// one phrased as an instruction (FR-6.4: clear, non-nagging).
    public var notice: String {
        switch self {
        case .notConfigured, .noProvider:
            "Connect your AI in Settings to get answers"
        case .semanticSearchDisabled:
            "Semantic answers are off — showing local matches"
        case .network, .timedOut, .rateLimited, .providerError:
            "Semantic answers unavailable offline — showing local matches"
        }
    }
}

/// Whether the Claude answer step could run for this search.
public enum SemanticAvailability: Sendable, Hashable, Codable {
    case online
    case offline(SemanticUnavailable)

    public var isOnline: Bool { self == .online }

    public var reason: SemanticUnavailable? {
        guard case let .offline(reason) = self else { return nil }
        return reason
    }

    /// `nil` when online — there is nothing to say.
    public var notice: String? { reason?.notice }
}

/// Figure 2b's best-match answer card (FR-5.2).
///
/// Everything the card draws is here, including ``chunkRange`` — the UTF-16
/// range of the chunk in the note body, in the same coordinates as
/// `KeywordHit.matchRange`, so clicking the card opens the note scrolled to the
/// section the answer came from.
public struct AnswerCard: Sendable, Hashable, Identifiable {
    public let noteID: NoteID
    public let title: String
    public let relativePath: String
    public let modified: Date
    /// The chunk row this came from (`RankedChunk.id`).
    public let chunkID: Int64
    /// Where the chunk sits in the note body (FR-5.2 scroll-to).
    public let chunkRange: MatchRange
    /// What Copy puts on the pasteboard — the command or snippet alone.
    public let snippetText: String
    /// Fence info string, when the chunk was fenced code.
    public let language: String?
    /// `true` → draw it as a monospaced code block.
    public let isCode: Bool
    /// Heading trail inside the note, title first.
    public let headingPath: [String]

    public var id: Int64 { chunkID }

    public init(
        noteID: NoteID,
        title: String,
        relativePath: String,
        modified: Date,
        chunkID: Int64,
        chunkRange: MatchRange,
        snippetText: String,
        language: String?,
        isCode: Bool,
        headingPath: [String] = []
    ) {
        self.noteID = noteID
        self.title = title
        self.relativePath = relativePath
        self.modified = modified
        self.chunkID = chunkID
        self.chunkRange = chunkRange
        self.snippetText = snippetText
        self.language = language
        self.isCode = isCode
        self.headingPath = headingPath
    }

    /// `Commands / curl` — Figure 2b's "Best match · **Commands / curl** ·
    /// edited 2d ago".
    public var sourceLabel: String {
        let folder = PathRules.folderPath(of: relativePath)
        guard !folder.isEmpty else { return title }
        return folder.replacingOccurrences(of: "/", with: " / ") + " / " + title
    }
}

/// What ``AnswerExtractor/extract(query:results:now:)`` returns (M3-05).
///
/// A result is always produced: the card may be `nil` ("No good match"), but
/// ``rankedNotes`` is whatever retrieval found, so the panel has something to
/// draw whether or not Claude was reachable.
public struct AnswerResult: Sendable, Equatable {
    public let card: AnswerCard?
    /// The note list, re-ordered by the model when it ranked, otherwise as
    /// retrieval left it.
    public let rankedNotes: [RankedNote]
    public let source: AnswerSource
    public let confidence: AnswerConfidence
    /// Wall-clock cost of the answer step alone.
    public let latency: TimeInterval
    /// Set when the Claude step did not run or did not survive — drives the
    /// FR-5.5 notice.
    public let unavailable: SemanticUnavailable?
    /// The prompt that produced a `.model` answer (spec §9 versioning).
    public let promptVersion: PromptVersion?
    public let model: AIModel?

    public init(
        card: AnswerCard?,
        rankedNotes: [RankedNote],
        source: AnswerSource,
        confidence: AnswerConfidence = .low,
        latency: TimeInterval = 0,
        unavailable: SemanticUnavailable? = nil,
        promptVersion: PromptVersion? = nil,
        model: AIModel? = nil
    ) {
        self.card = card
        self.rankedNotes = rankedNotes
        self.source = source
        self.confidence = confidence
        self.latency = latency
        self.unavailable = unavailable
        self.promptVersion = promptVersion
        self.model = model
    }

    public static func empty(_ source: AnswerSource = .none) -> AnswerResult {
        AnswerResult(card: nil, rankedNotes: [], source: source)
    }

    public var hasCard: Bool { card != nil }
}
