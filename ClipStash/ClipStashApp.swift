import SwiftUI

/// Call this from main.swift to launch the app.
@MainActor
public func runApp() {
    ClipStashApp.main()
}

/// Main app entry point. The actual menu bar UI is managed by AppDelegate + StatusItemController.
public struct ClipStashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    public init() {}
    
    public var body: some Scene {
        Settings {
            SettingsView(viewModel: appDelegate.settingsViewModel)
        }
    }
}
