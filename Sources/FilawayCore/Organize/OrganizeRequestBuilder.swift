import Foundation

/// Turns an ``OrganizeRequestContext`` into the ``AIRequest`` that goes to the
/// provider (M2-06).
///
/// Everything about the request is fixed here so that the fixture key — a hash
/// of model, system, messages, tools and tool choice — moves if and only if
/// something about *what was asked* moved:
///
/// | Field | Value | Why |
/// |---|---|---|
/// | `model` | Settings, default `claude-sonnet-5` | plan §1 "Default models" |
/// | `system` | `organize.v1`, with `plan-format.v1` spliced in | §9 prompt versioning |
/// | `tools` | `OrganizationPlan.tool`, `strict: true` | FR-4.1's closed set |
/// | `toolChoice` | forced to that tool | the model must not answer in prose |
/// | `maxTokens` | 4 096 | a plan is small; a truncated one is unusable |
/// | `thinking` | adaptive | the filing decision is the hard part |
/// | `effort` | `low` | plans are short and the user pays per token (FR-6.2) |
/// | `timeout` | 60 s Claude, 180 s Ollama | `providerKind.timeout(for:)` (ADR-069) |
public enum OrganizeRequestBuilder {
    /// The marker `organize.v1` uses to pull in the shared output contract.
    ///
    /// The two prompts are versioned separately but *rendered* as one system
    /// string, so a change to either moves the fixture key and the golden tests
    /// notice. See ``PromptVersion/planFormat``.
    public static let includeMarker = "{{include:plan-format.v1}}"

    public static let maxTokens = 4_096

    /// The cap when the backend is a local model (`num_predict`). A valid plan
    /// is a few hundred tokens; the first real-world Ollama session produced a
    /// runaway constrained generation (1,480+ tokens at ~17 tok/s) that blew
    /// the 180 s budget and lost the session. Capped, the generation either
    /// finishes inside the budget (~60 s worst case) or truncates into a clean,
    /// visible `.maxTokens` failure instead of a timeout.
    public static let localMaxTokens = 1_024

    /// The rendered system prompt.
    public static func systemPrompt(
        _ version: PromptVersion = .organize,
        in directory: URL? = nil
    ) throws -> String {
        let organize = try PromptLibrary.text(version, in: directory)
        guard organize.contains(includeMarker) else { return organize }
        let format = try PromptLibrary.text(.planFormat, in: directory)
        return organize.replacingOccurrences(of: includeMarker, with: format)
    }

    /// Builds the request for a session.
    public static func request(
        for built: OrganizeRequestContext,
        settings: OrganizerSettings,
        promptsDirectory: URL? = nil
    ) throws -> AIRequest {
        AIRequest(
            model: settings.model,
            purpose: .organize,
            system: try systemPrompt(settings.promptVersion, in: promptsDirectory),
            messages: [.user(built.promptText)],
            tools: [OrganizationPlan.tool],
            toolChoice: .tool(name: OrganizationPlan.toolName),
            maxTokens: settings.providerKind == .ollama ? localMaxTokens : maxTokens,
            thinking: .adaptive(),
            effort: settings.effort,
            timeout: settings.requestTimeout
        )
    }
}
