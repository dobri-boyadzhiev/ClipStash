import AppKit
import Foundation
import LaunchAtLogin
import OSLog

@MainActor
protocol AppDataResetting {
    func deleteAllDataAndQuit() async throws
}

/// Deletes local app data and exits the application so the next launch starts clean.
@MainActor
final class AppDataResetService: AppDataResetting {
    private let logger = Logger(subsystem: "ClipStash", category: "AppDataResetService")
    private let settings: AppSettings
    private let database: AppDatabase
    private let passphraseProvider: any DatabasePassphraseProviding
    private let dataDirectoryURL: URL
    private let fileManager: FileManager
    private let prepareForReset: () -> Void
    private let terminateApplication: () -> Void
    private let setLaunchAtLoginEnabled: (Bool) -> Void

    init(
        settings: AppSettings,
        database: AppDatabase,
        passphraseProvider: any DatabasePassphraseProviding,
        dataDirectoryURL: URL = AppDatabase.appSupportDirectoryURL,
        fileManager: FileManager = .default,
        prepareForReset: @escaping () -> Void,
        terminateApplication: @escaping () -> Void = { NSApp.terminate(nil) },
        setLaunchAtLoginEnabled: @escaping (Bool) -> Void = { LaunchAtLogin.isEnabled = $0 }
    ) {
        self.settings = settings
        self.database = database
        self.passphraseProvider = passphraseProvider
        self.dataDirectoryURL = dataDirectoryURL
        self.fileManager = fileManager
        self.prepareForReset = prepareForReset
        self.terminateApplication = terminateApplication
        self.setLaunchAtLoginEnabled = setLaunchAtLoginEnabled
    }

    func deleteAllDataAndQuit() async throws {
        prepareForReset()

        do {
            try database.close()
            try removeItemIfNeeded(at: dataDirectoryURL)
            try removeExternalDatabaseArtifactsIfNeeded()
            try passphraseProvider.deleteStoredPassphrase()
            settings.resetToDefaults()
            setLaunchAtLoginEnabled(false)
            terminateApplication()
        } catch {
            logger.error("Failed to delete app data: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func removeExternalDatabaseArtifactsIfNeeded() throws {
        let databaseURL = URL(fileURLWithPath: database.path).standardizedFileURL
        let dataDirectoryURL = dataDirectoryURL.standardizedFileURL
        guard !isLocatedInside(databaseURL, directoryURL: dataDirectoryURL) else { return }

        try removeItemIfNeeded(at: databaseURL)
        try removeItemIfNeeded(at: URL(fileURLWithPath: databaseURL.path + "-wal"))
        try removeItemIfNeeded(at: URL(fileURLWithPath: databaseURL.path + "-shm"))
    }

    private func isLocatedInside(_ url: URL, directoryURL: URL) -> Bool {
        let filePath = url.path
        let directoryPath = directoryURL.path
        return filePath == directoryPath || filePath.hasPrefix(directoryPath + "/")
    }

    private func removeItemIfNeeded(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
