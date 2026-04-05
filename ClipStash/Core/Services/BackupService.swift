import Foundation
import GRDB
import CryptoKit
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

        // 5. Encrypt
        let salt = try KeychainDatabasePassphraseProvider.generateRandomKey(byteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)), salt: salt, info: Data(), outputByteCount: 32)

        let sealedBox = try AES.GCM.seal(zipData, using: key)
        var finalData = Data()
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
        guard fileData.count > 44 else { throw BackupError.backupCorrupted } // 32 salt + 12 nonce

        let salt = fileData.subdata(in: 0..<32)
        let nonceData = fileData.subdata(in: 32..<44)
        let ciphertextAndTag = fileData.subdata(in: 44..<fileData.count)
        guard ciphertextAndTag.count >= 16 else { throw BackupError.backupCorrupted }

        let tag = ciphertextAndTag.suffix(16)
        let ciphertext = ciphertextAndTag.prefix(upTo: ciphertextAndTag.count - 16)

        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(password.utf8)), salt: salt, info: Data(), outputByteCount: 32)

        let sealedBox = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData), ciphertext: ciphertext, tag: tag)
        let decryptedZipData: Data
        do {
            decryptedZipData = try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw BackupError.invalidPassphrase
        }

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
        let secretStore = KeychainSecretStore()
        let descriptor = DatabaseSecretDescriptor.clipStashPrimaryDatabase
        try? secretStore.deleteSecret(for: descriptor)
        do {
            try secretStore.storeSecret(keychainSecret, for: descriptor)
        } catch {
            // Keychain write failed — roll back DB files from backup
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
}

// MARK: - Notification Names
extension NSNotification.Name {
    static let backupRestoreCompleted = NSNotification.Name("ClipStash.BackupRestoreCompleted")
}
