import Foundation

/// Abstracts writing to the system clipboard.
@MainActor
protocol ClipboardWriting: Sendable {
    func write(_ entry: ClipboardEntry) throws
    func writePlainText(_ entry: ClipboardEntry) throws
}
