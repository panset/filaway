import Foundation

/// Where the Claude API key lives (FR-6.1, NFR-4: Keychain, never a plain file).
///
/// The protocol exists so nothing above it links against Security directly:
/// `swift test` runs without a signed binary, where a real Keychain query may
/// prompt or fail outright, so tests use ``InMemorySecretStore`` and the real
/// ``KeychainStore`` is exercised only behind `FILAWAY_TEST_KEYCHAIN=1`.
public protocol SecretStore: Sendable {
    /// The stored secret, or `nil` when there is none.
    func secret(for account: String) throws -> String?
    /// Stores (or replaces) the secret.
    func setSecret(_ secret: String, for account: String) throws
    /// Removes the secret; succeeds when there was nothing to remove.
    func deleteSecret(for account: String) throws
}

public extension SecretStore {
    /// The Claude API key, under the standard account name.
    func apiKey() throws -> String? { try secret(for: KeychainStore.apiKeyAccount) }

    func setAPIKey(_ key: String) throws { try setSecret(key, for: KeychainStore.apiKeyAccount) }

    func deleteAPIKey() throws { try deleteSecret(for: KeychainStore.apiKeyAccount) }
}

/// A dictionary-backed store for tests, previews and `filaway-bench`.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]

    public init(_ storage: [String: String] = [:]) {
        self.storage = storage
    }

    public convenience init(apiKey: String) {
        self.init([KeychainStore.apiKeyAccount: apiKey])
    }

    public func secret(for account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func setSecret(_ secret: String, for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = secret
    }

    public func deleteSecret(for account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = nil
    }
}

/// Where a request's credential comes from.
///
/// Resolution is a closure rather than a stored string so a key entered in
/// Settings takes effect on the next request without rebuilding the provider,
/// and so the key is never held in a long-lived property that could end up in a
/// crash log (NFR-4).
public struct APIKeySource: Sendable {
    private let resolve: @Sendable () throws -> String?

    public init(_ resolve: @escaping @Sendable () throws -> String?) {
        self.resolve = resolve
    }

    /// The current key, or `nil` when none is configured.
    public func key() throws -> String? {
        guard let key = try resolve()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }
        return key
    }

    /// A literal key — tests and one-off CLI runs.
    public static func fixed(_ key: String?) -> APIKeySource {
        APIKeySource { key }
    }

    /// `$ANTHROPIC_API_KEY` — how `record`/`live` test modes authenticate.
    public static func environment(_ name: String = "ANTHROPIC_API_KEY") -> APIKeySource {
        APIKeySource { ProcessInfo.processInfo.environment[name] }
    }

    /// A ``SecretStore`` (in production, the Keychain).
    public static func store(_ store: any SecretStore, account: String = KeychainStore.apiKeyAccount) -> APIKeySource {
        APIKeySource { try store.secret(for: account) }
    }

    /// The Keychain first, then the environment — the app's default, which also
    /// lets a developer run against `$ANTHROPIC_API_KEY` without onboarding.
    public static func storeThenEnvironment(
        _ store: any SecretStore,
        account: String = KeychainStore.apiKeyAccount,
        variable: String = "ANTHROPIC_API_KEY"
    ) -> APIKeySource {
        APIKeySource {
            if let key = try store.secret(for: account), !key.isEmpty { return key }
            return ProcessInfo.processInfo.environment[variable]
        }
    }

    /// No credential at all.
    public static let none = APIKeySource { nil }
}
