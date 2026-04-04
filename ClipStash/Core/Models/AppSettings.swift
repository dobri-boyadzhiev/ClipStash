import Foundation
import Combine

// MARK: - App Settings
final class AppSettings: ObservableObject {
    nonisolated(unsafe) static let shared = AppSettings()
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
    }

    private init() {
        let defaults = UserDefaults.standard
        for key in Self.legacyStorageKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
