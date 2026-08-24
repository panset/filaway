import Foundation
import Testing

@testable import FilawayCore

/// A `URLProtocol` that answers from a closure instead of the network.
///
/// This is what makes M2-01 testable on a machine with no API key: every branch
/// of the error taxonomy (401, 429 + `retry-after`, 529, a `URLError`, a body
/// that is not JSON) is a scripted response, and the requests the provider
/// actually sent are recorded for assertions on headers and body.
final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var body: Data

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        static func json(_ value: JSONValue, status: Int = 200, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers, body: (try? value.canonicalData()) ?? Data())
        }
    }

    enum Outcome {
        case reply(Reply)
        case failure(URLError)
    }

    /// One recorded request, with its body already read out of the stream —
    /// `URLProtocol` hands the body over as a stream, never as `httpBody`.
    struct Recorded {
        var url: URL?
        /// Header names are lower-cased: URLSession normalises their case on the
        /// way out, and HTTP header names are case-insensitive anyway.
        var method: String?
        var headers: [String: String]
        var body: Data?

        var json: JSONValue? {
            guard let body, !body.isEmpty else { return nil }
            return try? JSONValue.parse(body)
        }
    }

    /// Handlers and their recorded traffic, **keyed by host**.
    ///
    /// Suites run in parallel with one another, and `URLProtocol` state is
    /// necessarily global, so two provider suites sharing one handler would
    /// interleave and flake. A handler installed for a host serves and records
    /// only that host; the unkeyed handler serves everything else. That is what
    /// lets the Claude suite (`api.anthropic.com`) and the Ollama suite
    /// (`localhost`) run at the same time without seeing each other's requests.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: @Sendable (Recorded) -> Outcome] = [:]
        private var recorded: [String: [Recorded]] = [:]

        private static func key(_ host: String?) -> String { host?.lowercased() ?? "" }

        func install(host: String?, _ handler: @escaping @Sendable (Recorded) -> Outcome) {
            lock.lock()
            defer { lock.unlock() }
            handlers[Self.key(host)] = handler
            recorded[Self.key(host)] = []
        }

        func reset(host: String?) {
            lock.lock()
            defer { lock.unlock() }
            handlers[Self.key(host)] = nil
            recorded[Self.key(host)] = []
        }

        func handle(_ request: Recorded) -> Outcome {
            lock.lock()
            let host = Self.key(request.url?.host)
            let key = handlers[host] != nil ? host : ""
            let handler = handlers[key]
            recorded[key, default: []].append(request)
            lock.unlock()
            guard let handler else {
                return .reply(Reply(status: 500, body: Data(#"{"error":{"message":"no stub installed"}}"#.utf8)))
            }
            return handler(request)
        }

        func requests(host: String?) -> [Recorded] {
            lock.lock()
            defer { lock.unlock() }
            return recorded[Self.key(host)] ?? []
        }
    }

    private static let state = State()

    /// Installs a handler and clears the recorded requests.
    ///
    /// - Parameter host: when given, the handler serves and records only that
    ///   host, leaving any other suite's stub alone.
    static func install(host: String? = nil, _ handler: @escaping @Sendable (Recorded) -> Outcome) {
        state.install(host: host, handler)
    }

    /// Answers every request with the same outcome.
    static func always(host: String? = nil, _ outcome: Outcome) {
        install(host: host) { _ in outcome }
    }

    /// Answers with each outcome in turn, repeating the last one.
    static func sequence(host: String? = nil, _ outcomes: [Outcome]) {
        let box = Counter()
        install(host: host) { _ in
            let index = box.next()
            return outcomes[min(index, outcomes.count - 1)]
        }
    }

    static func reset(host: String? = nil) { state.reset(host: host) }
    static func requests(host: String?) -> [Recorded] { state.requests(host: host) }
    static var requests: [Recorded] { state.requests(host: nil) }

    /// A session configuration wired to this protocol.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = value
            value += 1
            return current
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(
            url: request.url,
            method: request.httpMethod,
            headers: Dictionary(
                (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) },
                uniquingKeysWith: { _, latest in latest }
            ),
            body: request.httpBody ?? StubURLProtocol.readBody(from: request)
        )

        switch StubURLProtocol.state.handle(recorded) {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .reply(reply):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.anthropic.com")!,
                statusCode: reply.status,
                httpVersion: "HTTP/1.1",
                headerFields: reply.headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// A clock that never actually sleeps, so backoff tests run in microseconds and
/// the delays they would have waited are assertable.
final class TestClock: AIClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: Date
    private var sleeps: [TimeInterval] = []
    private let fraction: Double

    init(now: Date = Date(timeIntervalSince1970: 1_756_000_000), randomFraction: Double = 0.5) {
        currentTime = now
        fraction = randomFraction
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    func sleep(for duration: TimeInterval) async throws {
        record(duration)
    }

    private func record(_ duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        sleeps.append(duration)
        currentTime = currentTime.addingTimeInterval(duration)
    }

    func randomFraction() -> Double { fraction }

    var recordedSleeps: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }
}

enum AITestPaths {
    /// `Tests/Fixtures/ai-recordings`, resolved from this file's location so the
    /// suite does not care about the working directory.
    static var fixtures: URL {
        URL(fileURLWithPath: #filePath)          // …/Tests/FilawayCoreTests/AITestSupport.swift
            .deletingLastPathComponent()          // …/Tests/FilawayCoreTests
            .deletingLastPathComponent()          // …/Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("ai-recordings", isDirectory: true)
    }

    static var recordingStore: AIRecordingStore { AIRecordingStore(directory: fixtures) }

    /// Bundled prompt resources, for tests that want the source files rather
    /// than the copied bundle.
    static var prompts: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/FilawayCore/AI/Prompts", isDirectory: true)
    }
}

// MARK: - Sample library

/// A small, fixed library used by the plan and validator suites.
enum SampleLibrary {
    static let scratchID = NoteID(UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
    static let curlID = NoteID(UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
    static let privateID = NoteID(UUID(uuidString: "33333333-3333-4333-8333-333333333333")!)
    static let untitledID = NoteID(UUID(uuidString: "44444444-4444-4444-8444-444444444444")!)

    static let scratchBody = """
    Random thoughts from today.

    ```sh
    curl -sS -H "Accept: application/json" https://example.test/documents
    ```

    Remember to write this up properly.
    """

    static let segment = """
    ```sh
    curl -sS -H "Accept: application/json" https://example.test/documents
    ```
    """

    static let curlBody = "# curl\n\nHandy invocations.\n"
    static let privateBody = "Salary review notes: the number is 12345.\n"

    static func note(
        id: NoteID,
        path: String,
        tags: [String] = [],
        body: String
    ) -> NoteSummary {
        NoteSummary(
            id: id,
            relativePath: path,
            title: PathRules.title(of: path),
            folderPath: PathRules.folderPath(of: path),
            tags: tags,
            created: Date(timeIntervalSince1970: 1_750_000_000),
            modified: Date(timeIntervalSince1970: 1_755_000_000),
            size: body.utf8.count,
            contentHash: Hashing.sha256Hex(body)
        )
    }

    static var notes: [NoteSummary] {
        [
            note(id: scratchID, path: "Scratch.md", body: scratchBody),
            note(id: curlID, path: "Commands/curl.md", tags: ["shell"], body: curlBody),
            note(id: privateID, path: "Private/Salary.md", body: privateBody),
            note(id: untitledID, path: "Untitled note.md", body: "todo\n"),
        ]
    }

    static var folderPaths: [String] { ["Commands", "Private"] }

    static var bodies: [NoteID: String] {
        [
            scratchID: scratchBody,
            curlID: curlBody,
            privateID: privateBody,
            untitledID: "todo\n",
        ]
    }

    static var snapshot: LibrarySnapshot {
        LibrarySnapshot(notes: notes, folderPaths: folderPaths, scannedAt: Date(timeIntervalSince1970: 1_756_000_000))
    }

    /// The context the organizer would build: `Private` excluded (FR-4.5).
    static var context: OrganizeContext {
        OrganizeContext(snapshot: snapshot, excludedFolders: ["Private"], bodies: bodies)
    }

    /// A context with nothing excluded.
    static var openContext: OrganizeContext {
        OrganizeContext(snapshot: snapshot, bodies: bodies)
    }

    static func precondition(for id: NoteID) -> String {
        notes.first { $0.id == id }?.contentHash ?? ""
    }
}
