import Foundation
@testable import esc_chatmail

/// Test-scoped migration flag storage.
///
/// A fresh instance per test keeps one-shot migration guards away from
/// process-global `UserDefaults.standard` keys. The lock is needed because
/// tests poll from the main actor while migration completions can write from
/// non-isolated `ViewModelTaskManager` operations.
final class InMemoryMigrationFlagStore: MigrationFlagStore {
    private let lock = NSLock()
    private var flags: [String: Bool] = [:]
    private var strings: [String: String] = [:]
    private var stringWriteCounts: [String: Int] = [:]

    func string(forKey defaultName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return strings[defaultName]
    }

    func setString(_ value: String?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        strings[defaultName] = value
        stringWriteCounts[defaultName, default: 0] += 1
    }

    /// How many times `setString(_:forKey:)` wrote `defaultName`, including
    /// writes of an unchanged or nil value. Lets a test prove a no-op pass
    /// skips the write rather than rewriting the same value.
    func stringWriteCount(forKey defaultName: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return stringWriteCounts[defaultName] ?? 0
    }

    func bool(forKey defaultName: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flags[defaultName] ?? false
    }

    func set(_ value: Bool, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        flags[defaultName] = value
    }
}
