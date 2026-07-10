import Foundation

/// Serializes mutations that derive and persist conversation rollups.
///
/// Background sync and user actions use separate Core Data contexts. Chaining
/// operations for every conversation they share prevents a stale rollup save
/// from landing after a newer read-state transaction.
actor ConversationRollupMutationSerializer {
    static let shared = ConversationRollupMutationSerializer()

    private var tailsByConversationKey: [String: Task<Void, Never>] = [:]
    private var tokensByConversationKey: [String: UUID] = [:]

    func perform<Value: Sendable>(
        conversationKeys: Set<String>,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        guard !conversationKeys.isEmpty else {
            return await operation()
        }

        let previousTasks = conversationKeys.compactMap { tailsByConversationKey[$0] }
        let token = UUID()
        let task = Task<Value, Never> {
            for previousTask in previousTasks {
                await previousTask.value
            }
            return await operation()
        }
        let completionTask = Task<Void, Never> {
            _ = await task.value
        }

        for key in conversationKeys {
            tailsByConversationKey[key] = completionTask
            tokensByConversationKey[key] = token
        }

        let value = await task.value

        for key in conversationKeys where tokensByConversationKey[key] == token {
            tailsByConversationKey[key] = nil
            tokensByConversationKey[key] = nil
        }

        return value
    }
}
