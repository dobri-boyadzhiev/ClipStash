import AppKit
import SwiftUI

import LaunchAtLogin

/// AppDelegate handles app lifecycle events and serves as the DI container.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Core services
    private(set) var database: AppDatabase!
    private(set) var repository: SQLiteEntryRepository!
    private(set) var imageCache: ImageFileCache!
    private(set) var entryManager: EntryManager!
    private(set) var clipboardMonitor: ClipboardMonitor!
    private(set) var clipboardWriter: PasteboardClipboardWriter!
    private(set) var dataResetService: AppDataResetService!
    private(set) var statusItemController: StatusItemController!
    private let hotKeyService = GlobalHotKeyService.shared
    private let databasePassphraseProvider: KeychainDatabasePassphraseProvider
    private let databaseSecurityStatus: DatabaseSecurityStatus
    private let startupAlertMessage: String?
    
    // MARK: - ViewModels
    private(set) var historyViewModel: HistoryViewModel!
    private(set) var settingsViewModel: SettingsViewModel!
    
    private let settings = AppSettings.shared
    
    override init() {
        let databasePassphraseProvider = KeychainDatabasePassphraseProvider(databaseURL: AppDatabase.defaultURL)
        let databaseBootstrap = AppDatabaseBootstrapper(passphraseProvider: databasePassphraseProvider).bootstrap()
        self.databasePassphraseProvider = databasePassphraseProvider
        self.databaseSecurityStatus = databaseBootstrap.securityStatus
        self.startupAlertMessage = databaseBootstrap.startupAlertMessage
        super.init()

        database = databaseBootstrap.database
        repository = SQLiteEntryRepository(database: database)
        imageCache = ImageFileCache(passphraseProvider: databasePassphraseProvider)
        entryManager = EntryManager(repository: repository, settings: settings, imageCache: imageCache)
        clipboardMonitor = ClipboardMonitor(entryManager: entryManager, settings: settings)
        clipboardWriter = PasteboardClipboardWriter(imageCache: imageCache)
        
        historyViewModel = HistoryViewModel(
            repository: repository,
            entryManager: entryManager,
            clipboardMonitor: clipboardMonitor,
            clipboardWriter: clipboardWriter,
            settings: settings
        )
        dataResetService = AppDataResetService(
            settings: settings,
            database: database,
            passphraseProvider: databasePassphraseProvider,
            dataDirectoryURL: AppDatabase.appSupportDirectoryURL,
            prepareForReset: { [weak self] in
                self?.clipboardMonitor.stop()
                self?.hotKeyService.unregisterAll()
            },
            terminateApplication: { NSApp.terminate(nil) },
            setLaunchAtLoginEnabled: { LaunchAtLogin.isEnabled = $0 }
        )
        settingsViewModel = SettingsViewModel(
            settings: settings,
            repository: repository,
            dataResetService: dataResetService,
            database: database,
            databasePassphraseProvider: databasePassphraseProvider,
            databaseSecurityStatus: databaseSecurityStatus
        )
        statusItemController = StatusItemController(
            settings: settings,
            imageCache: imageCache,
            historyViewModel: historyViewModel,
            settingsViewModel: settingsViewModel
        )

        NotificationCenter.default.addObserver(forName: NSNotification.Name("CloseDatabaseForRestore"), object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clipboardMonitor.stop()
                self?.hotKeyService.unregisterAll()
                try? self?.database.dbPool.close()
            }
        }

        NotificationCenter.default.addObserver(forName: NSNotification.Name("RestoreCompleted"), object: nil, queue: nil) { _ in
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Restore Successful"
                alert.informativeText = "ClipStash has been restored successfully. The app will now quit. Please reopen it to apply the changes."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSApp.terminate(nil)
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        clipboardMonitor.start()
        registerGlobalShortcuts()
        Task { await entryManager.reconcileStoredAssets() }
        presentStartupAlertIfNeeded()
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor.stop()
        hotKeyService.unregisterAll()
    }
    
    // MARK: - Global Shortcuts
    
    private func registerGlobalShortcuts() {
        // Cmd+Shift+P — toggle private mode
        hotKeyService.register(
            keyCode: GlobalHotKeyService.KeyCode.p,
            modifiers: GlobalHotKeyService.Modifiers.cmdShift
        ) { [weak self] in
            self?.settings.togglePrivateMode()
        }

        // Ctrl+Cmd+V — toggle clipboard panel
        hotKeyService.register(
            keyCode: GlobalHotKeyService.KeyCode.v,
            modifiers: GlobalHotKeyService.Modifiers.cmdControl
        ) { [weak self] in
            self?.statusItemController.togglePopover()
        }
        
        // Cmd+Shift+Left — previous entry
        hotKeyService.register(
            keyCode: GlobalHotKeyService.KeyCode.left,
            modifiers: GlobalHotKeyService.Modifiers.cmdShift
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.cycleToPreviousEntry() }
        }
        
        // Cmd+Shift+Right — next entry
        hotKeyService.register(
            keyCode: GlobalHotKeyService.KeyCode.right,
            modifiers: GlobalHotKeyService.Modifiers.cmdShift
        ) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.cycleToNextEntry() }
        }

        // Cmd+Option+I — Magic Replace with AI
        hotKeyService.register(
            keyCode: GlobalHotKeyService.KeyCode.i,
            modifiers: GlobalHotKeyService.Modifiers.cmdOption
        ) { [weak self] in
            guard let self, self.settings.isAIEnabled else { return }
            Task { @MainActor in await self.performMagicReplace() }
        }
    }
    
    private func cycleToPreviousEntry() async {
        let entries = (try? await repository.fetchPage(offset: 0, limit: 10)) ?? []
        guard entries.count >= 2 else { return }
        if let current = entryManager.latestEntry,
           let idx = entries.firstIndex(where: { $0.id == current.id }),
           idx + 1 < entries.count {
            _ = await historyViewModel.select(entries[idx + 1])
        } else {
            _ = await historyViewModel.select(entries[0])
        }
    }
    
    private func cycleToNextEntry() async {
        let entries = (try? await repository.fetchPage(offset: 0, limit: 10)) ?? []
        guard entries.count >= 2 else { return }
        if let current = entryManager.latestEntry,
           let idx = entries.firstIndex(where: { $0.id == current.id }),
           idx > 0 {
            _ = await historyViewModel.select(entries[idx - 1])
        } else if let last = entries.last {
            _ = await historyViewModel.select(last)
        }
    }

    private func performMagicReplace() async {
        let initialChangeCount = NSPasteboard.general.changeCount

        // 1. Tell ClipboardMonitor to ignore the next change
        clipboardMonitor.beginDebounce()

        // 2. Simulate Cmd+C to copy selected text
        await simulateKeystroke(keyCode: 8, modifiers: .maskCommand) // 8 is C

        // Wait for clipboard to update (up to 500ms)
        var waited = 0
        while NSPasteboard.general.changeCount == initialChangeCount && waited < 500 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            waited += 50
        }

        // If nothing was copied (e.g. no text selected or modifiers blocked the copy), cancel the debounce
        if NSPasteboard.general.changeCount == initialChangeCount {
            clipboardMonitor.cancelDebounce()
            return
        }

        guard let text = NSPasteboard.general.string(forType: .string) else {
            clipboardMonitor.cancelDebounce()
            return
        }

        do {
            let improvedText = try await OllamaService.improveText(
                text,
                urlString: self.settings.ollamaUrl,
                model: self.settings.ollamaModel,
                promptMode: self.settings.aiPromptMode,
                customPrompt: self.settings.customAIPrompt
            )

            // Save to entryManager so it's in history
            await self.entryManager.processNewText(improvedText, source: "Ollama", sourceName: "✨ AI Assistant")

            // 3. Tell ClipboardMonitor to ignore the upcoming change we are about to make
            clipboardMonitor.beginDebounce()

            // Write to pasteboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(improvedText, forType: .string)

            // Wait for pasteboard to update
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

            // Simulate Cmd+V to paste
            await simulateKeystroke(keyCode: 9, modifiers: .maskCommand) // 9 is V
        } catch {
            print("Magic Replace failed: \(error)")
        }
    }

    private func simulateKeystroke(keyCode: CGKeyCode, modifiers: CGEventFlags) async {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)

        keyDown?.flags = modifiers
        keyUp?.flags = modifiers

        keyDown?.post(tap: .cghidEventTap)
        // Add a small 20ms delay between key down and key up to ensure the OS registers it
        try? await Task.sleep(nanoseconds: 20_000_000)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func presentStartupAlertIfNeeded() {
        guard let startupAlertMessage else { return }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClipStash secure storage needs attention"
        alert.informativeText = startupAlertMessage
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
