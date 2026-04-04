import SwiftUI

/// Custom menu bar icon composed from SF Symbols.
/// Can be used as a replacement for a custom icon asset.
struct MenuBarIcon: View {
    let isPrivateMode: Bool
    
    var body: some View {
        Image(systemName: isPrivateMode ? "clipboard.fill" : "clipboard")
            .symbolRenderingMode(.hierarchical)
    }
}

/// Generates an NSImage for the menu bar status item.
/// This allows using a precise icon without needing an asset catalog.
enum MenuBarIconGenerator {
    static func generate(isPrivateMode: Bool) -> NSImage {
        let symbolName = isPrivateMode ? "clipboard.fill" : "clipboard"
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "ClipStash")!
            .withSymbolConfiguration(config)!
        image.isTemplate = true // Adapts to dark/light menu bar
        return image
    }
}
