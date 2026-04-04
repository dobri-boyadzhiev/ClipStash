import Foundation

/// Protocol defining all data operations for clipboard entries.
/// This abstraction allows swapping SQLite for any other storage.
protocol EntryRepository: Sendable {
    // MARK: - CRUD
    func save(_ entry: inout ClipboardEntry) async throws
    func delete(id: Int64) async throws
    func deleteAll(keepFavorites: Bool) async throws
    
    // MARK: - Queries
    func fetchPage(offset: Int, limit: Int) async throws -> [ClipboardEntry]
    func fetchHistoryPage(offset: Int, limit: Int) async throws -> [ClipboardEntry]
    func fetchFavorites() async throws -> [ClipboardEntry]
    func search(criteria: SearchCriteria, offset: Int, limit: Int) async throws -> [ClipboardEntry]
    func fetchEntry(id: Int64) async throws -> ClipboardEntry?
    
    // MARK: - Mutations
    func toggleFavorite(id: Int64) async throws -> ClipboardEntry?
    func moveToTop(id: Int64) async throws
    func updateUseCount(id: Int64) async throws
    
    // MARK: - Deduplication
    func findDuplicateText(textContent: String) async throws -> ClipboardEntry?
    func findDuplicateRTF(textContent: String, rtfData: Data) async throws -> ClipboardEntry?
    func findDuplicateFileURLs(textContent: String) async throws -> ClipboardEntry?
    func findDuplicate(imageHash: String) async throws -> ClipboardEntry?
    
    // MARK: - Maintenance
    func prune(maxItems: Int, maxBytes: Int) async throws -> Int
    func totalCount() async throws -> Int
    func totalBytes() async throws -> Int
    func fetchImageHashes() async throws -> Set<String>
    func fetchRecentSourceApps(limit: Int) async throws -> [String]
}
