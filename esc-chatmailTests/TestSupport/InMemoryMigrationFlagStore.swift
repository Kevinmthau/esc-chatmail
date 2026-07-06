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
