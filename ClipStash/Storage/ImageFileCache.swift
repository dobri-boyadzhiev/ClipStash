import Foundation
import OSLog

/// File-based cache for clipboard images.
/// Images are stored as files named by their SHA256 hash.
final class ImageFileCache: ImageCacheProtocol, Sendable {
    static var defaultDirectoryURL: URL {
        AppDatabase.appSupportDirectoryURL.appendingPathComponent("images", isDirectory: true)
    }

    private let cacheDir: URL
    private let logger = Logger(subsystem: "ClipStash", category: "ImageFileCache")
    
    init() {
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
    
    func save(data: Data, forHash hash: String) {
        let url = cacheDir.appendingPathComponent(hash)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            logger.error("Failed to store image cache file \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
    
    func load(forHash hash: String) -> Data? {
        let url = cacheDir.appendingPathComponent(hash)
        do {
            return try Data(contentsOf: url)
        } catch {
            logger.error("Failed to load image cache file \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
    
    func delete(forHash hash: String) {
        let url = cacheDir.appendingPathComponent(hash)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            logger.error("Failed to delete image cache file \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
    
    /// Remove orphaned image files not referenced in the database
    func cleanOrphans(validHashes: Set<String>) {
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
            for file in files where !validHashes.contains(file) {
                try FileManager.default.removeItem(at: cacheDir.appendingPathComponent(file))
            }
        } catch {
            logger.error("Failed to clean orphaned image cache files: \(error.localizedDescription, privacy: .public)")
        }
    }
}
