import Foundation
import OSLog

struct AppDatabaseBootstrap: Sendable {
    let database: AppDatabase
    let passphraseProvider: any DatabasePassphraseProviding
    /// Image cache directory paired with `database`; a fallback database gets its own temporary one.
    let imageCacheDirectoryURL: URL
    let securityStatus: DatabaseSecurityStatus
    let startupAlertMessage: String?
}

struct AppDatabaseBootstrapper {
    private static let logger = Logger(subsystem: "ClipStash", category: "DatabaseBootstrap")

    let databasePath: String
    let passphraseProvider: KeychainDatabasePassphraseProvider
    let imageCacheDirectoryURL: URL
    let fallbackDatabasePath: String

    init(
        databasePath: String = AppDatabase.defaultPath,
        passphraseProvider: KeychainDatabasePassphraseProvider,
        imageCacheDirectoryURL: URL = ImageFileCache.defaultDirectoryURL,
        fallbackDatabasePath: String = AppDatabaseBootstrapper.makeFallbackDatabasePath()
    ) {
        self.databasePath = databasePath
        self.passphraseProvider = passphraseProvider
        self.imageCacheDirectoryURL = imageCacheDirectoryURL
        self.fallbackDatabasePath = fallbackDatabasePath
    }

    /// The fallback database never references the persistent images, so it must not share their
    /// directory: reconciling the image cache against it would delete every stored image.
    static func fallbackImageCacheDirectoryURL(forDatabasePath databasePath: String) -> URL {
        let databaseURL = URL(fileURLWithPath: databasePath)
        let directoryName = databaseURL.deletingPathExtension().lastPathComponent + "_images"
        return databaseURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    func bootstrap() -> AppDatabaseBootstrap {
        do {
            return try makePrimaryBootstrap()
        } catch {
            let primaryIssueDescription = Self.localizedDescription(for: error)
            Self.logger.error("Failed to initialize primary encrypted database: \(primaryIssueDescription, privacy: .public)")
            return makeFallbackBootstrap(issueDescription: primaryIssueDescription)
        }
    }

    private func makePrimaryBootstrap() throws -> AppDatabaseBootstrap {
        let database = try AppDatabase(path: databasePath, passphraseProvider: passphraseProvider)
        return AppDatabaseBootstrap(
            database: database,
            passphraseProvider: passphraseProvider,
            imageCacheDirectoryURL: imageCacheDirectoryURL,
            securityStatus: .keychainBacked(
                databasePath: databasePath,
                keyStorageDescription: passphraseProvider.keyStorageDescription
            ),
            startupAlertMessage: nil
        )
    }

    private func makeFallbackBootstrap(issueDescription: String) -> AppDatabaseBootstrap {
        do {
            let fallbackProvider = try EphemeralDatabasePassphraseProvider()
            let fallbackDatabase = try AppDatabase(path: fallbackDatabasePath, passphraseProvider: fallbackProvider)
            let fallbackStatus = DatabaseSecurityStatus.temporaryFallback(
                databasePath: fallbackDatabasePath,
                issueDescription: issueDescription
            )
            Self.logger.notice("Using temporary encrypted fallback database at \(fallbackDatabasePath, privacy: .public)")
            return AppDatabaseBootstrap(
                database: fallbackDatabase,
                passphraseProvider: fallbackProvider,
                imageCacheDirectoryURL: Self.fallbackImageCacheDirectoryURL(forDatabasePath: fallbackDatabasePath),
                securityStatus: fallbackStatus,
                startupAlertMessage: fallbackStatus.startupAlertMessage
            )
        } catch {
            preconditionFailure("Failed to initialize fallback database: \(error.localizedDescription)")
        }
    }

    private static func makeFallbackDatabasePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("clipstash_fallback_\(UUID().uuidString).db")
            .path
    }

    private static func localizedDescription(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
