import Foundation

/// A versioned prompt identity, e.g. `organize.v1` (spec §9, plan §1 "Prompts").
///
/// Every plan and every answer records the version that produced it, so a
/// prompt change is visible in the Activity log and in the golden fixtures
/// rather than silently altering behaviour.
public struct PromptVersion: Sendable, Hashable, Codable, CustomStringConvertible, LosslessStringConvertible {
    public let id: String
    public let version: Int

    public init(id: String, version: Int) {
        self.id = id
        self.version = version
    }

    /// Parses `"organize.v1"`.
    public init?(_ description: String) {
        let parts = description.split(separator: ".")
        guard parts.count == 2, parts[1].hasPrefix("v"), let version = Int(parts[1].dropFirst()) else { return nil }
        id = String(parts[0])
        self.version = version
    }

    public var description: String { "\(id).v\(version)" }

    /// Resource file name: `organize.v1.txt`.
    public var fileName: String { "\(description).txt" }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = PromptVersion(raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "\(raw) is not a prompt version (expected \"name.vN\")"
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: - Known prompts

    /// The shared description of the plan tool contract, included by
    /// `organize.v1`. Owned by M2-04 because it mirrors
    /// ``OrganizationPlan/toolSchema``.
    public static let planFormat = PromptVersion(id: "plan-format", version: 1)
    /// The organization prompt (M2-06 writes the file).
    public static let organize = PromptVersion(id: "organize", version: 1)
    /// The search answer-extraction prompt (M3-05 writes the file).
    public static let answer = PromptVersion(id: "answer", version: 1)
}

public enum PromptError: Error, Equatable, CustomStringConvertible {
    case missing(PromptVersion, searched: [String])

    public var description: String {
        switch self {
        case let .missing(version, searched):
            return "Prompt \(version) not found. Looked in: \(searched.joined(separator: ", "))"
        }
    }
}

/// Loads versioned prompt text.
///
/// Prompts are **SwiftPM resources of `FilawayCore`**, under
/// `Sources/FilawayCore/AI/Prompts/`. Plan §2.7 sketched a top-level `Prompts/`
/// folder "copied as Core resources", but SwiftPM can only declare resources
/// that live inside the target directory, and this project has no copy step
/// (plan §8: no Xcode, pure SwiftPM), so the files live in the target and the
/// build system does the copying. See `docs/decisions.md`.
///
/// A directory override exists for two cases: `filaway-bench prompts --live`
/// iterating on wording without a rebuild, and tests that want a throwaway
/// prompt.
public enum PromptLibrary {
    /// `FILAWAY_PROMPTS_DIR`, when set, wins over the bundled resources.
    public static let environmentVariable = "FILAWAY_PROMPTS_DIR"

    /// Loads the prompt text.
    ///
    /// - Parameter directory: an explicit override; otherwise
    ///   `$FILAWAY_PROMPTS_DIR`, then the bundled resources.
    public static func text(
        _ version: PromptVersion,
        in directory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        var searched: [String] = []

        for candidate in [directory, environment[environmentVariable].map { URL(fileURLWithPath: $0, isDirectory: true) }] {
            guard let candidate else { continue }
            let url = candidate.appendingPathComponent(version.fileName, isDirectory: false)
            searched.append(url.path)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        }

        if let url = Bundle.module.url(forResource: version.description, withExtension: "txt", subdirectory: "Prompts")
            ?? Bundle.module.url(forResource: version.description, withExtension: "txt") {
            searched.append(url.path)
            if let text = try? String(contentsOf: url, encoding: .utf8) { return text }
        } else {
            searched.append("Bundle.module/Prompts/\(version.fileName)")
        }

        throw PromptError.missing(version, searched: searched)
    }

    /// `true` when the prompt can be loaded — used by tests that must not fail
    /// on a prompt a later milestone still owes.
    public static func exists(_ version: PromptVersion, in directory: URL? = nil) -> Bool {
        (try? text(version, in: directory)) != nil
    }
}
