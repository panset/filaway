import AppKit
import FilawayCore

/// User intents that mutate the library: new note, title commit, and the
/// sidebar's context menu (FR-1.4, FR-4.x manual editing).
///
/// Every one of these goes through `NoteStore` — nothing here touches the
/// filesystem directly — and then patches `MetadataStore` so the sidebar is
/// correct before the watcher's own reconcile catches up.
@MainActor
extension AppModel {

    // MARK: - New note (FR-1.4)

    /// ⌘N and the toolbar button. No dialogs, no required metadata: an
    /// `Untitled note` at the Library root `[ASSUMPTION]`, selected, focus in
    /// the body.
    func newNote(inFolder folderPath: String = "") {
        Task { await newNoteAsync(inFolder: folderPath) }
    }

    @discardableResult
    func newNoteAsync(inFolder folderPath: String = "") async -> NoteID? {
        guard let store, let metadata else { return nil }
        if let current = openNote?.id, let autosave {
            await autosave.flush(noteID: current, trigger: .noteSwitch)
        }
        do {
            let note = try await store.createNote(inFolder: folderPath, title: nil, body: "")
            try? await metadata.apply([.added(note.summary)])
            if !folderPath.isEmpty { expandedFolders.insert(folderPath) }
            await refreshSidebarNow()
            await open(noteID: note.id)
            return note.id
        } catch {
            show(Banner(text: "Could not create a note: \(error)",
                        symbol: "exclamationmark.triangle", isError: true))
            return nil
        }
    }

    // MARK: - Title (DS-1: the filename stem *is* the title)

    func commitTitle(_ raw: String) {
        Task { await commitTitleAsync(raw) }
    }

    func commitTitleAsync(_ raw: String) async {
        guard let store, let metadata, let open = openNote else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = trimmed.isEmpty ? PathRules.untitled : trimmed
        guard wanted != open.title else { return }
        // Write the body first: `rename` moves the file, and a pending write to
        // the old path would resurrect it.
        await autosave?.flush(noteID: open.id, trigger: .noteSwitch)
        do {
            let summary = try await store.rename(open.relativePath, to: wanted)
            try? await metadata.apply([.moved(from: open.relativePath, to: summary.relativePath, note: summary)])
            // `.moved` re-inserts the row, so restore the Recents ordering key.
            try? await metadata.markOpened(id: summary.id)
            openNote?.relativePath = summary.relativePath
            openNote?.title = summary.title
            editorTitle = summary.title
            autosave?.noteRelocated(noteID: summary.id, to: summary.relativePath)
            await refreshSidebarNow()
        } catch {
            editorTitle = open.title
            show(Banner(text: "Could not rename: \(error)",
                        symbol: "exclamationmark.triangle", isError: true))
        }
    }

    // MARK: - Notes

    func renameNote(_ note: NoteSummary, to newTitle: String) {
        Task {
            guard let store, let metadata else { return }
            let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != note.title else { return }
            if openNote?.id == note.id {
                await commitTitleAsync(trimmed)
                return
            }
            do {
                let summary = try await store.rename(note.relativePath, to: trimmed)
                try? await metadata.apply([.moved(from: note.relativePath, to: summary.relativePath, note: summary)])
                await refreshSidebarNow()
            } catch {
                show(Banner(text: "Could not rename: \(error)", symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    /// Context menu → Move to…, and the drag-a-note-onto-a-folder drop.
    func moveNote(_ note: NoteSummary, toFolder folderPath: String) {
        Task {
            guard let store, let metadata else { return }
            guard note.folderPath != folderPath else { return }
            do {
                if openNote?.id == note.id {
                    await autosave?.flush(noteID: note.id, trigger: .noteSwitch)
                }
                let summary = try await store.move(note.relativePath, toFolder: folderPath)
                try? await metadata.apply([.moved(from: note.relativePath, to: summary.relativePath, note: summary)])
                if openNote?.id == summary.id {
                    try? await metadata.markOpened(id: summary.id)
                    openNote?.relativePath = summary.relativePath
                    autosave?.noteRelocated(noteID: summary.id, to: summary.relativePath)
                }
                if !folderPath.isEmpty { expandedFolders.insert(folderPath) }
                await refreshSidebarNow()
            } catch StorageError.folderTooDeep {
                // Plan §1: refuse the drag rather than surfacing an error sheet.
                show(Banner(text: "The Library is only \(PathRules.maxFolderDepth) folders deep.",
                            symbol: "folder.badge.questionmark"))
            } catch {
                show(Banner(text: "Could not move: \(error)", symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    /// Delete → macOS Trash. Nothing is ever hard-deleted (ADR-008).
    func deleteNote(_ note: NoteSummary) {
        Task {
            guard let store, let metadata else { return }
            do {
                autosave?.discard(noteID: note.id)
                _ = try await store.deleteNote(note.relativePath)
                try? await metadata.apply([.removed(relativePath: note.relativePath, id: note.id)])
                if openNote?.id == note.id { closeOpenNote() }
                await refreshSidebarNow()
                show(Banner(text: "‘\(note.title)’ moved to Trash.", symbol: "trash"))
            } catch {
                show(Banner(text: "Could not delete: \(error)", symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    // MARK: - Folders

    func createFolder(named name: String, in parent: String = "") {
        Task {
            guard let store, let metadata else { return }
            let stem = PathRules.sanitizeTitle(name)
            guard !stem.isEmpty else { return }
            let path = parent.isEmpty ? stem : "\(parent)/\(stem)"
            do {
                try await store.createFolder(path)
                try? await metadata.apply([.folderAdded(path)])
                expandedFolders.insert(path)
                if !parent.isEmpty { expandedFolders.insert(parent) }
                persistExpansion()
                await refreshSidebarNow()
            } catch StorageError.folderTooDeep {
                show(Banner(text: "The Library is only \(PathRules.maxFolderDepth) folders deep.",
                            symbol: "folder.badge.questionmark"))
            } catch {
                show(Banner(text: "Could not create the folder: \(error)",
                            symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    /// Renaming a folder is a move of every note inside it; the simplest correct
    /// implementation is to create the new folder, move the notes, then trash
    /// the husk — all through `NoteStore`, all reconciled by a rescan.
    func renameFolder(_ folder: Folder, to newName: String) {
        Task {
            guard let store, let watcher else { return }
            let stem = PathRules.sanitizeTitle(newName)
            guard !stem.isEmpty, stem != folder.name else { return }
            let parent = PathRules.parent(of: folder.path) ?? ""
            let destination = parent.isEmpty ? stem : "\(parent)/\(stem)"
            do {
                try await store.createFolder(destination)
                for note in allNotes(in: folder) {
                    _ = try await store.move(note.relativePath, toFolder: destination)
                }
                _ = try? await store.deleteFolder(folder.path)
                expandedFolders.remove(folder.path)
                expandedFolders.insert(destination)
                persistExpansion()
                _ = try? await watcher.reconcile()
                await refreshSidebarNow()
            } catch {
                show(Banner(text: "Could not rename the folder: \(error)",
                            symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    func deleteFolder(_ folder: Folder) {
        Task {
            guard let store, let watcher else { return }
            let doomed = Set(allNotes(in: folder).map(\.id))
            for id in doomed { autosave?.discard(noteID: id) }
            do {
                _ = try await store.deleteFolder(folder.path)
                expandedFolders.remove(folder.path)
                persistExpansion()
                if let open = openNote?.id, doomed.contains(open) { closeOpenNote() }
                _ = try? await watcher.reconcile()
                await refreshSidebarNow()
                show(Banner(text: "‘\(folder.name)’ moved to Trash.", symbol: "trash"))
            } catch {
                show(Banner(text: "Could not delete the folder: \(error)",
                            symbol: "exclamationmark.triangle", isError: true))
            }
        }
    }

    /// Every folder a note may be moved into: the root plus every folder that
    /// still has room beneath it.
    var moveDestinations: [(path: String, label: String)] {
        var out: [(String, String)] = [("", "Library")]
        func walk(_ folder: Folder, prefix: String) {
            for child in folder.subfolders {
                out.append((child.path, prefix.isEmpty ? child.name : "\(prefix) › \(child.name)"))
                if PathRules.depth(ofFolder: child.path) < PathRules.maxFolderDepth {
                    walk(child, prefix: prefix.isEmpty ? child.name : "\(prefix) › \(child.name)")
                }
            }
        }
        if let tree { walk(tree, prefix: "") }
        return out
    }

    /// Resolves a dragged relative path back to its summary.
    func note(atRelativePath path: String) -> NoteSummary? {
        guard let tree else { return nil }
        return allNotes(in: tree).first { $0.relativePath == path }
    }

    func allNotes(in folder: Folder) -> [NoteSummary] {
        folder.notes + folder.subfolders.flatMap(allNotes(in:))
    }

    // MARK: - Expansion state (FR-1.5)

    func toggleFolder(_ path: String, expanded: Bool) {
        if expanded { expandedFolders.insert(path) } else { expandedFolders.remove(path) }
        persistExpansion()
    }

    func persistExpansion() {
        AppSettings.setExpandedFolders(expandedFolders, libraryKey: library.key)
    }

}
