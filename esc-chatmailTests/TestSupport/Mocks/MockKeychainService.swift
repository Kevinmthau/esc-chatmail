import Foundation
@testable import esc_chatmail

/// In-memory mock implementation of KeychainServiceProtocol for testing.
/// All data is stored in memory and lost when the mock is deallocated.
final class MockKeychainService: KeychainServiceProtocol {

    /// In-memory storage for keychain items
    private var storage: [String: Data] = [:]

    /// Tracks method calls for verification in tests
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0
    private(set) var deleteCallCount = 0

    /// Optional error to throw on next operation (resets after throwing)
    var errorToThrow: Error?

    /// Clears all stored data and resets call counts
    func reset() {
        storage.removeAll()
        saveCallCount = 0
        loadCallCount = 0
        deleteCallCount = 0
        errorToThrow = nil
    }

    // MARK: - KeychainServiceProtocol

    func save(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel) throws {
        saveCallCount += 1
        if let error = errorToThrow {
            errorToThrow = nil
            throw error
        }
        storage[key] = data
    }

    func load(for key: String) throws -> Data {
        loadCallCount += 1
        if let error = errorToThrow {
            errorToThrow = nil
            throw error
        }
        guard let data = storage[key] else {
            throw KeychainError.itemNotFound
        }
        return data
    }

    func delete(for key: String) throws {
        deleteCallCount += 1
        if let error = errorToThrow {
            errorToThrow = nil
            throw error
        }
        storage.removeValue(forKey: key)
    }

    func exists(for key: String) -> Bool {
        storage[key] != nil
    }

    func update(_ data: Data, for key: String) throws {
        if let error = errorToThrow {
            errorToThrow = nil
            throw error
        }
        guard storage[key] != nil else {
            throw KeychainError.itemNotFound
        }
        storage[key] = data
    }

    func clearAll() throws {
        if let error = errorToThrow {
            errorToThrow = nil
            throw error
        }
        storage.removeAll()
    }

    func saveString(_ string: String, for key: String, withAccess access: KeychainService.AccessLevel) throws {
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

    func saveCodable<T: Codable>(_ object: T, for key: String, withAccess access: KeychainService.AccessLevel) throws {
        let data = try JSONEncoder().encode(object)
        try save(data, for: key, withAccess: access)
    }

    func loadCodable<T: Codable>(_ type: T.Type, for key: String) throws -> T {
        let data = try load(for: key)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Test Helpers

extension MockKeychainService {
    /// Pre-populates storage with test data
    func preload(_ data: [String: Data]) {
        for (key, value) in data {
            storage[key] = value
        }
    }

    /// Pre-populates storage with string values
    func preloadStrings(_ data: [String: String]) {
        for (key, value) in data {
            if let data = value.data(using: .utf8) {
                storage[key] = data
            }
        }
    }

    /// Returns all stored keys for inspection
    var storedKeys: [String] {
        Array(storage.keys)
    }

    /// Returns raw storage for inspection
    var allStoredData: [String: Data] {
        storage
    }
}
