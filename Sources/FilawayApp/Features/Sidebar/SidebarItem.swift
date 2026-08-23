import Foundation
import FilawayCore

/// What a sidebar row selects.
///
/// The same note appears in Recents *and* in the Library tree, so the two must
/// carry different `List` selection tags — otherwise AppKit highlights both and
/// arrow-key navigation jumps between the sections. Both cases resolve to the
/// same ``noteID``, which is all the editor cares about.
enum SidebarItem: Hashable {
    case recent(NoteID)
    case library(NoteID)

    var noteID: NoteID? {
        switch self {
        case let .recent(id), let .library(id): return id
        }
    }
}

/// Relative timestamps for Recents (FR-1.2, Figure 1: "2d ago", "4d ago").
enum RelativeTime {

    /// What Figure 1 shows under the note being edited.
    static let editingLabel = "Now · editing"

    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        switch seconds {
        case ..<0: return "Now"
        case ..<60: return "Now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400))d ago"
        case ..<(86_400 * 28): return "\(Int(seconds / (86_400 * 7)))w ago"
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = now.timeIntervalSince(date) < 86_400 * 365 ? "d MMM" : "MMM yyyy"
            return formatter.string(from: date)
        }
    }
}
