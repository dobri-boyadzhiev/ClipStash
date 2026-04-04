import Foundation
import GRDB

/// SQLite implementation of EntryRepository using GRDB.
final class SQLiteEntryRepository: EntryRepository, @unchecked Sendable {
    private let db: AppDatabase
    
    init(database: AppDatabase) {
        self.db = database
    }
    
    // MARK: - CRUD
    
    func save(_ entry: inout ClipboardEntry) async throws {
        let entryToSave = entry
        let saved: ClipboardEntry = try await db.dbPool.write { [entryToSave] db in
            var e = entryToSave
            try e.insert(db)
            return e
        }
        entry = saved
    }
    
    func delete(id: Int64) async throws {
        _ = try await db.dbPool.write { db in
            try ClipboardEntry.deleteOne(db, id: id)
        }
    }
    
    func deleteAll(keepFavorites: Bool) async throws {
        _ = try await db.dbPool.write { db in
            if keepFavorites {
                try ClipboardEntry
                    .filter(Column("isFavorite") == false)
                    .deleteAll(db)
            } else {
                try ClipboardEntry.deleteAll(db)
            }
        }
    }
    
    // MARK: - Queries
    
    func fetchPage(offset: Int, limit: Int) async throws -> [ClipboardEntry] {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .order(Column("lastUsedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    func fetchHistoryPage(offset: Int, limit: Int) async throws -> [ClipboardEntry] {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .filter(Column("isFavorite") == false)
                .order(Column("lastUsedAt").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }
    
    func fetchFavorites() async throws -> [ClipboardEntry] {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .filter(Column("isFavorite") == true)
                .order(Column("lastUsedAt").desc)
                .fetchAll(db)
        }
    }
    
    func search(criteria: SearchCriteria, offset: Int, limit: Int) async throws -> [ClipboardEntry] {
        try await db.dbPool.read { db in
            var sql = "SELECT clipboardEntry.* FROM clipboardEntry"
            var conditions: [String] = []
            var arguments = StatementArguments()

            if let freeText = criteria.normalizedFreeText {
                let pattern = FTS5Pattern(matchingAllPrefixesIn: freeText)
                if let pattern {
                    sql += " JOIN clipboardEntryFts ON clipboardEntryFts.rowid = clipboardEntry.id"
                    conditions.append("clipboardEntryFts MATCH ?")
                    arguments += [pattern.rawPattern]
                } else {
                    conditions.append("clipboardEntry.textContent LIKE ?")
                    arguments += ["%\(freeText)%"]
                }
            }

            if !criteria.includedTypes.isEmpty {
                let placeholders = Array(repeating: "?", count: criteria.includedTypes.count).joined(separator: ", ")
                conditions.append("clipboardEntry.type IN (\(placeholders))")
                for type in criteria.includedTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
                    arguments += [type.rawValue]
                }
            }

            if !criteria.excludedTypes.isEmpty {
                let placeholders = Array(repeating: "?", count: criteria.excludedTypes.count).joined(separator: ", ")
                conditions.append("clipboardEntry.type NOT IN (\(placeholders))")
                for type in criteria.excludedTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
                    arguments += [type.rawValue]
                }
            }

            for appName in criteria.includedApps {
                conditions.append("(COALESCE(clipboardEntry.sourceAppName, '') LIKE ? OR COALESCE(clipboardEntry.sourceAppBundleId, '') LIKE ?)")
                arguments += ["%\(appName)%", "%\(appName)%"]
            }

            for appName in criteria.excludedApps {
                conditions.append("(COALESCE(clipboardEntry.sourceAppName, '') NOT LIKE ? AND COALESCE(clipboardEntry.sourceAppBundleId, '') NOT LIKE ?)")
                arguments += ["%\(appName)%", "%\(appName)%"]
            }

            if criteria.favoritesOnly {
                conditions.append("clipboardEntry.isFavorite = 1")
            }

            if let createdAfter = criteria.createdAfter {
                conditions.append("clipboardEntry.createdAt >= ?")
                arguments += [createdAfter]
            }

            if let createdBefore = criteria.createdBefore {
                let endOfDay = Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: createdBefore) ?? createdBefore
                conditions.append("clipboardEntry.createdAt <= ?")
                arguments += [endOfDay]
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }

            sql += " ORDER BY clipboardEntry.lastUsedAt DESC LIMIT ? OFFSET ?"
            arguments += [limit, offset]

            return try ClipboardEntry.fetchAll(db, sql: sql, arguments: arguments)
        }
    }
    
    func fetchEntry(id: Int64) async throws -> ClipboardEntry? {
        try await db.dbPool.read { db in
            try ClipboardEntry.fetchOne(db, id: id)
        }
    }
    
    // MARK: - Mutations
    
    func toggleFavorite(id: Int64) async throws -> ClipboardEntry? {
        try await db.dbPool.write { db in
            guard var entry = try ClipboardEntry.fetchOne(db, id: id) else { return nil }
            entry.isFavorite.toggle()
            try entry.update(db)
            return entry
        }
    }
    
    func moveToTop(id: Int64) async throws {
        _ = try await db.dbPool.write { db in
            guard var entry = try ClipboardEntry.fetchOne(db, id: id) else { return }
            entry.lastUsedAt = Date()
            try entry.update(db)
        }
    }
    
    func updateUseCount(id: Int64) async throws {
        _ = try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE clipboardEntry SET useCount = useCount + 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }
    
    // MARK: - Dedup
    
    func findDuplicateText(textContent: String) async throws -> ClipboardEntry? {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .filter(Column("type") == EntryType.text.rawValue)
                .filter(Column("textContent") == textContent)
                .fetchOne(db)
        }
    }

    func findDuplicateRTF(textContent: String, rtfData: Data) async throws -> ClipboardEntry? {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .filter(Column("type") == EntryType.rtf.rawValue)
                .filter(Column("textContent") == textContent)
                .filter(Column("rtfData") == rtfData)
                .fetchOne(db)
        }
    }

    func findDuplicateFileURLs(textContent: String) async throws -> ClipboardEntry? {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .filter(Column("type") == EntryType.fileURL.rawValue)
                .filter(Column("textContent") == textContent)
                .fetchOne(db)
        }
    }
    
    func findDuplicate(imageHash: String) async throws -> ClipboardEntry? {
        try await db.dbPool.read { db in
            try ClipboardEntry
                .filter(Column("type") == EntryType.image.rawValue)
                .filter(Column("imageHash") == imageHash)
                .fetchOne(db)
        }
    }
    
    // MARK: - Maintenance
    
    func prune(maxItems: Int, maxBytes: Int) async throws -> Int {
        try await db.dbPool.write { db in
            var deleted = 0
            
            let totalCount = try ClipboardEntry
                .filter(Column("isFavorite") == false)
                .fetchCount(db)
            
            if totalCount > maxItems {
                let toDelete = totalCount - maxItems
                let oldEntries = try ClipboardEntry
                    .filter(Column("isFavorite") == false)
                    .order(Column("lastUsedAt").asc)
                    .limit(toDelete)
                    .fetchAll(db)
                
                for entry in oldEntries {
                    try entry.delete(db)
                    deleted += 1
                }
            }
            
            let totalBytes = try Int.fetchOne(db, sql: """
                SELECT COALESCE(SUM(contentSizeBytes), 0)
                FROM clipboardEntry WHERE isFavorite = 0
                """) ?? 0
            
            if totalBytes > maxBytes {
                let entries = try ClipboardEntry
                    .filter(Column("isFavorite") == false)
                    .order(Column("lastUsedAt").asc)
                    .fetchAll(db)
                
                var currentBytes = totalBytes
                for entry in entries {
                    guard currentBytes > maxBytes else { break }
                    currentBytes -= entry.contentSizeBytes
                    try entry.delete(db)
                    deleted += 1
                }
            }
            
            return deleted
        }
    }
    
    func totalCount() async throws -> Int {
        try await db.dbPool.read { db in
            try ClipboardEntry.fetchCount(db)
        }
    }
    
    func totalBytes() async throws -> Int {
        try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(contentSizeBytes), 0) FROM clipboardEntry") ?? 0
        }
    }

    func fetchImageHashes() async throws -> Set<String> {
        try await db.dbPool.read { db in
            let hashes = try String.fetchAll(
                db,
                sql: "SELECT imageHash FROM clipboardEntry WHERE imageHash IS NOT NULL"
            )
            return Set(hashes)
        }
    }

    func fetchRecentSourceApps(limit: Int) async throws -> [String] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT sourceApp
                FROM (
                    SELECT
                        COALESCE(NULLIF(sourceAppName, ''), NULLIF(sourceAppBundleId, '')) AS sourceApp,
                        MAX(lastUsedAt) AS mostRecentUsedAt
                    FROM clipboardEntry
                    WHERE COALESCE(NULLIF(sourceAppName, ''), NULLIF(sourceAppBundleId, '')) IS NOT NULL
                    GROUP BY sourceApp
                    ORDER BY mostRecentUsedAt DESC
                    LIMIT ?
                )
                ORDER BY mostRecentUsedAt DESC
                """,
                arguments: [limit]
            )

            return rows.compactMap { row in
                row["sourceApp"] as String?
            }
        }
    }
}
