import AppKit
import SwiftUI

/// The unified search/command bar of Figure 1 (FR-1.3): a pill with the ✦ AI
/// mark, the "Ask anything…" placeholder and a ⌘K hint, always visible in the
/// toolbar.
///
/// The field keeps keyboard focus for the whole search — ↑/↓/⏎/Esc are handled
/// here and forwarded to ``SearchCoordinator``, which owns the selection. That
/// is what lets the results panel be a plain, non-focusable overlay (ADR-025)
/// and what makes every keystroke path reachable from the headless smoke
/// driver.
struct SearchFieldView: View {

    @ObservedObject var coordinator: SearchCoordinator
    var isFocused: FocusState<Bool>.Binding

    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)

            TextField("Ask anything…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused(isFocused)
                .onChange(of: text) { _, newValue in coordinator.query(newValue) }
                .onChange(of: coordinator.text) { _, newValue in
                    // The coordinator can clear itself (Escape, ✕, result opened).
                    if newValue != text { text = newValue }
                }
                .onChange(of: isFocused.wrappedValue) { _, focused in
                    if focused { coordinator.activate() } else { coordinator.fieldLostFocus() }
                }
                // ⏎ opens the selected hit; with nothing selected it falls
                // through (M3-06 turns that into "run the semantic query").
                .onSubmit { coordinator.openSelected() }
                .onKeyPress(.upArrow) {
                    guard coordinator.isPresented else { return .ignored }
                    coordinator.moveSelection(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard coordinator.isPresented else { return .ignored }
                    coordinator.moveSelection(by: 1)
                    return .handled
                }
                .onExitCommand { coordinator.handleEscape() }
                .accessibilityLabel("Search notes")
                .accessibilityValue(coordinator.isPresented ? coordinator.statusDescription : "")
                .accessibilityHint(
                    "Type to search. Up and down arrows move through results, "
                    + "Return opens the selected note, Escape closes. "
                    + "Press Command K from anywhere to return here."
                )

            if text.isEmpty {
                Text("⌘K")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary.opacity(0.6))
                    )
                    .accessibilityHidden(true)
            } else {
                Button {
                    text = ""
                    coordinator.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(minWidth: 220, idealWidth: 340, maxWidth: 460)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.quinary)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(isFocused.wrappedValue ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                      lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused.wrappedValue = true }
    }
}

/// ⌘K should behave like every other macOS search field: focus it *and* select
/// what is already there, so the next keystroke replaces the old query.
///
/// SwiftUI's `FocusState` moves first responder but leaves the caret where it
/// was, so the selection is done through the field editor — guarded, because the
/// same call on the note's text view would select the whole document.
enum SearchFieldSelection {
    @MainActor
    static func selectAllInFocusedField() {
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isFieldEditor
        else { return }
        editor.selectAll(nil)
    }
}
