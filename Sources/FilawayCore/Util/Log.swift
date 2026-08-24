import OSLog

/// Central `Logger` factory.
///
/// Never log note content: NFR-4 requires zero-content telemetry, so any
/// interpolated user text must be marked `privacy: .private` at the call site.
public enum Log {
    /// Makes a logger in the Filaway subsystem for the given category.
    public static func make(_ category: String) -> Logger {
        Logger(subsystem: FilawayCore.subsystem, category: category)
    }

    public static let app = make("app")
    public static let store = make("store")
    public static let index = make("index")
    public static let ai = make("ai")
}
