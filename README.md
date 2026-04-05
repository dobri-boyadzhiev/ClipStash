# ClipStash — Clipboard History Manager for macOS

A native, lightweight clipboard history manager for macOS (Apple Silicon).  
Inspired by the GNOME Clipboard History extension, rebuilt from scratch for macOS using Swift and SwiftUI.

## Features

| Feature | Description |
|---------|-------------|
| 📋 **Clipboard History** | Automatically records everything you copy — text, RTF, images, file paths |
| 🔍 **Full-text Search** | Instant search powered by SQLite FTS5 (full-text search engine) |
| ⭐ **Favorites** | Pin important items — they survive history clearing |
| 🔒 **Private Mode** | Temporarily pauses clipboard recording |
| 📊 **Source Tracking** | Shows which app each clipboard entry came from |
| ♻️ **Deduplication** | Same text copied twice? Just moves to top (no duplicates) |
| 🤖 **AI Assistant** | Use local models via Ollama to instantly improve/rewrite copied text securely |
| 💾 **Backup & Restore** | Export history and settings to an encrypted, password-protected archive |
| 🧹 **Auto Pruning** | Old entries pruned automatically by count or total size |
| 🚀 **Launch at Login** | Runs silently in menu bar on startup |
| ✂️ **Strip Whitespace** | Optional automatic trimming of copied text |
| 📐 **Click to Copy** | Select entry → copy the chosen item to the clipboard and close the panel |
| 🔐 **Encrypted Database** | SQLCipher protects the local clipboard database at rest |

## Keyboard Shortcuts

### Global (work from any app)

| Shortcut | Action |
|----------|--------|
| `⌃⌘V` | Toggle the clipboard panel open/closed |
| `⌘⇧P` | Toggle Private Mode on/off |
| `⌘⌥I` | Magic Replace with AI (Requires Ollama configured in Settings) |
| `⌘⇧←` | Cycle to previous entry (copies without opening panel) |
| `⌘⇧→` | Cycle to next entry |

### In-Panel (when panel is open)

| Shortcut | Action |
|----------|--------|
| `/` | Focus search field |

## Requirements

- **macOS 14 (Sonoma)** or later
- **Apple Silicon** (M1/M2/M3/M4) — ARM64 native binary

## Installation

### From DMG

```bash
# Build the DMG
cd ClipStash
bash scripts/build.sh 1.0.22

# Install
open /tmp/ClipStash-1.0.22.dmg
# → Drag ClipStash.app to Applications
```

### From Source (Xcode)

```bash
cd ClipStash
open Package.swift   # Opens in Xcode
# Xcode → Product → Run (⌘R)
```

### From Source (Command Line)

```bash
cd ClipStash
swift build --scratch-path /tmp/clipstash-build
# Binary: /tmp/clipstash-build/arm64-apple-macosx/debug/ClipStashApp
```

## Running Tests

```bash
cd ClipStash
swift run --scratch-path /tmp/clipstash-build ClipStashTests
```

Expected output: `✅ All tests passed!`

## Privacy & Security

- ClipStash stores clipboard history only on the local Mac.
- The SQLite database is encrypted at rest with SQLCipher.
- On first launch, ClipStash generates a random database key and stores it in macOS Keychain.
- If the Keychain item is missing but an encrypted database still exists, ClipStash warns and falls back to a temporary encrypted session database instead of silently creating a new key.
- Use `Private Mode` before copying secrets that should never be stored in history at all.
- `Delete All Data` removes the local database, cached images, saved settings, and the stored Keychain key.

## Project Structure

```
ClipStash/
├── Package.swift                          # SPM manifest (Swift 6.0)
├── scripts/build.sh                       # Build + DMG creation script
│
├── ClipStash/                             # Main library (ClipStashLib target)
│   ├── ClipStashApp.swift                 # App scene entry point
│   ├── AppDelegate.swift                  # Lifecycle, DI container, global hotkeys
│   │
│   ├── Core/                              # Pure Swift — no platform imports
│   │   ├── Models/
│   │   │   ├── EntryType.swift            # .text | .image | .rtf | .fileURL
│   │   │   ├── ClipboardEntry.swift       # Main data model (GRDB record)
│   │   │   ├── AppSettings.swift          # All settings via @AppStorage
│   │   │   └── BackupManifest.swift       # Backup metadata and settings
│   │   ├── Protocols/
│   │   │   ├── EntryRepository.swift      # Data access interface
│   │   │   └── ClipboardAccessor.swift    # Clipboard write abstraction
│   │   └── Services/
│   │       ├── EntryManager.swift         # Business logic: save, dedup, prune
│   │       ├── AppDataResetService.swift  # Delete-all-data flow + app reset
│   │       └── BackupService.swift        # Encrypted backup & restore
│   │
│   ├── Storage/                           # SQLite persistence
│   │   ├── Database.swift                 # WAL mode, FTS5, schema migrations
│   │   ├── SQLiteEntryRepository.swift    # Full CRUD, search, prune
│   │   └── ImageFileCache.swift           # SHA256-keyed image file storage
│   │
│   ├── Platform/                          # macOS-specific APIs (AppKit, Carbon)
│   │   ├── ClipboardMonitor.swift         # Adaptive NSPasteboard polling with timer tolerance
│   │   ├── GlobalHotKeyService.swift      # Carbon Event hotkey registration
│   │   └── LoginItemHelper.swift          # Launch at login toggle
│   │
│   ├── ViewModels/
│   │   ├── HistoryViewModel.swift         # Main panel state + pagination
│   │   └── SettingsViewModel.swift        # Settings + stats
│   │
│   └── UI/                                # SwiftUI views
│       ├── PopoverView.swift              # Main panel layout
│       ├── HistoryListView.swift          # Scrollable, paginated entry list
│       ├── EntryRowView.swift             # Single clipboard entry row
│       ├── SearchBarView.swift            # Search input field
│       ├── FavoritesView.swift            # Collapsible favorites section
│       ├── SettingsView.swift             # Inline settings content + fallback scene
│       └── Components/
│           ├── EntryContextMenu.swift     # Right-click menu
│           └── MenuBarIcon.swift          # SF Symbols menu bar icon
│
├── ClipStashEntry/                        # Executable target
│   └── main.swift                         # Entry point → calls runApp()
│
└── ClipStashTests/                        # Test suite
    └── ClipStashTests.swift               # Standalone runner with regression coverage
```

## Architecture Overview

The project follows a **4-layer architecture** with strict dependency rules:

```
┌─────────────────────────────────────────────┐
│  UI Layer (SwiftUI)                         │
│  PopoverView, SettingsView, EntryRowView    │
│  Depends on: ViewModels                     │
├─────────────────────────────────────────────┤
│  ViewModel Layer                            │
│  HistoryViewModel, SettingsViewModel        │
│  Depends on: Core, Platform                 │
├─────────────────────────────────────────────┤
│  Core Layer (Pure Swift)                    │
│  Models, Protocols, Services                │
│  Depends on: NOTHING (fully testable)       │
├─────────────────────────────────────────────┤
│  Storage Layer          │  Platform Layer   │
│  SQLite + GRDB          │  AppKit, Carbon   │
│  Depends on: Core       │  Depends on: Core │
└─────────────────────────┴───────────────────┘
```

**Key design decisions:**
- Core has **zero** platform imports → fully unit-testable
- All I/O is `async` → never blocks the main thread
- `EntryRepository` protocol → storage is swappable
- SQLite WAL mode → crash-safe, ACID, concurrent reads

## Dependencies

| Library | Purpose | Why |
|---------|---------|-----|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | SQLite wrapper | Fast, type-safe, FTS5 support, migrations, Swift Concurrency |
| [SQLCipher.swift](https://github.com/sqlcipher/SQLCipher.swift) | Encrypted SQLite binary | Protects clipboard history at rest |
| [LaunchAtLogin-Modern](https://github.com/sindresorhus/LaunchAtLogin-Modern) | Start at login | Uses SMAppService (modern macOS API), 10 lines of code |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | ZIP archives | Creates and extracts backup archives seamlessly |

## Data Storage

| What | Where |
|------|-------|
| Encrypted database | `~/Library/Application Support/ClipStash/clipboard.db` |
| Image cache | `~/Library/Application Support/ClipStash/images/` |
| Database key | macOS Keychain (`com.clipstash.app.database` / `primary-key`) |
| Settings | `UserDefaults` (standard macOS preferences) |

If secure storage cannot be unlocked on launch, ClipStash falls back to a temporary encrypted session database in `/tmp` and surfaces a warning.

## License

MIT
