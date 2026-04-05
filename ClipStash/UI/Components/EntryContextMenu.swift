import SwiftUI

/// Right-click context menu for a clipboard entry.
struct EntryContextMenu: View {
    let entry: ClipboardEntry
    let onSelect: () -> Void
    let onCopyPlainText: (() -> Void)?
    let onImproveText: (() -> Void)?
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        Button {
            onSelect()
        } label: {
            Label("Copy and Close", systemImage: "doc.on.clipboard")
        }
        
        Button {
            onToggleFavorite()
        } label: {
            Label(
                entry.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: entry.isFavorite ? "star.slash" : "star"
            )
        }
        
        Divider()
        
        if let onCopyPlainText, entry.textContent != nil, entry.type != .image {
            Button {
                onCopyPlainText()
            } label: {
                Label("Copy as Plain Text", systemImage: "doc.on.doc")
            }

            if AppSettings.shared.isAIEnabled {
                Button {
                    onImproveText?()
                } label: {
                    Label("Improve Text with AI", systemImage: "wand.and.stars")
                }
            }

            Divider()
        }

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}
