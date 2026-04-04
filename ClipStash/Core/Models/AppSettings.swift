import Foundation
import SwiftUI

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
    @AppStorage("maxItems") var maxItems: Int = 10_000
    @AppStorage("maxCacheSizeMB") var maxCacheSizeMB: Int = 10_240
    
    // Behavior
    @AppStorage("stripWhitespace") var stripWhitespace: Bool = false
    @AppStorage("confirmBeforeClear") var confirmBeforeClear: Bool = true
    @AppStorage("launchAtLogin") var launchAtLogin: Bool = false
    
    // Display
    @AppStorage("windowWidthPercentage") var windowWidthPercentage: Int = 33
    
    // Privacy
    @AppStorage("isPrivateMode") var isPrivateMode: Bool = false
    
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
