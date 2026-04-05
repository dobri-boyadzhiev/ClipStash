import Foundation

enum SearchFilterChip: Hashable, Identifiable, Sendable {
    case type(EntryType)
    case excludedType(EntryType)
    case app(String)
    case excludedApp(String)
    case favoritesOnly
    case after(Date)
    case before(Date)

    var id: String {
        switch self {
        case .type(let type):
            return "type:\(type.rawValue)"
        case .excludedType(let type):
            return "-type:\(type.rawValue)"
        case .app(let app):
            return "app:\(app.lowercased())"
        case .excludedApp(let app):
            return "-app:\(app.lowercased())"
        case .favoritesOnly:
            return "favorite"
        case .after(let date):
            return "after:\(date.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
        case .before(let date):
            return "before:\(date.formatted(.iso8601.year().month().day().dateSeparator(.dash)))"
        }
    }

    var label: String {
        switch self {
        case .type(let type):
            return type.displayName
        case .excludedType(let type):
            return "Not \(type.displayName)"
        case .app(let app):
            return app
        case .excludedApp(let app):
            return "Not \(app)"
        case .favoritesOnly:
            return "Favorite"
        case .after(let date):
            return "After \(date.formatted(date: .abbreviated, time: .omitted))"
        case .before(let date):
            return "Before \(date.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    var systemImage: String {
        switch self {
        case .type(let type):
            return type.systemImage
        case .excludedType(let type):
            return type.systemImage
        case .app:
            return "app"
        case .excludedApp:
            return "app.dashed"
        case .favoritesOnly:
            return "star.fill"
        case .after:
            return "calendar.badge.plus"
        case .before:
            return "calendar.badge.minus"
        }
    }
}

struct SearchCriteria: Equatable, Sendable {
    var freeTextTerms: [String] = []
    var includedTypes: Set<EntryType> = []
    var excludedTypes: Set<EntryType> = []
    var includedApps: [String] = []
    var excludedApps: [String] = []
    var favoritesOnly = false
    var createdAfter: Date?
    var createdBefore: Date?

    static let empty = SearchCriteria()

    var normalizedFreeText: String? {
        let text = freeTextTerms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var isEmpty: Bool {
        normalizedFreeText == nil &&
        includedTypes.isEmpty &&
        excludedTypes.isEmpty &&
        includedApps.isEmpty &&
        excludedApps.isEmpty &&
        favoritesOnly == false &&
        createdAfter == nil &&
        createdBefore == nil
    }

    var chips: [SearchFilterChip] {
        var items: [SearchFilterChip] = []
        items.append(contentsOf: includedTypes.sorted(by: { $0.displayName < $1.displayName }).map(SearchFilterChip.type))
        items.append(contentsOf: excludedTypes.sorted(by: { $0.displayName < $1.displayName }).map(SearchFilterChip.excludedType))
        items.append(contentsOf: includedApps.map(SearchFilterChip.app))
        items.append(contentsOf: excludedApps.map(SearchFilterChip.excludedApp))
        if favoritesOnly {
            items.append(.favoritesOnly)
        }
        if let createdAfter {
            items.append(.after(createdAfter))
        }
        if let createdBefore {
            items.append(.before(createdBefore))
        }
        return items
    }

    var filterCount: Int {
        chips.count
    }
}
