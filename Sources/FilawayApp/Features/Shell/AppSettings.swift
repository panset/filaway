import AppKit
import Foundation
import FilawayCore

/// Everything the shell remembers between launches (FR-1.5).
///
/// Window *frame* is AppKit's own job (`NSWindow.setFrameAutosaveName`); this
/// covers the rest: sidebar width, which note was open, and which Library
/// folders were expanded.
///
/// Per-library values are keyed by `Library.key`, so pointing the app at a
/// different notes root (or a throwaway `FILAWAY_NOTES_ROOT` in the smoke
/// driver) never inherits the previous library's selection.
enum AppSettings {

    /// `NSWindow` frame autosave name — AppKit persists size *and* position.
    /// The smoke driver uses its own, so a scripted run never moves the user's
    /// real window.
    static var windowFrameAutosaveName: NSWindow.FrameAutosaveName {
        isSmokeRun ? "FilawayMainWindow-smoke" : "FilawayMainWindow"
    }

    /// `FILAWAY_DEFAULTS_SUITE` redirects every preference into a throwaway
    /// domain, so `Tools/smoke.sh` can relaunch the app against persisted state
    /// and then delete the whole plist.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard let suite = ProcessInfo.processInfo.environment["FILAWAY_DEFAULTS_SUITE"],
              !suite.isEmpty, let store = UserDefaults(suiteName: suite)
        else { return .standard }
        return store
    }()

    static var isSmokeRun: Bool {
        let value = ProcessInfo.processInfo.environment["FILAWAY_SMOKE"]
        return value != nil && value != "0"
    }

    // MARK: - Notes root

    /// `~/Notes` unless `FILAWAY_NOTES_ROOT` overrides it (tests, smoke driver).
    /// Onboarding's folder picker (M4-01) replaces this with a bookmark.
    static var notesRoot: URL {
        if let override = ProcessInfo.processInfo.environment["FILAWAY_NOTES_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        return Library.defaultRoot
    }

    /// `FILAWAY_SUPPORT_ROOT` redirects the derived database out of the user's
    /// real Application Support — smoke runs and tests only.
    static var supportRoot: URL? {
        guard let override = ProcessInfo.processInfo.environment["FILAWAY_SUPPORT_ROOT"],
              !override.isEmpty else { return nil }
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
    }

    // MARK: - Sidebar

    static let sidebarMinWidth: Double = 190
    static let sidebarDefaultWidth: Double = 248
    static let sidebarMaxWidth: Double = 420

    static var sidebarWidth: Double {
        get {
            let stored = defaults.double(forKey: "sidebar.width")
            guard stored >= sidebarMinWidth, stored <= sidebarMaxWidth else { return sidebarDefaultWidth }
            return stored
        }
        set { defaults.set(newValue, forKey: "sidebar.width") }
    }

    // MARK: - Per-library state

    static func lastOpenNoteID(libraryKey: String) -> NoteID? {
        defaults.string(forKey: "note.lastOpen.\(libraryKey)").flatMap(NoteID.init)
    }

    static func setLastOpenNoteID(_ id: NoteID?, libraryKey: String) {
        let key = "note.lastOpen.\(libraryKey)"
        if let id {
            defaults.set(id.uuidString, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    static func expandedFolders(libraryKey: String) -> Set<String> {
        Set(defaults.stringArray(forKey: "sidebar.expanded.\(libraryKey)") ?? [])
    }

    static func setExpandedFolders(_ folders: Set<String>, libraryKey: String) {
        defaults.set(Array(folders).sorted(), forKey: "sidebar.expanded.\(libraryKey)")
    }

    /// Forces preferences to disk. Called on the terminate path, where the
    /// process may exit before the periodic flush.
    static func flush() {
        defaults.synchronize()
    }
}
