import AppKit
import FilawayCore
import SwiftUI

/// Help → **Log Retrieval Outcome…** (M4-11, spec §8).
///
/// Spec §8's second success criterion is *"find a specific stored command via
/// natural language in under 10 seconds, at least 90% of the time"*. M3-07
/// measures that against a fixed 302-note corpus; only the dogfood week
/// measures it against the library it is actually about. This is the
/// instrument for that week: after a search, one menu item, three fields, one
/// line appended to
/// `~/Library/Application Support/Filaway/retrieval-log.jsonl`.
///
/// `filaway-bench retrieval-log summarize` reads the file back and prints the
/// hit rate and the median seconds. The protocol is
/// `docs/verification/success-criteria.md`.
///
/// **Plain AppKit, on purpose.** ADR-037 records what hosting SwiftUI in a
/// window the scene did not create costs (an AttributeGraph precondition
/// failure that aborts the process), and this has to work in a session where
/// the scene may never have been built at all — including the headless smoke
/// runs. An `NSAlert` with an accessory view is three controls and no scene.
struct RetrievalOutcomeCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Log Retrieval Outcome…") { RetrievalOutcomePrompt.present() }
                .keyboardShortcut("l", modifiers: [.control, .option, .command])
        }
    }
}

/// The three-field prompt, and the one write it performs.
enum RetrievalOutcomePrompt {

    /// Shows the prompt and appends an outcome if the user confirms.
    ///
    /// - Returns: what was written, or `nil` when the user cancelled or the
    ///   query was blank. The return value exists so a smoke check can call
    ///   ``record(query:found:seconds:note:log:)`` directly.
    @MainActor
    @discardableResult
    static func present(log: RetrievalOutcomeLog = RetrievalOutcomeLog()) -> RetrievalOutcome? {
        let alert = NSAlert()
        alert.messageText = "Log a retrieval outcome"
        alert.informativeText = """
            One line per search you just ran, for the §8 dogfood week. \
            Stored locally in Application Support; never uploaded, and it never \
            records note content.
            """
        alert.addButton(withTitle: "Log")
        alert.addButton(withTitle: "Cancel")

        let fields = Fields()
        alert.accessoryView = fields.view
        alert.window.initialFirstResponder = fields.query

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let query = fields.query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }

        return record(
            query: query,
            found: fields.found.state == .on,
            seconds: fields.seconds.doubleValue,
            note: fields.note.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
            log: log
        )
    }

    /// Appends one outcome, reporting a write failure as a log line rather
    /// than as an alert: losing a dogfood entry is not worth interrupting
    /// someone's writing for.
    @discardableResult
    static func record(
        query: String,
        found: Bool,
        seconds: Double,
        note: String? = nil,
        log: RetrievalOutcomeLog = RetrievalOutcomeLog()
    ) -> RetrievalOutcome? {
        let outcome = RetrievalOutcome(query: query, found: found, seconds: seconds, note: note)
        do {
            try log.append(outcome)
            // NFR-4: the query is user text. Count it, never quote it.
            Log.app.info("retrieval outcome logged (found: \(found, privacy: .public))")
            return outcome
        } catch {
            Log.app.error("retrieval log append failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The accessory view's three controls, kept alive by the alert.
    @MainActor
    private final class Fields {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 96))
        let query = NSTextField(frame: NSRect(x: 0, y: 66, width: 320, height: 24))
        let found = NSButton(checkboxWithTitle: "Found what I was looking for", target: nil, action: nil)
        let seconds = NSTextField(frame: NSRect(x: 90, y: 4, width: 70, height: 24))
        let note = NSTextField(frame: NSRect(x: 0, y: 36, width: 320, height: 24))

        init() {
            query.placeholderString = "What you typed into ⌘K"
            query.setAccessibilityLabel("Search query")

            note.placeholderString = "Anything worth remembering (optional)"
            note.setAccessibilityLabel("Note")

            found.frame = NSRect(x: 0, y: 8, width: 220, height: 18)
            // The common case is a hit; the interesting case is unticking it.
            found.state = .on
            found.setAccessibilityLabel("Found what I was looking for")

            let label = NSTextField(labelWithString: "Seconds:")
            label.frame = NSRect(x: 230, y: 8, width: 58, height: 18)
            seconds.frame = NSRect(x: 288, y: 4, width: 32, height: 22)
            seconds.alignment = .right
            seconds.placeholderString = "0"
            seconds.setAccessibilityLabel("Seconds taken")

            view.addSubview(query)
            view.addSubview(note)
            view.addSubview(found)
            view.addSubview(label)
            view.addSubview(seconds)
        }
    }
}
