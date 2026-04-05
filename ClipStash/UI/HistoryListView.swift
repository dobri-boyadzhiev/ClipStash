import SwiftUI

/// Scrollable, paginated list of clipboard history entries.
struct HistoryListView: View {
    let entries: [ClipboardEntry]
    let imageCache: ImageCacheProtocol?
    @Binding var selectedId: Int64?
    let hasMore: Bool
    let isLoading: Bool
    let onSelect: (ClipboardEntry) -> Void
    let onCopyPlainText: (ClipboardEntry) -> Void
    let onImproveText: (ClipboardEntry) -> Void
    let onToggleFavorite: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    let onHoverImageChanged: (ClipboardEntry?) -> Void
    let onLoadMore: () -> Void
    
    var body: some View {
        if entries.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clipboard")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("No clipboard history")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(minHeight: 200)
        } else {
            ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(entries) { entry in
                            EntryRowView(
                                entry: entry,
                                imageCache: imageCache,
                                isSelected: selectedId == entry.id,
                                onSelect: { onSelect(entry) },
                                onCopyPlainText: { onCopyPlainText(entry) },
                                onImproveText: { onImproveText(entry) },
                                onToggleFavorite: { onToggleFavorite(entry) },
                                onDelete: { onDelete(entry) },
                                onHoverImageChanged: onHoverImageChanged
                            )
                            .id(entry.id)
                            
                            Divider().padding(.leading, 66)
                        }
                        
                        // Auto-load more on scroll to bottom
                        if hasMore {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(8)
                                .onAppear {
                                    guard !isLoading else { return }
                                    onLoadMore()
                                }
                        }
                    }
                }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}
