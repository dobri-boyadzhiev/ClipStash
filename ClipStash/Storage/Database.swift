import Foundation
import GRDB
import OSLog

/// Central database manager. Sets up SQLite with WAL mode, FTS5, and migrations.
final class AppDatabase: Sendable {
    private static let logger = Logger(subsystem: "ClipStash", category: "AppDatabase")
    let path: String
    let protectionMode: DatabaseProtectionMode
    let dbPool: DatabasePool

    private init(
        path: String,
        protectionMode: DatabaseProtectionMode,
        connectionSetup: @escaping @Sendable (Database) throws -> Void
    ) throws {
        self.path = path
        self.protectionMode = protectionMode
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            try connectionSetup(db)
            // WAL mode for concurrent reads + single writer
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            // Slightly faster, still safe with WAL
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }

        dbPool = try DatabasePool(path: path, configuration: config)
        try migrator.migrate(dbPool)
        try Self.applyRestrictedFilePermissionsIfNeeded(to: URL(fileURLWithPath: path))
        try Self.applyRestrictedFilePermissionsIfNeeded(to: URL(fileURLWithPath: path + "-wal"))
        try Self.applyRestrictedFilePermissionsIfNeeded(to: URL(fileURLWithPath: path + "-shm"))
    }

    /// Creates or opens the database at the given path.
    convenience init(path: String, passphraseProvider: any DatabasePassphraseProviding) throws {
        let passphrase = try passphraseProvider.passphrase()
        try self.init(path: path, protectionMode: passphraseProvider.protectionMode) { db in
            try db.usePassphrase(passphrase)
        }
    }

    func close() throws {
        try dbPool.close()
    }

    /// Temporary database for testing (uses temp file for WAL support)
    static func inMemory() throws -> AppDatabase {
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("clipstash_test_\(UUID().uuidString).db").path
        let passphraseProvider = try EphemeralDatabasePassphraseProvider()
        return try AppDatabase(path: tempFile, passphraseProvider: passphraseProvider)
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createClipboardEntry") { db in
            try db.create(table: "clipboardEntry") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("type", .text).notNull()
                t.column("textContent", .text)
                t.column("imageHash", .text)
                t.column("sourceAppBundleId", .text)
                t.column("sourceAppName", .text)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("lastUsedAt", .datetime).notNull()
                t.column("useCount", .integer).notNull().defaults(to: 1)
                t.column("contentSizeBytes", .integer).notNull().defaults(to: 0)
            }

            // Indices for common queries
            try db.create(index: "idx_clipboardEntry_lastUsedAt",
                          on: "clipboardEntry", columns: ["lastUsedAt"])
            try db.create(index: "idx_clipboardEntry_isFavorite",
                          on: "clipboardEntry", columns: ["isFavorite"])
            try db.create(index: "idx_clipboardEntry_imageHash",
                          on: "clipboardEntry", columns: ["imageHash"],
                          unique: false)
            try db.create(index: "idx_clipboardEntry_createdAt",
                          on: "clipboardEntry", columns: ["createdAt"])
        }

        migrator.registerMigration("v1_createFTS") { db in
            // Full-text search index on textContent
            try db.create(virtualTable: "clipboardEntryFts", using: FTS5()) { t in
                t.synchronize(withTable: "clipboardEntry")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("textContent")
            }
        }

        migrator.registerMigration("v2_addRtfPayload") { db in
            try db.alter(table: "clipboardEntry") { t in
                t.add(column: "rtfData", .blob)
            }
        }

        migrator.registerMigration("v3_addDedupIndex") { db in
            try db.create(index: "idx_clipboardEntry_type_textContent",
                          on: "clipboardEntry", columns: ["type", "textContent"])
        }

        migrator.registerMigration("v4_addContentHash") { db in
            try db.alter(table: "clipboardEntry") { t in
                t.add(column: "contentHash", .text)
            }
            try db.create(index: "idx_clipboardEntry_contentHash",
                          on: "clipboardEntry", columns: ["contentHash"])

            // Backfill contentHash for existing text/rtf/fileURL entries
            let cursor = try Row.fetchCursor(db, sql: """
                SELECT id, type, textContent, rtfData, imageHash
                FROM clipboardEntry WHERE contentHash IS NULL
                """)
            while let row = try cursor.next() {
                let id: Int64 = row["id"]
                let type: String = row["type"]
                let hashValue: String?

                if type == "image" {
                    hashValue = row["imageHash"] as String?
                } else if type == "rtf", let rtfData = row["rtfData"] as? Data {
                    hashValue = rtfData.sha256HexString
                } else if let text = row["textContent"] as? String, let data = text.data(using: .utf8) {
                    hashValue = data.sha256HexString
                } else {
                    hashValue = nil
                }

                if let hashValue {
                    try db.execute(
                        sql: "UPDATE clipboardEntry SET contentHash = ? WHERE id = ?",
                        arguments: [hashValue, id]
                    )
                }
            }
        }

        return migrator
    }

    /// Database file path in Application Support
    static var defaultPath: String {
        defaultURL.path
    }

    static var defaultURL: URL {
        appSupportDirectoryURL.appendingPathComponent("clipboard.db")
    }

    static var appSupportDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("ClipStash", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: appDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: appDir.path)
        } catch {
            logger.error("Failed to create application support directory: \(error.localizedDescription, privacy: .public)")
        }
        return appDir
    }

    private static func applyRestrictedFilePermissionsIfNeeded(to url: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension AppDatabase: DatabaseResettable {}
