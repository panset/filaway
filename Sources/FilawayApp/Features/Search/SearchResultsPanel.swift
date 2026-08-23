import FilawayCore
import SwiftUI

/// Hosts the ⌘K panel over the whole window.
///
/// Its own `@ObservedObject` matters: `ShellView` observes `AppModel`, and
/// ``SearchCoordinator`` is a separate object, so without this wrapper the
/// overlay would never notice the panel opening.
struct SearchOverlay: View {

    @ObservedObject var coordinator: SearchCoordinator
    /// Lets the shell drop focus when the panel is dismissed by a click.
    var onDismissedByClick: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if coordinator.isPresented {
                // Click-off dismissal, Spotlight-style. Transparent, so the
                // window still reads as one surface.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        coordinator.close()
                        onDismissedByClick()
                    }
                SearchResultsPanel(coordinator: coordinator)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .allowsHitTesting(coordinator.isPresented)
        .animation(.easeOut(duration: 0.12), value: coordinator.isPresented)
    }
}

/// The ⌘K results panel of Figure 2b: a floating card under the toolbar's
/// search field with a ranked list of hits beneath it.
///
/// It is deliberately **not** focusable. The search field keeps first responder
/// for the whole interaction and forwards ↑/↓/⏎/Esc to
/// ``SearchCoordinator``; the panel only draws what the coordinator says is
/// selected. See ADR-034 for why that beats an `NSPopover`.
///
/// M1 renders keyword hits only. The semantic answer card and the Find/Ask
/// toggle of Figure 2b are M3-06 — the two spots they go are marked below.
struct SearchResultsPanel: View {

    @ObservedObject var coordinator: SearchCoordinator

    /// Enough for ~6 rows; the list scrolls past that.
    private let maxHeight: CGFloat = 372

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // MARK: - Extension point (M3-06)
            // Figure 2b's Find/Ask toggle goes here, and the best-match answer
            // card (code block + Copy + source note + edited-ago) goes between
            // it and the list, above `caption`. Both are semantic-only, so both
            // stay out of M1: keyword search must work with no AI at all
            // (FR-5.5).

            caption

            if coordinator.showsEmptyState {
                emptyState
            } else {
                resultList
            }
        }
        .frame(width: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Search results")
    }

    // MARK: - Caption

    private var caption: some View {
        HStack(spacing: 6) {
            Image(systemName: coordinator.isShowingRecents ? "clock" : "magnifyingglass")
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(coordinator.statusDescription)
                .font(.system(size: 10, weight: .medium))
            Spacer(minLength: 0)
            if !coordinator.results.isEmpty {
                Text("↑↓ to move · ⏎ to open · esc to close")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 6)
    }

    // MARK: - List

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(coordinator.results.enumerated()), id: \.element.id) { index, hit in
                        SearchResultRow(
                            hit: hit,
                            isSelected: index == coordinator.selectedIndex,
                            position: index + 1,
                            total: coordinator.results.count
                        )
                        .id(hit.id)
                        .contentShape(Rectangle())
                        .onTapGesture { coordinator.open(hit) }
                        .onHover { inside in if inside { coordinator.select(index: index) } }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: maxHeight)
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: coordinator.selectedIndex) { _, index in
                guard coordinator.results.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(coordinator.results[index].id, anchor: .center)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Text("No matches")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Keyword search looks at note titles and body text.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No matches for \(coordinator.text)")
    }
}

/// One hit: title · relative modified time on the first line, the snippet with
/// the match highlighted on the second, the folder path alongside the title.
struct SearchResultRow: View {

    let hit: KeywordHit
    let isSelected: Bool
    let position: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(hit.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                Text(RelativeTime.label(for: hit.modified))
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .fixedSize()
            }
            if !hit.snippet.isEmpty {
                highlightedSnippet
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// `Commands / Docker` — the note's folder, or nothing at the Library root.
    private var folder: String {
        let path = PathRules.folderPath(of: hit.relativePath)
        guard !path.isEmpty else { return "" }
        return path.replacingOccurrences(of: "/", with: " / ")
    }

    /// The snippet in secondary, with the matched span in primary + bold — the
    /// "snippet with the match highlighted" of Figure 2b.
    ///
    /// Three concatenated `Text` runs rather than an `AttributedString`: the
    /// range from `SearchService` is UTF-16 (ADR-019), which `NSString`
    /// slices exactly, and `Text + Text` keeps one line-breaking context so
    /// truncation still works.
    private var highlightedSnippet: Text {
        let plain = Text(hit.snippet).foregroundStyle(.secondary)
        guard let match = hit.snippetRange else { return plain }
        let snippet = hit.snippet as NSString
        let range = match.nsRange
        guard range.location >= 0, range.length > 0,
              range.upperBound <= snippet.length else { return plain }
        return Text(snippet.substring(to: range.location)).foregroundStyle(.secondary)
            + Text(snippet.substring(with: range)).foregroundStyle(.primary).bold()
            + Text(snippet.substring(from: range.upperBound)).foregroundStyle(.secondary)
    }

    private var accessibilityLabel: String {
        var parts = [hit.title]
        if !folder.isEmpty { parts.append("in \(folder)") }
        parts.append("edited \(RelativeTime.label(for: hit.modified))")
        if !hit.snippet.isEmpty { parts.append(hit.snippet) }
        parts.append("result \(position) of \(total)")
        return parts.joined(separator: ", ")
    }
}
