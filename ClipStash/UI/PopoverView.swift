import AppKit
import SwiftUI

enum ClipboardPanelLayout {
    static let fallbackWidth: CGFloat = 420
    static let minWidth: CGFloat = 360
    static let maxWidth: CGFloat = 900
    static let height: CGFloat = 520

    static func panelWidth(screenWidth: CGFloat?, percentage: Int) -> CGFloat {
        guard let screenWidth else { return fallbackWidth }

        let configuredWidth = screenWidth * CGFloat(percentage) / 100
        return min(max(configuredWidth, minWidth), maxWidth)
    }

    static func panelSize(screenWidth: CGFloat?, percentage: Int) -> CGSize {
        CGSize(width: panelWidth(screenWidth: screenWidth, percentage: percentage), height: height)
    }
}

enum PopoverScreen {
    case history
    case settings
}

@MainActor
final class PopoverState: ObservableObject {
    @Published var screen: PopoverScreen = .history

    func showHistory() {
        screen = .history
    }

    func showSettings() {
        screen = .settings
    }
}

/// Main popover view — the clipboard history panel.
struct PopoverView: View {
    @ObservedObject var viewModel: HistoryViewModel
    @ObservedObject var settingsViewModel: SettingsViewModel
    @ObservedObject var popoverState: PopoverState
    let imageCache: ImageCacheProtocol
    @ObservedObject private var settings = AppSettings.shared
    let onClosePopover: () -> Void
    @FocusState private var isSearchFocused: Bool
    @State private var selectedEntryId: Int64?
    @State private var hoveredImageEntry: ClipboardEntry?
    
    var body: some View {
        Group {
            switch popoverState.screen {
            case .history:
                historyContent
            case .settings:
                settingsContent
            }
        }
        .frame(width: panelWidth, height: ClipboardPanelLayout.height)
        .background(.ultraThinMaterial)
        .onAppear {
            if popoverState.screen == .history {
                isSearchFocused = true
            } else {
                Task { await settingsViewModel.loadStats() }
            }
        }
        .onChange(of: viewModel.entries) { _, newEntries in
            guard let selectedEntryId else {
                self.selectedEntryId = newEntries.first?.id
                return
            }

            if !newEntries.contains(where: { $0.id == selectedEntryId }) &&
                !viewModel.favorites.contains(where: { $0.id == selectedEntryId }) {
                self.selectedEntryId = newEntries.first?.id ?? viewModel.favorites.first?.id
            }

            if let hoveredImageEntry,
               !newEntries.contains(where: { $0.id == hoveredImageEntry.id }) &&
                !viewModel.favorites.contains(where: { $0.id == hoveredImageEntry.id }) {
                self.hoveredImageEntry = nil
            }
        }
        .onChange(of: viewModel.favorites) { _, newFavorites in
            guard let hoveredImageEntry else { return }
            if !viewModel.entries.contains(where: { $0.id == hoveredImageEntry.id }) &&
                !newFavorites.contains(where: { $0.id == hoveredImageEntry.id }) {
                self.hoveredImageEntry = nil
            }
        }
        .onChange(of: viewModel.searchQuery) { _, newQuery in
            if !newQuery.isEmpty {
                hoveredImageEntry = nil
            }
        }
        .onKeyPress("/") {
            guard popoverState.screen == .history else { return .ignored }
            isSearchFocused = true
            return .handled
        }
        .onChange(of: popoverState.screen) { _, newScreen in
            switch newScreen {
            case .history:
                isSearchFocused = true
                Task { await viewModel.loadInitial() }
            case .settings:
                isSearchFocused = false
                hoveredImageEntry = nil
                Task { await settingsViewModel.loadStats() }
            }
        }
    }

    private var historyContent: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    SearchBarView(
                        text: $viewModel.searchQuery,
                        activeFilterCount: viewModel.activeSearchCriteria.filterCount,
                        recentApps: viewModel.recentSourceApps,
                        onApplyQuickFilter: viewModel.applyQuickFilter,
                        onApplyRecentAppFilter: viewModel.applyRecentAppFilter,
                        onClearFilters: viewModel.clearSearchFilters
                    )
                    .focused($isSearchFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)

                    if !viewModel.activeSearchCriteria.chips.isEmpty {
                        SearchFilterChipsView(
                            chips: viewModel.activeSearchCriteria.chips,
                            onRemove: viewModel.removeSearchFilter
                        )
                        .padding(.bottom, 6)
                    }
                }

                Divider()

                if !viewModel.favorites.isEmpty && viewModel.searchQuery.isEmpty {
                    FavoritesView(
                        favorites: viewModel.favorites,
                        imageCache: imageCache,
                        selectedId: $selectedEntryId,
                        onSelect: { entry in
                            selectedEntryId = entry.id
                            Task { await handleSelection(entry) }
                        },
                        onCopyPlainText: { entry in
                            selectedEntryId = entry.id
                            Task { _ = await viewModel.copyAsPlainText(entry) }
                        },
                        onToggleFavorite: { entry in Task { await viewModel.toggleFavorite(entry) }},
                        onDelete: { entry in Task { await viewModel.delete(entry) }},
                        onHoverImageChanged: handleHoveredImageChange
                    )
                    Divider()
                }

                HistoryListView(
                    entries: viewModel.entries,
                    imageCache: imageCache,
                    selectedId: $selectedEntryId,
                    hasMore: viewModel.hasMore,
                    onSelect: { entry in
                        selectedEntryId = entry.id
                        Task { await handleSelection(entry) }
                    },
                    onCopyPlainText: { entry in
                        selectedEntryId = entry.id
                        Task { _ = await viewModel.copyAsPlainText(entry) }
                    },
                    onToggleFavorite: { entry in Task { await viewModel.toggleFavorite(entry) }},
                    onDelete: { entry in Task { await viewModel.delete(entry) }},
                    onHoverImageChanged: handleHoveredImageChange,
                    onLoadMore: { Task { await viewModel.loadNextPage() }}
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Divider()

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    Divider()
                }

                if viewModel.showClearConfirmation {
                    ClearHistoryPrompt(
                        onCancel: { viewModel.cancelClearConfirmation() },
                        onConfirm: { Task { await viewModel.performClear() } }
                    )
                    Divider()
                }

                BottomToolbar(
                    settings: settings,
                    onTogglePrivateMode: { settings.togglePrivateMode() },
                    onClear: { Task { await viewModel.clearAll() } },
                    onOpenSettings: { popoverState.showSettings() },
                    onQuit: { NSApp.terminate(nil) }
                )
            }

            if let hoveredImageEntry {
                HoveredImagePreviewCard(
                    entry: hoveredImageEntry,
                    imageCache: imageCache,
                    maxWidth: hoverPreviewWidth
                )
                .padding(.top, 54)
                .padding(.trailing, 12)
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            }
        }
        .animation(.easeInOut(duration: 0.16), value: hoveredImageEntry?.id)
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    popoverState.showHistory()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay {
                Text("Settings")
                    .font(.headline)
            }

            Divider()

            SettingsContentView(viewModel: settingsViewModel)
        }
    }

    private var panelWidth: CGFloat {
        ClipboardPanelLayout.panelWidth(
            screenWidth: NSScreen.main?.visibleFrame.width,
            percentage: viewModel.settings.windowWidthPercentage
        )
    }

    private func handleSelection(_ entry: ClipboardEntry) async {
        hoveredImageEntry = nil
        let didCopy = await viewModel.select(entry)
        guard didCopy else { return }
        onClosePopover()
    }

    private var hoverPreviewWidth: CGFloat {
        min(max(panelWidth * 0.58, 220), 320)
    }

    private func handleHoveredImageChange(_ entry: ClipboardEntry?) {
        guard popoverState.screen == .history else {
            hoveredImageEntry = nil
            return
        }

        hoveredImageEntry = entry
    }
}

// MARK: - Bottom Toolbar
struct ClearHistoryPrompt: View {
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clear clipboard history?")
                    .font(.system(size: 12, weight: .semibold))
                Text("Favorites will be kept.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Cancel", action: onCancel)
                .controlSize(.small)

            Button("Clear", role: .destructive, action: onConfirm)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.08))
    }
}

struct BottomToolbar: View {
    @ObservedObject var settings: AppSettings
    let onTogglePrivateMode: () -> Void
    let onClear: () -> Void
    let onOpenSettings: () -> Void
    let onQuit: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTogglePrivateMode) {
                HStack(spacing: 6) {
                    Image(systemName: settings.isPrivateMode ? "eye.slash.fill" : "eye")
                    Text(settings.isPrivateMode ? "Private On" : "Private Off")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(settings.isPrivateMode ? Color.orange : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(settings.isPrivateMode ? Color.orange.opacity(0.16) : Color.secondary.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .help(settings.isPrivateMode ? "Private mode is active" : "Private mode is inactive")
            
            Spacer()
            
            // Clear button
            Button(action: onClear) {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Clear history")
            
            // Settings button
            Button(action: onOpenSettings) {
                Image(systemName: "gear")
            }
            .controlSize(.small)
            .help("Settings")

            Button(action: onQuit) {
                Image(systemName: "power")
            }
            .controlSize(.small)
            .help("Quit ClipStash")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct HoveredImagePreviewCard: View {
    let entry: ClipboardEntry
    let imageCache: ImageCacheProtocol
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let hash = entry.imageHash {
                ClipboardCachedImageView(
                    hash: hash,
                    imageCache: imageCache,
                    width: maxWidth,
                    height: min(maxWidth * 0.82, 220),
                    contentMode: .fit,
                    cornerRadius: 12,
                    thumbnailMaxPixelSize: 512
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.04))
                )
            }

            HStack(spacing: 6) {
                Text("Image")
                    .font(.system(size: 12, weight: .semibold))
                Text(entry.contentSizeBytes.formattedStorageSize)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let sourceAppName = entry.sourceAppName {
                Text(sourceAppName)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: maxWidth + 24, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 18, x: 0, y: 10)
    }
}
