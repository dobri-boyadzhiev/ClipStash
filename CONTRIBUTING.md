# Contributing to ClipStash

This guide explains how to add new features, content types, settings, and UI elements.  
The modular architecture makes extensions straightforward — the compiler guides you.

---

## Table of Contents

1. [Adding a New Content Type](#1-adding-a-new-content-type)
2. [Adding a New Setting](#2-adding-a-new-setting)
3. [Adding a New Global Shortcut](#3-adding-a-new-global-shortcut)
4. [Adding a New UI Component](#4-adding-a-new-ui-component)
5. [Adding a Database Migration](#5-adding-a-database-migration)
6. [Removing a Feature](#6-removing-a-feature)
7. [Testing](#7-testing)
8. [Build & Release](#8-build--release)

---

## 1. Adding a New Content Type

**Example: adding HTML clipboard support**

### Step 1: Add case to EntryType

```swift
// Core/Models/EntryType.swift
enum EntryType: String, Codable, CaseIterable, Sendable {
    case text
    case image
    case rtf
    case fileURL
    case html       // ← NEW
}
```

Add `displayName` and `systemImage` in the switch statements.

### Step 2: Update ClipboardMonitor to detect it

```swift
// Platform/ClipboardMonitor.swift — in checkForChanges()
} else if let htmlData = pasteboard.data(forType: .html),
          let htmlString = String(data: htmlData, encoding: .utf8) {
    let plainText = pasteboard.string(forType: .string) ?? htmlString
    Task {
        await entryManager.processNewHTML(plainText: plainText, source: sourceBundle, sourceName: sourceName)
    }
}
```

### Step 3: Add processing method in EntryManager

```swift
// Core/Services/EntryManager.swift
func processNewHTML(plainText: String, source: String?, sourceName: String?) async {
    // Same pattern as processNewRTF
    let content = settings.stripWhitespace ? plainText.trimmingCharacters(in: .whitespacesAndNewlines) : plainText
    guard !content.isEmpty else { return }
    if let existing = try? await repository.findDuplicateText(textContent: content) {
        await handleDuplicate(existing)
        return
    }
    var entry = ClipboardEntry(
        id: nil, type: .html, textContent: content, imageHash: nil,
        sourceAppBundleId: source, sourceAppName: sourceName,
        isFavorite: false, isPinned: false,
        createdAt: Date(), lastUsedAt: Date(),
        useCount: 1, contentSizeBytes: content.utf8.count
    )
    await saveAndPrune(&entry)
}
```

### Step 4: Update EntryRowView preview (if needed)

The `.preview` computed property in `ClipboardEntry` handles unknown types gracefully (falls through to text), so this may not need changes.

### Step 5: Add tests

Add a test to `ClipStashTests.swift` that saves an HTML entry and verifies it's stored correctly.

**That's it.** No database migration needed — `type` is stored as TEXT.

---

## 2. Adding a New Setting

**Example: adding "sound on copy" setting**

### Step 1: Add @AppStorage property

```swift
// Core/Models/AppSettings.swift
@AppStorage("playSoundOnCopy") var playSoundOnCopy: Bool = false
```

### Step 2: Use it in the relevant service

```swift
// Platform/ClipboardMonitor.swift or wherever appropriate
if settings.playSoundOnCopy {
    NSSound(named: "Tink")?.play()
}
```

### Step 3: Add UI toggle in SettingsView

```swift
// UI/SettingsView.swift — in GeneralSettingsTab
Toggle("Play sound on copy", isOn: $settings.playSoundOnCopy)
```

**That's it.** `@AppStorage` handles persistence automatically.

---

## 3. Adding a New Global Shortcut

### Step 1: Register in AppDelegate

```swift
// AppDelegate.swift — in registerGlobalShortcuts()
hotKeyService.register(
    keyCode: GlobalHotKeyService.KeyCode.x,  // or any key code
    modifiers: GlobalHotKeyService.Modifiers.cmdShift
) { [weak self] in
    // Your action here
}
```

### Step 2: Add key code if needed

```swift
// Platform/GlobalHotKeyService.swift — in KeyCode enum
static let x: UInt32 = 7
```

Carbon virtual key codes: https://developer.apple.com/documentation/carbon/universal_access_virtual_key_codes

### Step 3: Document in SettingsView

```swift
// UI/SettingsView.swift — in ShortcutsSettingsTab
LabeledContent("Your shortcut") { Text("⌘⇧X").foregroundStyle(.secondary) }
```

---

## 4. Adding a New UI Component

### Adding to the popover panel

1. Create a new SwiftUI view in `UI/Components/`
2. Add it to `PopoverView.swift` in the appropriate position
3. Pass data from `HistoryViewModel` via bindings or closures

### Adding a new Settings tab

1. Create the tab view:
```swift
struct MyNewTab: View {
    var body: some View {
        Form {
            Section("My Section") {
                // controls
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

2. Add it to `SettingsView.body`:
```swift
MyNewTab()
    .tabItem { Label("My Tab", systemImage: "star") }
```

---

## 5. Adding a Database Migration

When you need to add a column, index, or table:

```swift
// Storage/Database.swift — add after existing migrations in the migrator property

migrator.registerMigration("v2_addCategoryColumn") { db in
    try db.alter(table: "clipboardEntry") { t in
        t.add(column: "category", .text)
    }
    try db.create(index: "idx_clipboardEntry_category",
                  on: "clipboardEntry", columns: ["category"])
}
```

Also update the `ClipboardEntry` struct to include the new property.

**Important:** Never modify existing migrations. Always add new ones.

---

## 6. Removing a Feature

The modular structure makes removal safe:

1. Delete the relevant file(s)
2. **Compile** — the compiler shows every reference that needs updating
3. Fix all compile errors
4. Run tests: `swift run --scratch-path /tmp/clipstash-build ClipStashTests`

**Example: removing image support**
1. Delete `ImageFileCache.swift`
2. Remove `.image` from `EntryType`
3. Compiler errors show you: `EntryManager.processNewImage`, `ClipboardMonitor` image detection, `ClipboardEntry.image()` factory
4. Remove those methods/cases
5. Done

---

## 7. Testing

### Running tests

```bash
cd ClipStash
swift run --scratch-path /tmp/clipstash-build ClipStashTests
```

### Adding a new test

In `ClipStashTests/ClipStashTests.swift`, add inside `TestMain.main()`:

```swift
await t.run("My new test") {
    let db = try AppDatabase.inMemory()
    let repo = SQLiteEntryRepository(database: db)
    
    // Arrange
    var entry = ClipboardEntry.text("Test")
    try await repo.save(&entry)
    
    // Act
    let result = try await repo.fetchPage(offset: 0, limit: 10)
    
    // Assert
    t.checkEqual(result.count, 1)
    t.checkEqual(result[0].textContent, "Test")
}
```

### Test infrastructure

| Function | Usage |
|----------|-------|
| `t.check(condition, message)` | Assert boolean condition is true |
| `t.checkEqual(a, b, message)` | Assert two Equatable values are equal |
| `t.run("name") { ... }` | Run a test, catch and report errors |

Each test gets a fresh in-memory database (temporary file).

---

## 8. Build & Release

### Debug build
```bash
swift build --scratch-path /tmp/clipstash-build
```

### Release build + DMG
```bash
bash scripts/build.sh 1.0.0
# Output: /tmp/ClipStash.app + /tmp/ClipStash-1.0.0.dmg
```

### Code signing (for distribution)

```bash
codesign --force --deep --sign "Developer ID Application: Your Name" /tmp/ClipStash.app
```

### Notarization (for Gatekeeper)

```bash
xcrun notarytool submit /tmp/ClipStash-1.0.0.dmg --apple-id YOU --team-id TEAM
```
