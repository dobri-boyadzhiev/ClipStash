import Foundation

/// Supported clipboard content types
enum EntryType: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case rtf
    case fileURL
    
    var displayName: String {
        switch self {
        case .text:    return "Text"
        case .image:   return "Image"
        case .rtf:     return "Rich Text"
        case .fileURL: return "File"
        }
    }
    
    var systemImage: String {
        switch self {
        case .text:    return "doc.text"
        case .image:   return "photo"
        case .rtf:     return "doc.richtext"
        case .fileURL: return "doc"
        }
    }
}
