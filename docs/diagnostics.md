# Diagnostics — what Filaway will tell you about itself

One page. Everything here is Phase 1 behaviour, implemented in
`Sources/FilawayCore/Diagnostics/` and tested in
`Tests/FilawayCoreTests/ReliabilityDiagnosticsTests.swift`.

## The promise

**NFR-4 is zero-content telemetry.** Filaway sends nothing anywhere on its own.
The only diagnostics that ever leave the machine are the ones the user
deliberately exports and attaches to a bug report, and that bundle must be safe
to hand to a stranger. Concretely, a diagnostics export never contains:

- the text of a note;
- the **title** of a note, or a folder name the user created (DS-1 makes a title
  a filename, so a path is a title);
- any path inside the notes root — they read `<notes-root>/…`;
- anything sent to or received from the model: prompts, plans, session text;
- the API key.

The first four are structural: `DiagnosticsExporter` never opens a note, never
reads a row out of `activity_events`, never touches `PromptLibrary`. The last
two are enforced by `DiagnosticsRedactor` over every byte that came from
somewhere else, plus a leak sweep that drops a file rather than ship it.

## Help ▸ Export Diagnostics…

`Sources/FilawayApp/Features/Diagnostics/DiagnosticsMenu.swift` — a save panel,
then `DiagnosticsExporter.export(to:)`, then the Finder reveals the zip.

```
Filaway-diagnostics-<timestamp>/
  README.txt               what this is, and the list above
  versions.txt             app, build, core, macOS, schema version, library key
  settings.txt             every FR-8.1 preference except anything the user typed
  database.txt             sqlite_master DDL + a row COUNT per table; no rows
  support-directory.txt    file names and sizes under Application Support
  oslog.txt                log show --predicate 'subsystem == "com.tejaspanse.filaway"' --last 1d
  crash-reports/           Filaway*.ips from the last 30 days, scrubbed
```

Two details worth knowing:

- **`settings.txt` reports `excludedFolders` as a count, not as names.** The
  names are folders the user made, which is the same class of secret as a title.
- **`database.txt` is schema plus counts.** `activity_events` holds raw session
  text and before/after images; the count is diagnostic, the rows are the notes.

## What the redactor does

`DiagnosticsRedactor` runs over every text file the bundle contains, including
the ones the exporter writes itself.

| In | Out |
|---|---|
| `/Users/ada/Notes/Commands/curl.md` | `<notes-root>/…` |
| `/Users/ada/Library/Logs/…` | `~/Library/Logs/…` |
| `/Users/someone-else/…` | `/Users/<user>/…` |
| `sk-ant-api03-…` | `<redacted-key>` |

The notes-root rule collapses the **whole remainder** of the path, not just the
prefix — `<notes-root>/Commands/curl.md` would still name a folder and a title.
The key rule is a pattern, so a key Filaway never held is masked too.

The account-name rule fires **only where the name is a path component**. A bare
substring replacement mauls ordinary text: on the machine this was written on,
the account name is a substring of `com.tejaspanse.filaway`, and every log line
came out as `com.<user>.filaway`.

After everything is staged, `sweepForLeaks` reads each file back and removes any
that still contains a library path or a known secret. `DiagnosticsExport.dropped`
names them; it should always be empty, and a non-empty one is a bug.

## OSLog, and why the excerpt is safe

Every logger comes from `Log.make(_:)` in the `com.tejaspanse.filaway` subsystem.
The rule in `CLAUDE.md` is absolute: **never interpolate note text into a
`Logger` without `privacy: .private`.** `log show` honours those annotations for
a process it is not attached to, so user text arrives in the excerpt as
`<private>` and stays that way — the export copies what `log show` printed, it
does not re-read the log store.

Categories in use: `app`, `store`, `index`, `ai`, `organize`, `search`,
`storage`, `maintenance`, `diagnostics`.

To watch Filaway live while reproducing something:

```
log stream --predicate 'subsystem == "com.tejaspanse.filaway"' --level debug
```

## Crash reports

There is no crash reporter in Phase 1 (plan §1). macOS writes `.ips` reports to
`~/Library/Logs/DiagnosticReports/`, and the export copies the `Filaway*` ones
from the last 30 days, scrubbed. An opt-in reporter with scrubbing is deferred.

## Databases that turn out not to be databases

A power cut, an interrupted restore or a cloud-sync conflict can leave
`filaway.sqlite` with bytes that are not a database at all. `DatabaseFile.open`
wraps every SQLite open in Filaway: on `SQLITE_NOTADB` / `SQLITE_CORRUPT` the
file and its `-wal` / `-shm` sidecars are moved aside as
`filaway.sqlite.corrupt-<timestamp>` and a fresh one takes their place.

- **Moved, never deleted.** The derived half rebuilds from the notes folder, but
  the Activity history and the organized baselines in that same file do not.
  Keeping the bytes leaves a salvage path (ADR-057).
- `MetadataStore`, `ActivityLog`, `AIUsageLedger` all expose
  `recoveredFromCorruption`, and `database.txt` lists every quarantined file —
  which is the whole explanation for "my Activity history is empty".
- The notes themselves are never involved. They are Markdown in a folder.

## Maintenance

`MaintenanceScheduler` (Core) keeps a durable stamp in
`<supportDirectory>/maintenance.json` and lets a job through at most once a day.
`OrganizeCoordinator.start()` uses it to run `ActivityLog.prune()`, which is what
enforces FR-4.4's 30-day window on raw session text. A stamp in the future — a
restored backup, a timezone fix — counts as due rather than as a lockout.
