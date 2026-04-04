import AppKit
import Combine
import SwiftUI

/// Controls the menu bar status item and clipboard history popover.
@MainActor
final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let settings: AppSettings
    private let imageCache: ImageCacheProtocol
    private let historyViewModel: HistoryViewModel
    private let settingsViewModel: SettingsViewModel
    private let popoverState = PopoverState()
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings,
        imageCache: ImageCacheProtocol,
        historyViewModel: HistoryViewModel,
        settingsViewModel: SettingsViewModel
    ) {
        self.settings = settings
        self.imageCache = imageCache
        self.historyViewModel = historyViewModel
        self.settingsViewModel = settingsViewModel
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        configurePopover()
        configureStatusItem()
        observeUpdates()
        updatePopoverSize()
        updateStatusItemAppearance()
    }

    func togglePopover() {
        popover.isShown ? closePopover() : showPopover()
    }

    func showPopover() {
        guard let button = statusItem.button else { return }

        popoverState.showHistory()
        Task { @MainActor in
            await historyViewModel.loadInitial()
        }
        updatePopoverSize()
        updateStatusItemAppearance()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 420, height: 520)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(
                viewModel: historyViewModel,
                settingsViewModel: settingsViewModel,
                popoverState: popoverState,
                imageCache: imageCache,
                onClosePopover: { [weak self] in self?.closePopover() },
            )
        )
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp])
        button.lineBreakMode = .byTruncatingTail
        button.imageScaling = .scaleProportionallyDown
    }

    private func observeUpdates() {
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePopoverSize()
                self?.updateStatusItemAppearance()
            }
            .store(in: &cancellables)
    }

    private func updatePopoverSize() {
        let screenWidth = statusItem.button?.window?.screen?.visibleFrame.width ?? NSScreen.main?.visibleFrame.width
        popover.contentSize = ClipboardPanelLayout.panelSize(
            screenWidth: screenWidth,
            percentage: settings.windowWidthPercentage
        )
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem.button else { return }

        statusItem.length = NSStatusItem.squareLength
        button.title = ""
        button.image = MenuBarIconGenerator.generate(isPrivateMode: settings.isPrivateMode)
        button.alphaValue = 1
        button.imagePosition = .imageOnly
    }

    @objc
    private func handleStatusItemClick() {
        togglePopover()
    }
}
