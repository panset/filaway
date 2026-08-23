import Foundation

/// The provider abstraction of NFR-5 / FR-6.5.
///
/// Everything above this protocol — the organizer, search answer extraction,
/// Settings, the record/replay harness — is written against it, so a second
/// provider (local Ollama in a later phase) is additive.
public protocol AIProvider: Sendable {
    /// Stable, content-free identifier for logs and the Activity log:
    /// `"claude"`, `"replay"`, `"recording"`, `"mock"`.
    var identifier: String { get }

    /// Runs one request to completion.
    ///
    /// - Throws: ``AIError`` — never a raw `URLError` or decoding error.
    func complete(_ request: AIRequest) async throws -> AIResponse

    /// Checks the credential and returns the models it can reach.
    ///
    /// Plan §1 amendment 4: this is `GET /v1/models`, which is free, rather than
    /// FR-6.1's literal "test call" (which would bill a message).
    func validateKey() async throws -> [AIModelInfo]
}
