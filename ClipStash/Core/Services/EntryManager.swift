import Foundation
import CryptoKit
import OSLog

/// Main business logic coordinator for clipboard entries.
@MainActor
final class EntryManager: ObservableObject {
    @Published private(set) var latestEntry: ClipboardEntry?
    
    private let logger = Logger(subsystem: "ClipStash", category: "EntryManager")
    private let repository: EntryRepository
    private let settings: AppSettings
    private let imageCache: ImageCacheProtocol?
    
    init(repository: EntryRepository, settings: AppSettings, imageCache: ImageCacheProtocol? = nil) {
        self.repository = repository
        self.settings = settings
        self.imageCache = imageCache
    }
    
    // MARK: - Process new clipboard content

    private func processAndSave(
        duplicateCheck: () async throws -> ClipboardEntry?,
        entryCreation: () -> ClipboardEntry,
        onNewEntry: (() async -> Void)? = nil,
        onFailure: ((Error) async -> Void)? = nil,
        errorMessage: String
    ) async {
        do {
            if let existing = try await duplicateCheck() {
                try await handleDuplicate(existing)
                return
            }

            await onNewEntry?()
            var entry = entryCreation()
            try await saveAndPrune(&entry)
        } catch {
            logger.error("\(errorMessage, privacy: .public): \(error.localizedDescription, privacy: .public)")
            await onFailure?(error)
        }
    }

    func processNewText(_ text: String, source: String?, sourceName: String?) async {
        var content = text
        if settings.stripWhitespace {
            content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !content.isEmpty else { return }

        await processAndSave(
            duplicateCheck: { try await self.repository.findDuplicateText(textContent: content) },
            entryCreation: { ClipboardEntry.text(content, source: source, sourceName: sourceName) },
            errorMessage: "Failed to process text clipboard entry"
        )
    }

    func processNewRTF(plainText: String, rtfData: Data, source: String?, sourceName: String?) async {
        let content = settings.stripWhitespace ? plainText.trimmingCharacters(in: .whitespacesAndNewlines) : plainText
        guard !content.isEmpty else { return }

        await processAndSave(
            duplicateCheck: { try await self.repository.findDuplicateRTF(textContent: content, rtfData: rtfData) },
            entryCreation: { ClipboardEntry.rtf(content, data: rtfData, source: source, sourceName: sourceName) },
            errorMessage: "Failed to process RTF clipboard entry"
        )
    }

    func processNewImage(_ data: Data, source: String?, sourceName: String?) async {
        let hash = data.sha256HexString

        await processAndSave(
            duplicateCheck: { try await self.repository.findDuplicate(imageHash: hash) },
            entryCreation: { ClipboardEntry.image(hash: hash, sizeBytes: data.count, source: source, sourceName: sourceName) },
            onNewEntry: { await self.imageCache?.save(data: data, forHash: hash) },
            onFailure: { _ in
                await self.imageCache?.delete(forHash: hash)
                await self.reconcileStoredAssets()
            },
            errorMessage: "Failed to process image clipboard entry"
        )
    }

    func processNewFileURLs(_ paths: String, source: String?, sourceName: String?) async {
        guard !paths.isEmpty else { return }

        await processAndSave(
            duplicateCheck: { try await self.repository.findDuplicateFileURLs(textContent: paths) },
            entryCreation: {
                ClipboardEntry(
                    id: nil, type: .fileURL, textContent: paths, rtfData: nil, imageHash: nil,
                    sourceAppBundleId: source, sourceAppName: sourceName,
                    isFavorite: false, isPinned: false,
                    createdAt: Date(), lastUsedAt: Date(),
                    useCount: 1, contentSizeBytes: paths.utf8.count
                )
            },
            errorMessage: "Failed to process file URL clipboard entry"
        )
    }
    
    // MARK: - Actions
    
    func select(_ entry: ClipboardEntry) async throws -> ClipboardEntry {
        guard let id = entry.id else {
            throw EntryManagerError.missingEntryID
        }
        try await repository.moveToTop(id: id)
        try await repository.updateUseCount(id: id)
        let updated = try await repository.fetchEntry(id: id) ?? entry
        latestEntry = updated
        return updated
    }
    
    func toggleFavorite(_ entry: ClipboardEntry) async throws -> ClipboardEntry {
        guard let id = entry.id else {
            throw EntryManagerError.missingEntryID
        }
        guard let updated = try await repository.toggleFavorite(id: id) else {
            throw EntryManagerError.entryNotFound
        }
        return updated
    }
    
    func delete(_ entry: ClipboardEntry) async throws {
        guard let id = entry.id else {
            throw EntryManagerError.missingEntryID
        }
        try await repository.delete(id: id)
        if latestEntry?.id == id { latestEntry = nil }
        await reconcileStoredAssets()
    }
    
    func clearHistory(keepFavorites: Bool = true) async throws {
        try await repository.deleteAll(keepFavorites: keepFavorites)
        latestEntry = nil
        await reconcileStoredAssets()
    }

    func reconcileStoredAssets() async {
        guard let imageCache else { return }
        do {
            let validHashes = try await repository.fetchImageHashes()
            await imageCache.cleanOrphans(validHashes: validHashes)
        } catch {
            logger.error("Failed to reconcile image cache: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    // MARK: - Private helpers
    
    private func handleDuplicate(_ existing: ClipboardEntry) async throws {
        guard let id = existing.id else {
            throw EntryManagerError.missingEntryID
        }
        try await repository.moveToTop(id: id)
        try await repository.updateUseCount(id: id)
        latestEntry = try await repository.fetchEntry(id: id) ?? existing
    }
    
    private func saveAndPrune(_ entry: inout ClipboardEntry) async throws {
        try await repository.save(&entry)
        latestEntry = entry
        
        let maxBytes = settings.maxCacheSizeMB * 1_048_576
        let deleted = try await repository.prune(maxItems: settings.maxItems, maxBytes: maxBytes)
        if deleted > 0 {
            await reconcileStoredAssets()
        }
    }
}

enum EntryManagerError: LocalizedError {
    case missingEntryID
    case entryNotFound

    var errorDescription: String? {
        switch self {
        case .missingEntryID:
            return "Clipboard entry is missing a persistent identifier."
        case .entryNotFound:
            return "Clipboard entry was not found in storage."
        }
    }
}

// MARK: - Data SHA256 extension
extension Data {
    var sha256HexString: String {
        let digest = SHA256.hash(data: self)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - ImageCache Protocol
protocol ImageCacheProtocol: Sendable {
    func save(data: Data, forHash hash: String) async
    func load(forHash hash: String) async -> Data?
    func delete(forHash hash: String) async
    func cleanOrphans(validHashes: Set<String>) async
}
