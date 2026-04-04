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
    
    private let repository: EntryRepository
    private let dataResetService: AppDataResetting
    
    init(
        settings: AppSettings,
        repository: EntryRepository,
        dataResetService: AppDataResetting,
        databaseSecurityStatus: DatabaseSecurityStatus
    ) {
        self.settings = settings
        self.repository = repository
        self.dataResetService = dataResetService
        self.databaseSecurityStatus = databaseSecurityStatus
    }
    
    func loadStats() async {
        totalItems = (try? await repository.totalCount()) ?? 0
        let bytes = (try? await repository.totalBytes()) ?? 0
        totalSizeMB = Double(bytes) / 1_048_576.0
    }

    var localDataDirectoryPath: String {
        AppDatabase.appSupportDirectoryURL.path
    }

    var activeDatabasePath: String {
        databaseSecurityStatus.activeDatabasePath
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
