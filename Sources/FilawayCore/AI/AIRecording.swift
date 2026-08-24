import Foundation

/// How the AI layer is wired for this process (M2-02).
///
/// `FILAWAY_AI_MODE` selects it. **`replay` is the default**, so a plain
/// `swift test` — and every CI run — never touches the network and never needs
/// a key; `record` and `live` are opt-in and need `ANTHROPIC_API_KEY`.
public enum AIMode: String, Sendable, CaseIterable {
    /// Serve responses from `Tests/Fixtures/ai-recordings`. Missing fixture =
    /// a test failure naming the file to record.
    case replay
    /// Call the real API and write the exchange to a fixture.
    case record
    /// Call the real API and record nothing.
    case live

    public static let environmentVariable = "FILAWAY_AI_MODE"

    /// The mode named by `FILAWAY_AI_MODE`, defaulting to ``replay``.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIMode {
        guard let raw = environment[environmentVariable]?.lowercased(), let mode = AIMode(rawValue: raw) else {
            return .replay
        }
        return mode
    }

    /// `true` when the mode reaches the network.
    public var isLive: Bool { self != .replay }
}

/// One recorded exchange.
///
/// The fixture keeps **three** things: the decoded ``AIRequest`` (easy to read
/// and diff), the exact wire request body (what was actually sent — this is
/// what the FR-4.5 exclusion assertion inspects), and the exact wire response
/// body (so a hand-authored fixture exercises the same decoder a live response
/// would).
public struct AIRecording: Sendable, Hashable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var purpose: AIPurpose
    /// ``AIRequest/fixtureKey`` — also the filename stem.
    public var key: String
    public var model: String
    public var recordedAt: Date?
    /// Free-text note for hand-authored fixtures ("organize: invalid plan").
    public var note: String?
    public var request: AIRequest
    public var requestBody: JSONValue
    public var responseBody: JSONValue

    public init(
        version: Int = AIRecording.currentVersion,
        purpose: AIPurpose,
        key: String,
        model: String,
        recordedAt: Date? = nil,
        note: String? = nil,
        request: AIRequest,
        requestBody: JSONValue,
        responseBody: JSONValue
    ) {
        self.version = version
        self.purpose = purpose
        self.key = key
        self.model = model
        self.recordedAt = recordedAt
        self.note = note
        self.request = request
        self.requestBody = requestBody
        self.responseBody = responseBody
    }

    /// Builds a recording from a live exchange.
    public init(request: AIRequest, response: AIResponse, recordedAt: Date = Date(), note: String? = nil) {
        self.init(
            purpose: request.purpose,
            key: request.fixtureKey,
            model: request.model.id,
            recordedAt: recordedAt,
            note: note,
            request: request,
            requestBody: ClaudeWire.body(for: request),
            responseBody: ClaudeWire.value(for: response)
        )
    }

    /// Decodes the stored wire response — the same path a live call takes.
    public func response() throws -> AIResponse {
        try ClaudeWire.response(from: responseBody)
    }
}

/// The fixture directory: `<root>/<purpose>/<key>.json`.
public struct AIRecordingStore: Sendable {
    public let directory: URL
    private var fileManager: FileManager { .default }

    public init(directory: URL) {
        self.directory = directory
    }

    /// `FILAWAY_AI_FIXTURES`, when set.
    ///
    /// Tests pass the directory explicitly (derived from `#filePath`) so the
    /// suite works from any working directory; the environment variable exists
    /// for `filaway-bench` and one-off recording runs.
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AIRecordingStore? {
        guard let path = environment["FILAWAY_AI_FIXTURES"], !path.isEmpty else { return nil }
        return AIRecordingStore(directory: URL(fileURLWithPath: path, isDirectory: true))
    }

    public func url(purpose: AIPurpose, key: String) -> URL {
        directory
            .appendingPathComponent(purpose.rawValue, isDirectory: true)
            .appendingPathComponent("\(key).json", isDirectory: false)
    }

    public func url(for request: AIRequest) -> URL {
        url(purpose: request.purpose, key: request.fixtureKey)
    }

    /// Loads a fixture, or `nil` when the file does not exist.
    public func load(purpose: AIPurpose, key: String) throws -> AIRecording? {
        let url = url(purpose: purpose, key: key)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "bad date \(raw)"
                )
            }
            return date
        }
        return try decoder.decode(AIRecording.self, from: data)
    }

    public func load(for request: AIRequest) throws -> AIRecording? {
        try load(purpose: request.purpose, key: request.fixtureKey)
    }

    /// Writes a fixture, pretty-printed with sorted keys so a re-record shows a
    /// meaningful diff rather than a reshuffle.
    @discardableResult
    public func save(_ recording: AIRecording) throws -> URL {
        let url = url(purpose: recording.purpose, key: recording.key)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.string(from: date))
        }
        try encoder.encode(recording).write(to: url, options: .atomic)
        return url
    }

    /// Every fixture on disk, sorted by path — used by the fixture-integrity
    /// tests.
    public func all() throws -> [AIRecording] {
        var out: [AIRecording] = []
        for purpose in AIPurpose.allCases {
            let folder = directory.appendingPathComponent(purpose.rawValue, isDirectory: true)
            let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") {
                let key = String(name.dropLast(".json".count))
                if let recording = try load(purpose: purpose, key: key) { out.append(recording) }
            }
        }
        return out
    }
}
