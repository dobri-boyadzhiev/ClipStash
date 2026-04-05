import Foundation
import OSLog
import CryptoKit

/// File-based cache for clipboard images.
/// Images are stored as files named by their SHA256 hash.
final class ImageFileCache: ImageCacheProtocol, Sendable {
    static var defaultDirectoryURL: URL {
        AppDatabase.appSupportDirectoryURL.appendingPathComponent("images", isDirectory: true)
    }

    private let cacheDir: URL
    private let logger = Logger(subsystem: "ClipStash", category: "ImageFileCache")
    private let passphraseProvider: any DatabasePassphraseProviding

    init(passphraseProvider: any DatabasePassphraseProviding) {
        self.passphraseProvider = passphraseProvider
        cacheDir = Self.defaultDirectoryURL
        do {
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheDir.path)
        } catch {
            logger.error("Failed to create image cache directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func symmetricKey() throws -> SymmetricKey {
        let passphrase = try passphraseProvider.passphrase()
        let hash = SHA256.hash(data: passphrase)
        return SymmetricKey(data: hash)
    }

    func save(data: Data, forHash hash: String) async {
        let url = cacheDir.appendingPathComponent(hash)
        let provider = self.passphraseProvider
        let log = self.logger
        await Task.detached {
            do {
                let passphrase = try provider.passphrase()
                let keyHash = SHA256.hash(data: passphrase)
                let key = SymmetricKey(data: keyHash)
                let sealedBox = try AES.GCM.seal(data, using: key)
                guard let encryptedData = sealedBox.combined else { return }
                try encryptedData.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {
                log.error("Failed to store image cache file \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

    func load(forHash hash: String) async -> Data? {
        let url = cacheDir.appendingPathComponent(hash)
        let provider = self.passphraseProvider
        let log = self.logger
        return await Task.detached {
            do {
                let encryptedData = try Data(contentsOf: url)
                let passphrase = try provider.passphrase()
                let keyHash = SHA256.hash(data: passphrase)
                let key = SymmetricKey(data: keyHash)
                let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
                return try AES.GCM.open(sealedBox, using: key)
            } catch {
                log.error("Failed to load image cache file \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    func delete(forHash hash: String) async {
        let url = cacheDir.appendingPathComponent(hash)
        let log = self.logger
        await Task.detached {
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                log.error("Failed to delete image cache file \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }

    /// Remove orphaned image files not referenced in the database
    func cleanOrphans(validHashes: Set<String>) async {
        let dir = cacheDir
        let log = self.logger
        await Task.detached {
            do {
                let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                for file in files where !validHashes.contains(file) {
                    try FileManager.default.removeItem(at: dir.appendingPathComponent(file))
                }
            } catch {
                log.error("Failed to clean orphaned image cache files: \(error.localizedDescription, privacy: .public)")
            }
        }.value
    }
}
