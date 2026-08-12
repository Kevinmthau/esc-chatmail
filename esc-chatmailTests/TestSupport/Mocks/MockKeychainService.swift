import Foundation
@testable import esc_chatmail

/// In-memory mock implementation of KeychainServiceProtocol for testing.
/// All data is stored in memory and lost when the mock is deallocated.
///
/// All state is guarded by `lock`: tests poll this mock from the test
/// executor (`waitUntil` closures) while `AuthSession` mutates it from
/// MainActor tasks, so unsynchronized dictionaries would be a data race.
/// The `onLoad`/`onDelete` hooks deliberately fire OUTSIDE the lock so a
/// hook that re-enters the mock cannot deadlock.
final class MockKeychainService: KeychainServiceProtocol, @unchecked Sendable {

    private let lock = NSLock()

    /// In-memory storage for keychain items
    private var storage: [String: Data] = [:]
    private var accessLevels: [String: KeychainService.AccessLevel] = [:]

    private var _saveCallCount = 0
    private var _loadCallCount = 0
    private var _deleteCallCount = 0

    /// Tracks method calls for verification in tests
    var saveCallCount: Int { lock.withLock { _saveCallCount } }
    var loadCallCount: Int { lock.withLock { _loadCallCount } }
    var deleteCallCount: Int { lock.withLock { _deleteCallCount } }

    private var _errorToThrow: Error?
    private var saveErrorsByKey: [String: Error] = [:]
    private var deleteErrorsByKey: [String: Error] = [:]

    /// Optional error to throw on next operation (resets after throwing)
    var errorToThrow: Error? {
        get { lock.withLock { _errorToThrow } }
        set { lock.withLock { _errorToThrow = newValue } }
    }

    private var _onLoad: (() -> Void)?
    private var _onDelete: ((String) -> Void)?

    /// Interleave hook: runs after `load(for:)` has read the stored value but
    /// before it returns, letting tests deterministically emulate mutations
    /// (e.g. clearTokens) that land while a keychain read is in flight.
    var onLoad: (() -> Void)? {
        get { lock.withLock { _onLoad } }
        set { lock.withLock { _onLoad = newValue } }
    }
    var onDelete: ((String) -> Void)? {
        get { lock.withLock { _onDelete } }
        set { lock.withLock { _onDelete = newValue } }
    }

    /// Clears all stored data and resets call counts
    func reset() {
        lock.withLock {
            storage.removeAll()
            accessLevels.removeAll()
            _saveCallCount = 0
            _loadCallCount = 0
            _deleteCallCount = 0
            _errorToThrow = nil
            saveErrorsByKey.removeAll()
            deleteErrorsByKey.removeAll()
            _onLoad = nil
            _onDelete = nil
        }
    }

    // MARK: - KeychainServiceProtocol

    func save(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel) throws {
        try lock.withLock {
            _saveCallCount += 1
            if let error = saveErrorsByKey.removeValue(forKey: key) {
                throw error
            }
            if let error = _errorToThrow {
                _errorToThrow = nil
                throw error
            }
            storage[key] = data
            accessLevels[key] = access
        }
    }

    func load(for key: String) throws -> Data {
        let (data, hook): (Data, (() -> Void)?) = try lock.withLock {
            _loadCallCount += 1
            if let error = _errorToThrow {
                _errorToThrow = nil
                throw error
            }
            guard let data = storage[key] else {
                throw KeychainError.itemNotFound
            }
            return (data, _onLoad)
        }
        // Fires after the value was read so the caller receives a snapshot
        // that any mutation made by the hook did not see (TOCTOU window).
        hook?()
        return data
    }

    func delete(for key: String) throws {
        let hook: ((String) -> Void)? = lock.withLock {
            _deleteCallCount += 1
            return _onDelete
        }
        hook?(key)
        try lock.withLock {
            if let error = deleteErrorsByKey.removeValue(forKey: key) {
                throw error
            }
            if let error = _errorToThrow {
                _errorToThrow = nil
                throw error
            }
            storage.removeValue(forKey: key)
            accessLevels.removeValue(forKey: key)
        }
    }

    func exists(for key: String) -> Bool {
        lock.withLock { storage[key] != nil }
    }

    func update(_ data: Data, for key: String, withAccess access: KeychainService.AccessLevel?) throws {
        try lock.withLock {
            if let error = _errorToThrow {
                _errorToThrow = nil
                throw error
            }
            guard storage[key] != nil else {
                throw KeychainError.itemNotFound
            }
            storage[key] = data
            if let access {
                accessLevels[key] = access
            }
        }
    }

    func clearAll() throws {
        try lock.withLock {
            if let error = _errorToThrow {
                _errorToThrow = nil
                throw error
            }
            storage.removeAll()
            accessLevels.removeAll()
        }
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
    func failNextSave(for key: String, with error: Error) {
        lock.withLock { saveErrorsByKey[key] = error }
    }

    func failNextDelete(for key: String, with error: Error) {
        lock.withLock { deleteErrorsByKey[key] = error }
    }

    /// Pre-populates storage with test data
    func preload(_ data: [String: Data]) {
        lock.withLock {
            for (key, value) in data {
                storage[key] = value
            }
        }
    }

    /// Pre-populates storage with string values
    func preloadStrings(_ data: [String: String]) {
        lock.withLock {
            for (key, value) in data {
                if let data = value.data(using: .utf8) {
                    storage[key] = data
                }
            }
        }
    }

    /// Returns all stored keys for inspection
    var storedKeys: [String] {
        lock.withLock { Array(storage.keys) }
    }

    /// Returns raw storage for inspection
    var allStoredData: [String: Data] {
        lock.withLock { storage }
    }

    func accessLevel(for key: String) -> KeychainService.AccessLevel? {
        lock.withLock { accessLevels[key] }
    }
}
