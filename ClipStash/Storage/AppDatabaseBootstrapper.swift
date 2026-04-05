import Foundation
import OSLog

struct AppDatabaseBootstrap: Sendable {
    let database: AppDatabase
    let passphraseProvider: any DatabasePassphraseProviding
    let securityStatus: DatabaseSecurityStatus
    let startupAlertMessage: String?
}

struct AppDatabaseBootstrapper {
    private static let logger = Logger(subsystem: "ClipStash", category: "DatabaseBootstrap")

    let databasePath: String
    let passphraseProvider: KeychainDatabasePassphraseProvider
    let fallbackDatabasePath: String

    init(
        databasePath: String = AppDatabase.defaultPath,
        passphraseProvider: KeychainDatabasePassphraseProvider,
        fallbackDatabasePath: String = AppDatabaseBootstrapper.makeFallbackDatabasePath()
    ) {
        self.databasePath = databasePath
        self.passphraseProvider = passphraseProvider
        self.fallbackDatabasePath = fallbackDatabasePath
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
