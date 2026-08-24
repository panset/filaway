import CoreML
import Foundation

/// The Core ML model shipped inside `FilawayCore` (M3-01, ADR-012).
///
/// `Package.swift` copies `Sources/FilawayCore/Resources/Models` into the
/// target's resource bundle, so the three artefacts
/// `Tools/embedder/convert.py` produces travel with the app:
///
/// | File | Size | Role |
/// |---|---:|---|
/// | `bge-small-en-v1.5-s256-b1.mlpackage` | 63.5 MB | fp16 ML Program, CLS-pooled, L2-normalised |
/// | `bge-small-en-v1.5-s256-b1.json` | 365 B | ``EmbeddingModelDescriptor`` |
/// | `bge-small-en-v1.5.vocab.txt` | 226 KB | WordPiece vocabulary |
///
/// Only the `.mlpackage` ships — never a `.mlmodelc`. It is compiled on first
/// launch by ``CompiledModelStore`` (47–86 ms, cached in Application Support),
/// which is both what plan §8 forces (no `coremlcompiler` without Xcode) and
/// what ADR-012 adopted permanently.
public enum BundledEmbeddingModel {
    /// Basename of the `.mlpackage`/descriptor pair.
    public static let packageStem = "bge-small-en-v1.5-s256-b1"
    /// Basename of the vocabulary, which is shared across sequence lengths.
    public static let modelName = "bge-small-en-v1.5"

    /// `Models/` inside the target's resource bundle, or `nil` when the
    /// resources were not built (a bare `swift build` of a stripped checkout).
    public static var directory: URL? {
        guard let root = Bundle.module.resourceURL else { return nil }
        let models = root.appendingPathComponent("Models", isDirectory: true)
        return FileManager.default.fileExists(atPath: models.path) ? models : nil
    }

    public static var packageURL: URL? {
        directory?.appendingPathComponent("\(packageStem).mlpackage", isDirectory: true)
    }

    public static var descriptorURL: URL? {
        directory?.appendingPathComponent("\(packageStem).json", isDirectory: false)
    }

    public static var vocabularyURL: URL? {
        directory?.appendingPathComponent("\(modelName).vocab.txt", isDirectory: false)
    }

    /// `true` when all three artefacts are present and readable.
    public static var isAvailable: Bool {
        guard let packageURL, let descriptorURL, let vocabularyURL else { return false }
        let manager = FileManager.default
        return manager.fileExists(atPath: packageURL.path)
            && manager.fileExists(atPath: descriptorURL.path)
            && manager.fileExists(atPath: vocabularyURL.path)
    }

    public static func descriptor() throws -> EmbeddingModelDescriptor {
        guard let descriptorURL, FileManager.default.fileExists(atPath: descriptorURL.path) else {
            throw EmbedderError.modelUnavailable("no bundled \(packageStem).json")
        }
        return try EmbeddingModelDescriptor(contentsOf: descriptorURL)
    }

    /// Compiles (if the cache is cold) and opens the bundled model.
    public static func load(
        computeUnits: MLComputeUnits = .all,
        cacheDirectory: URL? = nil
    ) async throws -> (embedder: CoreMLEmbedder, compilation: CompiledModelStore.Outcome) {
        guard let packageURL, let vocabularyURL, isAvailable else {
            throw EmbedderError.modelUnavailable(
                "Resources/Models is missing from the FilawayCore bundle"
            )
        }
        return try await CoreMLEmbedder.load(
            packageAt: packageURL,
            vocabularyAt: vocabularyURL,
            descriptor: try descriptor(),
            computeUnits: computeUnits,
            cacheDirectory: cacheDirectory
        )
    }
}

/// Which rung of the fallback ladder is live, in the shape Settings renders
/// (plan §5 risk #4, ADR-012).
public struct ActiveEmbedder: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// The bundled Core ML bge-small — the shipped path.
        case coreML
        /// `NLContextualEmbedding`, mean-pooled. Demoted by ADR-012.
        case nlContextual
        /// `NLEmbedding.sentenceEmbedding`. Demoted by ADR-012.
        case nlSentence
        /// No embedder at all: search degrades to keyword-only (FR-5.5).
        case unavailable
    }

    public let kind: Kind
    /// ``Embedder/identifier``, or `""` when nothing loaded.
    public let identifier: String
    public let dimension: Int
    /// One line for the Settings row.
    public let displayName: String
    /// A second line explaining *why* this rung, and what it cost.
    public let detail: String
    /// `false` means the UI must say "semantic answers unavailable" (FR-5.5).
    public var supportsSemanticSearch: Bool { kind != .unavailable }

    public init(kind: Kind, identifier: String, dimension: Int, displayName: String, detail: String) {
        self.kind = kind
        self.identifier = identifier
        self.dimension = dimension
        self.displayName = displayName
        self.detail = detail
    }

    public static let unavailable = ActiveEmbedder(
        kind: .unavailable,
        identifier: "",
        dimension: 0,
        displayName: "Keyword search only",
        detail: "No local embedding model could be loaded; semantic answers are unavailable."
    )
}

/// Chooses the embedder the app runs with, walking ADR-012's ladder.
///
/// ```swift
/// let (embedder, active) = await EmbedderFactory.default()
/// settings.embedderRow = active          // "bge-small-en-v1.5 · bundled"
/// if let embedder { indexer = Indexer(metadata: metadata, embedder: embedder) }
/// ```
///
/// Loading costs 45 ms warm and 1.5–3 s the very first time (the Neural Engine
/// caching its own program), so callers must do this off the main actor —
/// NFR-1 gives the whole launch 2 s.
public enum EmbedderFactory {
    /// The ladder, in order, with the reason each rung was skipped logged.
    ///
    /// - Parameter allowNaturalLanguage: ADR-012 demoted the `NL*` embedders to
    ///   "keep the code, do not present them as equivalent" — they answered
    ///   4/20 spike queries against 20/20 for Core ML and 16/20 for plain BM25.
    ///   The default is therefore **false**: without the bundled model the app
    ///   degrades to keyword-only rather than to a worse embedder. Tests and
    ///   `filaway-bench` pass `true` to exercise the lower rungs.
    public static func `default`(
        computeUnits: MLComputeUnits = .all,
        cacheDirectory: URL? = nil,
        allowNaturalLanguage: Bool = false
    ) async -> (embedder: (any Embedder)?, active: ActiveEmbedder) {
        let log = Log.index

        if BundledEmbeddingModel.isAvailable {
            do {
                let (embedder, compilation) = try await BundledEmbeddingModel.load(
                    computeUnits: computeUnits, cacheDirectory: cacheDirectory
                )
                let compiled = compilation.didCompile
                    ? String(format: "compiled in %.0f ms", compilation.compileDuration * 1000)
                    : "compiled model cached"
                let active = ActiveEmbedder(
                    kind: .coreML,
                    identifier: embedder.identifier,
                    dimension: embedder.dimension,
                    displayName: "\(BundledEmbeddingModel.modelName) (bundled)",
                    detail: "Core ML, fp16, \(embedder.dimension)-d, sequence \(embedder.maxSequenceLength) — \(compiled)."
                )
                log.info("embedder: \(active.identifier, privacy: .public) — \(compiled, privacy: .public)")
                return (embedder, active)
            } catch {
                log.error("bundled Core ML embedder failed: \(String(describing: error), privacy: .public)")
            }
        } else {
            log.notice("bundled Core ML embedder is absent from the bundle")
        }

        if allowNaturalLanguage {
            if NLContextualEmbedder.assetsAvailable(), let embedder = try? NLContextualEmbedder() {
                let active = ActiveEmbedder(
                    kind: .nlContextual,
                    identifier: embedder.identifier,
                    dimension: embedder.dimension,
                    displayName: "Apple contextual embedding (fallback)",
                    detail: "Much weaker than the bundled model (ADR-012); results will be poor."
                )
                log.notice("embedder fallback: \(active.identifier, privacy: .public)")
                return (embedder, active)
            }
            if NLSentenceEmbedder.isAvailable(), let embedder = try? NLSentenceEmbedder() {
                let active = ActiveEmbedder(
                    kind: .nlSentence,
                    identifier: embedder.identifier,
                    dimension: embedder.dimension,
                    displayName: "Apple sentence embedding (fallback)",
                    detail: "Much weaker than the bundled model (ADR-012); results will be poor."
                )
                log.notice("embedder fallback: \(active.identifier, privacy: .public)")
                return (embedder, active)
            }
        }

        log.notice("no embedder available — semantic search degrades to keyword-only")
        return (nil, .unavailable)
    }
}
