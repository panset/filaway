import AppKit
import FilawayCore
import SwiftUI

/// Settings → AI, Figure 4 (FR-6.2, FR-6.3, FR-6.5, FR-6.6, FR-4.2, FR-4.5).
///
/// Top to bottom: the provider chooser, the connection card for whichever
/// provider is selected (and, under Ollama, its Base URL / model / Test
/// connection rows), the four form rows the mockup names, the Advanced model
/// override, the monthly usage line, and the privacy statement — which is
/// always visible, never behind a disclosure.
///
/// **The provider is the pane's one branch.** Everything below it is either
/// shared or reworded by `AIConnectionCopy`; the Advanced override is the only
/// Claude-only row, because choosing a model *is* the Ollama section (FR-6.2).
struct AISettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var isShowingKeySheet = false

    var body: some View {
        Form {
            Section {
                ForEach(AIProviderKind.allCases, id: \.self) { kind in
                    ProviderOptionRow(
                        kind: kind,
                        isSelected: model.aiProvider == kind,
                        status: model.aiProvider == kind ? model.connectionStatusLine : nil
                    ) {
                        Task { await model.selectProvider(kind) }
                    }
                }
            } header: {
                Text("Provider")
            }

            Section {
                ConnectionCard(model: model) { isShowingKeySheet = true }
                if model.aiProvider == .ollama {
                    OllamaConnectionRows(model: model)
                }
            }

            Section {
                SettingsRow(
                    title: "Auto-organize after idle",
                    detail: "How long you have to stop typing before a writing session is filed."
                ) {
                    IdleIntervalPicker(minutes: model.idleInterval)
                }

                SettingsRow(title: "Mode", detail: model.organizationMode.wrappedValue.detail) {
                    // NFR-6: the accessibility name has to be applied before
                    // `.labelsHidden()`, or AppKit's control is left nameless.
                    Picker("Mode", selection: model.organizationMode) {
                        ForEach(OrganizationMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .accessibilityLabel("Organization mode")
                    .pickerStyle(.menu)
                    .frame(width: 180)
                    .labelsHidden()
                }

                SettingsRow(
                    title: "Semantic search",
                    detail: "Keyword search keeps working either way, online or off."
                ) {
                    Toggle("Semantic search", isOn: model.semanticSearchEnabled)
                        .accessibilityLabel("Semantic search")
                        .accessibilityHint("Off keeps keyword search and stops building the index")
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                SettingsRow(
                    title: "Exclude folders from AI",
                    detail: model.exclusionDetail
                ) {
                    ExcludedFoldersPicker(model: model)
                }
            }

            Section {
                AdvancedModelSection(model: model)
            }

            Section {
                if let usage = model.usageSummary {
                    Label(usage, systemImage: "chart.bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Usage. \(usage)")
                }
                PrivacyStatementView(statement: model.privacyStatement)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingKeySheet) {
            APIKeySheet(model: model)
        }
    }
}

// MARK: - Connection card

/// "☁︎ Claude · connected · <model> · Change" (Figure 4), and its local
/// counterpart: the same card with **Test connection** where Change… is,
/// because there is no key to change (FR-6.5).
private struct ConnectionCard: View {
    @ObservedObject var model: SettingsModel
    let change: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.connectionTitle)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if model.isRefreshing || model.isTestingLocal {
                ProgressView().controlSize(.small)
            }
            if model.aiProvider == .ollama {
                Button("Test connection") { Task { await model.testLocalConnection() } }
                    .accessibilityLabel("Test the connection to the local Ollama daemon")
                    .disabled(model.isTestingLocal)
            } else {
                Button(model.hasStoredKey ? "Change…" : "Connect…", action: change)
                    .accessibilityLabel(model.hasStoredKey ? "Change API key" : "Connect an API key")
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(AIConnectionCopy.providerLabel(model.aiProvider)) connection. "
            + "\(model.connectionTitle). \(subtitle)")
    }

    /// SF Symbols stand in for Figure 4's placeholder ☁︎ glyph.
    private var symbol: String {
        switch model.status {
        case .connected: return "cloud.fill"
        case .notConfigured: return "cloud"
        case .invalidKey: return "exclamationmark.triangle.fill"
        case .offline: return "wifi.slash"
        case .rateLimited: return "hourglass"
        case .error: return "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch model.status {
        case .connected: return .accentColor
        case .invalidKey, .error: return .orange
        case .notConfigured, .offline, .rateLimited: return .secondary
        }
    }

    private var subtitle: String { model.connectionStatusLine }
}

// MARK: - The local daemon (FR-6.5, P2-02)

/// Base URL, model, and the two hints that turn a failed check into something
/// the user can act on. Only drawn when Ollama is the selected provider.
private struct OllamaConnectionRows: View {
    @ObservedObject var model: SettingsModel
    @FocusState private var baseURLFocused: Bool

    var body: some View {
        SettingsRow(
            title: "Base URL",
            detail: model.ollamaBaseURLProblem
                ?? "Where the daemon listens. Plain http is allowed for this Mac only."
        ) {
            TextField("http://localhost:11434", text: $model.ollamaBaseURLText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityLabel("Ollama base URL")
                .focused($baseURLFocused)
                .onSubmit { Task { await model.commitOllamaBaseURL() } }
                .onChange(of: baseURLFocused) { _, focused in
                    // Committing on blur as well as on ⏎: a user who types an
                    // address and clicks Test connection expects the test to
                    // use what they just typed.
                    if !focused { Task { await model.commitOllamaBaseURL() } }
                }
                .labelsHidden()
        }

        SettingsRow(title: "Model", detail: modelDetail) {
            HStack(spacing: 8) {
                Picker("Ollama model", selection: model.ollamaModel) {
                    ForEach(model.availableOllamaModelIDs(), id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .accessibilityLabel("Ollama model")
                .pickerStyle(.menu)
                .frame(width: 180)
                .labelsHidden()

                Button {
                    Task { await model.testLocalConnection() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh the list of pulled models")
                .disabled(model.isTestingLocal)
            }
        }
    }

    /// The pull command when the tag is not on the daemon, the reassurance when
    /// it is.
    private var modelDetail: String {
        if case let .error(message) = model.status, message == AIConnectionCopy.modelNotPulled {
            return AIConnectionCopy.pullHint(model: AIModel(model.ollamaModel.wrappedValue))
        }
        return "Pulled models are listed here. Refresh after an `ollama pull`."
    }
}

// MARK: - Rows

/// Figure 4's "3 min", as a stepper over `AppSettings.idleIntervalRange`.
private struct IdleIntervalPicker: View {
    @Binding var minutes: Int

    var body: some View {
        HStack(spacing: 8) {
            Text("\(minutes) min")
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
            // The name and the value go on the `Stepper` itself. Putting them
            // on the enclosing `HStack` with `children: .combine` reads well in
            // SwiftUI but leaves AppKit's `AXIncrementor` unnamed, which is
            // what VoiceOver actually lands on (NFR-6, M4-06).
            Stepper(
                "Auto-organize after idle",
                value: $minutes,
                in: CoreSettings.idleIntervalRange
            )
            .accessibilityLabel("Auto-organize after idle")
            .accessibilityValue("\(minutes) minute\(minutes == 1 ? "" : "s")")
            .labelsHidden()
        }
        .accessibilityElement(children: .contain)
    }
}

/// FR-4.5's picker: a menu of the library's folders with check marks, and
/// Figure 4's "Personal"-style summary as the button's title.
private struct ExcludedFoldersPicker: View {
    @ObservedObject var model: SettingsModel

    private var summary: String {
        let excluded = model.excludedFolders
        switch excluded.count {
        case 0: return "None"
        case 1: return excluded[0]
        case 2: return excluded.joined(separator: ", ")
        default: return "\(excluded[0]) + \(excluded.count - 1) more"
        }
    }

    var body: some View {
        Menu {
            if model.folders.isEmpty {
                Text("No folders in this library yet")
            }
            ForEach(model.folders, id: \.self) { folder in
                Toggle(folder, isOn: Binding(
                    get: { model.excludedFolders.contains(folder) },
                    set: { model.setFolderExcluded(folder, $0) }
                ))
            }
            if !model.excludedFolders.isEmpty {
                Divider()
                Button("Include everything") {
                    for folder in model.excludedFolders { model.setFolderExcluded(folder, false) }
                }
            }
        } label: {
            Text(summary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 180, alignment: .trailing)
        .accessibilityLabel("Folders excluded from AI")
        .accessibilityValue(summary)
    }
}

/// FR-6.2's "advanced override": off by default, so the house defaults ship.
///
/// **Claude-only.** Under Ollama the model *is* the Model row above — there are
/// no house defaults to override, and two pickers disagreeing about which model
/// runs would be a bug with a UI. The section says so rather than disappearing
/// without explanation.
private struct AdvancedModelSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        if model.aiProvider == .ollama {
            SettingsRow(
                title: "Advanced: choose models",
                detail: "The local provider uses the model chosen above for both organizing and search."
            ) {
                Text(model.connectionModelName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Local model in use: \(model.connectionModelName)")
            }
        } else {
            claudeRows
        }
    }

    @ViewBuilder private var claudeRows: some View {
        SettingsRow(
            title: "Advanced: choose models",
            detail: "Off means the defaults: \(AIModel.defaultOrganize.id) for organizing, "
                + "\(AIModel.defaultSearch.id) for search."
        ) {
            Toggle("Advanced model override", isOn: model.advancedModelOverride)
                .accessibilityLabel("Choose models manually")
                .toggleStyle(.switch)
                .labelsHidden()
        }

        if model.advancedModelOverride.wrappedValue {
            SettingsRow(title: "Organizing") {
                ModelPicker(label: "Organizing model", selection: model.organizeModel, model: model)
            }
            SettingsRow(title: "Search") {
                ModelPicker(label: "Search model", selection: model.searchModel, model: model)
            }
            HStack {
                Spacer()
                Button("Use defaults") { model.resetModelsToDefaults() }
                    .controlSize(.small)
            }
        }
    }
}

private struct ModelPicker: View {
    let label: String
    @Binding var selection: String
    @ObservedObject var model: SettingsModel

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(model.availableModelIDs(), id: \.self) { id in
                Text(model.displayName(forModel: id)).tag(id)
            }
        }
        .accessibilityLabel(label)
        .pickerStyle(.menu)
        .frame(width: 220)
        .labelsHidden()
    }
}
