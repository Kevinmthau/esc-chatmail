import Foundation
import Security

// MARK: - Keychain Error
enum KeychainError: LocalizedError {
    case unhandledError(status: OSStatus)
    case unexpectedData
    case itemNotFound
    case duplicateItem
    case invalidParameters

    var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            return "Keychain error: \(status)"
        case .unexpectedData:
            return "Unexpected data format in keychain"
        case .itemNotFound:
            return "Item not found in keychain"
        case .duplicateItem:
            return "Item already exists in keychain"
        case .invalidParameters:
            return "Invalid keychain parameters"
        }
    }
}

// MARK: - Keychain Service Protocol
protocol KeychainServiceProtocol {
    func save(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel) throws
    func load(for key: String) throws -> Data
    func delete(for key: String) throws
    func exists(for key: String) -> Bool
    func update(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel?) throws
    func clearAll() throws
    func saveString(_ string: String, for key: String, withAccess access: KeychainService.AccessLevel) throws
    func loadString(for key: String) throws -> String
    func saveCodable<T: Codable>(_ object: T, for key: String, withAccess access: KeychainService.AccessLevel) throws
    func loadCodable<T: Codable>(_ type: T.Type, for key: String) throws -> T
}

// MARK: - Keychain Service Implementation
final class KeychainService: KeychainServiceProtocol {
    static let shared = KeychainService()

    private let service: String
    private let accessGroup: String?
    private let itemOperations: KeychainItemOperations

    // MARK: - Access Levels
    enum AccessLevel: Equatable {
        case whenUnlocked
        case whenUnlockedThisDeviceOnly
        case afterFirstUnlock
        case afterFirstUnlockThisDeviceOnly
        case whenPasscodeSetThisDeviceOnly

        var attribute: String {
            switch self {
            case .whenUnlocked:
                return kSecAttrAccessibleWhenUnlocked as String
            case .whenUnlockedThisDeviceOnly:
                return kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
            case .afterFirstUnlock:
                return kSecAttrAccessibleAfterFirstUnlock as String
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            case .whenPasscodeSetThisDeviceOnly:
                return kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String
            }
        }
    }

    // MARK: - Keychain Keys
    enum Key: String, CaseIterable {
        // Authentication
        case googleAccessToken = "com.esc.inboxchat.google.accessToken"
        case googleRefreshToken = "com.esc.inboxchat.google.refreshToken"
        case googleUserEmail = "com.esc.inboxchat.google.userEmail"
        case googleUserId = "com.esc.inboxchat.google.userId"

        // App State
        case localStoreResetRequired = "com.esc.inboxchat.localStoreResetRequired.v1"
        case credentialCleanupRequired = "com.esc.inboxchat.credentialCleanupRequired.v1"
        case durableSignedOut = "com.esc.inboxchat.durableSignedOut.v1"
        case installationId = "com.esc.inboxchat.installationId"
        case installationTimestamp = "com.esc.inboxchat.installationTimestamp"
        case lastSyncToken = "com.esc.inboxchat.lastSyncToken"
        case encryptionKey = "com.esc.inboxchat.encryptionKey"

        // User Preferences (secure)
        case biometricEnabled = "com.esc.inboxchat.biometricEnabled"
        case pinCode = "com.esc.inboxchat.pinCode"
    }

    // MARK: - Initialization
    init(
        service: String? = nil,
        accessGroup: String? = nil,
        itemOperations: KeychainItemOperations = .system
    ) {
        self.service = service ?? Bundle.main.bundleIdentifier ?? "com.esc.inboxchat"
        self.accessGroup = accessGroup
        self.itemOperations = itemOperations
    }

    // MARK: - Core Operations

    func save(_ data: Data, for key: String, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = access.attribute

        let status = itemOperations.add(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            try update(data, for: key, withAccess: access)
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    func load(for key: String) throws -> Data {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = itemOperations.copyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.unexpectedData
            }
            return data
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    func delete(for key: String) throws {
        let query = baseQuery(for: key)
        let status = itemOperations.delete(query as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    func exists(for key: String) -> Bool {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = itemOperations.copyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func update(_ data: Data, for key: String, withAccess access: AccessLevel? = nil) throws {
        let query = baseQuery(for: key)
        var attributes: [String: Any] = [kSecValueData as String: data]
        if let access {
            attributes[kSecAttrAccessible as String] = access.attribute
        }

        let status = itemOperations.update(query as CFDictionary, attributes as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    func clearAll() throws {
        // Clear all keychain items for this service. Unlike `baseQuery(for:)`,
        // this sets no access group, so it matches the service's items in any
        // group.
        let query = serviceQuery()

        let status = itemOperations.delete(query as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Typed Convenience Methods

    func save(_ data: Data, for key: Key, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        try save(data, for: key.rawValue, withAccess: access)
    }

    func load(for key: Key) throws -> Data {
        try load(for: key.rawValue)
    }

    func delete(for key: Key) throws {
        try delete(for: key.rawValue)
    }

    func exists(for key: Key) -> Bool {
        exists(for: key.rawValue)
    }

    // MARK: - Private Helpers

    /// What every query this service issues starts from: its generic-password
    /// items in the data protection keychain.
    ///
    /// On macOS, a query without `kSecUseDataProtectionKeychain` goes to the
    /// older file-based keychain, where the `kSecAttrAccessible…` levels in
    /// `AccessLevel` don't apply. Without both this flag and the Mac build's
    /// `keychain-access-groups` entitlement, sign-in appears to work but the
    /// session is gone after a relaunch (docs/mac-app-plan.md, PR C). iOS has
    /// only the data protection keychain, so the flag changes nothing there:
    /// items that builds without it saved still match (`KeychainServiceTests`).
    /// `GoogleSignInKeychainProbe` in `AuthSession.swift` passes the same flag.
    private func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func baseQuery(for key: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = key

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }
}
