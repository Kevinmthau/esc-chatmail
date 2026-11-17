import Foundation
import CoreData

/// Serializes mutations that derive and persist conversation rollups.
///
/// Background sync and user actions use separate Core Data contexts. Chaining
/// operations for every conversation they share prevents a stale rollup save
/// from landing after a newer read-state transaction.
actor ConversationRollupMutationSerializer {
    static let shared = ConversationRollupMutationSerializer()

    /// Cleanup reads a store-wide snapshot before making destructive conversation
    /// decisions. Optimistic-send creation uses the same key so its durable
    /// message + mutation record lands wholly before or wholly after that snapshot.
    private static let cleanupSensitiveMutationKey = "conversation-cleanup-sensitive-mutation"

    private actor CompletionGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let currentWaiters = waiters
            waiters.removeAll()
            currentWaiters.forEach { $0.resume() }
        }
    }

    private struct LocalReadState: @unchecked Sendable {
        let objectID: NSManagedObjectID
        let localModifiedAt: Date
        let isUnread: Bool
    }

    private var tailsByConversationKey: [String: Task<Void, Never>] = [:]
    private var tokensByConversationKey: [String: UUID] = [:]

    func perform<Value: Sendable>(
        conversationKeys: Set<String>,
        onEnqueued: (@Sendable () async -> Void)? = nil,
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
        await onEnqueued?()

        let value = await task.value

        for key in conversationKeys where tokensByConversationKey[key] == token {
            tailsByConversationKey[key] = nil
            tokensByConversationKey[key] = nil
        }

        return value
    }

    func performThrowing<Value: Sendable>(
        conversationKeys: Set<String>,
        onEnqueued: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard !conversationKeys.isEmpty else {
            try Task.checkCancellation()
            return try await operation()
        }

        let previousTasks = conversationKeys.compactMap { tailsByConversationKey[$0] }
        let token = UUID()
        let completionGate = CompletionGate()
        let completionTask = Task<Void, Never> {
            await completionGate.wait()
        }

        for key in conversationKeys {
            tailsByConversationKey[key] = completionTask
            tokensByConversationKey[key] = token
        }
        await onEnqueued?()

        do {
            for previousTask in previousTasks {
                await previousTask.value
            }
            try Task.checkCancellation()
            let value = try await operation()
            await completionGate.open()
            releaseTails(for: conversationKeys, token: token)
            return value
        } catch {
            await completionGate.open()
            releaseTails(for: conversationKeys, token: token)
            throw error
        }
    }

    func performCleanupSensitiveMutation<Value: Sendable>(
        onEnqueued: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await perform(
            conversationKeys: [Self.cleanupSensitiveMutationKey],
            onEnqueued: onEnqueued,
            operation: operation
        )
    }

    func performThrowingCleanupSensitiveMutation<Value: Sendable>(
        onEnqueued: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await performThrowing(
            conversationKeys: [Self.cleanupSensitiveMutationKey],
            onEnqueued: onEnqueued,
            operation: operation
        )
    }

    /// The turns of the conversations an optimistic send may anchor to, for
    /// a caller that already holds the cleanup-sensitive gate
    /// (`GmailSendService.createOptimisticMessage`).
    ///
    /// Archive and Report Spam change a conversation on a background context
    /// inside that conversation's turn. A send that chose the conversation
    /// while one of them was still running read it as it was, anchored to
    /// it, and was archived with it. Inside the turn the send runs wholly
    /// before the action or wholly after it, and only a send to a
    /// conversation being archived waits for the archive.
    ///
    /// The order is the gate, then the turn, and it is one-way: an operation
    /// that holds a conversation's turn must never ask for the gate, because
    /// a send that holds the gate and waits for that turn is then waited on
    /// by it. For the same reason nothing may ask for the gate and a
    /// conversation's turn in one call: queued behind a send's gate, it is
    /// ahead of that send's turn. Both fail silently, as a hang. No holder
    /// of a conversation's turn asks for the gate today.
    func performThrowingAnchoredSendMutation<Value: Sendable>(
        conversationIDs: Set<NSManagedObjectID>,
        onEnqueued: (@Sendable () async -> Void)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await performThrowing(
            conversationKeys: Self.conversationKeys(for: conversationIDs),
            onEnqueued: onEnqueued,
            operation: operation
        )
    }

    func performSyncMutation<Value: Sendable>(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value {
        await perform(conversationKeys: Self.conversationKeys(for: conversationIDs)) {
            await Self.preserveNewerLocalReadState(
                for: conversationIDs,
                in: context
            )
            return await operation()
        }
    }

    func performThrowingSyncMutation<Value: Sendable>(
        conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await performThrowing(conversationKeys: Self.conversationKeys(for: conversationIDs)) {
            await Self.preserveNewerLocalReadState(
                for: conversationIDs,
                in: context
            )
            return try await operation()
        }
    }

    private nonisolated static func conversationKeys(
        for conversationIDs: Set<NSManagedObjectID>
    ) -> Set<String> {
        Set(conversationIDs.map { $0.uriRepresentation().absoluteString })
    }

    private func releaseTails(for conversationKeys: Set<String>, token: UUID) {
        for key in conversationKeys where tokensByConversationKey[key] == token {
            tailsByConversationKey[key] = nil
            tokensByConversationKey[key] = nil
        }
    }

    /// A sync context can prepare mailbox state before a serialized local read
    /// commits. Restore newer durable read values for every affected conversation
    /// before deriving rollups or saving the sync context.
    private nonisolated static func preserveNewerLocalReadState(
        for conversationIDs: Set<NSManagedObjectID>,
        in context: NSManagedObjectContext
    ) async {
        guard let persistentStoreCoordinator = context.persistentStoreCoordinator else { return }

        let updatedMessageObjectIDs: [NSManagedObjectID] = await context.perform {
            context.updatedObjects
                .compactMap { $0 as? Message }
                .map(\.objectID)
                .filter { !$0.isTemporaryID }
        }

        let storeContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        storeContext.persistentStoreCoordinator = persistentStoreCoordinator
        let localStates: [LocalReadState] = await storeContext.perform {
            var statesByObjectID: [NSManagedObjectID: LocalReadState] = [:]

            for objectID in updatedMessageObjectIDs {
                guard let message = try? storeContext.existingObject(with: objectID) as? Message,
                      let localModifiedAt = message.localModifiedAt else {
                    continue
                }
                statesByObjectID[objectID] = LocalReadState(
                    objectID: objectID,
                    localModifiedAt: localModifiedAt,
                    isUnread: message.isUnread
                )
            }

            let conversations = conversationIDs.compactMap {
                try? storeContext.existingObject(with: $0) as? Conversation
            }
            if !conversations.isEmpty {
                let request = Message.fetchRequest()
                request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "conversation IN %@", conversations),
                    NSPredicate(format: "localModifiedAt != nil")
                ])
                request.includesPendingChanges = false

                for message in (try? storeContext.fetch(request)) ?? [] {
                    guard let localModifiedAt = message.localModifiedAt else { continue }
                    statesByObjectID[message.objectID] = LocalReadState(
                        objectID: message.objectID,
                        localModifiedAt: localModifiedAt,
                        isUnread: message.isUnread
                    )
                }
            }

            return Array(statesByObjectID.values)
        }
        guard !localStates.isEmpty else { return }

        await context.perform {
            for state in localStates {
                guard let message = try? context.existingObject(with: state.objectID) as? Message,
                      !message.isDeleted,
                      message.localModifiedAt.map({ $0 < state.localModifiedAt }) ?? true else {
                    continue
                }
                message.isUnread = state.isUnread
                message.localModifiedAt = state.localModifiedAt
            }
        }
    }
}
