import LaunchAtLogin
import SwiftUI

/// Reusable settings content, shown inline in the clipboard panel and as a fallback scene.
struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        SettingsContentView(viewModel: viewModel)
            .frame(width: 480, height: 420)
    }
}

struct SettingsContentView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject private var settings: AppSettings
    @State private var showDeleteDataConfirmation = false
    @State private var showAdvancedDataDetails = false

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settings)
    }

    var body: some View {
        Form {
            Section("History") {
                Stepper("Max items: \(settings.maxItems)", value: $settings.maxItems, in: 10...100_000, step: 100)
                Stepper("Storage limit: \(storageLimitLabel)", value: $settings.maxCacheSizeMB, in: 256...20_480, step: 256)
            }

            Section("Behavior") {
                Toggle("Strip whitespace", isOn: $settings.stripWhitespace)
                Toggle("Confirm before clearing", isOn: $settings.confirmBeforeClear)
            }

            Section("AI Assistant (Ollama)") {
                Toggle("Enable AI Assistant", isOn: $settings.isAIEnabled)

                if settings.isAIEnabled {
                    TextField("Host URL", text: $settings.ollamaUrl)
                        .onChange(of: settings.ollamaUrl) { _, _ in
                            viewModel.loadAIModels()
                        }

                    if viewModel.isFetchingModels {
                        HStack {
                            Text("Model Name")
                            Spacer()
                            ProgressView().controlSize(.small)
                        }
                    } else if viewModel.availableAIModels.isEmpty {
                        HStack {
                            TextField("Model Name", text: $settings.ollamaModel)

                            Button {
                                viewModel.loadAIModels()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Retry fetching models")
                        }

                        if let error = viewModel.fetchModelsError {
                            Text("Failed to load models: \(error)")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    } else {
                        HStack {
                            Picker("Model Name", selection: $settings.ollamaModel) {
                                ForEach(viewModel.availableAIModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            Button {
                                viewModel.loadAIModels()
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Refresh models")
                        }
                    }

                    Picker("Improvement Mode", selection: $settings.aiPromptMode) {
                        Text("Fix Grammar & Spelling").tag(0)
                        Text("Make it Professional").tag(1)
                        Text("Custom Prompt").tag(2)
                    }

                    if settings.aiPromptMode == 2 {
                        VStack(alignment: .leading) {
                            Text("Custom Instructions:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextEditor(text: $settings.customAIPrompt)
                                .frame(height: 60)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.2)))
                        }
                    }
                }
            }

            Section("System") {
                LaunchAtLoginToggle()
            }

            Section("Panel") {
                Stepper("Panel width: \(settings.windowWidthPercentage)%", value: $settings.windowWidthPercentage, in: 10...100, step: 5)
            }

            Section("Global Shortcuts") {
                LabeledContent("Toggle panel") { Text("⌃⌘V").foregroundStyle(.secondary) }
                LabeledContent("Private mode") { Text("⌘⇧P").foregroundStyle(.secondary) }
                LabeledContent("Previous entry") { Text("⌘⇧←").foregroundStyle(.secondary) }
                LabeledContent("Next entry") { Text("⌘⇧→").foregroundStyle(.secondary) }
            }

            Section("Data") {
                Text("ClipStash stores its database and cached images locally on this Mac.")
                    .foregroundStyle(.secondary)

                LabeledContent("Protection") {
                    Text(viewModel.databaseSecurityStatus.protectionLabel)
                        .foregroundStyle(viewModel.databaseSecurityStatus.isFallback ? .orange : .secondary)
                }

                Text(viewModel.databaseSecurityStatus.detailText)
                    .foregroundStyle(viewModel.databaseSecurityStatus.isFallback ? .orange : .secondary)

                LabeledContent("Key storage") {
                    Text(viewModel.databaseSecurityStatus.keyStorageDescription)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Advanced details", isExpanded: $showAdvancedDataDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Active database")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(viewModel.activeDatabasePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text("Application Support")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Text(viewModel.localDataDirectoryPath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.top, 4)
                }

                Text("Delete All Data permanently removes clipboard history, cached images, and saved settings. The app will quit after cleanup.")
                    .foregroundStyle(.secondary)

                if showDeleteDataConfirmation {
                    HStack {
                        Button("Cancel") {
                            showDeleteDataConfirmation = false
                            viewModel.deleteAllDataErrorMessage = nil
                        }
                        .disabled(viewModel.isDeletingAllData)

                        Spacer()

                        Button("Delete and Quit", role: .destructive) {
                            Task { await viewModel.deleteAllData() }
                        }
                        .disabled(viewModel.isDeletingAllData)
                    }
                } else {
                    Button("Delete All Data", role: .destructive) {
                        showDeleteDataConfirmation = true
                    }
                    .disabled(viewModel.isDeletingAllData)
                }

                if viewModel.isDeletingAllData {
                    ProgressView("Deleting local data…")
                }

                if let errorMessage = viewModel.deleteAllDataErrorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("About") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ClipStash")
                        .font(.headline)
                    Text("Clipboard History Manager")
                        .foregroundStyle(.secondary)
                    Text(appVersionLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Divider()
                    Text("Items: \(viewModel.totalItems)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Size: \(String(format: "%.1f", viewModel.totalSizeMB)) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            Task {
                await viewModel.loadStats()
            }
            viewModel.loadAIModels()
        }
        .onChange(of: settings.isAIEnabled) { _, isEnabled in
            if isEnabled {
                viewModel.loadAIModels()
            }
        }
    }

    private var storageLimitLabel: String {
        if settings.maxCacheSizeMB >= 1024 {
            let gigabytes = Double(settings.maxCacheSizeMB) / 1024.0
            if gigabytes.rounded() == gigabytes {
                return "\(Int(gigabytes)) GB"
            }
            return String(format: "%.1f GB", gigabytes)
        }

        return "\(settings.maxCacheSizeMB) MB"
    }

    private var appVersionLabel: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildVersion) {
        case let (short?, build?) where short != build:
            return "v\(short) (\(build))"
        case let (short?, _):
            return "v\(short)"
        case let (_, build?):
            return "v\(build)"
        default:
            return "Version unavailable"
        }
    }
}
