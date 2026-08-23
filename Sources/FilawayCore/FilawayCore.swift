/// Namespace for package-wide constants.
///
/// `FilawayCore` holds every piece of logic that is testable without a UI.
/// It must never `import AppKit` or `import SwiftUI`.
public enum FilawayCore {
    /// Marketing version, kept in sync with `CFBundleShortVersionString`.
    public static let version = "0.1.0"

    /// Bundle identifier and OSLog subsystem (plan §2.2).
    public static let subsystem = "com.tejaspanse.filaway"
}
