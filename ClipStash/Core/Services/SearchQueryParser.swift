import Foundation

enum SearchQuickFilter: String, CaseIterable, Sendable {
    case images
    case text
    case richText
    case files
    case favorites
    case today
    case last7Days

    static var allCases: [SearchQuickFilter] {
        [.images, .text, .richText, .files, .favorites, .today, .last7Days]
    }

    static var contentCases: [SearchQuickFilter] {
        [.images, .text, .richText, .files, .favorites]
    }

    static var timeCases: [SearchQuickFilter] {
        [.today, .last7Days]
    }

    var label: String {
        switch self {
        case .images:
            return "Images"
        case .text:
            return "Text"
        case .richText:
            return "Rich Text"
        case .files:
            return "Files"
        case .favorites:
            return "Favorites"
        case .today:
            return "Today"
        case .last7Days:
            return "Last 7 Days"
        }
    }

    var systemImage: String {
        switch self {
        case .images:
            return EntryType.image.systemImage
        case .text:
            return EntryType.text.systemImage
        case .richText:
            return EntryType.rtf.systemImage
        case .files:
            return EntryType.fileURL.systemImage
        case .favorites:
            return "star.fill"
        case .today:
            return "calendar"
        case .last7Days:
            return "calendar.badge.clock"
        }
    }
}

enum SearchQueryParser {
    static func parse(_ query: String) -> SearchCriteria {
        var criteria = SearchCriteria.empty

        for rawToken in tokenize(query) {
            guard !rawToken.isEmpty else { continue }

            let isExcluded = rawToken.hasPrefix("-")
            let token = isExcluded ? String(rawToken.dropFirst()) : rawToken
            let lowercasedToken = token.lowercased()

            if lowercasedToken == "fav" || lowercasedToken == "favorite" || lowercasedToken == "is:favorite" || lowercasedToken == "is:fav" {
                if !isExcluded {
                    criteria.favoritesOnly = true
                }
                continue
            }

            if lowercasedToken.hasPrefix("type:"), let type = parseEntryType(String(token.dropFirst(5))) {
                if isExcluded {
                    criteria.excludedTypes.insert(type)
                    criteria.includedTypes.remove(type)
                } else {
                    criteria.includedTypes.insert(type)
                    criteria.excludedTypes.remove(type)
                }
                continue
            }

            if lowercasedToken.hasPrefix("app:") {
                let appName = String(token.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !appName.isEmpty {
                    if isExcluded {
                        criteria.excludedApps.append(appName)
                    } else {
                        criteria.includedApps.append(appName)
                    }
                    continue
                }
            }

            if lowercasedToken.hasPrefix("after:"), let date = parseDate(String(token.dropFirst(6))) {
                criteria.createdAfter = date
                continue
            }

            if lowercasedToken.hasPrefix("before:"), let date = parseDate(String(token.dropFirst(7))) {
                criteria.createdBefore = date
                continue
            }

            criteria.freeTextTerms.append(token)
        }

        return criteria
    }

    static func serialize(_ criteria: SearchCriteria) -> String {
        var tokens = criteria.freeTextTerms.map(serializeTerm)
        tokens.append(contentsOf: criteria.includedTypes.sorted(by: { $0.displayName < $1.displayName }).map { "type:\($0.rawValue)" })
        tokens.append(contentsOf: criteria.excludedTypes.sorted(by: { $0.displayName < $1.displayName }).map { "-type:\($0.rawValue)" })
        tokens.append(contentsOf: criteria.includedApps.map { "app:\(serializeValue($0))" })
        tokens.append(contentsOf: criteria.excludedApps.map { "-app:\(serializeValue($0))" })
        if criteria.favoritesOnly {
            tokens.append("fav")
        }
        if let createdAfter = criteria.createdAfter {
            tokens.append("after:\(formatDate(createdAfter))")
        }
        if let createdBefore = criteria.createdBefore {
            tokens.append("before:\(formatDate(createdBefore))")
        }
        return tokens.joined(separator: " ")
    }

    static func applying(_ filter: SearchQuickFilter, to criteria: SearchCriteria) -> SearchCriteria {
        var updated = criteria
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        switch filter {
        case .images:
            updated.includedTypes.insert(.image)
            updated.excludedTypes.remove(.image)
        case .text:
            updated.includedTypes.insert(.text)
            updated.excludedTypes.remove(.text)
        case .richText:
            updated.includedTypes.insert(.rtf)
            updated.excludedTypes.remove(.rtf)
        case .files:
            updated.includedTypes.insert(.fileURL)
            updated.excludedTypes.remove(.fileURL)
        case .favorites:
            updated.favoritesOnly = true
        case .today:
            updated.createdAfter = startOfToday
            updated.createdBefore = startOfToday
        case .last7Days:
            let startOfWindow = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
            updated.createdAfter = startOfWindow
            updated.createdBefore = nil
        }
        return updated
    }

    static func removing(_ chip: SearchFilterChip, from criteria: SearchCriteria) -> SearchCriteria {
        var updated = criteria
        switch chip {
        case .type(let type):
            updated.includedTypes.remove(type)
        case .excludedType(let type):
            updated.excludedTypes.remove(type)
        case .app(let app):
            updated.includedApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        case .excludedApp(let app):
            updated.excludedApps.removeAll { $0.caseInsensitiveCompare(app) == .orderedSame }
        case .favoritesOnly:
            updated.favoritesOnly = false
        case .after:
            updated.createdAfter = nil
        case .before:
            updated.createdBefore = nil
        }
        return updated
    }

    static func clearingFilters(from criteria: SearchCriteria) -> SearchCriteria {
        SearchCriteria(freeTextTerms: criteria.freeTextTerms)
    }

    private static func tokenize(_ query: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var isInsideQuotes = false

        for character in query {
            if character == "\"" {
                isInsideQuotes.toggle()
                continue
            }

            if character.isWhitespace && !isInsideQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private static func parseEntryType(_ rawValue: String) -> EntryType? {
        switch rawValue.lowercased() {
        case "text":
            return .text
        case "image", "images", "photo", "photos":
            return .image
        case "rtf", "richtext", "rich-text", "rich":
            return .rtf
        case "file", "files", "url", "fileurl":
            return .fileURL
        default:
            return nil
        }
    }

    private static func parseDate(_ rawValue: String) -> Date? {
        dateFormatter.date(from: rawValue)
    }

    private static func formatDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private static func serializeTerm(_ term: String) -> String {
        serializeValue(term)
    }

    private static func serializeValue(_ value: String) -> String {
        if value.contains(where: \.isWhitespace) {
            return "\"\(value)\""
        }
        return value
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
