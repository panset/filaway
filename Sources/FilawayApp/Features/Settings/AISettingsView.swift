import AppKit
import FilawayCore
import SwiftUI

/// Settings → AI, Figure 4 (FR-6.2, FR-6.3, FR-6.5, FR-6.6, FR-4.2, FR-4.5).
///
/// Top to bottom: the connection card, the disabled local-model slot, the four
/// form rows the mockup names, the Advanced model override, the monthly usage
/// line, and the privacy statement — which is always visible, never behind a
/// disclosure.
struct AISettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var isShowingKeySheet = false

    var body: some View {
        Form {
            Section {
                ConnectionCard(model: model) { isShowingKeySheet = true }
                // Figure 3's second option card, shared with onboarding.
                LocalModelOptionRow()
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
                    detail: "Nothing in an excluded folder is ever sent to Claude."
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
                PrivacyStatementView(notesPath: model.notesRootDisplayPath)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingKeySheet) {
            APIKeySheet(model: model)
        }
    }
}

// MARK: - Connection card

/// "☁︎ Claude · connected · <model> · Change" (Figure 4).
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
            }

            Spacer()

            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button(model.hasStoredKey ? "Change…" : "Connect…", action: change)
                .accessibilityLabel(model.hasStoredKey ? "Change API key" : "Connect an API key")
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude connection. \(model.connectionTitle). \(subtitle)")
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

    private var subtitle: String {
        switch model.status {
        case .connected: return model.connectionModelName
        case .notConfigured: return "Capture and keyword search work without a key."
        case .invalidKey: return "The stored key was rejected. Enter a new one."
        case .offline: return "The API is unreachable — filing will resume when it is back."
        case .rateLimited: return "Rate limited; organization is queued."
        case let .error(message): return message
        }
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
private struct AdvancedModelSection: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
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
