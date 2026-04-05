import AppKit
import ImageIO
import SwiftUI

/// Single row in the clipboard history list.
struct EntryRowView: View {
    let entry: ClipboardEntry
    let imageCache: ImageCacheProtocol?
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopyPlainText: (() -> Void)?
    let onImproveText: ((Int?) -> Void)?
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    let onHoverImageChanged: (ClipboardEntry?) -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 8) {
            leadingVisual
            
            // Content preview
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .font(.system(size: 12.5))
                    .lineLimit(entry.type == .image ? 1 : 2)
                    .foregroundStyle(.primary)
                
                HStack(spacing: 4) {
                    if let appName = entry.sourceAppName {
                        Text(appName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if entry.type == .image {
                        Text(storageSizeDescription)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Text(entry.createdAt.relativeFormatted)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            // Action buttons (shown on hover)
            if isHovered || isSelected {
                HStack(spacing: 2) {
                    if AppSettings.shared.isAIEnabled, entry.type != .image, let onImproveText {
                        Button { onImproveText(nil) } label: {
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(.secondary)
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .help("Improve Text with AI")
                    }

                    Button(action: onToggleFavorite) {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(entry.isFavorite ? .yellow : .secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .help(entry.isFavorite ? "Remove from favorites" : "Add to favorites")
                    
                    Button(action: onDelete) {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovered = hovering
            guard entry.type == .image else { return }
            onHoverImageChanged(hovering ? entry : nil)
        }
        .contextMenu {
            EntryContextMenu(
                entry: entry,
                onSelect: onSelect,
                onCopyPlainText: onCopyPlainText,
                onImproveText: onImproveText,
                onToggleFavorite: onToggleFavorite,
                onDelete: onDelete
            )
        }
    }

    @ViewBuilder
    private var leadingVisual: some View {
        if entry.type == .image, let hash = entry.imageHash, let imageCache {
            ClipboardCachedImageView(
                hash: hash,
                imageCache: imageCache,
                width: 44,
                height: 44,
                contentMode: .fill,
                cornerRadius: 8,
                thumbnailMaxPixelSize: 88
            )
        } else {
            Image(systemName: entry.type.systemImage)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
                .frame(width: 16)
        }
    }

    private var primaryText: String {
        switch entry.type {
        case .image:
            return "Image"
        default:
            return entry.preview
        }
    }

    private var storageSizeDescription: String {
        entry.contentSizeBytes.formattedStorageSize
    }
}

enum ClipboardImageContentMode {
    case fill
    case fit
}

struct ClipboardCachedImageView: View {
    let hash: String
    let imageCache: ImageCacheProtocol
    let width: CGFloat
    let height: CGFloat
    let contentMode: ClipboardImageContentMode
    let cornerRadius: CGFloat
    let thumbnailMaxPixelSize: Int

    @State private var thumbnail: NSImage?
    @State private var failedToLoad = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .interpolation(.medium)
                    .modifier(ImageScalingModifier(mode: contentMode))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay {
                        Image(systemName: failedToLoad ? "photo.badge.exclamationmark" : "photo")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .task(id: hash) {
            await loadThumbnailIfNeeded()
        }
    }

    @MainActor
    private func loadThumbnailIfNeeded() async {
        let cacheKey = "\(hash)-\(thumbnailMaxPixelSize)" as NSString
        if let cached = ClipboardThumbnailMemoryCache.shared.object(forKey: cacheKey) {
            thumbnail = cached
            failedToLoad = false
            return
        }

        let loadedThumbnail = await generateThumbnail(imageCache: imageCache, hash: hash, maxPixelSize: thumbnailMaxPixelSize)

        if let loadedThumbnail {
            ClipboardThumbnailMemoryCache.shared.setObject(loadedThumbnail, forKey: cacheKey)
            thumbnail = loadedThumbnail
            failedToLoad = false
        } else {
            failedToLoad = true
        }
    }

    nonisolated private func generateThumbnail(imageCache: ImageCacheProtocol, hash: String, maxPixelSize: Int) async -> NSImage? {
        guard !Task.isCancelled else { return nil }
        guard let data = await imageCache.load(forHash: hash) else { return nil }
        guard !Task.isCancelled else { return nil }
        return ClipboardThumbnailRenderer.makeThumbnail(from: data, maxPixelSize: maxPixelSize)
    }
}

private struct ImageScalingModifier: ViewModifier {
    let mode: ClipboardImageContentMode

    func body(content: Content) -> some View {
        switch mode {
        case .fill:
            content.scaledToFill()
        case .fit:
            content.scaledToFit()
        }
    }
}

@MainActor
private enum ClipboardThumbnailMemoryCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()
}

private enum ClipboardThumbnailRenderer {
    static func makeThumbnail(from data: Data, maxPixelSize: Int) -> NSImage? {
        let cfData = data as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil) else {
            return NSImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }

        return NSImage(data: data)
    }
}

// MARK: - Date formatting helper
@MainActor
extension Date {
    private static let sharedRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var relativeFormatted: String {
        Self.sharedRelativeFormatter.localizedString(for: self, relativeTo: Date())
    }
}

extension Int {
    var formattedStorageSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}
