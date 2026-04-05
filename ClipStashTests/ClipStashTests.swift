import Foundation
import GRDB
@testable import ClipStashLib

// MARK: - Test Infrastructure

@MainActor
final class TestRunner {
    var totalTests = 0
    var passedTests = 0
    var failedTests: [(String, String)] = []
    
    func check(_ condition: Bool, _ message: String = "", file: String = #file, line: Int = #line) {
        totalTests += 1
        if condition {
            passedTests += 1
        } else {
            let name = file.components(separatedBy: "/").last ?? file
            failedTests.append(("\(name):\(line)", message))
            print("  ❌ FAIL: \(message) (\(name):\(line))")
        }
    }
    
    func checkEqual<T: Equatable>(_ a: T?, _ b: T?, _ msg: String = "", file: String = #file, line: Int = #line) {
        check(a == b, msg.isEmpty ? "Expected \(String(describing: b)), got \(String(describing: a))" : msg, file: file, line: line)
    }
    
    func run(_ name: String, _ block: @MainActor () async throws -> Void) async {
        do {
            try await block()
            print("  ✅ \(name)")
        } catch {
            totalTests += 1
            failedTests.append((name, error.localizedDescription))
            print("  ❌ \(name): \(error)")
        }
    }
    
    func printResults() {
        print("\n" + String(repeating: "═", count: 40))
        print("📊 Results: \(passedTests)/\(totalTests) passed")
        if failedTests.isEmpty {
            print("✅ All tests passed!")
        } else {
            print("❌ \(failedTests.count) test(s) failed:")
            for (loc, msg) in failedTests {
                print("   • \(loc): \(msg)")
            }
        }
        print(String(repeating: "═", count: 40) + "\n")
    }
}

@MainActor
final class MockClipboardWriter: ClipboardWriting, @unchecked Sendable {
    private(set) var writtenEntries: [ClipboardEntry] = []
    private(set) var plainTextEntries: [ClipboardEntry] = []

    func write(_ entry: ClipboardEntry) throws {
        writtenEntries.append(entry)
    }

    func writePlainText(_ entry: ClipboardEntry) throws {
        plainTextEntries.append(entry)
    }
}

final class SpyImageCache: ImageCacheProtocol, @unchecked Sendable {
    private(set) var storedData: [String: Data] = [:]
    private(set) var cleanedHashesHistory: [Set<String>] = []

    func save(data: Data, forHash hash: String) {
        storedData[hash] = data
    }

    func load(forHash hash: String) -> Data? {
        storedData[hash]
    }

    func delete(forHash hash: String) {
        storedData.removeValue(forKey: hash)
    }

    func cleanOrphans(validHashes: Set<String>) {
        cleanedHashesHistory.append(validHashes)
        storedData = storedData.filter { validHashes.contains($0.key) }
    }
}

@MainActor
final class StubDataResetService: AppDataResetting {
    private(set) var deleteCallCount = 0
    var error: Error?

    func deleteAllDataAndQuit() async throws {
        deleteCallCount += 1
        if let error {
            throw error
        }
    }
}

struct TestError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

final class InMemorySecretStore: DatabaseSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    func readSecret(for descriptor: DatabaseSecretDescriptor) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key(for: descriptor)]
    }

    func storeSecret(_ data: Data, for descriptor: DatabaseSecretDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key(for: descriptor)] = data
    }

    func deleteSecret(for descriptor: DatabaseSecretDescriptor) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key(for: descriptor))
    }

    private func key(for descriptor: DatabaseSecretDescriptor) -> String {
        "\(descriptor.service)|\(descriptor.account)"
    }
}

// MARK: - Main Entry Point

@main
struct TestMain {
    static func main() async {
        let t = TestRunner()
        
        print("\n🧪 ClipStash Test Suite\n")
        
        print("📦 SQLiteEntryRepository")
        
        await t.run("Save and fetch") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Hello, World!")
            try await repo.save(&entry)
            t.check(entry.id != nil, "Should have ID")
            let fetched = try await repo.fetchPage(offset: 0, limit: 10)
            t.checkEqual(fetched.count, 1)
            t.checkEqual(fetched[0].textContent, "Hello, World!")
        }
        
        await t.run("Text deduplication") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Dup text")
            try await repo.save(&entry)
            let found = try await repo.findDuplicateText(textContent: "Dup text")
            t.check(found != nil, "Should find duplicate")
            t.checkEqual(found?.id, entry.id)
            let notFound = try await repo.findDuplicateText(textContent: "Other")
            t.check(notFound == nil, "Should not find non-existent")
        }

        await t.run("Deduplication respects entry type") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            let rtfPayload = "{\\rtf1\\ansi Same}".data(using: .utf8)!

            var textEntry = ClipboardEntry.text("Same")
            var rtfEntry = ClipboardEntry.rtf("Same", data: rtfPayload)
            var fileEntry = ClipboardEntry(
                id: nil,
                type: .fileURL,
                textContent: "/tmp/Same",
                rtfData: nil,
                imageHash: nil,
                contentHash: "/tmp/Same".data(using: .utf8)?.sha256HexString,
                sourceAppBundleId: nil,
                sourceAppName: nil,
                isFavorite: false,
                isPinned: false,
                createdAt: Date(),
                lastUsedAt: Date(),
                useCount: 1,
                contentSizeBytes: 9
            )

            try await repo.save(&textEntry)
            try await repo.save(&rtfEntry)
            try await repo.save(&fileEntry)

            t.checkEqual(try await repo.findDuplicateText(textContent: "Same")?.type, .text)
            t.checkEqual(try await repo.findDuplicateRTF(textContent: "Same", rtfData: rtfPayload)?.type, .rtf)
            t.checkEqual(try await repo.findDuplicateFileURLs(textContent: "/tmp/Same")?.type, .fileURL)
            t.check(try await repo.findDuplicateFileURLs(textContent: "Same") == nil, "File URLs should not collide with plain text")
        }
        
        await t.run("Toggle favorite") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Fav me")
            try await repo.save(&entry)
            let on = try await repo.toggleFavorite(id: entry.id!)
            t.check(on?.isFavorite == true, "Should be favorite")
            let off = try await repo.toggleFavorite(id: entry.id!)
            t.check(off?.isFavorite == false, "Should be unfavorited")
        }
        
        await t.run("Delete") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Delete me")
            try await repo.save(&entry)
            try await repo.delete(id: entry.id!)
            t.checkEqual(try await repo.totalCount(), 0)
        }
        
        await t.run("Prune by count") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            for i in 0..<10 {
                var e = ClipboardEntry.text("Item \(i)")
                try await repo.save(&e)
                try await Task.sleep(for: .milliseconds(10))
            }
            let deleted = try await repo.prune(maxItems: 5, maxBytes: Int.max)
            t.checkEqual(deleted, 5, "Should delete 5")
            t.checkEqual(try await repo.totalCount(), 5)
        }
        
        await t.run("Prune preserves favorites") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            for i in 0..<5 {
                var e = ClipboardEntry.text("Item \(i)")
                try await repo.save(&e)
                if i == 0 { let _ = try await repo.toggleFavorite(id: e.id!) }
            }
            let _ = try await repo.prune(maxItems: 2, maxBytes: Int.max)
            t.checkEqual(try await repo.totalCount(), 3, "2 non-fav + 1 fav")
            t.checkEqual(try await repo.fetchFavorites().count, 1)
        }
        
        await t.run("Search FTS") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e1 = ClipboardEntry.text("Swift programming")
            var e2 = ClipboardEntry.text("Python programming")
            var e3 = ClipboardEntry.text("Hello world")
            try await repo.save(&e1); try await repo.save(&e2); try await repo.save(&e3)
            let results = try await repo.search(criteria: SearchQueryParser.parse("programming"), offset: 0, limit: 10)
            t.checkEqual(results.count, 2, "Should find 2 matches")
            let noResults = try await repo.search(criteria: SearchQueryParser.parse("zzz"), offset: 0, limit: 10)
            t.checkEqual(noResults.count, 0)
        }

        await t.run("Search filters by type and favorites") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)

            var textEntry = ClipboardEntry.text("Alpha note", source: "com.apple.TextEdit", sourceName: "TextEdit")
            var imageEntry = ClipboardEntry.image(hash: "search-image", sizeBytes: 2048, source: "com.apple.Preview", sourceName: "Preview")
            var favoriteEntry = ClipboardEntry.text("Alpha favorite", source: "com.apple.Notes", sourceName: "Notes")

            try await repo.save(&textEntry)
            try await repo.save(&imageEntry)
            try await repo.save(&favoriteEntry)
            let _ = try await repo.toggleFavorite(id: favoriteEntry.id!)

            let imageResults = try await repo.search(criteria: SearchQueryParser.parse("type:image"), offset: 0, limit: 10)
            t.checkEqual(imageResults.count, 1)
            t.checkEqual(imageResults.first?.type, .image)

            let favoriteResults = try await repo.search(criteria: SearchQueryParser.parse("alpha fav"), offset: 0, limit: 10)
            t.checkEqual(favoriteResults.count, 1)
            t.checkEqual(favoriteResults.first?.id, favoriteEntry.id)
        }

        await t.run("Search filters by app and exclusion") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)

            var safariEntry = ClipboardEntry.text("Shared text", source: "com.apple.Safari", sourceName: "Safari")
            var chromeEntry = ClipboardEntry.text("Shared text", source: "com.google.Chrome", sourceName: "Google Chrome")
            try await repo.save(&safariEntry)
            try await repo.save(&chromeEntry)

            let included = try await repo.search(criteria: SearchQueryParser.parse("shared app:Safari"), offset: 0, limit: 10)
            t.checkEqual(included.count, 1)
            t.checkEqual(included.first?.sourceAppName, "Safari")

            let excluded = try await repo.search(criteria: SearchQueryParser.parse("shared -app:Chrome"), offset: 0, limit: 10)
            t.checkEqual(excluded.count, 1)
            t.checkEqual(excluded.first?.sourceAppName, "Safari")
        }

        await t.run("Recent source apps are unique and ordered by recency") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)

            var safariOld = ClipboardEntry.text("One", source: "com.apple.Safari", sourceName: "Safari")
            try await repo.save(&safariOld)
            try await Task.sleep(for: .milliseconds(5))

            var notes = ClipboardEntry.text("Two", source: "com.apple.Notes", sourceName: "Notes")
            try await repo.save(&notes)
            try await Task.sleep(for: .milliseconds(5))

            var safariNew = ClipboardEntry.text("Three", source: "com.apple.Safari", sourceName: "Safari")
            try await repo.save(&safariNew)
            try await Task.sleep(for: .milliseconds(5))

            var finder = ClipboardEntry.text("Four", source: "com.apple.finder", sourceName: "Finder")
            try await repo.save(&finder)

            let apps = try await repo.fetchRecentSourceApps(limit: 5)
            t.checkEqual(apps, ["Finder", "Safari", "Notes"])
        }

        print("\n🔐 Secure Storage")

        await t.run("Keychain-backed provider creates and reuses a passphrase") {
            let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-key-provider-\(UUID().uuidString).db")
            let store = InMemorySecretStore()
            let provider = KeychainDatabasePassphraseProvider(databaseURL: databaseURL, secretStore: store)

            let first = try provider.passphrase()
            let second = try provider.passphrase()

            t.checkEqual(first.count, 32, "Database key should be 32 bytes")
            t.checkEqual(first, second, "Provider should reuse the stored database key")
        }

        await t.run("Keychain-backed provider refuses to recreate a missing key for an existing database") {
            let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-missing-key-\(UUID().uuidString).db")
            try Data([0]).write(to: databaseURL)
            let provider = KeychainDatabasePassphraseProvider(databaseURL: databaseURL, secretStore: InMemorySecretStore())

            do {
                _ = try provider.passphrase()
                t.check(false, "Provider should not silently recreate a missing key")
            } catch let error as DatabasePassphraseError {
                switch error {
                case let .missingStoredPassphrase(path):
                    t.checkEqual(path, databaseURL.path)
                default:
                    t.check(false, "Unexpected error: \(error.localizedDescription)")
                }
            }
        }

        await t.run("Encrypted database reopens only with the same passphrase provider") {
            let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-encrypted-\(UUID().uuidString).db")
            let provider = try EphemeralDatabasePassphraseProvider()
            let db = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Encrypted hello")
            try await repo.save(&entry)
            try db.close()

            let reopened = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            let reopenedRepo = SQLiteEntryRepository(database: reopened)
            let reopenedEntries = try await reopenedRepo.fetchPage(offset: 0, limit: 10)
            t.checkEqual(reopenedEntries.first?.textContent, "Encrypted hello")
            try reopened.close()

            do {
                let wrongProvider = try EphemeralDatabasePassphraseProvider()
                _ = try AppDatabase(path: databaseURL.path, passphraseProvider: wrongProvider)
                t.check(false, "Opening with a different passphrase should fail")
            } catch {
                t.check(true, "Expected encrypted database open to fail with a different passphrase")
            }
        }

        await t.run("Backup service validates an imported database before restore") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-restore-validation-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let databaseURL = tempRoot.appendingPathComponent("clipboard.db")
            let provider = try EphemeralDatabasePassphraseProvider()
            let passphrase = try provider.passphrase()
            let db = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Restorable")
            try await repo.save(&entry)
            try db.close()

            try BackupService.shared.validateImportedDatabase(at: databaseURL.path, passphrase: passphrase)
        }

        await t.run("Backup service rejects an imported database when the manifest key does not match") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-restore-validation-mismatch-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tempRoot) }

            let databaseURL = tempRoot.appendingPathComponent("clipboard.db")
            let provider = try EphemeralDatabasePassphraseProvider()
            let db = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Encrypted")
            try await repo.save(&entry)
            try db.close()

            let wrongPassphrase = try KeychainDatabasePassphraseProvider.generateRandomKey(byteCount: 32)

            do {
                try BackupService.shared.validateImportedDatabase(at: databaseURL.path, passphrase: wrongPassphrase)
                t.check(false, "Validation should reject a database when the imported key does not match")
            } catch let error as BackupError {
                switch error {
                case .backupCorrupted:
                    t.check(true, "Expected backup validation to fail before restore commits")
                default:
                    t.check(false, "Unexpected backup error: \(error.localizedDescription)")
                }
            } catch {
                t.check(false, "Unexpected error: \(error.localizedDescription)")
            }
        }

        await t.run("Bootstrapper falls back when an existing database file has no matching key") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-bootstrap-existing-db-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            let databaseURL = tempRoot.appendingPathComponent("clipboard.db")
            try Data([0x53, 0x51, 0x4c, 0x69]).write(to: databaseURL)

            let store = InMemorySecretStore()
            let provider = KeychainDatabasePassphraseProvider(databaseURL: databaseURL, secretStore: store)
            let fallbackURL = tempRoot.appendingPathComponent("fallback.db")

            let bootstrap = AppDatabaseBootstrapper(
                databasePath: databaseURL.path,
                passphraseProvider: provider,
                fallbackDatabasePath: fallbackURL.path
            ).bootstrap()

            t.check(bootstrap.securityStatus.isFallback, "A pre-existing database without a matching key should trigger fallback")
            t.check(bootstrap.startupAlertMessage?.contains("could not open its primary database securely") == true, "Fallback should explain the secure-open failure")
            t.checkEqual(bootstrap.securityStatus.activeDatabasePath, fallbackURL.path)
            t.check(try store.readSecret(for: .clipStashPrimaryDatabase) == nil, "Fallback should not create a replacement database key")
            try bootstrap.database.close()
        }

        await t.run("Bootstrapper falls back when an encrypted database exists but its key is missing") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-bootstrap-missing-key-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

            let databaseURL = tempRoot.appendingPathComponent("clipboard.db")
            let store = InMemorySecretStore()
            let provider = KeychainDatabasePassphraseProvider(databaseURL: databaseURL, secretStore: store)
            let encryptedDatabase = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            let encryptedRepository = SQLiteEntryRepository(database: encryptedDatabase)
            var entry = ClipboardEntry.text("Still encrypted")
            try await encryptedRepository.save(&entry)
            try encryptedDatabase.close()
            try provider.deleteStoredPassphrase()

            let fallbackURL = tempRoot.appendingPathComponent("fallback.db")
            let bootstrap = AppDatabaseBootstrapper(
                databasePath: databaseURL.path,
                passphraseProvider: provider,
                fallbackDatabasePath: fallbackURL.path
            ).bootstrap()

            t.check(bootstrap.securityStatus.isFallback, "Missing key for an encrypted database should still trigger fallback")
            t.check(bootstrap.startupAlertMessage?.contains("temporary encrypted database") == true, "Fallback should explain that the session database is temporary")
            t.checkEqual(bootstrap.securityStatus.activeDatabasePath, fallbackURL.path)
            try bootstrap.database.close()
        }
        
        await t.run("Clear keeps favorites") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e1 = ClipboardEntry.text("Regular")
            var e2 = ClipboardEntry.text("Favorite")
            try await repo.save(&e1); try await repo.save(&e2)
            let _ = try await repo.toggleFavorite(id: e2.id!)
            try await repo.deleteAll(keepFavorites: true)
            t.checkEqual(try await repo.totalCount(), 1)
            t.checkEqual(try await repo.fetchFavorites()[0].textContent, "Favorite")
        }
        
        await t.run("Clear all") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e1 = ClipboardEntry.text("A"); var e2 = ClipboardEntry.text("B")
            try await repo.save(&e1); try await repo.save(&e2)
            let _ = try await repo.toggleFavorite(id: e2.id!)
            try await repo.deleteAll(keepFavorites: false)
            t.checkEqual(try await repo.totalCount(), 0)
        }
        
        await t.run("Move to top") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e1 = ClipboardEntry.text("Old")
            try await repo.save(&e1)
            try await Task.sleep(for: .milliseconds(50))
            var e2 = ClipboardEntry.text("New")
            try await repo.save(&e2)
            t.checkEqual(try await repo.fetchPage(offset: 0, limit: 10)[0].textContent, "New")
            try await repo.moveToTop(id: e1.id!)
            t.checkEqual(try await repo.fetchPage(offset: 0, limit: 10)[0].textContent, "Old")
        }
        
        await t.run("Pagination") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            for i in 0..<20 {
                var e = ClipboardEntry.text("P\(i)")
                try await repo.save(&e)
                try await Task.sleep(for: .milliseconds(5))
            }
            let p1 = try await repo.fetchPage(offset: 0, limit: 5)
            let p2 = try await repo.fetchPage(offset: 5, limit: 5)
            t.checkEqual(p1.count, 5); t.checkEqual(p2.count, 5)
            t.check(Set(p1.map(\.id)).isDisjoint(with: Set(p2.map(\.id))), "No overlap")
        }

        await t.run("History pagination excludes favorites at the repository layer") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)

            for i in 0..<12 {
                var entry = ClipboardEntry.text("H\(i)")
                try await repo.save(&entry)
                if i < 3 {
                    let _ = try await repo.toggleFavorite(id: entry.id!)
                }
                try await Task.sleep(for: .milliseconds(2))
            }

            let page = try await repo.fetchHistoryPage(offset: 0, limit: 20)
            t.checkEqual(page.count, 9)
            t.check(page.allSatisfy { !$0.isFavorite }, "History page should exclude favorites")
        }
        
        await t.run("Use count") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e = ClipboardEntry.text("Count")
            try await repo.save(&e)
            try await repo.updateUseCount(id: e.id!)
            try await repo.updateUseCount(id: e.id!)
            t.checkEqual(try await repo.fetchEntry(id: e.id!)?.useCount, 3)
        }
        
        await t.run("Image dedup") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e = ClipboardEntry.image(hash: "abc123", sizeBytes: 1024)
            try await repo.save(&e)
            t.check(try await repo.findDuplicate(imageHash: "abc123") != nil)
            t.check(try await repo.findDuplicate(imageHash: "zzz") == nil)
        }

        await t.run("RTF payload round-trip") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            let payload = "{\\rtf1\\ansi Test}".data(using: .utf8)!
            var entry = ClipboardEntry.rtf("Test", data: payload)
            try await repo.save(&entry)

            let fetched = try await repo.fetchEntry(id: entry.id!)
            t.checkEqual(fetched?.type, .rtf)
            t.checkEqual(fetched?.textContent, "Test")
            t.checkEqual(fetched?.rtfData, payload)
        }

        await t.run("Fetch image hashes") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var e1 = ClipboardEntry.image(hash: "hash-a", sizeBytes: 1)
            var e2 = ClipboardEntry.image(hash: "hash-b", sizeBytes: 1)
            try await repo.save(&e1)
            try await repo.save(&e2)

            t.checkEqual(try await repo.fetchImageHashes(), Set(["hash-a", "hash-b"]))
        }
        
        print("\n📦 ClipboardEntry Model")
        
        await t.run("Text factory") {
            let e = ClipboardEntry.text("Test", source: "com.t", sourceName: "T")
            t.checkEqual(e.type, .text); t.checkEqual(e.textContent, "Test")
            t.check(!e.isFavorite); t.checkEqual(e.useCount, 1)
        }
        
        await t.run("Image factory") {
            let e = ClipboardEntry.image(hash: "h", sizeBytes: 2048)
            t.checkEqual(e.type, .image); t.checkEqual(e.contentSizeBytes, 2048)
            t.check(e.textContent == nil)
        }
        
        await t.run("Preview truncation") {
            let e = ClipboardEntry.text(String(repeating: "A", count: 300))
            t.check(e.preview.count <= 201)
            t.check(e.preview.hasSuffix("…"))
        }
        
        await t.run("Short preview") {
            t.checkEqual(ClipboardEntry.text("Hi").preview, "Hi")
        }

        await t.run("RTF factory") {
            let payload = "{\\rtf1\\ansi Hello}".data(using: .utf8)!
            let entry = ClipboardEntry.rtf("Hello", data: payload)
            t.checkEqual(entry.type, .rtf)
            t.checkEqual(entry.textContent, "Hello")
            t.checkEqual(entry.rtfData, payload)
        }

        await t.run("Search query parser extracts filters and free text") {
            let criteria = SearchQueryParser.parse("invoice type:image app:\"Google Chrome\" fav -type:file after:2026-04-01")
            t.checkEqual(criteria.normalizedFreeText, "invoice")
            t.check(criteria.includedTypes.contains(.image), "Parser should include image type")
            t.check(criteria.excludedTypes.contains(.fileURL), "Parser should exclude file type")
            t.checkEqual(criteria.includedApps, ["Google Chrome"])
            t.check(criteria.favoritesOnly, "Parser should detect favorites filter")
            t.check(criteria.createdAfter != nil, "Parser should parse after date")
        }

        await t.run("Search query parser serializes back to text") {
            var criteria = SearchCriteria.empty
            criteria.freeTextTerms = ["hello world"]
            criteria.includedTypes = [.image]
            criteria.includedApps = ["Google Chrome"]
            criteria.favoritesOnly = true

            let query = SearchQueryParser.serialize(criteria)
            t.check(query.contains("\"hello world\""))
            t.check(query.contains("type:image"))
            t.check(query.contains("app:\"Google Chrome\""))
            t.check(query.contains("fav"))
        }

        await t.run("Search quick filters apply time windows") {
            let todayCriteria = SearchQueryParser.applying(.today, to: .empty)
            t.check(todayCriteria.createdAfter != nil, "Today filter should set a start date")
            t.check(todayCriteria.createdBefore != nil, "Today filter should set an end date")
            t.checkEqual(todayCriteria.createdAfter, todayCriteria.createdBefore, "Today filter should anchor both dates to the same day")

            let last7DaysCriteria = SearchQueryParser.applying(.last7Days, to: .empty)
            t.check(last7DaysCriteria.createdAfter != nil, "Last 7 Days filter should set a start date")
            t.check(last7DaysCriteria.createdBefore == nil, "Last 7 Days filter should not set a hard end date")
        }

        print("\n📦 ViewModels")

        await t.run("History hides favorites from main list") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var favorite = ClipboardEntry.text("Favorite")
            var regular = ClipboardEntry.text("Regular")
            try await repo.save(&favorite)
            try await repo.save(&regular)
            let _ = try await repo.toggleFavorite(id: favorite.id!)

            let settings = AppSettings.shared
            let imageCache = SpyImageCache()
            let entryManager = EntryManager(repository: repo, settings: settings, imageCache: imageCache)
            let monitor = ClipboardMonitor(entryManager: entryManager, settings: settings)
            let writer = MockClipboardWriter()
            let viewModel = HistoryViewModel(
                repository: repo,
                entryManager: entryManager,
                clipboardMonitor: monitor,
                clipboardWriter: writer,
                settings: settings
            )

            await viewModel.loadInitial()

            t.checkEqual(viewModel.favorites.count, 1)
            t.checkEqual(viewModel.entries.count, 1)
            t.checkEqual(viewModel.entries.first?.textContent, "Regular")
        }

        await t.run("History pagination stays full when favorites are present") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)

            for i in 0..<55 {
                var entry = ClipboardEntry.text("Item \(i)")
                try await repo.save(&entry)
                if i < 5 {
                    let _ = try await repo.toggleFavorite(id: entry.id!)
                }
                try await Task.sleep(for: .milliseconds(2))
            }

            let settings = AppSettings.shared
            let imageCache = SpyImageCache()
            let entryManager = EntryManager(repository: repo, settings: settings, imageCache: imageCache)
            let monitor = ClipboardMonitor(entryManager: entryManager, settings: settings)
            let writer = MockClipboardWriter()
            let viewModel = HistoryViewModel(
                repository: repo,
                entryManager: entryManager,
                clipboardMonitor: monitor,
                clipboardWriter: writer,
                settings: settings
            )

            await viewModel.loadInitial()
            let firstPageIDs = Set(viewModel.entries.compactMap(\.id))
            let firstPageCount = viewModel.entries.count
            await viewModel.loadNextPage()

            t.checkEqual(viewModel.favorites.count, 5)
            t.checkEqual(firstPageCount, 50)
            t.checkEqual(viewModel.entries.count, 50, "Second page should not duplicate or underfill when there are only 50 non-favorites")
            t.checkEqual(Set(viewModel.entries.compactMap(\.id)).count, 50)
            t.check(firstPageIDs.isSubset(of: Set(viewModel.entries.compactMap(\.id))), "Loading next page should preserve the first page entries")
        }

        await t.run("Selection uses clipboard writer") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var entry = ClipboardEntry.text("Selected")
            try await repo.save(&entry)

            let settings = AppSettings.shared

            let imageCache = SpyImageCache()
            let entryManager = EntryManager(repository: repo, settings: settings, imageCache: imageCache)
            let monitor = ClipboardMonitor(entryManager: entryManager, settings: settings)
            let writer = MockClipboardWriter()
            let viewModel = HistoryViewModel(
                repository: repo,
                entryManager: entryManager,
                clipboardMonitor: monitor,
                clipboardWriter: writer,
                settings: settings
            )

            let didSelect = await viewModel.select(entry)

            t.check(didSelect, "Selecting an entry should copy it to the clipboard")
            t.checkEqual(writer.writtenEntries.first?.id, entry.id)
        }

        await t.run("Copy as plain text uses the plain-text clipboard writer path") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            let payload = "{\\rtf1\\ansi Selected}".data(using: .utf8)!
            var entry = ClipboardEntry.rtf("Selected", data: payload)
            try await repo.save(&entry)

            let settings = AppSettings.shared
            let imageCache = SpyImageCache()
            let entryManager = EntryManager(repository: repo, settings: settings, imageCache: imageCache)
            let monitor = ClipboardMonitor(entryManager: entryManager, settings: settings)
            let writer = MockClipboardWriter()
            let viewModel = HistoryViewModel(
                repository: repo,
                entryManager: entryManager,
                clipboardMonitor: monitor,
                clipboardWriter: writer,
                settings: settings
            )

            let didCopy = await viewModel.copyAsPlainText(entry)

            t.check(didCopy, "Copy as plain text should succeed for rich text entries")
            t.checkEqual(writer.plainTextEntries.first?.id, entry.id)
            t.checkEqual(writer.writtenEntries.count, 0, "Plain-text copy should not go through the rich clipboard path")
            t.checkEqual(try await repo.fetchEntry(id: entry.id!)?.useCount, 2, "Plain-text copy should still update usage metadata")
        }

        await t.run("Clear history reconciles image cache") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            var imageEntry = ClipboardEntry.image(hash: "keep-me-gone", sizeBytes: 3)
            try await repo.save(&imageEntry)

            let settings = AppSettings.shared
            let imageCache = SpyImageCache()
            imageCache.save(data: Data([1, 2, 3]), forHash: "keep-me-gone")

            let entryManager = EntryManager(repository: repo, settings: settings, imageCache: imageCache)
            try await entryManager.clearHistory(keepFavorites: false)

            t.checkEqual(imageCache.cleanedHashesHistory.last, Set<String>())
            t.check(imageCache.load(forHash: "keep-me-gone") == nil, "Image cache should be cleaned after clear")
        }

        await t.run("Saving text without pruning does not rescan image cache") {
            let db = try AppDatabase.inMemory()
            let repo = SQLiteEntryRepository(database: db)
            let settings = AppSettings.shared
            let imageCache = SpyImageCache()
            let entryManager = EntryManager(repository: repo, settings: settings, imageCache: imageCache)

            await entryManager.processNewText("No prune needed", source: nil, sourceName: nil)

            t.checkEqual(imageCache.cleanedHashesHistory.count, 0, "Text saves should not trigger orphan scans when nothing was pruned")
        }

        print("\n📦 Clipboard Monitor")

        await t.run("Polling is relaxed in normal mode") {
            let schedule = ClipboardMonitor.makePollSchedule(isPrivateMode: false, isLowPowerModeEnabled: false)
            t.checkEqual(schedule, ClipboardMonitor.PollSchedule(interval: 0.45, tolerance: 0.15))
        }

        await t.run("Polling is slower in low power mode") {
            let schedule = ClipboardMonitor.makePollSchedule(isPrivateMode: false, isLowPowerModeEnabled: true)
            t.checkEqual(schedule, ClipboardMonitor.PollSchedule(interval: 0.9, tolerance: 0.3))
        }

        await t.run("Polling is slowest in private mode") {
            let schedule = ClipboardMonitor.makePollSchedule(isPrivateMode: true, isLowPowerModeEnabled: false)
            t.checkEqual(schedule, ClipboardMonitor.PollSchedule(interval: 1.2, tolerance: 0.4))
        }

        await t.run("Panel width follows configured percentage") {
            let width = ClipboardPanelLayout.panelWidth(screenWidth: 1440, percentage: 33)
            t.check(abs(width - 475.2) < 0.001, "Panel width should scale with screen width")
        }

        await t.run("Panel width clamps to minimum") {
            let width = ClipboardPanelLayout.panelWidth(screenWidth: 800, percentage: 10)
            t.checkEqual(width, 360)
        }

        await t.run("Panel width clamps to maximum") {
            let width = ClipboardPanelLayout.panelWidth(screenWidth: 4000, percentage: 50)
            t.checkEqual(width, 900)
        }

        print("\n📦 Settings & Reset")

        await t.run("Reset settings removes stored values") {
            let settings = AppSettings.shared
            settings.maxItems = 42
            settings.maxCacheSizeMB = 512
            settings.maxEntrySizeMB = 10
            settings.windowWidthPercentage = 55

            settings.resetToDefaults()

            t.checkEqual(settings.maxItems, 10_000)
            t.checkEqual(settings.maxCacheSizeMB, 10_240)
            t.checkEqual(settings.maxEntrySizeMB, 50)
            t.checkEqual(settings.windowWidthPercentage, 33)
        }

        await t.run("Settings view model triggers delete all data flow") {
            let provider = try EphemeralDatabasePassphraseProvider()
            let db = try AppDatabase(path: FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db").path, passphraseProvider: provider)
            let repo = SQLiteEntryRepository(database: db)
            let resetService = StubDataResetService()
            let viewModel = SettingsViewModel(
                settings: AppSettings.shared,
                repository: repo,
                dataResetService: resetService,
                database: db,
                databasePassphraseProvider: provider,
                databaseSecurityStatus: .keychainBacked(
                    databasePath: AppDatabase.defaultPath,
                    keyStorageDescription: "macOS Keychain"
                )
            )

            await viewModel.deleteAllData()

            t.checkEqual(resetService.deleteCallCount, 1)
            t.check(viewModel.deleteAllDataErrorMessage == nil, "Delete flow should not show an error on success")
        }

        await t.run("Settings view model surfaces reset errors") {
            let provider = try EphemeralDatabasePassphraseProvider()
            let db = try AppDatabase(path: FileManager.default.temporaryDirectory.appendingPathComponent("test-\(UUID().uuidString).db").path, passphraseProvider: provider)
            let repo = SQLiteEntryRepository(database: db)
            let resetService = StubDataResetService()
            resetService.error = TestError(message: "Boom")
            let viewModel = SettingsViewModel(
                settings: AppSettings.shared,
                repository: repo,
                dataResetService: resetService,
                database: db,
                databasePassphraseProvider: provider,
                databaseSecurityStatus: .keychainBacked(
                    databasePath: AppDatabase.defaultPath,
                    keyStorageDescription: "macOS Keychain"
                )
            )

            await viewModel.deleteAllData()

            t.checkEqual(resetService.deleteCallCount, 1)
            t.checkEqual(viewModel.deleteAllDataErrorMessage, "Boom")
            t.check(viewModel.isDeletingAllData == false, "Delete flow should stop loading after an error")
        }

        await t.run("App data reset service deletes local data and disables launch at login") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-reset-\(UUID().uuidString)", isDirectory: true)
            let dataDirectory = tempRoot.appendingPathComponent("ClipStash", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)

            let databaseURL = dataDirectory.appendingPathComponent("clipboard.db")
            let provider = try EphemeralDatabasePassphraseProvider()
            let db = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            try Data([1, 2, 3]).write(to: dataDirectory.appendingPathComponent("images/sample"))

            var didPrepare = false
            var didTerminate = false
            var launchAtLoginValues: [Bool] = []

            let service = AppDataResetService(
                settings: AppSettings.shared,
                database: db,
                passphraseProvider: provider,
                dataDirectoryURL: dataDirectory,
                prepareForReset: { didPrepare = true },
                terminateApplication: { didTerminate = true },
                setLaunchAtLoginEnabled: { launchAtLoginValues.append($0) }
            )

            try await service.deleteAllDataAndQuit()

            t.check(didPrepare, "Reset should stop services before deleting data")
            t.check(didTerminate, "Reset should terminate the app after cleanup")
            t.checkEqual(launchAtLoginValues, [false])
            t.check(FileManager.default.fileExists(atPath: dataDirectory.path) == false, "Reset should remove the local data directory")
        }

        await t.run("App data reset service deletes the stored database key") {
            let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipstash-reset-key-\(UUID().uuidString)", isDirectory: true)
            let dataDirectory = tempRoot.appendingPathComponent("ClipStash", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

            let databaseURL = dataDirectory.appendingPathComponent("clipboard.db")
            let store = InMemorySecretStore()
            let provider = KeychainDatabasePassphraseProvider(databaseURL: databaseURL, secretStore: store)
            let firstKey = try provider.passphrase()

            let db = try AppDatabase(path: databaseURL.path, passphraseProvider: provider)
            let service = AppDataResetService(
                settings: AppSettings.shared,
                database: db,
                passphraseProvider: provider,
                dataDirectoryURL: dataDirectory,
                prepareForReset: {},
                terminateApplication: {},
                setLaunchAtLoginEnabled: { _ in }
            )

            try await service.deleteAllDataAndQuit()

            let replacementProvider = KeychainDatabasePassphraseProvider(databaseURL: databaseURL, secretStore: store)
            let secondKey = try replacementProvider.passphrase()
            t.check(firstKey != secondKey, "Reset should remove the old database key so a fresh one is created")
        }
        
        print("\n📦 SHA256")
        
        await t.run("Consistent hash") {
            let d = "Hello!".data(using: .utf8)!
            t.checkEqual(d.sha256HexString, d.sha256HexString)
            t.checkEqual(d.sha256HexString.count, 64)
        }
        
        await t.run("Different hash for different data") {
            let d1 = "A".data(using: .utf8)!
            let d2 = "B".data(using: .utf8)!
            t.check(d1.sha256HexString != d2.sha256HexString)
        }
        
        t.printResults()
        
        if !t.failedTests.isEmpty { exit(1) }
    }
}
