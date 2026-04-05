import SwiftUI

/// Collapsible section showing favorited clipboard entries.
struct FavoritesView: View {
    let favorites: [ClipboardEntry]
    let imageCache: ImageCacheProtocol?
    @Binding var selectedId: Int64?
    let onSelect: (ClipboardEntry) -> Void
    let onCopyPlainText: (ClipboardEntry) -> Void
    let onImproveText: (ClipboardEntry) -> Void
    let onToggleFavorite: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    let onHoverImageChanged: (ClipboardEntry?) -> Void
    
    @State private var isExpanded = true
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 11))
                    Text("Favorites")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("(\(favorites.count))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(favorites) { entry in
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
                        }
                    }
                }
                .frame(maxHeight: 150)
            }
        }
    }
}
