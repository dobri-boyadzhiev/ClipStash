import CryptoKit
import Foundation
import GRDB

/// Core data model for a clipboard history entry.
/// Conforms to GRDB protocols for direct database mapping.
struct ClipboardEntry: Identifiable, Codable, Hashable, Sendable {
    var id: Int64?
    var type: EntryType
    var textContent: String?
    var rtfData: Data?
    var imageHash: String?
    var contentHash: String?
    var sourceAppBundleId: String?
    var sourceAppName: String?
    var isFavorite: Bool
    var isPinned: Bool
    var createdAt: Date
    var lastUsedAt: Date
    var useCount: Int
    var contentSizeBytes: Int
    
    // Swift Regex — immutable value, safe for concurrent reads despite Sendable limitation
    private nonisolated(unsafe) static let whitespaceRegex = /\s+/

    /// Display preview — first N characters for text, type name for others
    var preview: String {
        switch type {
        case .text, .rtf:
            guard let text = textContent else { return "" }
            // Only process first 500 chars to avoid O(n) regex on large text (#6 fix included)
            let slice = text.count > 500 ? String(text.prefix(500)) : text
            let cleaned = slice.replacing(Self.whitespaceRegex, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count > 200 {
                return String(cleaned.prefix(199)) + "…"
            }
            return cleaned
        case .image:
            return "📷 Image"
        case .fileURL:
            guard let path = textContent else { return "📄 File" }
            return "📄 " + (path.components(separatedBy: "/").last ?? path)
        }
    }
}

// MARK: - GRDB Record conformance
extension ClipboardEntry: FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clipboardEntry"
    
    /// Auto-assign ID after insert
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Factory methods
extension ClipboardEntry {
    static func text(_ content: String, source: String? = nil, sourceName: String? = nil) -> ClipboardEntry {
        ClipboardEntry(
            id: nil,
            type: .text,
            textContent: content,
            rtfData: nil,
            imageHash: nil,
            contentHash: computeHash(content.data(using: .utf8)),
            sourceAppBundleId: source,
            sourceAppName: sourceName,
            isFavorite: false,
            isPinned: false,
            createdAt: Date(),
            lastUsedAt: Date(),
            useCount: 1,
            contentSizeBytes: content.utf8.count
        )
    }

    static func image(hash: String, sizeBytes: Int, source: String? = nil, sourceName: String? = nil) -> ClipboardEntry {
        ClipboardEntry(
            id: nil,
            type: .image,
            textContent: nil,
            rtfData: nil,
            imageHash: hash,
            contentHash: hash, // image hash is already a content hash
            sourceAppBundleId: source,
            sourceAppName: sourceName,
            isFavorite: false,
            isPinned: false,
            createdAt: Date(),
            lastUsedAt: Date(),
            useCount: 1,
            contentSizeBytes: sizeBytes
        )
    }

    static func rtf(_ plainText: String, data: Data, source: String? = nil, sourceName: String? = nil) -> ClipboardEntry {
        ClipboardEntry(
            id: nil,
            type: .rtf,
            textContent: plainText,
            rtfData: data,
            imageHash: nil,
            contentHash: computeHash(data),
            sourceAppBundleId: source,
            sourceAppName: sourceName,
            isFavorite: false,
            isPinned: false,
            createdAt: Date(),
            lastUsedAt: Date(),
            useCount: 1,
            contentSizeBytes: data.count
        )
    }

    private static func computeHash(_ data: Data?) -> String? {
        guard let data else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
