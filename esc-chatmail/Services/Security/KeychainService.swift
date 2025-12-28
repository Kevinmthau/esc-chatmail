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
    func update(_ data: Data, for key: String) throws
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

    // MARK: - Access Levels
    enum AccessLevel {
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
        case installationId = "com.esc.inboxchat.installationId"
        case installationTimestamp = "com.esc.inboxchat.installationTimestamp"
        case lastSyncToken = "com.esc.inboxchat.lastSyncToken"
        case encryptionKey = "com.esc.inboxchat.encryptionKey"

        // User Preferences (secure)
        case biometricEnabled = "com.esc.inboxchat.biometricEnabled"
        case pinCode = "com.esc.inboxchat.pinCode"
    }

    // MARK: - Initialization
    init(service: String? = nil, accessGroup: String? = nil) {
        self.service = service ?? Bundle.main.bundleIdentifier ?? "com.esc.inboxchat"
        self.accessGroup = accessGroup
    }

    // MARK: - Core Operations

    func save(_ data: Data, for key: String, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        var query = baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = access.attribute

        let status = SecItemAdd(query as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            try update(data, for: key)
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    func load(for key: String) throws -> Data {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

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
        let status = SecItemDelete(query as CFDictionary)

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

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    func update(_ data: Data, for key: String) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

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
        // Clear all keychain items for this service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)

        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw KeychainError.unhandledError(status: status)
        }
    }

    // MARK: - Convenience Methods

    func saveString(_ string: String, for key: String, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        guard let data = string.data(using: .utf8) else {
            throw KeychainError.invalidParameters
        }
        try save(data, for: key, withAccess: access)
    }

    func loadString(for key: String) throws -> String {
        let data = try load(for: key)
        guard let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    func saveCodable<T: Codable>(_ object: T, for key: String, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(object)
        try save(data, for: key, withAccess: access)
    }

    func loadCodable<T: Codable>(_ type: T.Type, for key: String) throws -> T {
        let data = try load(for: key)
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
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

    func saveString(_ string: String, for key: Key, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        try saveString(string, for: key.rawValue, withAccess: access)
    }

    func loadString(for key: Key) throws -> String {
        try loadString(for: key.rawValue)
    }

    // MARK: - Private Helpers

    private func baseQuery(for key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        return query
    }

    // MARK: - Migration Support

    func migrateFromOldKeychain() {
        // Migrate old keychain items to new structure
        // This is called during app initialization if needed

        // Example: Migrate old Google tokens
        let oldTokenQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(oldTokenQuery as CFDictionary, &result)

        if status == errSecSuccess,
           let items = result as? [[String: Any]] {
            // Process and migrate old items
            for _ in items {
                // Migration logic here - to be implemented when needed
            }
        }
    }
}

// MARK: - Keychain Service + Installation ID
extension KeychainService {
    func getOrCreateInstallationId() -> String {
        if let existingId = try? loadString(for: .installationId) {
            return existingId
        }

        let newId = UUID().uuidString
        try? saveString(newId, for: .installationId, withAccess: .afterFirstUnlockThisDeviceOnly)

        // Also create installation timestamp when creating new installation ID
        setInstallationTimestamp()

        return newId
    }

    func verifyInstallationId(_ id: String) -> Bool {
        guard let storedId = try? loadString(for: .installationId) else {
            return false
        }
        return storedId == id
    }

    func getOrCreateInstallationTimestamp() -> Date {
        if let timestamp = getInstallationTimestamp() {
            return timestamp
        }

        // Create new timestamp with a 10-minute buffer in the past
        // This accounts for emails that arrived just before the app was installed
        let bufferMinutes: TimeInterval = 10 * 60
        let timestamp = Date().addingTimeInterval(-bufferMinutes)
        setInstallationTimestamp(timestamp)
        Log.debug("Created installation timestamp with 10-minute buffer: \(timestamp)", category: .auth)
        return timestamp
    }

    func getInstallationTimestamp() -> Date? {
        guard let timestampString = try? loadString(for: .installationTimestamp),
              let timestamp = Double(timestampString) else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    func setInstallationTimestamp(_ date: Date = Date()) {
        let timestamp = date.timeIntervalSince1970
        try? saveString(String(timestamp), for: .installationTimestamp, withAccess: .afterFirstUnlockThisDeviceOnly)
    }

    /// Resets the installation timestamp to include older messages
    /// - Parameter minutesBack: How many minutes in the past to set the timestamp (default 30)
    func resetInstallationTimestamp(minutesBack: Int = 30) {
        let newTimestamp = Date().addingTimeInterval(-TimeInterval(minutesBack * 60))
        setInstallationTimestamp(newTimestamp)
        Log.debug("Reset installation timestamp to: \(newTimestamp) (\(minutesBack) minutes ago)", category: .auth)
    }

    /// Clears the installation timestamp so it will be recreated on next sync
    func clearInstallationTimestamp() {
        try? delete(for: .installationTimestamp)
        Log.debug("Cleared installation timestamp", category: .auth)
    }
}