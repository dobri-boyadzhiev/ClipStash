import Foundation
import GRDB
import CryptoKit
import CommonCrypto
import ZIPFoundation
import AppKit

enum BackupError: LocalizedError {
    case invalidPassphrase
    case backupCorrupted
    case keychainAccessFailed
    case internalError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidPassphrase: return "Invalid password. The backup could not be decrypted."
        case .backupCorrupted: return "The backup file is corrupted or missing necessary files."
        case .keychainAccessFailed: return "Failed to access or update the Keychain."
        case .internalError(let error): return "Internal error: \(error.localizedDescription)"
        }
    }
}

final class BackupService: @unchecked Sendable {
    static let shared = BackupService()
    private let fileManager = FileManager.default
    private var isBusy = false

    // Backup file format constants
    private static let backupMagic = Data([0x43, 0x53, 0x42]) // "CSB"
    private static let backupFormatVersion: UInt8 = 2
    private static let pbkdf2Iterations: UInt32 = 600_000

    /// Called by importBackup to request the app close its database before restore.
    /// The closure must close the DB, stop monitors, etc., and then return.
    var onCloseDatabaseForRestore: (@Sendable () async -> Void)?

    private init() {}

    private func guardNotBusy() throws {
        guard !isBusy else {
            throw BackupError.internalError(NSError(domain: "BackupService", code: -1, userInfo: [NSLocalizedDescriptionKey: "A backup operation is already in progress."]))
        }
    }

    // MARK: - Export
    func exportBackup(to url: URL, password: String, database: AppDatabase, passphraseProvider: DatabasePassphraseProviding) async throws {
        try guardNotBusy()
        isBusy = true
        defer { isBusy = false }
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contentDir = tempDir.appendingPathComponent("content")
        try fileManager.createDirectory(at: contentDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        // 1. Backup DB safely
        let backupDBURL = contentDir.appendingPathComponent("clipboard.db")
        try await Task.detached {
            // SQLCipher does not support GRDB's .backup() API.
            // We use a write block to ensure no other writers are active,
            // then copy the main database file along with its WAL and SHM files.
            try database.dbPool.write { db in
                try FileManager.default.copyItem(atPath: database.path, toPath: backupDBURL.path)

                let walPath = database.path + "-wal"
                if FileManager.default.fileExists(atPath: walPath) {
                    try FileManager.default.copyItem(atPath: walPath, toPath: backupDBURL.path + "-wal")
                }

                let shmPath = database.path + "-shm"
                if FileManager.default.fileExists(atPath: shmPath) {
                    try FileManager.default.copyItem(atPath: shmPath, toPath: backupDBURL.path + "-shm")
                }
            }
        }.value

        // 2. Copy Images
        let imagesSourceURL = ImageFileCache.defaultDirectoryURL
        let imagesDestURL = contentDir.appendingPathComponent("images")
        if fileManager.fileExists(atPath: imagesSourceURL.path) {
            try fileManager.copyItem(at: imagesSourceURL, to: imagesDestURL)
        } else {
            try fileManager.createDirectory(at: imagesDestURL, withIntermediateDirectories: true)
        }

        // 3. Create Manifest
        let keychainData = try passphraseProvider.passphrase()
        let keychainBase64 = keychainData.base64EncodedString()
        let manifest = await MainActor.run { BackupManifest(keychainPassphraseBase64: keychainBase64, settings: AppSettings.shared) }
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: contentDir.appendingPathComponent("manifest.json"))

        // 4. Zip the content directory
        let archiveURL = tempDir.appendingPathComponent("archive.zip")
        try fileManager.zipItem(at: contentDir, to: archiveURL, shouldKeepParent: false)
        let zipData = try Data(contentsOf: archiveURL)

        // 5. Encrypt with PBKDF2 (v2 format)
        let salt = try KeychainDatabasePassphraseProvider.generateRandomKey(byteCount: 32)
        let key = try Self.deriveKeyPBKDF2(password: password, salt: salt)

        let sealedBox = try AES.GCM.seal(zipData, using: key)
        var finalData = Data()
        finalData.append(Self.backupMagic)
        finalData.append(Self.backupFormatVersion)
        withUnsafeBytes(of: Self.pbkdf2Iterations.bigEndian) { finalData.append(contentsOf: $0) }
        finalData.append(contentsOf: salt)
        finalData.append(contentsOf: sealedBox.nonce)
        finalData.append(contentsOf: sealedBox.ciphertext)
        finalData.append(contentsOf: sealedBox.tag)

        try finalData.write(to: url)
    }

    // MARK: - Import
    func importBackup(from url: URL, password: String) async throws {
        try guardNotBusy()
        isBusy = true
        defer { isBusy = false }

        let fileData = try Data(contentsOf: url)
        let decryptedZipData = try Self.decryptBackupData(fileData, password: password)

        let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent("archive.zip")
        try decryptedZipData.write(to: archiveURL)

        let extractDir = tempDir.appendingPathComponent("extracted")
        try fileManager.unzipItem(at: archiveURL, to: extractDir)

        let manifestURL = extractDir.appendingPathComponent("manifest.json")
        let dbURL = extractDir.appendingPathComponent("clipboard.db")
        let imagesURL = extractDir.appendingPathComponent("images")

        guard fileManager.fileExists(atPath: manifestURL.path),
              fileManager.fileExists(atPath: dbURL.path) else {
            throw BackupError.backupCorrupted
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: manifestData)
        guard BackupManifest.supportedVersions.contains(manifest.version) else {
            throw BackupError.internalError(NSError(domain: "BackupService", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported backup version \(manifest.version). This app supports versions \(BackupManifest.supportedVersions.lowerBound)–\(BackupManifest.supportedVersions.upperBound)."
            ]))
        }
        guard let keychainSecret = Data(base64Encoded: manifest.keychainPassphraseBase64) else {
            throw BackupError.backupCorrupted
        }

        try validateImportedDatabase(at: dbURL.path, passphrase: keychainSecret)

        // At this point we have valid data. Time to restore.
        // For UI reasons, we can perform the actual hot-swap in AppDelegate.
        // We will call AppDataResetService methods and then overwrite.

        let targetDBPath = AppDatabase.defaultPath
        let targetImagesPath = ImageFileCache.defaultDirectoryURL.path

        // Need a closure to execute the final steps to avoid cyclic dependencies
        // Or we just throw a notification or let AppDelegate handle the swap.
        // Better: Do it here and then tell AppDelegate to restart.

        // 1. Close current DB (awaits until the app confirms closure)
        if let closeDatabase = onCloseDatabaseForRestore {
            await closeDatabase()
        }

        // 2. Rename existing data to .backup for atomic swap
        let backupDBPath = targetDBPath + ".restore-backup"
        let backupImagesPath = targetImagesPath + ".restore-backup"

        // Clean up any stale backup from a previous failed restore
        try? fileManager.removeItem(atPath: backupDBPath)
        try? fileManager.removeItem(atPath: backupDBPath + "-shm")
        try? fileManager.removeItem(atPath: backupDBPath + "-wal")
        try? fileManager.removeItem(atPath: backupImagesPath)

        // Rename current files to .backup (atomic — single rename per file)
        if fileManager.fileExists(atPath: targetDBPath) {
            try fileManager.moveItem(atPath: targetDBPath, toPath: backupDBPath)
        }
        if fileManager.fileExists(atPath: targetDBPath + "-wal") {
            try fileManager.moveItem(atPath: targetDBPath + "-wal", toPath: backupDBPath + "-wal")
        }
        if fileManager.fileExists(atPath: targetDBPath + "-shm") {
            try fileManager.moveItem(atPath: targetDBPath + "-shm", toPath: backupDBPath + "-shm")
        }
        if fileManager.fileExists(atPath: targetImagesPath) {
            try fileManager.moveItem(atPath: targetImagesPath, toPath: backupImagesPath)
        }

        // 3. Move extracted files into place; roll back on failure
        do {
            try fileManager.moveItem(atPath: dbURL.path, toPath: targetDBPath)

            let walPath = dbURL.path + "-wal"
            if fileManager.fileExists(atPath: walPath) {
                try fileManager.moveItem(atPath: walPath, toPath: targetDBPath + "-wal")
            }

            let shmPath = dbURL.path + "-shm"
            if fileManager.fileExists(atPath: shmPath) {
                try fileManager.moveItem(atPath: shmPath, toPath: targetDBPath + "-shm")
            }

            if fileManager.fileExists(atPath: imagesURL.path) {
                try fileManager.moveItem(atPath: imagesURL.path, toPath: targetImagesPath)
            }
        } catch {
            // Roll back: remove partially restored files and put originals back
            try? fileManager.removeItem(atPath: targetDBPath)
            try? fileManager.removeItem(atPath: targetDBPath + "-wal")
            try? fileManager.removeItem(atPath: targetDBPath + "-shm")
            try? fileManager.removeItem(atPath: targetImagesPath)

            if fileManager.fileExists(atPath: backupDBPath) {
                try? fileManager.moveItem(atPath: backupDBPath, toPath: targetDBPath)
            }
            if fileManager.fileExists(atPath: backupDBPath + "-wal") {
                try? fileManager.moveItem(atPath: backupDBPath + "-wal", toPath: targetDBPath + "-wal")
            }
            if fileManager.fileExists(atPath: backupDBPath + "-shm") {
                try? fileManager.moveItem(atPath: backupDBPath + "-shm", toPath: targetDBPath + "-shm")
            }
            if fileManager.fileExists(atPath: backupImagesPath) {
                try? fileManager.moveItem(atPath: backupImagesPath, toPath: targetImagesPath)
            }
            throw BackupError.internalError(error)
        }

        // 4. Update Keychain BEFORE removing backup files (so rollback is still possible)
        //    storeSecret does SecItemUpdate → SecItemAdd, so no need to delete first.
        //    We save the previous key so we can restore it if storeSecret fails.
        let secretStore = KeychainSecretStore()
        let descriptor = DatabaseSecretDescriptor.clipStashPrimaryDatabase
        let previousKeychainSecret = try? secretStore.readSecret(for: descriptor)
        do {
            try secretStore.storeSecret(keychainSecret, for: descriptor)
        } catch {
            // Keychain write failed — try to restore the previous key
            if let previousKeychainSecret {
                try? secretStore.storeSecret(previousKeychainSecret, for: descriptor)
            }
            // Roll back DB files from backup
            try? fileManager.removeItem(atPath: targetDBPath)
            try? fileManager.removeItem(atPath: targetDBPath + "-wal")
            try? fileManager.removeItem(atPath: targetDBPath + "-shm")
            try? fileManager.removeItem(atPath: targetImagesPath)

            if fileManager.fileExists(atPath: backupDBPath) {
                try? fileManager.moveItem(atPath: backupDBPath, toPath: targetDBPath)
            }
            if fileManager.fileExists(atPath: backupDBPath + "-wal") {
                try? fileManager.moveItem(atPath: backupDBPath + "-wal", toPath: targetDBPath + "-wal")
            }
            if fileManager.fileExists(atPath: backupDBPath + "-shm") {
                try? fileManager.moveItem(atPath: backupDBPath + "-shm", toPath: targetDBPath + "-shm")
            }
            if fileManager.fileExists(atPath: backupImagesPath) {
                try? fileManager.moveItem(atPath: backupImagesPath, toPath: targetImagesPath)
            }
            throw BackupError.keychainAccessFailed
        }

        // 5. All committed — safe to remove backup files now
        try? fileManager.removeItem(atPath: backupDBPath)
        try? fileManager.removeItem(atPath: backupDBPath + "-shm")
        try? fileManager.removeItem(atPath: backupDBPath + "-wal")
        try? fileManager.removeItem(atPath: backupImagesPath)

        // 6. Update settings
        await MainActor.run {
            manifest.apply(to: AppSettings.shared)
        }

        // 7. Request App Restart
        NotificationCenter.default.post(name: .backupRestoreCompleted, object: nil)
    }

    func validateImportedDatabase(at databasePath: String, passphrase: Data) throws {
        do {
            let validatedDatabase = try AppDatabase(
                path: databasePath,
                passphraseProvider: RestoreValidationPassphraseProvider(secret: passphrase)
            )
            defer { try? validatedDatabase.close() }

            try validatedDatabase.dbPool.read { db in
                let quickCheck = try String.fetchOne(db, sql: "PRAGMA quick_check(1)")
                guard quickCheck == "ok" else {
                    throw BackupError.backupCorrupted
                }

                guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clipboardEntry") != nil else {
                    throw BackupError.backupCorrupted
                }
            }
        } catch let error as BackupError {
            throw error
        } catch {
            throw BackupError.backupCorrupted
        }
    }

    // MARK: - Key Derivation

    /// Derives an encryption key from a user password using PBKDF2-SHA256.
    private static func deriveKeyPBKDF2(password: String, salt: Data, iterations: UInt32 = pbkdf2Iterations) throws -> SymmetricKey {
        let passwordData = Data(password.utf8)
        var derivedKey = Data(count: 32)

        let status = derivedKey.withUnsafeMutableBytes { derivedKeyPtr in
            passwordData.withUnsafeBytes { passwordPtr in
                salt.withUnsafeBytes { saltPtr in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordPtr.baseAddress!.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterations,
                        derivedKeyPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        32
                    )
                }
            }
        }

        guard status == kCCSuccess else {
            throw BackupError.internalError(NSError(domain: "PBKDF2", code: Int(status), userInfo: [
                NSLocalizedDescriptionKey: "PBKDF2 key derivation failed with status \(status)"
            ]))
        }

        return SymmetricKey(data: derivedKey)
    }

    /// Decrypts backup file data, auto-detecting format version.
    /// - v2 (PBKDF2): starts with "CSB" magic + version byte
    /// - v1 (legacy HKDF): raw salt + nonce + ciphertext + tag
    private static func decryptBackupData(_ fileData: Data, password: String) throws -> Data {
        if fileData.count >= 4, fileData.prefix(3) == backupMagic {
            // v2+ format: magic(3) + version(1) + iterations(4) + salt(32) + nonce(12) + ciphertext + tag(16)
            let version = fileData[3]
            guard version == backupFormatVersion else {
                throw BackupError.internalError(NSError(domain: "BackupService", code: -3, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported backup file format version \(version)."
                ]))
            }
            let headerSize = 4 + 4 + 32 + 12 // magic+ver + iterations + salt + nonce
            guard fileData.count > headerSize + 16 else { throw BackupError.backupCorrupted }

            let iterationsData = fileData.subdata(in: 4..<8)
            let iterations = iterationsData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
            let salt = fileData.subdata(in: 8..<40)
            let nonceData = fileData.subdata(in: 40..<52)
            let ciphertextAndTag = fileData.subdata(in: 52..<fileData.count)
            guard ciphertextAndTag.count >= 16 else { throw BackupError.backupCorrupted }

            let tag = ciphertextAndTag.suffix(16)
            let ciphertext = ciphertextAndTag.prefix(upTo: ciphertextAndTag.count - 16)

            let key = try deriveKeyPBKDF2(password: password, salt: salt, iterations: iterations)
            let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)

            do {
                return try AES.GCM.open(sealedBox, using: key)
            } catch {
                throw BackupError.invalidPassphrase
            }
        } else {
            // Legacy v1 format: salt(32) + nonce(12) + ciphertext + tag(16), using HKDF
            guard fileData.count > 44 else { throw BackupError.backupCorrupted }

            let salt = fileData.subdata(in: 0..<32)
            let nonceData = fileData.subdata(in: 32..<44)
            let ciphertextAndTag = fileData.subdata(in: 44..<fileData.count)
            guard ciphertextAndTag.count >= 16 else { throw BackupError.backupCorrupted }

            let tag = ciphertextAndTag.suffix(16)
            let ciphertext = ciphertextAndTag.prefix(upTo: ciphertextAndTag.count - 16)

            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)), salt: salt, info: Data(), outputByteCount: 32)
            let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)

            do {
                return try AES.GCM.open(sealedBox, using: key)
            } catch {
                throw BackupError.invalidPassphrase
            }
        }
    }
}

// MARK: - Notification Names
extension NSNotification.Name {
    static let backupRestoreCompleted = NSNotification.Name("ClipStash.BackupRestoreCompleted")
}

private struct RestoreValidationPassphraseProvider: DatabasePassphraseProviding {
    let protectionMode: DatabaseProtectionMode = .keychainBacked
    let keyStorageDescription = "Imported backup manifest"

    let secret: Data

    func passphrase() throws -> Data {
        secret
    }

    func deleteStoredPassphrase() throws {
        // Validation uses an in-memory passphrase only.
    }
}
