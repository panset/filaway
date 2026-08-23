import SwiftUI

/// The unified search/command bar of Figure 1 (FR-1.3): a pill with the ✦ AI
/// mark, the "Ask anything…" placeholder and a ⌘K hint, always visible in the
/// toolbar.
///
/// M1-09 ships the field and the shortcut; every keystroke goes to
/// ``SearchCoordinator/query(_:)``. The results popover is M1-12.
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
                    // The coordinator can clear itself (Escape, result opened).
                    if newValue != text { text = newValue }
                }
                .onSubmit { coordinator.query(text) }
                .onExitCommand {
                    coordinator.dismiss()
                    isFocused.wrappedValue = false
                }
                .accessibilityLabel("Search notes")
                .accessibilityHint("Type to search; press Command K from anywhere to return here")

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
                    coordinator.dismiss()
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
