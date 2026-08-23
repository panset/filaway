import AppKit
import FilawayCore
import SwiftUI

// M4-08 — Help ▸ "Export Diagnostics…" (plan §1, "Crash/diagnostics": no crash
// reporter in Phase 1, OSLog with privacy annotations, and a menu item that
// zips the logs and never the notes).
//
// Everything that decides *what* goes in the zip lives in
// `FilawayCore/Diagnostics`, which is where its NFR-4 tests are. This file is
// only the menu item and the save panel — the two things that need AppKit.

/// The Help-menu command.
struct DiagnosticsCommands: Commands {
    @ObservedObject var model: DiagnosticsMenuModel

    var body: some Commands {
        CommandGroup(after: .help) {
            Divider()
            Button(model.isExporting ? "Exporting Diagnostics…" : "Export Diagnostics…") {
                model.exportDiagnostics()
            }
            .disabled(model.isExporting)
        }
    }
}

/// Runs the save panel and the export, and reports the outcome as a banner.
///
/// `@MainActor` because it drives an `NSSavePanel`; the export itself happens
/// on ``DiagnosticsExporter``, off the main thread, because it shells out to
/// `log show`.
@MainActor
final class DiagnosticsMenuModel: ObservableObject {
    static let shared = DiagnosticsMenuModel()

    @Published private(set) var isExporting = false

    /// Set by ``AppModel`` so the export names the library the user is actually
    /// using; falls back to the default root before the library is open.
    var library: () -> Library = {
        Library(root: AppSettings.notesRoot, supportRoot: AppSettings.supportRoot)
    }

    /// Where to report success or failure. `AppModel.show(_:)` when wired.
    var onMessage: ((String, String) -> Void)?

    private let log = Log.make("diagnostics")

    func exportDiagnostics() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.message = "The bundle contains logs, versions and database counts — "
            + "never your notes, their titles or their paths."
        panel.nameFieldStringValue = DiagnosticsExporter.suggestedFileName()
        panel.allowedContentTypes = [.zip]
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        let library = self.library()
        let settings = SettingsModel.shared.settings
        Task { [weak self] in
            let exporter = DiagnosticsExporter(library: library, settings: settings)
            do {
                let export = try await exporter.export(to: destination)
                await MainActor.run {
                    self?.isExporting = false
                    self?.finish(export)
                }
            } catch {
                await MainActor.run {
                    self?.isExporting = false
                    self?.log.error("diagnostics export failed: \(String(describing: error), privacy: .public)")
                    self?.onMessage?("Could not export diagnostics: \(error)", "exclamationmark.triangle")
                }
            }
        }
    }

    private func finish(_ export: DiagnosticsExport) {
        NSWorkspace.shared.activateFileViewerSelecting([export.url])
        let detail = export.warnings.isEmpty
            ? ""
            : " (\(export.warnings.count) item\(export.warnings.count == 1 ? "" : "s") could not be collected)"
        onMessage?("Diagnostics exported to \(export.url.lastPathComponent).\(detail)", "doc.zipper")
    }
}
