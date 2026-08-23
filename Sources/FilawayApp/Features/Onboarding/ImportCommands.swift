import AppKit
import FilawayCore
import SwiftUI

/// File → Import… (M4-10, FR-7.2).
///
/// The item is present and **disabled**, with the reason in its tooltip. Present
/// because the spec asks for a stub the user can see the shape of; disabled
/// because Phase 1 cannot do it and a menu item that opens a "not yet" alert is
/// worse than one that says so before you click. The sentence comes from
/// `AppleNotesImporter.unavailableMessage`, so the menu, the error and the
/// release notes cannot drift apart. See ADR-039.
struct ImportCommands: Commands {
    private let importers: [any NoteImporter] = [AppleNotesImporter()]

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Menu("Import") {
                ForEach(Array(importers.enumerated()), id: \.offset) { _, importer in
                    Button(importer.displayName) {}
                        .disabled(!importer.isAvailable)
                        .help(AppleNotesImporter.unavailableMessage)
                        .accessibilityHint(AppleNotesImporter.unavailableMessage)
                }
            }
        }
    }
}
