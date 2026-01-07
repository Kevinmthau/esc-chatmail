import Foundation

// MARK: - String & Codable Convenience Methods
extension KeychainService {
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

    // MARK: - Typed Key Overloads

    func saveString(_ string: String, for key: Key, withAccess access: AccessLevel = .whenUnlockedThisDeviceOnly) throws {
        try saveString(string, for: key.rawValue, withAccess: access)
    }

    func loadString(for key: Key) throws -> String {
        try loadString(for: key.rawValue)
    }
}
