import Foundation
import CoreData

/// Extension containing query methods for PendingActionsManager.
///
/// Caller-initiated reads and mutations are generation-stamped so work that
/// was requested for an old account cannot resume against a replacement
/// persistent store after teardown.
extension PendingActionsManager {

    private func withPendingActionRun<Result>(
        for accountWorkRequest: AccountWorkRequest,
        operation: (SyncRun) async -> Result
    ) async -> Result? {
        guard let syncRun = await syncRunCoordinator.acquireRun(
            kind: .pendingActions,
            for: accountWorkRequest
        ) else {
            return nil
        }

        let result = await operation(syncRun)
        await syncRunCoordinator.endRun(syncRun)
        return result
    }

    /// Returns the count of pending or failed actions that haven't exceeded retry limit.
    public func pendingActionCount() async -> Int {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return 0
        }
        return await pendingActionCount(accountWorkRequest: accountWorkRequest)
    }

    func pendingActionCount(accountWorkRequest: AccountWorkRequest) async -> Int {
        await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.pendingActionCount(within: syncRun)
        } ?? 0
    }

    private func pendingActionCount(within syncRun: SyncRun) async -> Int {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return 0 }

        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@ OR status == %@", "pending", "failed")
            request.resultType = .countResultType

            do {
                return try context.fetch(request).first?.intValue ?? 0
            } catch {
                Log.error("Failed to count pending actions", category: .sync, error: error)
                return 0
            }
        }
    }

    /// Checks if there's a pending action for a specific message and type.
    public func hasPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async -> Bool {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return false
        }
        return await hasPendingAction(
            forMessageId: messageId,
            type: type,
            accountWorkRequest: accountWorkRequest
        )
    }

    func hasPendingAction(
        forMessageId messageId: String,
        type: PendingAction.ActionType,
        accountWorkRequest: AccountWorkRequest
    ) async -> Bool {
        await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.hasPendingAction(
                forMessageId: messageId,
                type: type,
                within: syncRun
            )
        } ?? false
    }

    private func hasPendingAction(
        forMessageId messageId: String,
        type: PendingAction.ActionType,
        within syncRun: SyncRun
    ) async -> Bool {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return false }

        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "actionType == %@ AND (status == %@ OR status == %@)",
                type.rawValue, "pending", "processing"
            )
            request.fetchBatchSize = 20

            do {
                return try context.fetch(request).contains { action in
                    if action.messageIdValue == messageId {
                        return true
                    }
                    guard let payload = action.payloadValue,
                          let data = payload.data(using: .utf8),
                          let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let messageIds = decoded["messageIds"] as? [String] else {
                        return false
                    }
                    return messageIds.contains(messageId)
                }
            } catch {
                Log.error("Failed to check for pending action", category: .sync, error: error)
                return false  // Assume no pending action on error
            }
        }
    }

    /// Cancels a pending action for a specific message and type.
    public func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return
        }
        await cancelPendingAction(
            forMessageId: messageId,
            type: type,
            accountWorkRequest: accountWorkRequest
        )
    }

    func cancelPendingAction(
        forMessageId messageId: String,
        type: PendingAction.ActionType,
        accountWorkRequest: AccountWorkRequest
    ) async {
        _ = await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.cancelPendingAction(
                forMessageId: messageId,
                type: type,
                within: syncRun
            )
        }
    }

    private func cancelPendingAction(
        forMessageId messageId: String,
        type: PendingAction.ActionType,
        within syncRun: SyncRun
    ) async {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return }

        await MainActor.run {
            let context = coreDataStack.viewContext
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "messageId == %@ AND actionType == %@ AND status == %@",
                messageId, type.rawValue, "pending"
            )

            do {
                let actions = try context.fetch(request)
                for action in actions {
                    context.delete(action)
                }
                coreDataStack.saveIfNeeded(context: context)
            } catch {
                Log.error("Failed to cancel pending action for message \(messageId)", category: .sync, error: error)
            }
        }
    }

    // MARK: - Abandoned Action Queries

    /// Returns the count of permanently failed (abandoned) actions.
    public func abandonedActionCount() async -> Int {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return 0
        }
        return await abandonedActionCount(accountWorkRequest: accountWorkRequest)
    }

    func abandonedActionCount(accountWorkRequest: AccountWorkRequest) async -> Int {
        await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.abandonedActionCount(within: syncRun)
        } ?? 0
    }

    private func abandonedActionCount(within syncRun: SyncRun) async -> Int {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return 0 }

        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<NSNumber>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@", "abandoned")
            request.resultType = .countResultType

            do {
                return try context.fetch(request).first?.intValue ?? 0
            } catch {
                Log.error("Failed to count abandoned actions", category: .sync, error: error)
                return 0
            }
        }
    }

    /// Returns all permanently failed (abandoned) actions.
    public func fetchAbandonedActions() async -> [AbandonedActionInfo] {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return []
        }
        return await fetchAbandonedActions(accountWorkRequest: accountWorkRequest)
    }

    func fetchAbandonedActions(
        accountWorkRequest: AccountWorkRequest
    ) async -> [AbandonedActionInfo] {
        await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.fetchAbandonedActions(within: syncRun)
        } ?? []
    }

    private func fetchAbandonedActions(
        within syncRun: SyncRun
    ) async -> [AbandonedActionInfo] {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return [] }

        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@", "abandoned")
            request.sortDescriptors = [NSSortDescriptor(key: "createdAt", ascending: false)]

            do {
                let actions = try context.fetch(request)
                return actions.compactMap { action -> AbandonedActionInfo? in
                    guard let actionType = action.actionTypeEnum,
                          let createdAt = action.value(forKey: "createdAt") as? Date else {
                        return nil
                    }
                    return AbandonedActionInfo(
                        id: action.objectID,
                        actionType: actionType,
                        messageId: action.messageIdValue,
                        conversationId: action.conversationIdValue,
                        createdAt: createdAt,
                        retryCount: Int(action.retryCountValue)
                    )
                }
            } catch {
                Log.error("Failed to fetch abandoned actions", category: .sync, error: error)
                return []
            }
        }
    }

    /// Retries an abandoned action by resetting its status and retry count.
    public func retryAbandonedAction(objectID: NSManagedObjectID) async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return
        }
        await retryAbandonedAction(
            objectID: objectID,
            accountWorkRequest: accountWorkRequest
        )
    }

    func retryAbandonedAction(
        objectID: NSManagedObjectID,
        accountWorkRequest: AccountWorkRequest
    ) async {
        let didReset = await withPendingActionRun(for: accountWorkRequest) { syncRun in
            let didReset = await self.resetAbandonedAction(
                objectID: objectID,
                within: syncRun
            )
            if didReset {
                await self.lifecycleHooks.retryMutationDidResetAction?(syncRun)
            }
            return didReset
        } ?? false

        // Processing acquires its own cancellable run. Start it only after the
        // mutation lease has been released to avoid recursive acquisition.
        if didReset {
            await processAllPendingActions()
        }
    }

    private func resetAbandonedAction(
        objectID: NSManagedObjectID,
        within syncRun: SyncRun
    ) async -> Bool {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return false }

        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            do {
                guard let action = try context.existingObject(with: objectID) as? PendingAction else {
                    Log.warning("Abandoned action not found for retry", category: .sync)
                    return false
                }
                action.setValue("pending", forKey: "status")
                action.setValue(Int16(0), forKey: "retryCount")
                try context.save()
                Log.info("Abandoned action reset for retry", category: .sync)
                return true
            } catch {
                Log.error("Failed to retry abandoned action", category: .sync, error: error)
                return false
            }
        }
    }

    /// Retries all abandoned actions by resetting their status and retry count.
    public func retryAllAbandonedActions() async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return
        }
        await retryAllAbandonedActions(accountWorkRequest: accountWorkRequest)
    }

    func retryAllAbandonedActions(accountWorkRequest: AccountWorkRequest) async {
        let didReset = await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.resetAllAbandonedActions(within: syncRun)
        } ?? false

        if didReset {
            await processAllPendingActions()
        }
    }

    private func resetAllAbandonedActions(within syncRun: SyncRun) async -> Bool {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return false }

        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@", "abandoned")

            do {
                let actions = try context.fetch(request)
                for action in actions {
                    action.setValue("pending", forKey: "status")
                    action.setValue(Int16(0), forKey: "retryCount")
                }
                try context.save()
                Log.info("Reset \(actions.count) abandoned actions for retry", category: .sync)
                return true
            } catch {
                Log.error("Failed to retry all abandoned actions", category: .sync, error: error)
                return false
            }
        }
    }

    /// Dismisses (deletes) an abandoned action permanently.
    public func dismissAbandonedAction(objectID: NSManagedObjectID) async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return
        }
        await dismissAbandonedAction(
            objectID: objectID,
            accountWorkRequest: accountWorkRequest
        )
    }

    func dismissAbandonedAction(
        objectID: NSManagedObjectID,
        accountWorkRequest: AccountWorkRequest
    ) async {
        _ = await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.dismissAbandonedAction(objectID: objectID, within: syncRun)
        }
    }

    private func dismissAbandonedAction(
        objectID: NSManagedObjectID,
        within syncRun: SyncRun
    ) async {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return }

        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            do {
                guard let action = try context.existingObject(with: objectID) as? PendingAction else {
                    Log.warning("Abandoned action not found for dismissal", category: .sync)
                    return
                }
                context.delete(action)
                try context.save()
                Log.info("Dismissed abandoned action", category: .sync)
            } catch {
                Log.error("Failed to dismiss abandoned action", category: .sync, error: error)
            }
        }
    }

    /// Dismisses (deletes) all abandoned actions permanently.
    public func dismissAllAbandonedActions() async {
        guard let accountWorkRequest = await syncRunCoordinator.makeAccountWorkRequest() else {
            return
        }
        await dismissAllAbandonedActions(accountWorkRequest: accountWorkRequest)
    }

    func dismissAllAbandonedActions(accountWorkRequest: AccountWorkRequest) async {
        _ = await withPendingActionRun(for: accountWorkRequest) { syncRun in
            await self.dismissAllAbandonedActions(within: syncRun)
        }
    }

    private func dismissAllAbandonedActions(within syncRun: SyncRun) async {
        guard await syncRunCoordinator.isActiveRun(syncRun) else { return }

        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(format: "status == %@", "abandoned")

            do {
                let actions = try context.fetch(request)
                for action in actions {
                    context.delete(action)
                }
                try context.save()
                Log.info("Dismissed \(actions.count) abandoned actions", category: .sync)
            } catch {
                Log.error("Failed to dismiss all abandoned actions", category: .sync, error: error)
            }
        }
    }
}

// MARK: - Abandoned Action Info

/// Lightweight struct for displaying abandoned action information in the UI.
struct AbandonedActionInfo: Identifiable {
    let id: NSManagedObjectID
    let actionType: PendingAction.ActionType
    let messageId: String?
    let conversationId: UUID?
    let createdAt: Date
    let retryCount: Int

    var actionDescription: String {
        switch actionType {
        case .markRead: return "Mark as read"
        case .markUnread: return "Mark as unread"
        case .archive: return "Archive message"
        case .archiveConversation: return "Archive conversation"
        case .star: return "Star message"
        case .unstar: return "Unstar message"
        case .reportSpam: return "Report spam"
        }
    }
}
