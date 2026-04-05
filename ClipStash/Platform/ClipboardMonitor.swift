import AppKit
import Combine
import OSLog

/// Monitors the system clipboard for changes by polling NSPasteboard.
@MainActor
final class ClipboardMonitor: ObservableObject {
    struct PollSchedule: Equatable {
        let interval: TimeInterval
        let tolerance: TimeInterval
    }

    @Published private(set) var isRunning = false
    
    private let logger = Logger(subsystem: "ClipStash", category: "ClipboardMonitor")
    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int = 0
    private var pollTask: Task<Void, Never>?
    private let entryManager: EntryManager
    private let settings: AppSettings
    
    /// Tracks whether we just wrote to the pasteboard ourselves
    private var debounceCount: Int = 0
    
    init(entryManager: EntryManager, settings: AppSettings) {
        self.entryManager = entryManager
        self.settings = settings
    }
    
    func start() {
        guard pollTask == nil else { return }
        lastChangeCount = pasteboard.changeCount
        isRunning = true
        pollTask = Task { @MainActor [weak self] in
            while let self = self, !Task.isCancelled {
                let interval = self.currentPollSchedule().interval
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self.checkForChanges()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
    }
    
    /// Call before writing to pasteboard to prevent re-capture
    func beginDebounce() {
        debounceCount += 1
    }

    func cancelDebounce() {
        guard debounceCount > 0 else { return }
        debounceCount -= 1
    }

    static func makePollSchedule(isPrivateMode: Bool, isLowPowerModeEnabled: Bool) -> PollSchedule {
        if isPrivateMode {
            return PollSchedule(interval: 1.2, tolerance: 0.4)
        }

        if isLowPowerModeEnabled {
            return PollSchedule(interval: 0.9, tolerance: 0.3)
        }

        return PollSchedule(interval: 0.45, tolerance: 0.15)
    }

    func currentPollSchedule() -> PollSchedule {
        Self.makePollSchedule(
            isPrivateMode: settings.isPrivateMode,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }
    
    private func checkForChanges() {
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount
        
        if debounceCount > 0 { debounceCount -= 1; return }
        guard !settings.isPrivateMode else { return }
        
        let sourceBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let sourceName = NSWorkspace.shared.frontmostApplication?.localizedName
        
        // Priority order: RTF > Text > Image > File URLs
        // (RTF also contains plain text, but we prefer the rich version)
        
        if let rtfData = pasteboard.data(forType: .rtf) {
            // Note: NSAttributedString RTF parsing runs on main thread.
            // This is acceptable for typical clipboard RTF sizes (< 100KB).
            // For very large RTF documents this could cause brief UI stutter.
            let plainText = pasteboard.string(forType: .string)
                ?? (try? NSAttributedString(
                    data: rtfData,
                    options: [.documentType: NSAttributedString.DocumentType.rtf],
                    documentAttributes: nil
                ).string)
                ?? ""
            guard !plainText.isEmpty else { return }
            Task {
                await entryManager.processNewRTF(plainText: plainText, rtfData: rtfData, source: sourceBundle, sourceName: sourceName)
            }
        } else if let string = pasteboard.string(forType: .string) {
            Task {
                await entryManager.processNewText(string, source: sourceBundle, sourceName: sourceName)
            }
        } else if let imgData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            Task {
                await entryManager.processNewImage(imgData, source: sourceBundle, sourceName: sourceName)
            }
        } else if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let paths = urls.map(\.path).joined(separator: "\n")
            Task {
                await entryManager.processNewFileURLs(paths, source: sourceBundle, sourceName: sourceName)
            }
        }
    }
}
