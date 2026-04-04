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
    var sourceAppBundleId: String?
    var sourceAppName: String?
    var isFavorite: Bool
    var isPinned: Bool
    var createdAt: Date
    var lastUsedAt: Date
    var useCount: Int
    var contentSizeBytes: Int
    
    /// Display preview — first N characters for text, type name for others
    var preview: String {
        switch type {
        case .text, .rtf:
            guard let text = textContent else { return "" }
            let cleaned = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
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
}
