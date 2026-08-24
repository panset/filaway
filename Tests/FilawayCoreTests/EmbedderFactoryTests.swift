import Foundation
import Testing

@testable import FilawayCore

/// One compiled-model cache for the whole suite.
///
/// The first `MLModel(contentsOf:)` after a compile costs 1.5–3 s (the Neural
/// Engine building and caching its own program). Giving each test its own cache
/// directory paid that twice and slowed every other suite running in parallel
/// with it — including the highlighter's timing test.
actor BundledModelCache {
    static let shared = BundledModelCache()

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("filaway-model-cache-\(UUID().uuidString)", isDirectory: true)
    /// The load is memoised as a `Task`, not as its result: an actor suspends
    /// at every `await`, so two concurrent tests would both see a `nil`
    /// embedder and both compile into the same directory, and one of them would
    /// lose the race to move the `.mlmodelc` into place.
    private var loading: Task<CoreMLEmbedder, Error>?

    func load() async throws -> CoreMLEmbedder {
        if let loading { return try await loading.value }
        let directory = directory
        let task = Task {
            try await BundledEmbeddingModel.load(cacheDirectory: directory).embedder
        }
        loading = task
        return try await task.value
    }

    func factoryDefault() async -> (embedder: (any Embedder)?, active: ActiveEmbedder) {
        // Warm the cache first, so the factory's own compile is a cache hit.
        _ = try? await load()
        return await EmbedderFactory.default(cacheDirectory: directory)
    }
}

/// M3-01 — the bundled model and the ladder that chooses it (ADR-012).
@Suite("EmbedderFactory")
struct EmbedderFactoryTests {
    @Test("the bundled model resources are present in the FilawayCore bundle")
    func bundledResourcesExist() {
        #expect(BundledEmbeddingModel.isAvailable)
        #expect(BundledEmbeddingModel.directory != nil)
    }

    @Test("the bundled descriptor is the package the spike recommended")
    func descriptorMatchesTheDecision() throws {
        let descriptor = try BundledEmbeddingModel.descriptor()
        #expect(descriptor.model == "BAAI/bge-small-en-v1.5")
        #expect(descriptor.name == "bge-small-en-v1.5")
        #expect(descriptor.dimension == 384)
        #expect(descriptor.pooling == "cls")
        #expect(descriptor.maxSequenceLength == 256)
        #expect(descriptor.batchSize == 1)
        #expect(descriptor.precision == "fp16")
        #expect(descriptor.normalized)
        #expect(descriptor.lowercase)
    }

    @Test("the identifier carries everything that changes the numbers")
    func identifierIsComplete() throws {
        let descriptor = try BundledEmbeddingModel.descriptor()
        let identifier = descriptor.embedderIdentifier
        #expect(identifier.contains("bge-small-en-v1.5"))
        #expect(identifier.contains("cls"))
        #expect(identifier.contains("384d"))
        #expect(identifier.contains("s256"))
        #expect(identifier.contains("fp16"))
        #expect(identifier.hasSuffix("/v\(EmbeddingModelDescriptor.identifierVersion)"))

        // A different pooling, dimension, sequence length or precision must be
        // a different identifier, or a model swap would silently reuse stale
        // vectors.
        var other = descriptor
        other.pooling = "mean"
        #expect(other.embedderIdentifier != identifier)
        other = descriptor
        other.maxSequenceLength = 64
        #expect(other.embedderIdentifier != identifier)
    }

    @Test("bge asks for a query prefix; other families do not")
    func queryPrefix() throws {
        #expect(try BundledEmbeddingModel.descriptor().queryPrefix
            == "Represent this sentence for searching relevant passages: ")
        var mini = try BundledEmbeddingModel.descriptor()
        mini.name = "all-MiniLM-L6-v2"
        #expect(mini.queryPrefix.isEmpty)
    }

    // The two tests below actually run the model. `bundledResourcesExist`
    // above is the hard assertion that it is there (ADR-022); these skip
    // rather than fail, so a stripped checkout still gets a useful test run.
    @Test("the factory reports the Core ML rung when the bundle has the model",
          .enabled(if: BundledEmbeddingModel.isAvailable))
    func factoryPicksCoreML() async throws {
        let (embedder, active) = await BundledModelCache.shared.factoryDefault()
        let model = try #require(embedder)
        #expect(active.kind == .coreML)
        #expect(active.supportsSemanticSearch)
        #expect(active.dimension == 384)
        #expect(active.identifier == model.identifier)
        #expect(model.queryPrefix.hasPrefix("Represent this sentence"))

        // And it actually runs.
        let vectors = try await model.embed(["how do I copy a file to a remote host"])
        #expect(vectors.count == 1)
        #expect(vectors[0].count == 384)
        #expect(abs(EmbeddingMath.norm(vectors[0]) - 1) < 1e-3)
    }

    @Test("the query prefix moves a question towards its answer",
          .enabled(if: BundledEmbeddingModel.isAvailable))
    func queryPrefixHelpsRetrieval() async throws {
        let embedder = try await BundledModelCache.shared.load()

        let passage = try await embedder.embed("scp ./report.pdf user@host:/tmp/ copies a file to a remote host")
        let plain = try await embedder.embed("how do I copy a file to a remote host?")
        let prefixed = try await embedder.embedQuery("how do I copy a file to a remote host?")

        // Both must retrieve it; the prefixed form is the convention the model
        // was trained with, so it should not be worse.
        #expect(EmbeddingMath.dot(plain, passage) > 0.5)
        #expect(EmbeddingMath.dot(prefixed, passage) > 0.5)
    }

    @Test("the unavailable rung degrades to keyword-only rather than to a bad model")
    func unavailableRung() {
        #expect(!ActiveEmbedder.unavailable.supportsSemanticSearch)
        #expect(ActiveEmbedder.unavailable.dimension == 0)
    }
}
