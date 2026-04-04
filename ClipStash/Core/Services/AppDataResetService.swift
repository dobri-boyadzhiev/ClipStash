import Foundation
import OSLog

@MainActor
protocol AppDataResetting {
    func deleteAllDataAndQuit() async throws
}

protocol DatabaseResettable: Sendable {
    var path: String { get }
    func close() throws
}

/// Deletes local app data and exits the application so the next launch starts clean.
@MainActor
final class AppDataResetService: AppDataResetting {
    private let logger = Logger(subsystem: "ClipStash", category: "AppDataResetService")
    private let settings: AppSettings
    private let database: any DatabaseResettable
    private let passphraseProvider: any DatabasePassphraseProviding
    private let dataDirectoryURL: URL
    private let fileManager: FileManager
    private let prepareForReset: () -> Void
    private let terminateApplication: () -> Void
    private let setLaunchAtLoginEnabled: (Bool) -> Void

    init(
        settings: AppSettings,
        database: any DatabaseResettable,
        passphraseProvider: any DatabasePassphraseProviding,
        dataDirectoryURL: URL,
        fileManager: FileManager = .default,
        prepareForReset: @escaping () -> Void,
        terminateApplication: @escaping () -> Void,
        setLaunchAtLoginEnabled: @escaping (Bool) -> Void
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

        defer {
            terminateApplication()
        }

        var errors: [Error] = []

        do {
            try database.close()
        } catch {
            logger.error("Failed to close database: \(error.localizedDescription, privacy: .public)")
            errors.append(error)
        }

        do {
            try removeItemIfNeeded(at: dataDirectoryURL)
        } catch {
            logger.error("Failed to remove data directory: \(error.localizedDescription, privacy: .public)")
            errors.append(error)
        }

        do {
            try removeExternalDatabaseArtifactsIfNeeded()
        } catch {
            logger.error("Failed to remove external DB artifacts: \(error.localizedDescription, privacy: .public)")
            errors.append(error)
        }

        do {
            try passphraseProvider.deleteStoredPassphrase()
        } catch {
            logger.error("Failed to delete stored passphrase: \(error.localizedDescription, privacy: .public)")
            errors.append(error)
        }

        settings.resetToDefaults()
        setLaunchAtLoginEnabled(false)

        if let firstError = errors.first {
            throw firstError
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
