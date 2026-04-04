import Foundation
import Security

enum DatabaseProtectionMode: String, Sendable {
    case keychainBacked
    case ephemeralSession
}

struct DatabaseSecurityStatus: Sendable {
    let protectionMode: DatabaseProtectionMode
    let activeDatabasePath: String
    let keyStorageDescription: String
    let detailText: String
    let startupAlertMessage: String?
    let isFallback: Bool

    static func keychainBacked(databasePath: String, keyStorageDescription: String) -> DatabaseSecurityStatus {
        DatabaseSecurityStatus(
            protectionMode: .keychainBacked,
            activeDatabasePath: databasePath,
            keyStorageDescription: keyStorageDescription,
            detailText: "ClipStash encrypts its SQLite database with SQLCipher. The database key is generated once on this Mac and stored in macOS Keychain.",
            startupAlertMessage: nil,
            isFallback: false
        )
    }

    static func temporaryFallback(databasePath: String, issueDescription: String) -> DatabaseSecurityStatus {
        DatabaseSecurityStatus(
            protectionMode: .ephemeralSession,
            activeDatabasePath: databasePath,
            keyStorageDescription: "In-memory session key",
            detailText: "ClipStash is running with a temporary encrypted database for this session. Existing stored history is unavailable until secure storage is reinitialized. Reason: \(issueDescription)",
            startupAlertMessage: "ClipStash could not open its primary database securely.\n\n\(issueDescription)\n\nThe app is using a temporary encrypted database for this session. If you want to start fresh, open Settings and choose Delete All Data.",
            isFallback: true
        )
    }

    var protectionLabel: String {
        switch protectionMode {
        case .keychainBacked:
            return "Encrypted at rest"
        case .ephemeralSession:
            return "Temporary encrypted fallback"
        }
    }
}

protocol DatabasePassphraseProviding: Sendable {
    var protectionMode: DatabaseProtectionMode { get }
    var keyStorageDescription: String { get }
    func passphrase() throws -> Data
    func deleteStoredPassphrase() throws
}

enum DatabasePassphraseError: LocalizedError {
    case missingStoredPassphrase(databasePath: String)
    case invalidStoredPassphraseLength(expected: Int, actual: Int)
    case randomGenerationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .missingStoredPassphrase(databasePath):
            return "ClipStash found an existing database at \(databasePath), but the matching Keychain entry is missing."
        case let .invalidStoredPassphraseLength(expected, actual):
            return "ClipStash found a malformed database key in Keychain. Expected \(expected) bytes, got \(actual)."
        case let .randomGenerationFailed(status):
            return "ClipStash could not generate a secure random database key (\(status))."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .missingStoredPassphrase, .invalidStoredPassphraseLength:
            return "Use Delete All Data to remove the old database and let ClipStash create a fresh encrypted one."
        case .randomGenerationFailed:
            return "Try launching the app again. If the problem persists, restart macOS."
        }
    }
}

protocol DatabaseSecretStoring: Sendable {
    func readSecret(for descriptor: DatabaseSecretDescriptor) throws -> Data?
    func storeSecret(_ data: Data, for descriptor: DatabaseSecretDescriptor) throws
    func deleteSecret(for descriptor: DatabaseSecretDescriptor) throws
}

struct DatabaseSecretDescriptor: Sendable {
    let service: String
    let account: String
    let label: String

    static let clipStashPrimaryDatabase = DatabaseSecretDescriptor(
        service: "com.clipstash.app.database",
        account: "primary-key",
        label: "ClipStash Database Key"
    )
}

final class KeychainSecretStore: DatabaseSecretStoring {
    func readSecret(for descriptor: DatabaseSecretDescriptor) throws -> Data? {
        var query = baseQuery(for: descriptor)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainSecretStoreError.unexpectedStatus(status, operation: "read")
        }
    }

    func storeSecret(_ data: Data, for descriptor: DatabaseSecretDescriptor) throws {
        let query = baseQuery(for: descriptor)
        let updateAttributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrLabel as String] = descriptor.label

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainSecretStoreError.unexpectedStatus(addStatus, operation: "store")
            }
        default:
            throw KeychainSecretStoreError.unexpectedStatus(updateStatus, operation: "store")
        }
    }

    func deleteSecret(for descriptor: DatabaseSecretDescriptor) throws {
        let status = SecItemDelete(baseQuery(for: descriptor) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainSecretStoreError.unexpectedStatus(status, operation: "delete")
        }
    }

    private func baseQuery(for descriptor: DatabaseSecretDescriptor) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: descriptor.service,
            kSecAttrAccount as String: descriptor.account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }
}

enum KeychainSecretStoreError: LocalizedError {
    case unexpectedStatus(OSStatus, operation: String)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status, operation):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
            return "ClipStash failed to \(operation) its database key in Keychain (\(status): \(message))."
        }
    }
}

final class KeychainDatabasePassphraseProvider: DatabasePassphraseProviding {
    let protectionMode: DatabaseProtectionMode = .keychainBacked
    let keyStorageDescription = "macOS Keychain (local device item)"

    private let databaseURL: URL
    private let secretStore: any DatabaseSecretStoring
    private let descriptor: DatabaseSecretDescriptor
    private let keyByteCount: Int

    init(
        databaseURL: URL,
        secretStore: any DatabaseSecretStoring = KeychainSecretStore(),
        descriptor: DatabaseSecretDescriptor = .clipStashPrimaryDatabase,
        keyByteCount: Int = 32
    ) {
        self.databaseURL = databaseURL
        self.secretStore = secretStore
        self.descriptor = descriptor
        self.keyByteCount = keyByteCount
    }

    func passphrase() throws -> Data {
        if let existingSecret = try secretStore.readSecret(for: descriptor) {
            guard existingSecret.count == keyByteCount else {
                throw DatabasePassphraseError.invalidStoredPassphraseLength(expected: keyByteCount, actual: existingSecret.count)
            }
            return existingSecret
        }

        guard !FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw DatabasePassphraseError.missingStoredPassphrase(databasePath: databaseURL.path)
        }

        let newSecret = try Self.generateRandomKey(byteCount: keyByteCount)
        try secretStore.storeSecret(newSecret, for: descriptor)
        return newSecret
    }

    func deleteStoredPassphrase() throws {
        try secretStore.deleteSecret(for: descriptor)
    }

    static func generateRandomKey(byteCount: Int) throws -> Data {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw DatabasePassphraseError.randomGenerationFailed(status)
        }
        return data
    }
}

final class EphemeralDatabasePassphraseProvider: DatabasePassphraseProviding {
    let protectionMode: DatabaseProtectionMode = .ephemeralSession
    let keyStorageDescription = "In-memory session key"

    private let secret: Data

    init(keyByteCount: Int = 32) throws {
        self.secret = try KeychainDatabasePassphraseProvider.generateRandomKey(byteCount: keyByteCount)
    }

    func passphrase() throws -> Data {
        secret
    }

    func deleteStoredPassphrase() throws {
        // Session key is in-memory only.
    }
}
