# Accessibility and HIG checklist (M4-06 — NFR-6, NFR-7)

What Filaway promises: **VoiceOver labels on every control, full keyboard
navigation, and respect for the system text size** (NFR-6), inside a window that
is HIG-conformant and correct in light and dark (NFR-7).

This file is the audit. It says, for every claim, *how it is checked* — and it
is explicit about the line between what a script can prove on this machine and
what still needs a person at an unlocked screen with VoiceOver on. Plan §8 is
why that line exists: no Xcode, therefore no XCTest UI tests, and the GUI
session is usually locked.

---

## 1. What the smoke suite proves

`make smoke` phase **`a11y`** (`Features/Settings/SettingsSmokeCheck.swift`,
walker in `Features/Settings/AccessibilityAudit.swift`).

It walks the *live* accessibility tree — the same `NSAccessibility` protocol
methods Accessibility Inspector reads — and objects to any element that:

* has an action (button, checkbox, radio, pop-up, menu button, slider, stepper,
  text field, combo box, disclosure triangle) and has **no** label, title, help
  or value, **and no named ancestor**; or
* is a visible image with no label — a decorative glyph is expected to be
  `.accessibilityHidden(true)`, which removes it from the tree entirely.

Three rules keep it honest rather than merely quiet:

| Rule | Why |
|---|---|
| A control is a **leaf**: the walk does not descend into it | AppKit builds a stepper from two nested buttons and a tab item from a button inside a button. None is announced separately, and objecting to them is objecting to AppKit. |
| A **named ancestor covers its children** | That is exactly what `.accessibilityElement(children:)` and SwiftUI's own control wrappers do. Without this the walk objects to correct code. |
| The window's own furniture is skipped by **subrole** | Close/minimise/zoom/full-screen are drawn *and* announced by the system. |

And it audits itself first (`a11y-walk-finds-an-unlabelled-button`): a synthetic
window with one bare `NSButton` and one labelled one must produce **exactly one**
finding. A check that has silently stopped looking is worse than no check.

Covered by the walk today:

- [x] Settings → General (notes folder, Change…, Show in Finder, paste
      intelligence switch, Rebuild index)
- [x] Settings → AI (connection card and Change…/Connect…, idle stepper, mode
      picker, semantic switch, exclusion menu, Advanced toggle and model
      pickers, usage line, privacy statement)
- [x] Settings → Activity (Open Activity, the five recent rows)
- [ ] Main window: toolbar (sidebar toggle, search field, AI pill, New Note),
      sidebar rows with their relative-time values, the ⌘K panel with its
      Find/Ask toggle, result rows, answer card and Copy, the organization card,
      the Activity window rows and Undo, the onboarding steps
      — **the walk runs on them, but only when a `WindowGroup` window exists.**
      On a locked screen the phase prints `main-window-skipped` and moves on.

Two defects the walk found and M4-02/06 fixed:

1. `Toggle(…).labelsHidden()` and `Stepper(…).labelsHidden()` left AppKit's
   `PlatformSwitch` / `AXIncrementor` with no name of their own. The labels are
   now applied **before** `.labelsHidden()`, and the stepper carries its own
   `accessibilityLabel`/`accessibilityValue` rather than relying on the
   enclosing `HStack`'s `children: .combine`.
2. `AIStatusPill` announced "AI" — a badge, not a sentence. VoiceOver now gets
   the long `AIStatus.label` plus a queue count as its value.

## 2. Keyboard navigation

Every one of these is a method call on a `@MainActor` object, which is what lets
the headless phases drive them with no synthetic key events.

| Key | Does | Where | Verified by |
|---|---|---|---|
| ⌘N | New Note, no dialog (FR-1.4) | `AppCommands` | smoke `1` |
| ⌘K | Focus the search field and select its text; opens the panel | `AppModel.focusSearch()` | smoke `search`, `semantic` |
| ⌘1 / ⌘2 | Focus sidebar / focus editor | `AppCommands` → `focusSidebar()` / `focusEditor()` | manual |
| ⌘, | Settings | SwiftUI `Settings` scene | smoke `settings`, `a11y` |
| ⌥⌘A | Activity window | the `Window` scene's own shortcut | manual; Settings → Activity has a button for it |
| ⌥⌘Z | Undo Last Organization (**not** ⇧⌘Z — that is Redo in every macOS text view, including ours) | `AppCommands` | smoke `organize` (via the coordinator) |
| ⌘S | Flush now | `AppCommands` | smoke `1` |
| ↑ / ↓ | Move the ⌘K selection, clamped, no wrap | `SearchCoordinator` | smoke `search` |
| ⏎ | Open the selection; in Find, a question-shaped query switches to Ask | `SearchCoordinator.submit()` | smoke `search`, `semantic` |
| ⎋ | Close the ⌘K panel and return focus to the editor; a second ⎋ clears the field | `SearchCoordinator` | smoke `search` |
| ⎋ | Dismiss an Ask-mode organization card | `OrganizationCardView` | smoke `organize` |
| ⏎ | Accept an Ask-mode organization card | `OrganizationCardView` | smoke `organize` |
| ⌘C | Copy the answer card's snippet | `SearchCoordinator.copyAnswerSnippet()` | smoke `semantic` |
| ⌘⇧K | Wrap the last paste in a code block | `PasteIntelligence` | smoke `paste` |
| Tab | Moves through the sheets in reading order (Edit plan, View changes, API key, the onboarding steps) | SwiftUI default order | **manual** |

**Needs a person:** ⌘1/⌘2 actually moving first responder, Tab order inside
sheets, and whether ⎋ leaves focus somewhere sensible. All three are first
responder behaviour, and there is no first responder on a locked screen.

## 3. Dynamic Type (system text size)

- [x] Every string is a semantic font (`.callout`, `.caption`, `.headline`,
      `.title3`) or `.system(size:)` inside a fixed-metric AppKit control.
- [x] `AIStatusPill`'s icon uses `@ScaledMetric(relativeTo: .callout)`, so the
      pill grows with the text beside it instead of staying at 12 pt.
- [x] Multi-line explanatory text uses `.fixedSize(horizontal: false, vertical: true)`
      so it wraps rather than truncates when the text grows.
- [ ] **Manual:** walk the Settings panes and the ⌘K panel at the largest system
      text size and check nothing clips. The Settings window is a fixed
      560 × 580 (a grouped `Form` scrolls itself), which is the risk area.

## 4. HIG: symbols, colour, materials, appearance

- [x] **SF Symbols everywhere.** The spec's placeholder glyphs are drawn as
      symbols, not characters: `✦ → sparkles`, `📁 → folder`,
      `🔍 → magnifyingglass`, `☁︎ → cloud` / `cloud.fill`,
      `💻 → desktopcomputer`, `🔒 → lock.fill`. The only emoji left in
      `Sources/FilawayApp` are inside doc comments quoting the spec's figures;
      none is rendered.
- [x] **System colours and materials only** — `.secondary`, `.tertiary`,
      `.tint`, `Color(nsColor: .textBackgroundColor)`, `.regularMaterial`,
      `.bar`. No literal RGB. Light and dark therefore come for free.
- [x] **No modal alerts for degradation** (FR-6.4). Every AI state is the one
      toolbar pill; conflicts and failures are the non-blocking banner. The only
      dialogs in the app are the sidebar's name prompt, the notes-folder
      confirmation, and the file picker — all of them user-initiated.
- [x] **Light and dark captured.** The `a11y` phase toggles `NSApp.appearance`
      between `aqua` and `darkAqua` and writes the rendered panes to
      `$FILAWAY_SMOKE_SHOTS`. `Tools/smoke.sh` points that at its throwaway work
      directory; `--keep` is how a human gets at them. **The PNGs are never
      committed.**
- [ ] **Manual:** look at those PNGs, plus the main window and the ⌘K panel, in
      both appearances. A capture proves the render did not crash; only a person
      can say it looks right.

## 5. AppKit reentrancy (the M1 launch warning)

`WARNING: Application performed a reentrant operation in its NSTableView
delegate` had been in the launch log since M1. AppKit says it "will become an
assert in the future".

**Cause.** Two writes to `@Published` sidebar state from *inside* an AppKit
delegate callback, each of which invalidates the `List` that AppKit is still
walking:

1. `AppModel.bootstrap()` → `restoreLastNote()` → `open(noteID:)` writes
   `selection`, which is the sidebar `List`'s own binding. `Task.yield()` before
   the first `refreshSidebarNow()` got the *first paint* out of the update that
   `.task` started, but it can resume inside the same run-loop iteration, so the
   selection still landed during `NSTableView`'s layout.
2. `SidebarView.expansion(of:)` wrote `model.expandedFolders` synchronously from
   `DisclosureGroup`'s setter — i.e. from inside `NSOutlineView`'s
   expand/collapse delegate.

**Fix.** `MainActor.nextRunLoopTurn()` (a `DispatchQueue.main.async`
continuation, which *cannot* resume in the same iteration) before
`restoreLastNote()`; and a view-local `expansionOverlay` so the disclosure
triangle turns in the same frame while the model write is deferred one turn.

**Guard.** `Tools/smoke.sh` now keeps a transcript of every phase and fails the
run if `reentrant operation` appears in it. It arms itself only where it can
mean something: with no window there is no table, so on a locked screen the
script says so rather than claiming a pass.

- [ ] **Manual:** run `make smoke` once on an unlocked screen and confirm
      `SMOKE ok appkit-reentrancy`.

## 6. Still open, and why

| Item | Blocked on |
|---|---|
| VoiceOver rotor / focus-order pass over the main window, ⌘K panel, organization card, Activity window, onboarding | An unlocked screen with VoiceOver enabled |
| Tab order inside sheets; ⌘1/⌘2 first-responder movement | First responder does not exist on a locked screen |
| Largest-text-size walk of the fixed-size Settings window | A person looking at it |
| Visual light/dark check of the main window and ⌘K panel | The capture needs a `WindowGroup` window |
| Reduce Motion / Increase Contrast | Not yet audited — no animation in Filaway is longer than 200 ms, and none conveys information on its own, but this has not been checked against the settings |
