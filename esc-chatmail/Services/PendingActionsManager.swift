import Foundation
import CoreData

// MARK: - Protocol for Dependency Injection

/// Protocol for PendingActionsManager to enable testing with mock implementations
protocol PendingActionsManagerProtocol: Actor {
    func queueAction(type: PendingAction.ActionType, messageId: String, payload: [String: Any]?) async
    func queueConversationAction(type: PendingAction.ActionType, conversationId: UUID, messageIds: [String]) async
    func processAllPendingActions() async
    func pendingActionCount() async -> Int
    func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool
    func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async
    func stopMonitoring()
}

// MARK: - Pending Actions Manager

/// Manages a persistent queue of pending actions that need to be synced to Gmail.
/// Actions are stored in CoreData and processed when network is available.
///
/// Responsibilities have been decomposed:
/// - NetworkMonitor: Handles connectivity detection
/// - ActionExecutor: Handles action execution against Gmail API
/// - PendingActionsManager: Coordinates queuing and processing
actor PendingActionsManager: PendingActionsManagerProtocol {
    static let shared = PendingActionsManager()

    private let coreDataStack: CoreDataStack
    private let actionExecutor: ActionExecutorProtocol
    private let networkMonitor: NetworkMonitorProtocol

    private let maxRetries = 5
    private let baseRetryDelay: TimeInterval = 2.0
    private var isProcessing = false
    private var isInitialized = false

    // MARK: - Initialization

    /// Production initializer
    private init() {
        self.coreDataStack = CoreDataStack.shared
        self.actionExecutor = GmailActionExecutor()
        self.networkMonitor = AppNetworkMonitor.shared
    }

    /// Testable initializer with dependency injection
    init(
        coreDataStack: CoreDataStack,
        actionExecutor: ActionExecutorProtocol = GmailActionExecutor(),
        networkMonitor: NetworkMonitorProtocol = AppNetworkMonitor.shared
    ) {
        self.coreDataStack = coreDataStack
        self.actionExecutor = actionExecutor
        self.networkMonitor = networkMonitor
    }

    /// Sets up network monitoring on first use
    private func ensureInitialized() {
        guard !isInitialized else { return }
        isInitialized = true

        networkMonitor.onConnectivityChange = { [weak self] isConnected in
            guard isConnected else { return }
            Task { [weak self] in
                await self?.processAllPendingActions()
            }
        }
        networkMonitor.start()
    }

    func stopMonitoring() {
        networkMonitor.stop()
        isInitialized = false
    }

    // MARK: - Queue Actions

    func queueAction(
        type: PendingAction.ActionType,
        messageId: String,
        payload: [String: Any]? = nil
    ) async {
        ensureInitialized()

        await MainActor.run {
            let context = coreDataStack.viewContext
            createPendingAction(
                in: context,
                type: type,
                messageId: messageId,
                payload: payload
            )
            coreDataStack.saveIfNeeded(context: context)
        }

        if networkMonitor.isConnected {
            await processAllPendingActions()
        }
    }

    func queueConversationAction(
        type: PendingAction.ActionType,
        conversationId: UUID,
        messageIds: [String]
    ) async {
        ensureInitialized()

        Log.info("Queueing \(type.rawValue) for \(messageIds.count) messages", category: .sync)

        await MainActor.run {
            let context = coreDataStack.viewContext
            let payload: [String: Any] = ["messageIds": messageIds]
            createPendingAction(
                in: context,
                type: type,
                conversationId: conversationId,
                payload: payload
            )
            coreDataStack.saveIfNeeded(context: context)
        }

        if networkMonitor.isConnected {
            await processAllPendingActions()
        }
    }

    private nonisolated func createPendingAction(
        in context: NSManagedObjectContext,
        type: PendingAction.ActionType,
        messageId: String? = nil,
        conversationId: UUID? = nil,
        payload: [String: Any]? = nil
    ) {
        let action = PendingAction(context: context)
        action.setValue(UUID(), forKey: "id")
        action.setValue(type.rawValue, forKey: "actionType")
        action.setValue(messageId, forKey: "messageId")
        action.setValue(conversationId, forKey: "conversationId")
        action.setValue(Date(), forKey: "createdAt")
        action.setValue("pending", forKey: "status")
        action.setValue(Int16(0), forKey: "retryCount")

        if let payload = payload,
           let payloadData = try? JSONSerialization.data(withJSONObject: payload),
           let payloadString = String(data: payloadData, encoding: .utf8) {
            action.setValue(payloadString, forKey: "payload")
        }
    }

    // MARK: - Process Actions

    func processAllPendingActions() async {
        ensureInitialized()

        guard !isProcessing else { return }
        guard networkMonitor.isConnected else { return }

        isProcessing = true
        defer { isProcessing = false }

        let context = coreDataStack.newBackgroundContext()

        // Process actions one by one
        while let action = await fetchNextPendingAction(context: context) {
            await processAction(action, context: context)
        }

        await cleanupCompletedActions(context: context)
    }

    private func fetchNextPendingAction(context: NSManagedObjectContext) async -> PendingAction? {
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "status == %@ OR (status == %@ AND retryCount < %d)",
                "pending", "failed", self.maxRetries
            )
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: true)]
            request.fetchLimit = 1
            return try? context.fetch(request).first
        }
    }

    private func processAction(_ action: PendingAction, context: NSManagedObjectContext) async {
        let objectID = action.objectID
        let actionType = action.actionTypeEnum
        let messageId = action.value(forKey: "messageId") as? String
        let conversationId = action.value(forKey: "conversationId") as? UUID
        let payloadString = action.value(forKey: "payload") as? String
        let retryCount = action.value(forKey: "retryCount") as? Int16 ?? 0

        // Mark as processing
        await updateActionStatus(objectID: objectID, status: "processing", context: context)

        do {
            let payload = parsePayload(payloadString)

            guard let type = actionType else {
                throw PendingActionError.invalidActionType
            }

            try await actionExecutor.execute(
                type: type,
                messageId: messageId,
                conversationId: conversationId,
                payload: payload
            )

            await updateActionStatus(objectID: objectID, status: "completed", context: context)
            await clearLocalModifications(messageId: messageId, payload: payload, context: context)

            Log.info("Processed action: \(type.rawValue) for message: \(messageId ?? "N/A")", category: .sync)

        } catch {
            Log.error("Failed to process action: \(error)", category: .sync)
            await handleActionFailure(
                objectID: objectID,
                retryCount: retryCount,
                context: context
            )

            // Wait before processing next action
            let delay = baseRetryDelay * pow(2.0, Double(retryCount))
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 30.0) * 1_000_000_000))
        }
    }

    private func parsePayload(_ payloadString: String?) -> [String: Any]? {
        guard let payloadString = payloadString,
              let data = payloadString.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    private func updateActionStatus(objectID: NSManagedObjectID, status: String, context: NSManagedObjectContext) async {
        await context.perform {
            guard let action = try? context.existingObject(with: objectID) as? PendingAction else { return }
            action.setValue(status, forKey: "status")
            if status == "processing" {
                action.setValue(Date(), forKey: "lastAttempt")
            }
            try? context.save()
        }
    }

    private func handleActionFailure(objectID: NSManagedObjectID, retryCount: Int16, context: NSManagedObjectContext) async {
        await context.perform {
            guard let action = try? context.existingObject(with: objectID) as? PendingAction else { return }
            let newRetryCount = retryCount + 1
            action.setValue(newRetryCount, forKey: "retryCount")
            action.setValue("failed", forKey: "status")

            if newRetryCount >= Int16(self.maxRetries) {
                Log.warning("Action permanently failed after \(self.maxRetries) retries", category: .sync)
            } else {
                Log.info("Action will be retried (attempt \(newRetryCount + 1)/\(self.maxRetries))", category: .sync)
            }

            try? context.save()
        }
    }

    private func clearLocalModifications(messageId: String?, payload: [String: Any]?, context: NSManagedObjectContext) async {
        if let messageId = messageId {
            await clearLocalModification(forMessageId: messageId, context: context)
        } else if let messageIds = payload?["messageIds"] as? [String] {
            for msgId in messageIds {
                await clearLocalModification(forMessageId: msgId, context: context)
            }
        }
    }

    private func clearLocalModification(forMessageId messageId: String, context: NSManagedObjectContext) async {
        await context.perform {
            let request = NSFetchRequest<Message>(entityName: "Message")
            request.predicate = NSPredicate(format: "id == %@", messageId)
            if let message = try? context.fetch(request).first {
                message.setValue(nil, forKey: "localModifiedAt")
            }
        }
    }

    private func cleanupCompletedActions(context: NSManagedObjectContext) async {
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@", "completed")

            guard let completedActions = try? context.fetch(request), !completedActions.isEmpty else {
                return
            }

            for action in completedActions {
                context.delete(action)
            }
            try? context.save()

            Log.debug("Cleaned up \(completedActions.count) completed actions", category: .sync)
        }
    }

    // MARK: - Query Methods

    func pendingActionCount() async -> Int {
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@ OR status == %@", "pending", "failed")
            request.resultType = .countResultType
            return (try? context.fetch(request).first?.intValue) ?? 0
        }
    }

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
}
