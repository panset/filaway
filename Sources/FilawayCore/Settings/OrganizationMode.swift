import Foundation

/// Whether the organizer files a session's notes itself or asks first (FR-4.2).
///
/// Figure 4's "Mode" row. `askBeforeFiling` is the default because the spec's
/// first principle is that the AI never surprises the user with a change they
/// did not see; `autoFile` still writes an Activity entry and stays undoable.
public enum OrganizationMode: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// Show the plan on a card with Accept / Edit / Dismiss (Figure 2a).
    case askBeforeFiling
    /// Apply the plan and announce what happened, with Undo.
    case autoFile

    public var id: String { rawValue }

    /// The label Settings shows. Matches Figure 4's wording.
    public var label: String {
        switch self {
        case .askBeforeFiling: return "Ask before filing"
        case .autoFile: return "Auto-file"
        }
    }

    /// One-line explanation for the picker's help text.
    public var detail: String {
        switch self {
        case .askBeforeFiling: return "Review each plan before anything moves."
        case .autoFile: return "File automatically, then show what changed with Undo."
        }
    }
}
