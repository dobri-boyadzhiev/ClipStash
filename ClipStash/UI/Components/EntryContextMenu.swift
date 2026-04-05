import SwiftUI

/// Right-click context menu for a clipboard entry.
struct EntryContextMenu: View {
    let entry: ClipboardEntry
    let onSelect: () -> Void
    let onCopyPlainText: (() -> Void)?
    let onImproveText: ((Int?) -> Void)?
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

            if AppSettings.shared.isAIEnabled, let onImproveText {
                Menu {
                    Button { onImproveText(nil) } label: {
                        Label("Improve Text", systemImage: "sparkles")
                    }

                    Divider()

                    Button { onImproveText(0) } label: {
                        Label("Fix Grammar & Spelling", systemImage: "textformat.abc")
                    }
                    Button { onImproveText(1) } label: {
                        Label("Make it Professional", systemImage: "briefcase")
                    }
                    Button { onImproveText(3) } label: {
                        Label("Natural / Conversational", systemImage: "bubble.left")
                    }
                    Button { onImproveText(4) } label: {
                        Label("Fun / Witty", systemImage: "face.smiling")
                    }
                    Button { onImproveText(5) } label: {
                        Label("Executive / Concise", systemImage: "bolt")
                    }

                    if !AppSettings.shared.customAIPrompt.isEmpty {
                        Button { onImproveText(2) } label: {
                            Label("Custom Prompt", systemImage: "pencil.line")
                        }
                    }
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
