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

extension InMemoryMigrationFlagStore {
    /// A store whose one-shot conversation-list launch passes are marked done, for a
    /// list suite that must not have them run: with test-owned storage they sweep the
    /// suite's store and save conversations (the name refresh renames rows that have
    /// participants), and those saves reach the list through the sibling-save path,
    /// which registers rows and changes snapshots under a test that awaits. The list-
    /// title repair runs every launch regardless, and touches list conversations only.
    /// `@MainActor` because two of the keys are the coordinator's main-actor statics.
    @MainActor
    static func withConversationListLaunchPassesDone() -> InMemoryMigrationFlagStore {
        let store = InMemoryMigrationFlagStore()
        for key in [
            ConversationLaunchRepairCoordinator.conversationNameRefreshMigrationKey,
            ConversationLaunchRepairCoordinator.conversationPreviewRepairMigrationKey,
            ConversationLaunchRepairCoordinator.chatPreviewRepairMigrationKey,
            ConversationLaunchRepairCoordinator.blankChatPreviewBackfillMigrationKey,
            ConversationLaunchRepairCoordinator.richContentVerdictBackfillMigrationKey
        ] {
            store.set(true, forKey: key)
        }
        return store
    }
}
