# ClipStash — Architecture Documentation

This document describes every module, protocol, data flow, and design decision in detail.
Use this as a reference when reviewing, extending, or debugging the project.

---

## Table of Contents

1. [High-Level Architecture](#1-high-level-architecture)
2. [Core Layer](#2-core-layer)
3. [Storage Layer](#3-storage-layer)
4. [Platform Layer](#4-platform-layer)
5. [ViewModel Layer](#5-viewmodel-layer)
6. [UI Layer](#6-ui-layer)
7. [App Wiring (DI)](#7-app-wiring)
8. [Data Flows](#8-data-flows)
9. [Database Schema](#9-database-schema)
10. [Concurrency Model](#10-concurrency-model)
11. [Design Decisions](#11-design-decisions)

---

## 1. High-Level Architecture

```
UI (SwiftUI)  →  ViewModels  →  Core Services  →  Storage (SQLite)
                                                →  Platform (AppKit/Carbon)
```

**Dependency rule:** Each layer only depends on the layer directly below it.
Core depends on NOTHING — it defines protocols that Storage and Platform implement.

### SPM Targets

| Target | Type | Path | Description |
|--------|------|------|-------------|
| `ClipStashLib` | Library | `ClipStash/` | All source code — models, services, UI, everything |
| `ClipStashApp` | Executable | `ClipStashEntry/` | 3-line entry point that calls `runApp()` |
| `ClipStashTests` | Executable | `ClipStashTests/` | Standalone test runner with regression coverage |

Why a library + executable split?
→ SPM can't run tests against executable targets, so the library is testable.

---

## 2. Core Layer

**Path:** `ClipStash/Core/`
**Imports:** Only `Foundation` and `GRDB` (for record conformance)
**Purpose:** Business logic with zero macOS dependencies

### 2.1 Models

#### `EntryType` (Core/Models/EntryType.swift)

```swift
enum EntryType: String, Codable, CaseIterable, Sendable {
    case text      // Plain text from clipboard
    case image     // PNG/TIFF image data (stored as file, hash in DB)
    case rtf       // Rich Text Format (plain text stored, RTF preserved)
    case fileURL   // Copied file paths (newline-separated)
}
```

Each case has a `displayName` and `systemImage` (SF Symbol) for the UI.

#### `ClipboardEntry` (Core/Models/ClipboardEntry.swift)

The main data model. Conforms to GRDB's `FetchableRecord` and `MutablePersistableRecord` for automatic SQLite mapping.

| Property | Type | Description |
|----------|------|-------------|
| `id` | `Int64?` | Auto-incremented primary key (nil before first save) |
| `type` | `EntryType` | What kind of clipboard content |
| `textContent` | `String?` | The text (for .text, .rtf, .fileURL types) |
| `imageHash` | `String?` | SHA256 hash of image data (for dedup + file cache lookup) |
| `sourceAppBundleId` | `String?` | e.g. "com.apple.Safari" |
| `sourceAppName` | `String?` | e.g. "Safari" |
| `isFavorite` | `Bool` | Favorited entries survive history clearing |
| `isPinned` | `Bool` | (Reserved for future use — pinned to top) |
| `createdAt` | `Date` | When the entry was first captured |
| `lastUsedAt` | `Date` | When the entry was last selected/moved to top |
| `useCount` | `Int` | How many times this entry has been selected |
| `contentSizeBytes` | `Int` | Size for pruning calculations |

**Factory methods:**
- `ClipboardEntry.text("Hello", source: "com.app", sourceName: "App")`
- `ClipboardEntry.image(hash: "abc123", sizeBytes: 1024)`

**Computed properties:**
- `.preview` → First 200 chars (truncated with `…`), or "📷 Image", or "📄 filename"

#### `AppSettings` (Core/Models/AppSettings.swift)

Singleton (`AppSettings.shared`) using `@AppStorage` for persistence.

| Setting | Default | Description |
|---------|---------|-------------|
| `maxItems` | 10000 | Max entries before pruning |
| `maxCacheSizeMB` | 10240 | Max total size in MB |
| `stripWhitespace` | false | Auto-trim copied text |
| `confirmBeforeClear` | true | Confirm dialog before clearing |
| `isPrivateMode` | false | Pause recording |
| `windowWidthPercentage` | 33 | Panel width (% of screen) |
| `isAIEnabled` | false | Enable AI Assistant |
| `ollamaUrl` | `http://localhost:11434` | Ollama server URL |
| `ollamaModel` | `llama3.2` | Model to use for AI |
| `aiPromptMode` | 0 | 0=Grammar, 1=Professional, 2=Custom, 3=Natural, 4=Fun, 5=Executive |


#### `BackupManifest` (Core/Models/BackupManifest.swift)

Codable model that stores application settings and the Base64-encoded Keychain passphrase when exporting a backup archive. Used during restore to fully recover the app state.
### 2.2 Protocols

#### `EntryRepository` (Core/Protocols/EntryRepository.swift)

The central data access interface. Any storage implementation must conform.

```swift
protocol EntryRepository: Sendable {
    // CRUD
    func save(_ entry: inout ClipboardEntry) async throws
    func delete(id: Int64) async throws
    func deleteAll(keepFavorites: Bool) async throws

    // Queries (pagination built-in)
    func fetchPage(offset: Int, limit: Int) async throws -> [ClipboardEntry]
    func fetchHistoryPage(offset: Int, limit: Int) async throws -> [ClipboardEntry]
    func fetchFavorites() async throws -> [ClipboardEntry]
    func search(criteria: SearchCriteria, offset: Int, limit: Int) async throws -> [ClipboardEntry]
    func fetchEntry(id: Int64) async throws -> ClipboardEntry?

    // Mutations
    func toggleFavorite(id: Int64) async throws -> ClipboardEntry?
    func moveToTop(id: Int64) async throws
    func updateUseCount(id: Int64) async throws

    // Dedup
    func findDuplicateText(textContent: String) async throws -> ClipboardEntry?
    func findDuplicateRTF(textContent: String, rtfData: Data) async throws -> ClipboardEntry?
    func findDuplicateFileURLs(textContent: String) async throws -> ClipboardEntry?
    func findDuplicate(imageHash: String) async throws -> ClipboardEntry?

    // Maintenance
    func prune(maxItems: Int, maxBytes: Int) async throws -> Int
    func totalCount() async throws -> Int
    func totalBytes() async throws -> Int
    func fetchImageHashes() async throws -> Set<String>
}
```

#### `ClipboardWriting` (Core/Protocols/ClipboardAccessor.swift)

Abstraction for writing persisted entries back to the system clipboard.

#### `ImageCacheProtocol` (defined in EntryManager.swift)

```swift
protocol ImageCacheProtocol: Sendable {
    func save(data: Data, forHash hash: String)
    func load(forHash hash: String) -> Data?
    func delete(forHash hash: String)
}
```

### 2.3 Services

#### `EntryManager` (Core/Services/EntryManager.swift)

**The main business logic coordinator.** `@MainActor` isolated.

Responsibilities:
- Process new clipboard content (text, RTF, image, file URLs)
- Deduplicate: if the same content and type exists, move it to top instead of creating a new entry
- Prune: after each save, delete old entries exceeding limits
- Track the latest selected entry for keyboard cycling
- Coordinate favorites, deletion, clearing
- Reconcile orphaned image cache files after delete, clear, startup, or real prune events

Key methods:
- `processNewText(_ text:, source:, sourceName:)` → dedup → save → prune
- `processNewRTF(plainText:, rtfData:, source:, sourceName:)` → same flow
- `processNewImage(_ data:, source:, sourceName:)` → hash → dedup → cache file → save
- `processNewFileURLs(_ paths:, source:, sourceName:)` → dedup → save
- `select(_ entry:)` → move to top + increment use count
- `toggleFavorite(_ entry:)` → toggle via repository
- `delete(_ entry:)` → delete + clean up image cache
- `clearHistory(keepFavorites:)` → delete all (optionally keep favorites)
- `reconcileStoredAssets()` → remove orphaned cached image files

#### `OllamaService` (Core/Services/OllamaService.swift)

Handles communication with a local Ollama API to rewrite text using LLMs (e.g., Llama 3, Gemma). Uses the `/api/generate` endpoint with `system` and `prompt` separation to prevent conversational responses. Provides a stateless `improveText` method.


#### `BackupService` (Core/Services/BackupService.swift)

Handles creating and extracting encrypted `.clipstash_backup` archives.
- **Export**: Uses GRDB's concurrent backup API (`dbPool.backup()`) to copy the database, zips it along with the image cache and manifest, and encrypts the ZIP using `CryptoKit` (AES-GCM with PBKDF2-SHA256 key derivation, 600k iterations, from the user's password). The v2 file format includes a `"CSB"` magic header with embedded iteration count for forward compatibility.
- **Import**: Auto-detects the backup file format (v2 PBKDF2 or legacy v1 HKDF), decrypts the archive, performs a preflight database validation (integrity check + read test) before committing, hot-swaps the database and image cache directory, atomically updates the Keychain secret (preserving the previous key for rollback on failure), and triggers an app restart.

---

## 3. Storage Layer

**Path:** `ClipStash/Storage/`

### 3.1 `AppDatabase` (Storage/Database.swift)

Creates and configures the SQLite database using GRDB + SQLCipher.

**Configuration:**
- **SQLCipher passphrase** — loaded for every connection from the current passphrase provider
- **WAL mode** (Write-Ahead Logging) — allows concurrent reads while writing
- **SYNCHRONOUS=NORMAL** — slightly faster, still safe with WAL
- **Foreign keys enabled**

**Migrations:**
- `v1_createClipboardEntry` — creates main table with indices
- `v1_createFTS` — creates FTS5 virtual table for full-text search

**FTS5 tokenizer:** Porter stemmer wrapping unicode61
→ Handles English stemming ("programming" matches "program")
→ Unicode-aware tokenization

**Important paths:**
- Production DB: `~/Library/Application Support/ClipStash/clipboard.db`
- Test DB: `/tmp/clipstash_test_<UUID>.db` (temporary file per test)
- Production DB key: macOS Keychain item `com.clipstash.app.database / primary-key`
- Production data is local-only and encrypted at rest

### 3.2 `DatabasePassphraseProvider` (Storage/DatabasePassphraseProvider.swift)

Coordinates secure database key handling.

There are two runtime providers:
- `KeychainDatabasePassphraseProvider` — production provider; creates a 32-byte random key on first launch and stores it in macOS Keychain
- `EphemeralDatabasePassphraseProvider` — fallback/session provider used for tests and recovery-only temporary databases

**First-launch flow:**
1. Look up the ClipStash database key in Keychain
2. If it exists, reuse it
3. If it does not exist and the database file does not exist yet, generate a new random key and store it in Keychain
4. If it does not exist but the encrypted database file already exists, fail loudly instead of silently generating a different key

That last rule prevents “history disappeared” bugs caused by accidentally opening an old encrypted database with a brand-new key.

### 3.3 `SQLiteEntryRepository` (Storage/SQLiteEntryRepository.swift)

Implements `EntryRepository` protocol using GRDB.
197 lines covering all CRUD, search, prune, and dedup operations.

**Search strategy:**
1. Parse the raw search string into `SearchCriteria`
2. Use FTS5 `MATCH` only for the free-text terms
3. Apply type/app/favorite/date filters in SQL so pagination stays correct

**Prune strategy (in single transaction):**
1. Delete oldest non-favorite entries exceeding `maxItems`
2. If total bytes still exceed `maxBytes`, delete more oldest entries
3. Never delete favorites

### 3.3 `ImageFileCache` (Storage/ImageFileCache.swift)

File-based image storage. Each image is saved as a file named by its SHA256 hash.

Path: `~/Library/Application Support/ClipStash/images/<sha256hash>`

Has `cleanOrphans(validHashes:)` for removing files no longer referenced in DB.

---

## 4. Platform Layer

**Path:** `ClipStash/Platform/`
**macOS-specific code** that can't exist in Core.

### 4.1 `ClipboardMonitor` (Platform/ClipboardMonitor.swift)

Polls `NSPasteboard.general.changeCount` using an **adaptive timer**:
- **0.45s** in normal mode
- **0.9s** in Low Power Mode
- **1.2s** in Private Mode

The timer also uses tolerance so macOS can coalesce wakeups more efficiently.

Why polling? macOS has no clipboard change API:
- Fast enough to catch normal copy actions
- Lighter on battery than a fixed aggressive timer

**Content detection priority:** RTF → Text → Image → File URLs
(RTF contains plain text too, so we prefer RTF when available)

**Debounce mechanism:** When we write to the clipboard ourselves, we increment `debounceCount` to skip the next change detection.

**Privacy checks (in order):**
1. Private mode → skip

### 4.2 `GlobalHotKeyService` (Platform/GlobalHotKeyService.swift)

Custom implementation using Carbon `RegisterEventHotKey` API.

Why not KeyboardShortcuts library? It uses Swift macros (#Preview) that don't compile with `swift build` CLI (only Xcode).

The service:
- Installs a Carbon event handler at app launch
- Registers hotkeys with key code + modifier mask
- Dispatches to handler closures on main thread
- Provides `unregister(id:)` and `unregisterAll()`

Registered shortcuts:
- `⌃⌘V` — toggle clipboard panel
- `⌘⇧P` — toggle private mode
- `⌘⌥I` — Magic Replace with AI
- `⌘⇧←` / `⌘⇧→` — cycle through recent entries

### 4.3 `LoginItemHelper` (Platform/LoginItemHelper.swift)

Wraps LaunchAtLogin library's `LaunchAtLogin.Toggle` SwiftUI view.
Uses `SMAppService` under the hood (macOS 13+ modern API).

---

## 5. ViewModel Layer

**Path:** `ClipStash/ViewModels/`

### 5.1 `HistoryViewModel` (ViewModels/HistoryViewModel.swift)

`@MainActor`, `ObservableObject`. Drives the main popover UI.

**State:**
- `entries: [ClipboardEntry]` — current page of history
- `favorites: [ClipboardEntry]` — all favorites
- `searchQuery: String` — bound to search field (debounced 200ms)
- `hasMore: Bool` — whether more pages exist
- `isLoading: Bool` — loading indicator
- `showClearConfirmation: Bool` — alert trigger

**Key flows:**
- `loadInitial()` — parallel fetch of favorites + first page
- `loadNextPage()` — infinite scroll pagination (50 per page)
- `select(entry)` — write to pasteboard → close panel → move to top
- `toggleFavorite(entry)` — moves between favorites/history lists
- `delete(entry)` — removes from UI and DB
- `clearAll()` → `performClear()` — clears history, keeps favorites

### 5.2 `SettingsViewModel` (ViewModels/SettingsViewModel.swift)

Drives the inline settings content and fallback Settings scene. Loads stats (total items, total size).

---

## 6. UI Layer

**Path:** `ClipStash/UI/`

All views are SwiftUI. The menu bar presence is managed by `NSStatusItem` + `NSPopover` through `StatusItemController`.

| View | Purpose |
|------|---------|
| `PopoverView` | Main panel: search bar + favorites + history list + toolbar |
| `HistoryListView` | `ScrollView` + `LazyVStack` with auto-pagination on scroll |
| `EntryRowView` | Single row: icon, preview text, source app, time, hover actions |
| `SearchBarView` | Text field with magnifying glass and clear button |
| `FavoritesView` | Collapsible section with star icon header |
| `SettingsView` | Inline settings content shown inside the panel, plus fallback Settings scene |
| `EntryContextMenu` | Right-click menu: Copy and Close, Favorite, Copy Text, AI submenu (per-mode), Delete |
| `MenuBarIcon` | SF Symbols icon generator for the status item |

---

## 7. App Wiring

### Entry Point

`ClipStashEntry/main.swift` calls `ClipStashLib.runApp()` which calls `ClipStashApp.main()`.

### Dependency Injection (AppDelegate)

`AppDelegate.init()` creates the entire dependency graph:

```
AppDatabase ─────→ SQLiteEntryRepository ─→ EntryManager ─→ ClipboardMonitor
                                          ↗               ↗
ImageFileCache ──────────────────────────┘               /
AppSettings.shared ─────────────────────────────────────┘
                    ↘
                     HistoryViewModel / SettingsViewModel / StatusItemController
```

All objects are created once and live for the app's lifetime.

---

## 8. Data Flows

### Copy Flow (user copies text in Safari)

```
1. User presses ⌘C in Safari
2. NSPasteboard.changeCount increments
3. ClipboardMonitor detects change (next adaptive poll)
4. Checks: not private mode
5. Reads pasteboard: string found → calls entryManager.processNewText()
6. EntryManager: strip whitespace (if enabled)
7. EntryManager: check dedup → no duplicate found
8. EntryManager: save via repository → SQLite INSERT
9. EntryManager: prune if over limits
10. EntryManager: updates history state and pruning/image-cache maintenance
```

### Selection Flow (user selects entry in panel)

```
1. User clicks entry in HistoryListView
2. EntryRowView.onTapGesture → HistoryViewModel.select(entry)
3. ViewModel: clipboardMonitor.beginDebounce() (prevent re-capture)
4. ViewModel: NSPasteboard.setString(text)
5. PopoverView closes the panel window
6. EntryManager: moveToTop(id) + updateUseCount(id)
```

### Search Flow

```
1. User types "hello" in SearchBarView
2. Binding updates HistoryViewModel.searchQuery
3. Combine: debounce 200ms → performSearch("hello")
4. Repository: FTS5 MATCH "hello*" (prefix search)
5. Results populate entries array
6. LazyVStack updates with search results
```

### Magic Replace Flow (AI)

```
1. User selects text in any app and presses ⌘⌥I
2. AppDelegate simulates ⌘C to copy text
3. Reads text from pasteboard
4. Calls OllamaService to rewrite the text based on current settings
5. EntryManager saves new text to history as "✨ AI Assistant"
6. AppDelegate writes new text to pasteboard and simulates ⌘V
```

---

## 9. Database Schema

### Table: `clipboardEntry`

| Column | Type | Constraints |
|--------|------|-------------|
| id | INTEGER | PRIMARY KEY AUTOINCREMENT |
| type | TEXT | NOT NULL |
| textContent | TEXT | nullable |
| imageHash | TEXT | nullable |
| sourceAppBundleId | TEXT | nullable |
| sourceAppName | TEXT | nullable |
| isFavorite | BOOLEAN | NOT NULL DEFAULT 0 |
| isPinned | BOOLEAN | NOT NULL DEFAULT 0 |
| createdAt | DATETIME | NOT NULL |
| lastUsedAt | DATETIME | NOT NULL |
| useCount | INTEGER | NOT NULL DEFAULT 1 |
| contentSizeBytes | INTEGER | NOT NULL DEFAULT 0 |

### Indices

| Index | Columns | Purpose |
|-------|---------|---------|
| idx_clipboardEntry_lastUsedAt | lastUsedAt | ORDER BY in fetch/prune |
| idx_clipboardEntry_isFavorite | isFavorite | Filter favorites |
| idx_clipboardEntry_imageHash | imageHash | Image dedup lookup |
| idx_clipboardEntry_createdAt | createdAt | Chronological queries |

### Virtual Table: `clipboardEntryFts` (FTS5)

Synchronized with `clipboardEntry`. Indexes `textContent` column.
Tokenizer: Porter stemmer wrapping unicode61.

---

## 10. Concurrency Model

- **Swift 6 strict concurrency** — the project compiles with full Sendable checking
- **`@MainActor`** — EntryManager, ClipboardMonitor, ViewModels, AppDelegate
- **All DB operations are `async`** — GRDB's `DatabasePool` handles thread safety
- **WAL mode** — readers don't block writers, writers don't block readers
- **Timer** runs on main RunLoop with adaptive clipboard polling and tolerance
- **Carbon hotkey handler** dispatches to main queue via `DispatchQueue.main.async`

---

## 11. Design Decisions

### Why SQLite instead of a custom binary log?

| Aspect | Custom Binary | SQLite + GRDB |
|--------|---------------|---------------|
| Crash safety | Manual | WAL = automatic ACID |
| Full-text search | O(n) scan | FTS5 = O(log n) |
| Schema evolution | Impossible | Migrations = trivial |
| Deduplication | Custom index | DB index + UNIQUE |
| Pruning | Manual compaction | DELETE + auto-vacuum |
| Code complexity | ~500 lines | ~200 lines |

### Why Carbon hotkeys instead of KeyboardShortcuts library?

KeyboardShortcuts uses Swift macros (#Preview) that require Xcode to build.
Since this project targets `swift build` CLI, we use Carbon's `RegisterEventHotKey` directly.
It's ~120 lines, battle-tested (Carbon hotkey API exists since macOS 10.0).

### Why polling instead of callbacks?

macOS provides no clipboard change callback.
`NSPasteboard.general.changeCount` is the official approach used by all clipboard managers.
ClipStash uses adaptive polling with timer tolerance to reduce wakeups in Low Power Mode and Private Mode.

### Why `@AppStorage` instead of a settings file?

- Zero-code persistence — just declare the property
- Automatic UserDefaults sync
- SwiftUI bindings work directly
- Adding a new setting = 1 line of code

### Why no Core Data?

- GRDB is faster for this use case (simple table, many writes)
- FTS5 has no Core Data equivalent
- WAL mode is configurable directly
- Migration system is simpler
- No need for object graph or relationships
