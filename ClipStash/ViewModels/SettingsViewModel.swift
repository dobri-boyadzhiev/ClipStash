import Foundation
import SwiftUI

/// ViewModel for the inline settings content and fallback Settings scene.
@MainActor
final class SettingsViewModel: ObservableObject {
    let settings: AppSettings
    let databaseSecurityStatus: DatabaseSecurityStatus

    @Published var totalItems: Int = 0
    @Published var totalSizeMB: Double = 0
    @Published var isDeletingAllData: Bool = false
    @Published var deleteAllDataErrorMessage: String?

    @Published var availableAIModels: [String] = []
    @Published var isFetchingModels: Bool = false
    @Published var fetchModelsError: String? = nil

    private var loadModelsTask: Task<Void, Never>?

    private let repository: EntryRepository
    private let dataResetService: AppDataResetting
    private let database: AppDatabase
    private let databasePassphraseProvider: DatabasePassphraseProviding

    @Published var isProcessingBackup = false
    @Published var backupErrorMessage: String? = nil

    init(
        settings: AppSettings,
        repository: EntryRepository,
        dataResetService: AppDataResetting,
        database: AppDatabase,
        databasePassphraseProvider: DatabasePassphraseProviding,
        databaseSecurityStatus: DatabaseSecurityStatus
    ) {
        self.settings = settings
        self.repository = repository
        self.dataResetService = dataResetService
        self.database = database
        self.databasePassphraseProvider = databasePassphraseProvider
        self.databaseSecurityStatus = databaseSecurityStatus
    }

    func loadStats() async {
        totalItems = (try? await repository.totalCount()) ?? 0
        let bytes = (try? await repository.totalBytes()) ?? 0
        totalSizeMB = Double(bytes) / 1_048_576.0
    }

    func loadAIModels() {
        guard settings.isAIEnabled else { return }

        loadModelsTask?.cancel()

        loadModelsTask = Task { @MainActor in
            // Debounce fetching models when typing URLs quickly
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            isFetchingModels = true
            fetchModelsError = nil

            do {
                let models = try await OllamaService.fetchAvailableModels(urlString: settings.ollamaUrl)

                guard !Task.isCancelled else { return }

                availableAIModels = models

                if !models.isEmpty && !models.contains(settings.ollamaModel) {
                    settings.ollamaModel = models.first!
                }
            } catch {
                guard !Task.isCancelled else { return }
                print("Failed to fetch AI models: \(error)")
                availableAIModels = []
                fetchModelsError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }

            isFetchingModels = false
        }
    }

    var localDataDirectoryPath: String {
        AppDatabase.appSupportDirectoryURL.path
    }

    var activeDatabasePath: String {
        databaseSecurityStatus.activeDatabasePath
    }

    func exportBackup(to url: URL, password: String) async {
        isProcessingBackup = true
        backupErrorMessage = nil
        do {
            try await BackupService.shared.exportBackup(to: url, password: password, database: database, passphraseProvider: databasePassphraseProvider)
            isProcessingBackup = false
        } catch {
            isProcessingBackup = false
            backupErrorMessage = error.localizedDescription
        }
    }

    func importBackup(from url: URL, password: String) async {
        isProcessingBackup = true
        backupErrorMessage = nil
        do {
            try await BackupService.shared.importBackup(from: url, password: password)
            // It will trigger a restart automatically through notification or AppDelegate
            isProcessingBackup = false
        } catch {
            isProcessingBackup = false
            backupErrorMessage = error.localizedDescription
        }
    }

    func deleteAllData() async {
        guard !isDeletingAllData else { return }

        isDeletingAllData = true
        deleteAllDataErrorMessage = nil

        do {
            try await dataResetService.deleteAllDataAndQuit()
        } catch {
            deleteAllDataErrorMessage = (error as? LocalizedError)?.errorDescription ?? "Failed to delete ClipStash data."
            isDeletingAllData = false
        }
    }
}
