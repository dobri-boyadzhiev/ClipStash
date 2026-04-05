import Foundation
import SwiftUI
import Combine
import OSLog

/// ViewModel for the main clipboard history popover.
/// Manages pagination, search, favorites, and entry selection.
@MainActor
final class HistoryViewModel: ObservableObject {
    // MARK: - Published state
    @Published var entries: [ClipboardEntry] = []
    @Published var favorites: [ClipboardEntry] = []
    @Published var searchQuery: String = ""
    @Published private(set) var activeSearchCriteria: SearchCriteria = .empty
    @Published private(set) var recentSourceApps: [String] = []
    @Published var isLoading: Bool = false
    @Published var hasMore: Bool = false
    @Published var showClearConfirmation: Bool = false
    @Published var errorMessage: String?
    
    // MARK: - Dependencies
    private let logger = Logger(subsystem: "ClipStash", category: "HistoryViewModel")
    private let repository: EntryRepository
    private let entryManager: EntryManager
    private let clipboardMonitor: ClipboardMonitor
    private let clipboardWriter: ClipboardWriting
    let settings: AppSettings
    
    private let pageSize = 50
    private let recentAppLimit = 5
    private var currentOffset = 0
    private var cancellables = Set<AnyCancellable>()
    
    init(repository: EntryRepository, entryManager: EntryManager,
         clipboardMonitor: ClipboardMonitor, clipboardWriter: ClipboardWriting, settings: AppSettings) {
        self.repository = repository
        self.entryManager = entryManager
        self.clipboardMonitor = clipboardMonitor
        self.clipboardWriter = clipboardWriter
        self.settings = settings
        
        // Debounce search queries
        $searchQuery
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in
                Task { await self?.performSearch(query) }
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Load data
    
    func loadInitial() async {
        await loadRecentSourceApps()

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedQuery.isEmpty {
            await performSearch(trimmedQuery)
            return
        }

        isLoading = true
        currentOffset = 0

        do {
            async let favs = repository.fetchFavorites()
            async let page = repository.fetchHistoryPage(offset: 0, limit: pageSize + 1)

            let (fetchedFavs, fetchedPage) = try await (favs, page)

            favorites = fetchedFavs
            hasMore = fetchedPage.count > pageSize
            entries = Array(fetchedPage.prefix(pageSize))
            currentOffset = entries.count
            activeSearchCriteria = .empty
            errorMessage = nil
        } catch {
            reportError(error, fallbackMessage: "Failed to load clipboard history.")
        }

        isLoading = false
    }
    
    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true

        do {
            let fetched: [ClipboardEntry]
            if activeSearchCriteria.isEmpty {
                fetched = try await repository.fetchHistoryPage(offset: currentOffset, limit: pageSize + 1)
            } else {
                fetched = try await repository.search(criteria: activeSearchCriteria, offset: currentOffset, limit: pageSize + 1)
            }
            let newItems = Array(fetched.prefix(pageSize))
            hasMore = fetched.count > pageSize

            if newItems.isEmpty {
                hasMore = false
            }

            entries.append(contentsOf: newItems)
            currentOffset += newItems.count
            errorMessage = nil
        } catch {
            hasMore = false
            reportError(error, fallbackMessage: "Failed to load more clipboard history.")
        }

        isLoading = false
    }
    
    // MARK: - Search
    
    private func performSearch(_ query: String) async {
        let criteria = SearchQueryParser.parse(query)
        activeSearchCriteria = criteria

        guard !criteria.isEmpty else {
            await loadInitial()
            return
        }
        
        isLoading = true

        do {
            let fetched = try await repository.search(criteria: criteria, offset: 0, limit: pageSize + 1)
            hasMore = fetched.count > pageSize
            entries = Array(fetched.prefix(pageSize))
            currentOffset = entries.count
            favorites = []
            errorMessage = nil
        } catch {
            reportError(error, fallbackMessage: "Failed to search clipboard history.")
        }

        isLoading = false
    }

    func applyQuickFilter(_ filter: SearchQuickFilter) {
        let updatedCriteria = SearchQueryParser.applying(filter, to: activeSearchCriteria)
        searchQuery = SearchQueryParser.serialize(updatedCriteria)
    }

    func applyRecentAppFilter(_ appName: String) {
        var updatedCriteria = activeSearchCriteria
        updatedCriteria.includedApps.removeAll { $0.caseInsensitiveCompare(appName) == .orderedSame }
        updatedCriteria.excludedApps.removeAll { $0.caseInsensitiveCompare(appName) == .orderedSame }
        updatedCriteria.includedApps.append(appName)
        searchQuery = SearchQueryParser.serialize(updatedCriteria)
    }

    func clearSearchFilters() {
        let updatedCriteria = SearchQueryParser.clearingFilters(from: activeSearchCriteria)
        searchQuery = SearchQueryParser.serialize(updatedCriteria)
    }

    func removeSearchFilter(_ chip: SearchFilterChip) {
        let updatedCriteria = SearchQueryParser.removing(chip, from: activeSearchCriteria)
        searchQuery = SearchQueryParser.serialize(updatedCriteria)
    }
    
    // MARK: - Actions

    func improveText(for entry: ClipboardEntry) async {
        guard let text = entry.textContent else { return }

        isLoading = true
        errorMessage = nil

        do {
            let improvedText = try await OllamaService.improveText(
                text,
                urlString: settings.ollamaUrl,
                model: settings.ollamaModel,
                promptMode: settings.aiPromptMode,
                customPrompt: settings.customAIPrompt
            )

            await entryManager.processNewText(
                improvedText,
                source: "Ollama",
                sourceName: "✨ AI Assistant"
            )

            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(improvedText, forType: .string)
            }

            await loadInitial()
        } catch {
            reportError(error, fallbackMessage: "Failed to improve text with AI.")
        }

        isLoading = false
    }

    func select(_ entry: ClipboardEntry) async -> Bool {
        do {
            clipboardMonitor.beginDebounce()
            try await clipboardWriter.write(entry)
            let _ = try await entryManager.select(entry)
            errorMessage = nil
            return true
        } catch {
            clipboardMonitor.cancelDebounce()
            reportError(error, fallbackMessage: "Failed to restore the selected clipboard item.")
            return false
        }
    }

    func copyAsPlainText(_ entry: ClipboardEntry) async -> Bool {
        do {
            clipboardMonitor.beginDebounce()
            try await clipboardWriter.writePlainText(entry)
            let _ = try await entryManager.select(entry)
            errorMessage = nil
            return true
        } catch {
            clipboardMonitor.cancelDebounce()
            reportError(error, fallbackMessage: "Failed to copy the selected item as plain text.")
            return false
        }
    }
    
    func toggleFavorite(_ entry: ClipboardEntry) async {
        do {
            let updated = try await entryManager.toggleFavorite(entry)

            if updated.isFavorite {
                favorites.insert(updated, at: 0)
                entries.removeAll { $0.id == updated.id }
            } else {
                favorites.removeAll { $0.id == updated.id }
                entries.insert(updated, at: 0)
            }
            errorMessage = nil
        } catch {
            reportError(error, fallbackMessage: "Failed to update favorite state.")
        }
    }
    
    func delete(_ entry: ClipboardEntry) async {
        do {
            try await entryManager.delete(entry)
            entries.removeAll { $0.id == entry.id }
            favorites.removeAll { $0.id == entry.id }
            errorMessage = nil
        } catch {
            reportError(error, fallbackMessage: "Failed to delete clipboard item.")
        }
    }
    
    func clearAll() async {
        if settings.confirmBeforeClear {
            showClearConfirmation = true
        } else {
            await performClear()
        }
    }

    func cancelClearConfirmation() {
        showClearConfirmation = false
    }
    
    func performClear() async {
        showClearConfirmation = false
        do {
            try await entryManager.clearHistory(keepFavorites: true)
            entries = []
            currentOffset = 0
            hasMore = false
            favorites = try await repository.fetchFavorites()
            errorMessage = nil
        } catch {
            reportError(error, fallbackMessage: "Failed to clear clipboard history.")
        }
    }
    
    // MARK: - Keyboard navigation
    
    func selectByIndex(_ index: Int, fromFavorites: Bool = false) async {
        let list = fromFavorites ? favorites : entries
        guard index >= 0 && index < list.count else { return }
        let _ = await select(list[index])
    }

    private func loadRecentSourceApps() async {
        do {
            recentSourceApps = try await repository.fetchRecentSourceApps(limit: recentAppLimit)
        } catch {
            logger.error("Failed to load recent source apps: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reportError(_ error: Error, fallbackMessage: String) {
        let message = (error as? LocalizedError)?.errorDescription ?? fallbackMessage
        logger.error("\(message, privacy: .public)")
        errorMessage = message
    }
}
