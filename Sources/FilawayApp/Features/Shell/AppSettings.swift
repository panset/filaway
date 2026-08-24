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

    /// The FR-8.1 preference store, on the same suite as everything above.
    ///
    /// `SettingsModel` owns the instance the Settings window binds to; this one
    /// exists for the handful of places that need a preference *before* any
    /// window exists — the launch gate (`onboardingCompleted`), the notes-root
    /// bookmark, and the editor's paste offer.
    static let core = CoreSettings(defaults: defaults)

    // MARK: - Notes root

    /// Where the notes live, in precedence order:
    ///
    /// 1. `FILAWAY_NOTES_ROOT` — tests and the smoke driver, always wins;
    /// 2. the bookmark onboarding's folder picker stored (NFR-5: the root may be
    ///    an external or synced volume, and it may be renamed);
    /// 3. `~/Notes`, the FR-7.1 default.
    ///
    /// Resolved once per launch. Onboarding runs *before* the library is opened,
    /// so the value it writes is the one this launch uses; nothing else changes
    /// the root while the app is running.
    static var notesRoot: URL {
        if let cached = resolvedNotesRoot { return cached }
        // **Reading this does not run the launch gate.** It used to (ADR-049's
        // "whoever asks first"), and the asker turned out to be a SwiftUI
        // `StateObject` initialiser — so the gate's modal ran inside an
        // AttributeGraph update and the app came up with no window at all.
        // `AppModel.bootstrap()` waits for the gate instead, and nothing else
        // may resolve the root before it (ADR-061).
        let resolved = resolveNotesRoot()
        resolvedNotesRoot = resolved
        return resolved
    }

    nonisolated(unsafe) private static var resolvedNotesRoot: URL?

    /// Forgets the cached root. Called by onboarding after it stores a bookmark.
    static func invalidateNotesRoot() { resolvedNotesRoot = nil }

    private static func resolveNotesRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["FILAWAY_NOTES_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath).standardizedFileURL
        }
        if let bookmark = core.notesRootBookmark {
            do {
                let (library, isStale) = try Library.resolving(bookmark: bookmark)
                // A stale bookmark still resolves; macOS is asking for a fresh
                // one, and writing it back now keeps the next launch cheap.
                if isStale { core.notesRootBookmark = try? library.bookmarkData() }
                return library.root
            } catch {
                Log.app.error("notes-root bookmark did not resolve: \(String(describing: error), privacy: .public)")
            }
        }
        return Library.defaultRoot
    }

    /// Stores `url` as the notes root and drops the cached resolution.
    /// - Returns: `false` when macOS refused to make a bookmark.
    @discardableResult
    static func setNotesRoot(_ url: URL) -> Bool {
        let library = Library(root: url)
        guard let bookmark = try? library.bookmarkData() else {
            Log.app.error("could not bookmark the chosen notes folder")
            return false
        }
        core.notesRootBookmark = bookmark
        invalidateNotesRoot()
        return true
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
