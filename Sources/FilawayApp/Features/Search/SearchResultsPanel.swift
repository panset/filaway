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
/// Keyword mode draws a ranked list. Ask mode draws Figure 2b: the Find/Ask
/// toggle in the header, the best-match answer card, then the ranked notes,
/// with an FR-5.5 notice and the index status in the footer.
struct SearchResultsPanel: View {

    @ObservedObject var coordinator: SearchCoordinator

    /// Enough for ~6 rows; the list scrolls past that.
    private let maxHeight: CGFloat = 372

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            caption

            if coordinator.mode == .semantic {
                semanticBody
            } else if coordinator.showsEmptyState {
                emptyState
            } else {
                resultList
            }

            footer
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
            Image(systemName: captionSymbol)
                .font(.system(size: 9, weight: .semibold))
                .accessibilityHidden(true)
            Text(coordinator.statusDescription)
                .font(.system(size: 10, weight: .medium))
            if let hint = coordinator.askHint {
                Text("·")
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tint)
            }
            Spacer(minLength: 0)
            if coordinator.isAskAvailable {
                modeToggle
            } else if coordinator.itemCount > 0 {
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

    private var captionSymbol: String {
        if coordinator.mode == .semantic { return "sparkles" }
        return coordinator.isShowingRecents ? "clock" : "magnifyingglass"
    }

    /// Figure 2b's explicit override. Switching keeps the text (FR-5.1).
    private var modeToggle: some View {
        Picker("Search mode", selection: Binding(
            get: { coordinator.mode },
            set: { coordinator.setMode($0) }
        )) {
            ForEach(SearchMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
        .accessibilityLabel("Search mode")
        .accessibilityHint("Find searches titles and text. Ask answers a question about your notes.")
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
                        .onHover { inside in if inside { coordinator.hover(index: index) } }
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

    // MARK: - Semantic (M3-06, Figure 2b)

    @ViewBuilder
    private var semanticBody: some View {
        if coordinator.askedQuery == nil {
            askPrompt
        } else if coordinator.isRetrieving {
            progress("Searching…")
        } else if coordinator.itemCount == 0 && !coordinator.isAsking {
            semanticEmptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let card = coordinator.answerCard {
                            AnswerCardView(
                                card: card,
                                source: coordinator.answerSource,
                                isSelected: coordinator.selectedIndex == 0,
                                onOpen: { coordinator.open(.answer(card)) },
                                onCopy: { coordinator.copyAnswerSnippet() }
                            )
                            .id(SemanticRowID.card)
                            .onHover { inside in if inside { coordinator.hover(index: 0) } }
                            .padding(.bottom, 4)
                        } else if coordinator.isAsking {
                            // The list is already up; only the card is pending.
                            progress("Reading the best matches…")
                                .padding(.bottom, 4)
                        }

                        ForEach(Array(coordinator.semanticNotes.enumerated()), id: \.element.id) { offset, note in
                            let index = offset + (coordinator.answerCard == nil ? 0 : 1)
                            SemanticResultRow(
                                note: note,
                                isSelected: index == coordinator.selectedIndex,
                                position: index + 1,
                                total: coordinator.itemCount
                            )
                            .id(SemanticRowID.note(note.id))
                            .contentShape(Rectangle())
                            .onTapGesture { coordinator.open(.note(note)) }
                            .onHover { inside in if inside { coordinator.hover(index: index) } }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: maxHeight)
                .scrollBounceBehavior(.basedOnSize)
                .onChange(of: coordinator.selectedIndex) { _, index in
                    guard let target = semanticRowID(at: index) else { return }
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }

    private enum SemanticRowID: Hashable {
        case card
        case note(NoteID)
    }

    private func semanticRowID(at index: Int) -> SemanticRowID? {
        guard index >= 0 else { return nil }
        if coordinator.answerCard != nil {
            if index == 0 { return .card }
            let offset = index - 1
            guard coordinator.semanticNotes.indices.contains(offset) else { return nil }
            return .note(coordinator.semanticNotes[offset].id)
        }
        guard coordinator.semanticNotes.indices.contains(index) else { return nil }
        return .note(coordinator.semanticNotes[index].id)
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }

    private var askPrompt: some View {
        VStack(spacing: 4) {
            Text("Ask a question about your notes")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("“curl command to fetch documents”, “the thing I edited two days ago about auth”")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    private var semanticEmptyState: some View {
        VStack(spacing: 4) {
            Text("No good match")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Nothing in your notes answers that. Try Find for a literal search.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No good match for \(coordinator.text)")
    }

    // MARK: - Footer (FR-5.4, FR-5.5)

    @ViewBuilder
    private var footer: some View {
        let notice = coordinator.mode == .semantic ? coordinator.availabilityNotice : nil
        let indexing = coordinator.indexStatusDescription
        if notice != nil || indexing != nil {
            Divider()
            HStack(spacing: 6) {
                if let notice {
                    Image(systemName: coordinator.noticeOpensSettings ? "key" : "wifi.slash")
                        .font(.system(size: 9, weight: .semibold))
                        .accessibilityHidden(true)
                    if coordinator.noticeOpensSettings {
                        Button(notice) { coordinator.onOpenAISettings?() }
                            .buttonStyle(.link)
                            .font(.system(size: 10))
                    } else {
                        Text(notice).font(.system(size: 10))
                    }
                }
                Spacer(minLength: 0)
                if let indexing {
                    Text(indexing)
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

/// Figure 2b's best-match answer card (FR-5.2).
///
/// "Best match · Commands / curl · edited 2d ago", the snippet as a monospaced
/// code block with a Copy button, and — for anything but the snippet — a click
/// target that opens the note scrolled to the chunk the answer came from.
struct AnswerCardView: View {

    let card: AnswerCard
    let source: AnswerSource
    let isSelected: Bool
    var onOpen: () -> Void
    var onCopy: () -> String?

    @State private var isHovering = false
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            snippet
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.quinary))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(source == .model ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            Text("Best match")
                .font(.system(size: 10, weight: .semibold))
            Text("·").font(.system(size: 10)).accessibilityHidden(true)
            Text(card.sourceLabel)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            Text("·").font(.system(size: 10)).accessibilityHidden(true)
            Text("edited \(RelativeTime.label(for: card.modified))")
                .font(.system(size: 10))
                .fixedSize()
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var snippet: some View {
        if card.isCode {
            HStack(alignment: .top, spacing: 6) {
                Text(card.snippetText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.background.opacity(0.6))
                    )
                    .overlay(alignment: .topTrailing) { copyButton.padding(4) }
            }
        } else {
            Text(card.snippetText)
                .font(.system(size: 11))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        if isHovering || isSelected {
            Button {
                didCopy = onCopy() != nil
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.regularMaterial)
            )
            .accessibilityLabel("Copy snippet")
        }
    }

    private var accessibilityLabel: String {
        var parts = ["Best match", card.sourceLabel, "edited \(RelativeTime.label(for: card.modified))"]
        parts.append(card.isCode ? "code snippet: \(card.snippetText)" : card.snippetText)
        if source == .localHeuristic { parts.append("found locally") }
        return parts.joined(separator: ", ")
    }
}

/// One ranked note under the card: title · matching heading or snippet ·
/// relative time (Figure 2b's "Docker cheats · curl healthcheck · 4d ago").
struct SemanticResultRow: View {

    let note: RankedNote
    let isSelected: Bool
    let position: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(note.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 6)
                Text(RelativeTime.label(for: note.modified))
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .fixedSize()
            }
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 11, design: note.bestChunk.kind == .code ? .monospaced : .default))
                    .foregroundStyle(.secondary)
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

    /// The heading the match sits under, minus the note title the chunker puts
    /// in front of it — the row already shows that.
    private var subtitle: String {
        note.bestChunk.headingPath.dropFirst().joined(separator: " › ")
    }

    /// One line of the matching chunk, whitespace collapsed.
    private var preview: String {
        let lines = note.bestChunk.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("~~~") && !$0.contains(" › ") }
        return lines.first.map { String($0.prefix(140)) } ?? ""
    }

    private var accessibilityLabel: String {
        var parts = [note.title]
        if !subtitle.isEmpty { parts.append("in \(subtitle)") }
        parts.append("edited \(RelativeTime.label(for: note.modified))")
        if !preview.isEmpty { parts.append(preview) }
        parts.append("result \(position) of \(total)")
        return parts.joined(separator: ", ")
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
