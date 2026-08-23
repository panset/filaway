import Accelerate
import Foundation
import GRDB

/// Conversion between `Float` vectors and the raw IEEE 754 **binary16** bytes
/// stored in `embeddings.vector`.
///
/// Swift's `Float16` is unavailable on x86_64 macOS, and plan §1 keeps Intel in
/// scope, so the halves are carried as `UInt16` bit patterns and converted with
/// vImage — which is architecture-independent and vectorised on both.
public enum HalfVector {
    /// Bytes per stored component.
    public static let stride = MemoryLayout<UInt16>.size

    /// Packs `vector` into binary16 bytes.
    public static func encode(_ vector: [Float]) -> Data {
        guard !vector.isEmpty else { return Data() }
        var halves = [UInt16](repeating: 0, count: vector.count)
        vector.withUnsafeBufferPointer { source in
            halves.withUnsafeMutableBufferPointer { destination in
                convert(
                    from: UnsafeMutableRawPointer(mutating: source.baseAddress!),
                    sourceBytesPerRow: vector.count * MemoryLayout<Float>.size,
                    to: UnsafeMutableRawPointer(destination.baseAddress!),
                    destinationBytesPerRow: vector.count * stride,
                    count: vector.count,
                    toHalf: true
                )
            }
        }
        return halves.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Unpacks binary16 bytes into `Float`s. Returns `nil` on a truncated blob.
    public static func decode(_ data: Data, count: Int) -> [Float]? {
        guard data.count >= count * stride else { return nil }
        var halves = [UInt16](repeating: 0, count: count)
        halves.withUnsafeMutableBytes { destination in
            _ = data.copyBytes(to: destination, count: count * stride)
        }
        var out = [Float](repeating: 0, count: count)
        halves.withUnsafeBufferPointer { source in
            out.withUnsafeMutableBufferPointer { destination in
                decode(source.baseAddress!, count: count, into: destination.baseAddress!)
            }
        }
        return out
    }

    /// Bulk half → float, straight into a caller-owned buffer.
    static func decode(_ halves: UnsafePointer<UInt16>, count: Int, into out: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        convert(
            from: UnsafeMutableRawPointer(mutating: halves),
            sourceBytesPerRow: count * stride,
            to: UnsafeMutableRawPointer(out),
            destinationBytesPerRow: count * MemoryLayout<Float>.size,
            count: count,
            toHalf: false
        )
    }

    private static func convert(
        from source: UnsafeMutableRawPointer,
        sourceBytesPerRow: Int,
        to destination: UnsafeMutableRawPointer,
        destinationBytesPerRow: Int,
        count: Int,
        toHalf: Bool
    ) {
        var input = vImage_Buffer(
            data: source, height: 1, width: vImagePixelCount(count), rowBytes: sourceBytesPerRow
        )
        var output = vImage_Buffer(
            data: destination, height: 1, width: vImagePixelCount(count), rowBytes: destinationBytesPerRow
        )
        if toHalf {
            _ = vImageConvert_PlanarFtoPlanar16F(&input, &output, 0)
        } else {
            _ = vImageConvert_Planar16FtoPlanarF(&input, &output, 0)
        }
    }
}

/// The vector matrix's backing allocation.
///
/// A hand-managed buffer rather than an `[UInt16]`: the query loop hands raw
/// pointers to Accelerate, and Swift 6's region isolation rejects
/// `withUnsafeBufferPointer` nests that mix actor-isolated storage with local
/// scratch. Wrapping the allocation in a class puts the `deallocate` in a
/// `deinit` that an actor is allowed to have, and lets the matrix grow by
/// doubling instead of by `append`.
final class HalfMatrix {
    private(set) var baseAddress: UnsafeMutablePointer<UInt16>?
    private(set) var capacityRows = 0
    let dimension: Int

    init(dimension: Int) {
        self.dimension = max(1, dimension)
    }

    deinit {
        baseAddress?.deallocate()
    }

    /// Ensures room for `rows` slots, preserving the first `usedRows`.
    ///
    /// - Parameter exact: allocate exactly `rows` rather than doubling. A load
    ///   knows its final size up front, and doubling there would leave up to
    ///   40% of the matrix as slack — 10 MB at 20,000 chunks.
    func reserve(rows: Int, usedRows: Int, exact: Bool = false) {
        guard rows > capacityRows else { return }
        let newCapacity = exact ? rows : max(rows, max(1_024, capacityRows * 2))
        let replacement = UnsafeMutablePointer<UInt16>.allocate(capacity: newCapacity * dimension)
        replacement.initialize(repeating: 0, count: newCapacity * dimension)
        if let old = baseAddress, usedRows > 0 {
            replacement.update(from: old, count: usedRows * dimension)
        }
        baseAddress?.deallocate()
        baseAddress = replacement
        capacityRows = newCapacity
    }
}

/// One chunk that scored against a query vector.
public struct VectorNeighbor: Sendable, Equatable {
    public let chunkID: Int64
    public let noteID: NoteID
    /// Cosine similarity. Every stored vector is L2-normalised, so this is a
    /// plain dot product in [-1, 1].
    public let score: Float

    public init(chunkID: Int64, noteID: NoteID, score: Float) {
        self.chunkID = chunkID
        self.noteID = noteID
        self.score = score
    }
}

/// The in-memory vector index (M3-03, plan §1 "Semantic index").
///
/// Everything for the **active model** is held in one flat Float16 matrix with
/// `chunkIDs`/`noteIDs` side arrays, and a query is a single `cblas_sgemv` per
/// block. Brute force is the right shape here: 20,000 notes at ~4 chunks each
/// is 80,000 × 384 = 61 MB of halves, and a full scan of that is a few
/// milliseconds — an ANN index would add a rebuild, a recall cliff and a
/// dependency for no measurable win at this size (`sqlite-vec` remains the
/// Phase-2 escape hatch, ADR-012).
///
/// Loading is **lazy**: nothing is read until the first semantic query, so a
/// user who only ever uses ⌘K keyword search never pays for it (NFR-1's 2 s
/// launch budget).
///
/// ```swift
/// let store = VectorStore(reader: metadata.reader, modelID: embedder.identifier,
///                         dimension: embedder.dimension)
/// let hits = try await store.topK(queryVector, k: 50)
/// ```
public actor VectorStore {
    /// Rows converted to Float32 at a time. 4,096 × 384 floats is a 6 MB
    /// scratch buffer, which stays comfortably in L2 and bounds the transient
    /// cost of a query at any library size.
    static let blockRows = 4_096

    private let reader: any DatabaseReader
    public nonisolated let modelID: String
    public nonisolated let dimension: Int

    /// `rowCount * dimension` binary16 components.
    private var storage: HalfMatrix
    private var chunkIDs: [Int64] = []
    private var noteIDs: [NoteID] = []
    private var live: [Bool] = []
    private var slotByChunkID: [Int64: Int] = [:]
    private var freeSlots: [Int] = []
    private var rowCount = 0
    private var isLoaded = false

    private let log = Log.index

    public init(reader: any DatabaseReader, modelID: String, dimension: Int) {
        self.reader = reader
        self.modelID = modelID
        self.dimension = max(1, dimension)
        storage = HalfMatrix(dimension: max(1, dimension))
    }

    // MARK: - Loading

    /// How many live vectors are resident.
    public var count: Int { rowCount - freeSlots.count }

    public var loaded: Bool { isLoaded }

    /// Loads the matrix if it has not been loaded yet.
    public func ensureLoaded() throws {
        guard !isLoaded else { return }
        try reload()
    }

    /// Rereads every vector for the active model from the database.
    public func reload() throws {
        let start = ContinuousClock.now
        storage = HalfMatrix(dimension: dimension)
        chunkIDs.removeAll(keepingCapacity: false)
        noteIDs.removeAll(keepingCapacity: false)
        live.removeAll(keepingCapacity: false)
        slotByChunkID.removeAll(keepingCapacity: false)
        freeSlots.removeAll(keepingCapacity: false)
        rowCount = 0

        let dimension = dimension
        let expectedBytes = dimension * HalfVector.stride
        try reader.read { db in
            // Size the allocation exactly, so the resident matrix is the
            // number the memory report promises rather than up to 2× it.
            let expected = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM embeddings WHERE model_id = ? AND dim = ?",
                arguments: [modelID, dimension]
            ) ?? 0
            storage.reserve(rows: expected, usedRows: 0, exact: true)
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT e.chunk_id AS chunk_id, c.note_id AS note_id, e.vector AS vector
                FROM embeddings e
                JOIN chunks c ON c.id = e.chunk_id
                WHERE e.model_id = ? AND e.dim = ?
                ORDER BY e.chunk_id
                """, arguments: [modelID, dimension])
            while let row = try cursor.next() {
                let blob: Data = row["vector"]
                guard blob.count >= expectedBytes,
                      let noteID = NoteID(row["note_id"] as String)
                else { continue }
                appendRow(chunkID: row["chunk_id"], noteID: noteID, halfBytes: blob)
            }
        }
        isLoaded = true
        let elapsed = ContinuousClock.now - start
        let milliseconds = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1e15
        let summary = String(
            format: "%d vectors, %.1f MB, %.0f ms", rowCount, memory().megabytes, milliseconds
        )
        log.info("vector store loaded: \(summary, privacy: .public)")
    }

    /// Drops the matrix; the next query reloads it.
    public func unload() {
        storage = HalfMatrix(dimension: dimension)
        chunkIDs = []
        noteIDs = []
        live = []
        slotByChunkID = [:]
        freeSlots = []
        rowCount = 0
        isLoaded = false
    }

    private func appendRow(chunkID: Int64, noteID: NoteID, halfBytes: Data) {
        let slot = rowCount
        storage.reserve(rows: slot + 1, usedRows: rowCount)
        write(halfBytes, toSlot: slot)
        chunkIDs.append(chunkID)
        noteIDs.append(noteID)
        live.append(true)
        slotByChunkID[chunkID] = slot
        rowCount += 1
    }

    // MARK: - Incremental maintenance

    /// One vector to add or replace.
    public struct Upsert: Sendable {
        public let chunkID: Int64
        public let noteID: NoteID
        public let vector: [Float]

        public init(chunkID: Int64, noteID: NoteID, vector: [Float]) {
            self.chunkID = chunkID
            self.noteID = noteID
            self.vector = vector
        }
    }

    /// Applies an indexer's write to the resident matrix, so a note edited two
    /// seconds ago is findable without rereading 80,000 rows (FR-5.4).
    ///
    /// A no-op while the matrix has never been loaded — the next lazy load will
    /// pick the rows up from the database anyway.
    public func apply(upserts: [Upsert], deletedChunkIDs: [Int64] = []) {
        guard isLoaded else { return }
        remove(chunkIDs: deletedChunkIDs)
        for upsert in upserts {
            guard upsert.vector.count == dimension else { continue }
            let bytes = HalfVector.encode(upsert.vector)
            if let slot = slotByChunkID[upsert.chunkID] {
                write(bytes, toSlot: slot)
                noteIDs[slot] = upsert.noteID
                live[slot] = true
            } else if let slot = freeSlots.popLast() {
                write(bytes, toSlot: slot)
                chunkIDs[slot] = upsert.chunkID
                noteIDs[slot] = upsert.noteID
                live[slot] = true
                slotByChunkID[upsert.chunkID] = slot
            } else {
                appendRow(chunkID: upsert.chunkID, noteID: upsert.noteID, halfBytes: bytes)
            }
        }
    }

    /// Tombstones rows. Slots are reused by the next upsert rather than
    /// compacted, so a churning note never memmoves the whole matrix.
    public func remove(chunkIDs ids: [Int64]) {
        guard isLoaded else { return }
        for id in ids {
            guard let slot = slotByChunkID.removeValue(forKey: id), live[slot] else { continue }
            live[slot] = false
            freeSlots.append(slot)
            zero(slot: slot)
        }
    }

    /// Tombstones every row belonging to these notes (a delete or a move out of
    /// the library).
    public func removeNotes(_ ids: [NoteID]) {
        guard isLoaded, !ids.isEmpty else { return }
        let targets = Set(ids)
        for slot in 0 ..< rowCount where live[slot] && targets.contains(noteIDs[slot]) {
            slotByChunkID.removeValue(forKey: chunkIDs[slot])
            live[slot] = false
            freeSlots.append(slot)
            zero(slot: slot)
        }
    }

    private func write(_ bytes: Data, toSlot slot: Int) {
        guard let base = storage.baseAddress, bytes.count >= dimension * HalfVector.stride else { return }
        let destination = UnsafeMutableRawPointer(base + slot * dimension)
        bytes.withUnsafeBytes { raw in
            destination.copyMemory(from: raw.baseAddress!, byteCount: dimension * HalfVector.stride)
        }
    }

    private func zero(slot: Int) {
        guard let base = storage.baseAddress else { return }
        (base + slot * dimension).update(repeating: 0, count: dimension)
    }

    // MARK: - Search

    /// The `k` nearest chunks to `query` by cosine similarity.
    ///
    /// - Parameter allow: an optional note-level gate — the temporal **hard**
    ///   filter (FR-5.3) applies here rather than after the cut, so restricting
    ///   a search to "yesterday" cannot come back empty just because 50 newer
    ///   chunks scored higher.
    public func topK(
        _ query: [Float],
        k: Int,
        allow: (@Sendable (NoteID) -> Bool)? = nil
    ) throws -> [VectorNeighbor] {
        try ensureLoaded()
        guard k > 0, query.count == dimension, rowCount > 0 else { return [] }

        var selection = TopKSelection(capacity: k)
        let dimension = dimension
        guard let matrix = storage.baseAddress else { return [] }

        let blockRows = min(Self.blockRows, rowCount)
        let floats = UnsafeMutablePointer<Float>.allocate(capacity: blockRows * dimension)
        let scores = UnsafeMutablePointer<Float>.allocate(capacity: blockRows)
        let queryBuffer = UnsafeMutablePointer<Float>.allocate(capacity: dimension)
        defer {
            floats.deallocate()
            scores.deallocate()
            queryBuffer.deallocate()
        }
        for index in 0 ..< dimension { queryBuffer[index] = query[index] }

        var row = 0
        while row < rowCount {
            let rows = min(blockRows, rowCount - row)
            HalfVector.decode(matrix + row * dimension, count: rows * dimension, into: floats)
            // Every vector is unit length, so the matrix-vector product *is*
            // the cosine vector. `vDSP_mmul` and not `cblas_sgemv`: the CBLAS
            // entry points are deprecated without the ILP64 headers, and this
            // is the same BLAS kernel underneath.
            vDSP_mmul(
                floats, 1, queryBuffer, 1, scores, 1,
                vDSP_Length(rows), 1, vDSP_Length(dimension)
            )
            for offset in 0 ..< rows {
                let slot = row + offset
                guard live[slot] else { continue }
                if let allow, !allow(noteIDs[slot]) { continue }
                selection.offer(score: scores[offset], slot: slot)
            }
            row += rows
        }

        return selection.sorted().map { entry in
            VectorNeighbor(chunkID: chunkIDs[entry.slot], noteID: noteIDs[entry.slot], score: entry.score)
        }
    }

    /// A brute-force Float32 reference, for tests and for the bench's
    /// accuracy check. Never used on the query path.
    public func referenceTopK(_ query: [Float], k: Int) throws -> [VectorNeighbor] {
        try ensureLoaded()
        var scored: [(Int, Float)] = []
        scored.reserveCapacity(rowCount)
        for slot in 0 ..< rowCount where live[slot] {
            guard let vector = vector(atSlot: slot) else { continue }
            scored.append((slot, EmbeddingMath.dot(query, vector)))
        }
        return scored
            .sorted { $0.1 == $1.1 ? chunkIDs[$0.0] < chunkIDs[$1.0] : $0.1 > $1.1 }
            .prefix(k)
            .map { VectorNeighbor(chunkID: chunkIDs[$0.0], noteID: noteIDs[$0.0], score: $0.1) }
    }

    /// The resident vector for a chunk, as Float32.
    public func vector(forChunk chunkID: Int64) throws -> [Float]? {
        try ensureLoaded()
        guard let slot = slotByChunkID[chunkID], live[slot] else { return nil }
        return vector(atSlot: slot)
    }

    private func vector(atSlot slot: Int) -> [Float]? {
        guard slot < rowCount, let matrix = storage.baseAddress else { return nil }
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: dimension)
        defer { scratch.deallocate() }
        HalfVector.decode(matrix + slot * dimension, count: dimension, into: scratch)
        return Array(UnsafeBufferPointer(start: scratch, count: dimension))
    }

    // MARK: - Memory

    public struct MemoryReport: Sendable, Equatable {
        /// Live vectors.
        public let vectorCount: Int
        /// Slots allocated, including tombstones awaiting reuse.
        public let slotCount: Int
        public let dimension: Int
        /// Bytes held by the matrix and its side arrays.
        public let bytes: Int

        public var megabytes: Double { Double(bytes) / 1_048_576 }

        public var description: String {
            String(
                format: "%d vectors × %d-d = %.1f MB (%d slots)",
                vectorCount, dimension, megabytes, slotCount
            )
        }
    }

    public func memory() -> MemoryReport {
        let matrix = storage.capacityRows * dimension * HalfVector.stride
        let sideArrays = rowCount * (MemoryLayout<Int64>.size + MemoryLayout<UUID>.size + 1)
        // The dictionary is the one non-obvious cost: ~48 B per entry.
        let map = slotByChunkID.count * 48
        return MemoryReport(
            vectorCount: count,
            slotCount: rowCount,
            dimension: dimension,
            bytes: matrix + sideArrays + map
        )
    }
}

/// A fixed-capacity max-of-k selection: one pass, no sort of the full score
/// vector, no allocation past the initial reserve.
struct TopKSelection {
    struct Entry { var score: Float; var slot: Int }

    private let capacity: Int
    /// A min-heap: `heap[0]` is the weakest entry currently kept.
    private var heap: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        heap.reserveCapacity(self.capacity)
    }

    mutating func offer(score: Float, slot: Int) {
        if heap.count < capacity {
            heap.append(Entry(score: score, slot: slot))
            siftUp(from: heap.count - 1)
        } else if score > heap[0].score {
            heap[0] = Entry(score: score, slot: slot)
            siftDown(from: 0)
        }
    }

    /// Best first; ties broken by slot so the order is deterministic.
    func sorted() -> [Entry] {
        heap.sorted { $0.score == $1.score ? $0.slot < $1.slot : $0.score > $1.score }
    }

    private mutating func siftUp(from index: Int) {
        var child = index
        while child > 0 {
            let parent = (child - 1) / 2
            guard heap[child].score < heap[parent].score else { return }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < heap.count, heap[left].score < heap[smallest].score { smallest = left }
            if right < heap.count, heap[right].score < heap[smallest].score { smallest = right }
            guard smallest != parent else { return }
            heap.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
