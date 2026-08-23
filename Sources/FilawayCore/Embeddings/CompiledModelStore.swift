import CoreML
import Foundation

/// Compiles a `.mlpackage` on first use and caches the `.mlmodelc` in
/// Application Support.
///
/// Plan §8: this machine has no Xcode, so `coremlcompiler` cannot pre-compile
/// the model at build time. `MLModel.compileModel(at:)` is the runtime
/// equivalent, and it is available on every user's Mac — which also means the
/// shipped app only has to carry the `.mlpackage`, not a per-OS `.mlmodelc`.
///
/// The cache key is a cheap fingerprint (package name + total byte size +
/// newest mtime) written next to the compiled model, so re-running with a
/// re-converted package recompiles, and a normal launch does not.
public enum CompiledModelStore {
    public struct Outcome: Sendable {
        /// Location of the compiled `.mlmodelc` directory.
        public let compiledURL: URL
        /// `false` when the cached copy was reused.
        public let didCompile: Bool
        /// Seconds spent in `MLModel.compileModel(at:)` (0 for a cache hit).
        public let compileDuration: TimeInterval
    }

    public enum StoreError: Error, CustomStringConvertible {
        case packageMissing(URL)
        case cacheUnavailable(String)

        public var description: String {
            switch self {
            case let .packageMissing(url): "no .mlpackage at \(url.path)"
            case let .cacheUnavailable(detail): "model cache unavailable: \(detail)"
            }
        }
    }

    /// Default cache root: `~/Library/Application Support/com.tejaspanse.filaway/Models`.
    public static func defaultCacheDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return base.appendingPathComponent(FilawayCore.subsystem, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    /// Returns a compiled model URL for `packageURL`, compiling if needed.
    public static func compiledModel(
        forPackageAt packageURL: URL,
        cacheDirectory: URL? = nil
    ) async throws -> Outcome {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: packageURL.path) else {
            throw StoreError.packageMissing(packageURL)
        }

        let cacheRoot = try cacheDirectory ?? defaultCacheDirectory()
        try fileManager.createDirectory(at: cacheRoot, withIntermediateDirectories: true)

        let stem = packageURL.deletingPathExtension().lastPathComponent
        let compiledURL = cacheRoot.appendingPathComponent("\(stem).mlmodelc", isDirectory: true)
        let stampURL = cacheRoot.appendingPathComponent("\(stem).stamp")
        let fingerprint = try fingerprint(of: packageURL)

        if fileManager.fileExists(atPath: compiledURL.path),
           let cached = try? String(contentsOf: stampURL, encoding: .utf8),
           cached == fingerprint {
            return Outcome(compiledURL: compiledURL, didCompile: false, compileDuration: 0)
        }

        let start = DispatchTime.now()
        let temporaryURL = try await MLModel.compileModel(at: packageURL)
        let duration = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        // compileModel writes into a temporary directory that the system may
        // reclaim; move it into the cache before anyone opens it.
        if fileManager.fileExists(atPath: compiledURL.path) {
            try fileManager.removeItem(at: compiledURL)
        }
        do {
            try fileManager.moveItem(at: temporaryURL, to: compiledURL)
        } catch {
            try fileManager.copyItem(at: temporaryURL, to: compiledURL)
        }
        try? fingerprint.write(to: stampURL, atomically: true, encoding: .utf8)

        return Outcome(compiledURL: compiledURL, didCompile: true, compileDuration: duration)
    }

    /// Deletes any cached compilation of `packageURL` (used by tests and by a
    /// future "Rebuild index" that also wants a clean model cache).
    public static func removeCachedModel(
        forPackageAt packageURL: URL,
        cacheDirectory: URL? = nil
    ) throws {
        let cacheRoot = try cacheDirectory ?? defaultCacheDirectory()
        let stem = packageURL.deletingPathExtension().lastPathComponent
        for url in [
            cacheRoot.appendingPathComponent("\(stem).mlmodelc", isDirectory: true),
            cacheRoot.appendingPathComponent("\(stem).stamp"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// `name:totalBytes:newestModificationTime` over the package contents.
    private static func fingerprint(of packageURL: URL) throws -> String {
        let fileManager = FileManager.default
        var total = 0
        var newest: TimeInterval = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        if let enumerator = fileManager.enumerator(
            at: packageURL, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.isRegularFile == true else { continue }
                total += values.fileSize ?? 0
                newest = max(newest, values.contentModificationDate?.timeIntervalSince1970 ?? 0)
            }
        }
        return "\(packageURL.lastPathComponent):\(total):\(Int(newest))"
    }
}
