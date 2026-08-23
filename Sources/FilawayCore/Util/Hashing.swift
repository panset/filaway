import CryptoKit
import Foundation

/// Content hashes used for change detection (DS-4) and, later, the
/// compare-and-swap preconditions of the organizer (FR-3.2).
public enum Hashing {
    /// Lowercase hex SHA-256 of arbitrary bytes.
    public static func sha256Hex(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(64)
        for byte in SHA256.hash(data: data) {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return out
    }

    /// Lowercase hex SHA-256 of a string's UTF-8 bytes.
    public static func sha256Hex(_ text: String) -> String {
        sha256Hex(Data(text.utf8))
    }

    /// Short, stable, filesystem-safe identifier derived from a string —
    /// used for `libraryKey` (16 hex characters, 64 bits).
    public static func shortKey(_ text: String, length: Int = 16) -> String {
        String(sha256Hex(text).prefix(length))
    }

    private static let hexDigits: [Character] = Array("0123456789abcdef")
}
