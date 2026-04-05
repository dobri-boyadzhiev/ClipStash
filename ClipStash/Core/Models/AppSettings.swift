import Foundation
import Combine

// MARK: - App Settings
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private static let legacyStorageKeys = [
        "excludedApps",
        "ignorePasswordManagers",
        "topBarDisplayMode",
        "topBarPreviewLength"
    ]
    
    // History
    var maxItems: Int {
        get { UserDefaults.standard.object(forKey: "maxItems") as? Int ?? 10_000 }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "maxItems") }
    }
    var maxCacheSizeMB: Int {
        get { UserDefaults.standard.object(forKey: "maxCacheSizeMB") as? Int ?? 10_240 }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "maxCacheSizeMB") }
    }

    // Behavior
    var stripWhitespace: Bool {
        get { UserDefaults.standard.object(forKey: "stripWhitespace") as? Bool ?? false }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "stripWhitespace") }
    }
    var confirmBeforeClear: Bool {
        get { UserDefaults.standard.object(forKey: "confirmBeforeClear") as? Bool ?? true }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "confirmBeforeClear") }
    }
    var launchAtLogin: Bool {
        get { UserDefaults.standard.object(forKey: "launchAtLogin") as? Bool ?? false }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "launchAtLogin") }
    }

    // Display
    var windowWidthPercentage: Int {
        get { UserDefaults.standard.object(forKey: "windowWidthPercentage") as? Int ?? 33 }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "windowWidthPercentage") }
    }

    // Privacy
    var isPrivateMode: Bool {
        get { UserDefaults.standard.object(forKey: "isPrivateMode") as? Bool ?? false }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "isPrivateMode") }
    }

    // AI Assistant
    var isAIEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "isAIEnabled") as? Bool ?? false }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "isAIEnabled") }
    }
    var ollamaUrl: String {
        get { UserDefaults.standard.object(forKey: "ollamaUrl") as? String ?? "http://localhost:11434" }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "ollamaUrl") }
    }
    var ollamaModel: String {
        get { UserDefaults.standard.object(forKey: "ollamaModel") as? String ?? "llama3.2" }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "ollamaModel") }
    }
    var aiPromptMode: Int { // 0 = Grammar, 1 = Professional, 2 = Custom, 3 = Natural, 4 = Fun, 5 = Executive
        get { UserDefaults.standard.object(forKey: "aiPromptMode") as? Int ?? 0 }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "aiPromptMode") }
    }
    var customAIPrompt: String {
        get { UserDefaults.standard.object(forKey: "customAIPrompt") as? String ?? "" }
        set { objectWillChange.send(); UserDefaults.standard.set(newValue, forKey: "customAIPrompt") }
    }
    
    @MainActor
    func setPrivateMode(_ isEnabled: Bool) {
        objectWillChange.send()
        isPrivateMode = isEnabled
    }

    @MainActor
    func togglePrivateMode() {
        setPrivateMode(!isPrivateMode)
    }

    @MainActor
    func resetToDefaults() {
        objectWillChange.send()
        maxItems = 10_000
        maxCacheSizeMB = 10_240
        stripWhitespace = false
        confirmBeforeClear = true
        launchAtLogin = false
        windowWidthPercentage = 33
        isPrivateMode = false
        isAIEnabled = false
        ollamaUrl = "http://localhost:11434"
        ollamaModel = "llama3.2"
        aiPromptMode = 0
        customAIPrompt = ""
    }

    private init() {
        let defaults = UserDefaults.standard
        for key in Self.legacyStorageKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
