import AppKit

/// Restores persisted clipboard entries back into the system pasteboard.
@MainActor
final class PasteboardClipboardWriter: ClipboardWriting, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let imageCache: ImageCacheProtocol

    init(pasteboard: NSPasteboard = .general, imageCache: ImageCacheProtocol) {
        self.pasteboard = pasteboard
        self.imageCache = imageCache
    }

    func write(_ entry: ClipboardEntry) async throws {
        switch entry.type {
        case .text:
            guard let text = entry.textContent else {
                throw ClipboardWriteError.missingTextContent
            }
            try writeText(text)

        case .rtf:
            guard let rtfData = entry.rtfData else {
                throw ClipboardWriteError.missingRTFPayload
            }
            try writeRTF(rtfData, plainText: entry.textContent)

        case .image:
            guard let hash = entry.imageHash else {
                throw ClipboardWriteError.missingImageHash
            }
            guard let data = await imageCache.load(forHash: hash) else {
                throw ClipboardWriteError.missingImageData(hash: hash)
            }
            try writeImage(data)

        case .fileURL:
            guard let text = entry.textContent else {
                throw ClipboardWriteError.missingFileURLPayload
            }
            let urls = text
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { URL(fileURLWithPath: $0) }

            guard !urls.isEmpty else {
                throw ClipboardWriteError.missingFileURLPayload
            }
            try writeFileURLs(urls)
        }
    }

    func writePlainText(_ entry: ClipboardEntry) async throws {
        guard let text = entry.textContent else {
            throw ClipboardWriteError.plainTextRepresentationUnavailable(entry.type)
        }

        try writeText(text)
    }

    private func writeText(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw ClipboardWriteError.failedToWrite("text")
        }
    }

    private func writeRTF(_ data: Data, plainText: String?) throws {
        pasteboard.clearContents()
        var didWrite = false

        if pasteboard.setData(data, forType: .rtf) {
            didWrite = true
        }

        if let plainText, pasteboard.setString(plainText, forType: .string) {
            didWrite = true
        }

        if !didWrite {
            throw ClipboardWriteError.failedToWrite("RTF content")
        }
    }

    private func writeImage(_ data: Data) throws {
        guard let image = NSImage(data: data) else {
            throw ClipboardWriteError.invalidImagePayload
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            throw ClipboardWriteError.failedToWrite("image")
        }
    }

    private func writeFileURLs(_ urls: [URL]) throws {
        pasteboard.clearContents()
        guard pasteboard.writeObjects(urls as [NSURL]) else {
            throw ClipboardWriteError.failedToWrite("file URLs")
        }
    }
}

enum ClipboardWriteError: LocalizedError {
    case missingTextContent
    case missingRTFPayload
    case missingImageHash
    case missingImageData(hash: String)
    case invalidImagePayload
    case missingFileURLPayload
    case plainTextRepresentationUnavailable(EntryType)
    case failedToWrite(String)

    var errorDescription: String? {
        switch self {
        case .missingTextContent:
            return "The selected text entry has no text content."
        case .missingRTFPayload:
            return "The selected rich text entry has no stored RTF payload."
        case .missingImageHash:
            return "The selected image entry has no cache key."
        case .missingImageData(let hash):
            return "The cached image payload is missing for hash \(hash)."
        case .invalidImagePayload:
            return "The cached image payload could not be decoded."
        case .missingFileURLPayload:
            return "The selected file entry has no stored file paths."
        case .plainTextRepresentationUnavailable(let type):
            return "The selected \(type.displayName.lowercased()) entry has no plain-text representation."
        case .failedToWrite(let contentType):
            return "Failed to write \(contentType) to the pasteboard."
        }
    }
}
