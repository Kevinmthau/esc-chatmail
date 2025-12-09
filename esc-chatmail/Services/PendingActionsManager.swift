import Foundation
import CoreData
import Network

/// Manages a persistent queue of pending actions that need to be synced to Gmail.
/// Actions are stored in CoreData and processed when network is available.
/// This ensures actions are not lost if the app is closed or loses connectivity.
actor PendingActionsManager {
    static let shared = PendingActionsManager()

    private let coreDataStack = CoreDataStack.shared
    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 2.0
    private var isProcessing = false
    private var networkMonitor: NWPathMonitor?
    private var isNetworkAvailable = true
    private var isInitialized = false

    private init() {
        // Network monitoring setup is deferred to first use
        // because actor-isolated methods can't be called from nonisolated init
    }

    /// Ensures network monitoring is set up. Called lazily on first use.
    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handleNetworkChange(isAvailable: path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "PendingActionsNetworkMonitor"))
        networkMonitor = monitor
    }

    private func handleNetworkChange(isAvailable: Bool) async {
        let wasUnavailable = !isNetworkAvailable
        isNetworkAvailable = isAvailable

        // If network just became available, process pending actions
        if isAvailable && wasUnavailable {
            await processAllPendingActions()
        }
    }

    // MARK: - Queue Actions

    /// Queues an action for a single message
    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]? = nil
    ) async {
        ensureInitialized()

        await MainActor.run {
            let context = coreDataStack.viewContext

            let action = PendingAction(context: context)
            action.setValue(UUID(), forKey: "id")
            action.setValue(type.rawValue, forKey: "actionType")
            action.setValue(messageId, forKey: "messageId")
            action.setValue(Date(), forKey: "createdAt")
            action.setValue("pending", forKey: "status")
            action.setValue(Int16(0), forKey: "retryCount")

            if let payload = payload {
                if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
                   let payloadString = String(data: payloadData, encoding: .utf8) {
                    action.setValue(payloadString, forKey: "payload")
                }
            }

            coreDataStack.saveIfNeeded(context: context)
        }

        // Try to process immediately if network is available
        if isNetworkAvailable {
            await processAllPendingActions()
        }
    }

    /// Queues an action for a conversation
    func queueConversationAction(
        type: PendingAction.ActionType,
        conversationId: UUID,
        messageIds: [String]
    ) async {
        ensureInitialized()

        print("PendingActions: Queueing \(type.rawValue) for \(messageIds.count) messages")

        await MainActor.run {
            let context = coreDataStack.viewContext

            let action = PendingAction(context: context)
            action.setValue(UUID(), forKey: "id")
            action.setValue(type.rawValue, forKey: "actionType")
            action.setValue(conversationId, forKey: "conversationId")
            action.setValue(Date(), forKey: "createdAt")
            action.setValue("pending", forKey: "status")
            action.setValue(Int16(0), forKey: "retryCount")

            // Store message IDs in payload
            let payload: [String: Any] = ["messageIds": messageIds]
            if let payloadData = try? JSONSerialization.data(withJSONObject: payload),
               let payloadString = String(data: payloadData, encoding: .utf8) {
                action.setValue(payloadString, forKey: "payload")
                print("PendingActions: Payload created with \(messageIds.count) message IDs")
            } else {
                print("PendingActions: ERROR - Failed to create payload")
            }

            coreDataStack.saveIfNeeded(context: context)
            print("PendingActions: Action saved to CoreData")
        }

        // Try to process immediately if network is available
        print("PendingActions: Network available = \(isNetworkAvailable)")
        if isNetworkAvailable {
            await processAllPendingActions()
        }
    }

    // MARK: - Process Actions

    /// Processes all pending actions in order
    func processAllPendingActions() async {
        ensureInitialized()

        guard !isProcessing else { return }
        guard isNetworkAvailable else { return }

        isProcessing = true
        defer { isProcessing = false }

        let context = coreDataStack.newBackgroundContext()

        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@ OR status == %@", "pending", "failed")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]

            guard let actions = try? context.fetch(request), !actions.isEmpty else {
                return
            }

            print("Processing \(actions.count) pending actions")
        }

        // Fetch actions and process one by one
        while true {
            let nextAction = await fetchNextPendingAction(context: context)
            guard let action = nextAction else { break }

            await processAction(action, context: context)
        }

        // Clean up completed actions
        await cleanupCompletedActions(context: context)
    }

    private func fetchNextPendingAction(context: NSManagedObjectContext) async -> PendingAction? {
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@ OR (status == %@ AND retryCount < %d)", "pending", "failed", self.maxRetries)
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            request.fetchLimit = 1

            return try? context.fetch(request).first
        }
    }

    private func processAction(_ action: PendingAction, context: NSManagedObjectContext) async {
        // Extract all values we need from the action before any async boundaries
        // NSManagedObjectID is Sendable and can be used to re-fetch the object
        let objectID = action.objectID
        let actionId = action.value(forKey: "id") as? UUID
        let actionType = action.actionTypeEnum
        let messageId = action.value(forKey: "messageId") as? String
        let conversationId = action.value(forKey: "conversationId") as? UUID
        let payloadString = action.value(forKey: "payload") as? String
        let retryCount = action.value(forKey: "retryCount") as? Int16 ?? 0

        // Mark as processing
        await context.perform {
            guard let actionToUpdate = try? context.existingObject(with: objectID) as? PendingAction else { return }
            actionToUpdate.setValue("processing", forKey: "status")
            actionToUpdate.setValue(Date(), forKey: "lastAttempt")
            try? context.save()
        }

        do {
            // Parse payload if present
            var payload: [String: Any]?
            if let payloadString = payloadString,
               let data = payloadString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                payload = parsed
            }

            // Execute the action
            try await executeAction(
                type: actionType,
                messageId: messageId,
                conversationId: conversationId,
                payload: payload
            )

            // Mark as completed
            await context.perform {
                guard let actionToUpdate = try? context.existingObject(with: objectID) as? PendingAction else { return }
                actionToUpdate.setValue("completed", forKey: "status")
                try? context.save()
            }

            // Clear the localModifiedAt timestamp for the message since the action synced
            if let messageId = messageId {
                await clearLocalModification(forMessageId: messageId, context: context)
            } else if let payload = payload, let messageIds = payload["messageIds"] as? [String] {
                for msgId in messageIds {
                    await clearLocalModification(forMessageId: msgId, context: context)
                }
            }

            print("Successfully processed action: \(actionType?.rawValue ?? "unknown") for message: \(messageId ?? "N/A")")

        } catch {
            print("Failed to process action \(actionId?.uuidString ?? "unknown"): \(error)")

            // Handle failure with retry logic
            await context.perform {
                guard let actionToUpdate = try? context.existingObject(with: objectID) as? PendingAction else { return }
                let newRetryCount = retryCount + 1
                actionToUpdate.setValue(newRetryCount, forKey: "retryCount")

                if newRetryCount >= Int16(self.maxRetries) {
                    actionToUpdate.setValue("failed", forKey: "status")
                    print("Action permanently failed after \(self.maxRetries) retries")
                } else {
                    actionToUpdate.setValue("failed", forKey: "status")
                    print("Action will be retried (attempt \(newRetryCount + 1)/\(self.maxRetries))")
                }

                try? context.save()
            }

            // Wait before processing next action if this one failed
            let delay = baseRetryDelay * pow(2.0, Double(retryCount))
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 30.0) * 1_000_000_000))
        }
    }

    private func executeAction(
        type: PendingAction.ActionType?,
        messageId: String?,
        conversationId: UUID?,
        payload: [String: Any]?
    ) async throws {
        guard let type = type else {
            throw PendingActionError.invalidActionType
        }

        // Get the API client on the main actor
        let apiClient = await MainActor.run { GmailAPIClient.shared }

        switch type {
        case .markRead:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["UNREAD"])

        case .markUnread:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, addLabelIds: ["UNREAD"])

        case .archive:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["INBOX"])

        case .archiveConversation:
            guard let messageIds = payload?["messageIds"] as? [String], !messageIds.isEmpty else {
                throw PendingActionError.missingMessageIds
            }
            try await apiClient.batchModify(ids: messageIds, removeLabelIds: ["INBOX"])

        case .star:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, addLabelIds: ["STARRED"])

        case .unstar:
            guard let messageId = messageId else {
                throw PendingActionError.missingMessageId
            }
            _ = try await apiClient.modifyMessage(id: messageId, removeLabelIds: ["STARRED"])

        case .deleteConversation:
            guard let messageIds = payload?["messageIds"] as? [String], !messageIds.isEmpty else {
                throw PendingActionError.missingMessageIds
            }
            try await apiClient.batchModify(ids: messageIds, addLabelIds: ["TRASH"], removeLabelIds: ["INBOX"])
        }
    }

    private func cleanupCompletedActions(context: NSManagedObjectContext) async {
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@", "completed")

            guard let completedActions = try? context.fetch(request) else { return }

            for action in completedActions {
                context.delete(action)
            }

            try? context.save()

            if !completedActions.isEmpty {
                print("Cleaned up \(completedActions.count) completed actions")
            }
        }
    }

    // MARK: - Query Methods

    /// Returns the count of pending actions
    func pendingActionCount() async -> Int {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@ OR status == %@", "pending", "failed")
            request.resultType = .countResultType

            return (try? context.fetch(request).first?.intValue) ?? 0
        }
    }

    /// Check if there's a pending action for a specific message
    func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "messageId == %@ AND actionType == %@ AND (status == %@ OR status == %@)",
                messageId, type.rawValue, "pending", "processing"
            )
            request.fetchLimit = 1

            return (try? context.fetch(request).first) != nil
        }
    }

    /// Cancel a pending action for a message (e.g., if user toggles read/unread quickly)
    func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async {
        await MainActor.run {
            let context = coreDataStack.viewContext

            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "messageId == %@ AND actionType == %@ AND status == %@",
                messageId, type.rawValue, "pending"
            )

            if let actions = try? context.fetch(request) {
                for action in actions {
                    context.delete(action)
                }
                coreDataStack.saveIfNeeded(context: context)
            }
        }
    }

    // MARK: - Private Helpers

    /// Clear the localModifiedAt timestamp for a message after its action has been synced
    private func clearLocalModification(forMessageId messageId: String, context: NSManagedObjectContext) async {
        await context.perform {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageId)

            if let message = try? context.fetch(request).first {
                message.setValue(nil, forKey: "localModifiedAt")
            }
        }
    }
}

// MARK: - Errors

enum PendingActionError: LocalizedError {
    case invalidActionType
    case missingMessageId
    case missingMessageIds
    case missingConversationId

    var errorDescription: String? {
        switch self {
        case .invalidActionType:
            return "Invalid action type"
        case .missingMessageId:
            return "Message ID is required for this action"
        case .missingMessageIds:
            return "Message IDs are required for this action"
        case .missingConversationId:
            return "Conversation ID is required for this action"
        }
    }
}
