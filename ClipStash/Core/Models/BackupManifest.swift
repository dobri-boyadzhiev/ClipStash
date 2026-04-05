import Foundation

struct BackupManifest: Codable {
    static let currentVersion = 1
    static let supportedVersions: ClosedRange<Int> = 1...1

    let version: Int
    let keychainPassphraseBase64: String
    
    // User Settings
    let maxItems: Int
    let maxCacheSizeMB: Int
    let maxEntrySizeMB: Int?
    let stripWhitespace: Bool
    let confirmBeforeClear: Bool
    let windowWidthPercentage: Int
    let isAIEnabled: Bool
    let ollamaUrl: String
    let ollamaModel: String
    let aiPromptMode: Int
    let customAIPrompt: String
    
    @MainActor
    init(keychainPassphraseBase64: String, settings: AppSettings) {
        self.version = Self.currentVersion
        self.keychainPassphraseBase64 = keychainPassphraseBase64
        self.maxItems = settings.maxItems
        self.maxCacheSizeMB = settings.maxCacheSizeMB
        self.maxEntrySizeMB = settings.maxEntrySizeMB
        self.stripWhitespace = settings.stripWhitespace
        self.confirmBeforeClear = settings.confirmBeforeClear
        self.windowWidthPercentage = settings.windowWidthPercentage
        self.isAIEnabled = settings.isAIEnabled
        self.ollamaUrl = settings.ollamaUrl
        self.ollamaModel = settings.ollamaModel
        self.aiPromptMode = settings.aiPromptMode
        self.customAIPrompt = settings.customAIPrompt
    }
    
    @MainActor
    func apply(to settings: AppSettings) {
        settings.maxItems = self.maxItems
        settings.maxCacheSizeMB = self.maxCacheSizeMB
        if let maxEntrySizeMB { settings.maxEntrySizeMB = maxEntrySizeMB }
        settings.stripWhitespace = self.stripWhitespace
        settings.confirmBeforeClear = self.confirmBeforeClear
        settings.windowWidthPercentage = self.windowWidthPercentage
        settings.isAIEnabled = self.isAIEnabled
        settings.ollamaUrl = self.ollamaUrl
        settings.ollamaModel = self.ollamaModel
        settings.aiPromptMode = self.aiPromptMode
        settings.customAIPrompt = self.customAIPrompt
    }
}
