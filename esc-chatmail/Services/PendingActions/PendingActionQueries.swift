import Foundation
import CoreData

/// Extension containing query methods for PendingActionsManager.
///
/// These methods provide read-only access to pending action state without
/// modifying any data. They're used by UI and other services to check
/// pending action status.
extension PendingActionsManager {

    /// Returns the count of pending or failed actions that haven't exceeded retry limit.
    public func pendingActionCount() async -> Int {
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
        let context = coreDataStack.newBackgroundContext()
        return await context.perform {
            let request = NSFetchRequest<PendingAction>(entityName: "PendingAction")
            request.predicate = NSPredicate(
                format: "messageId == %@ AND actionType == %@ AND (status == %@ OR status == %@)",
                messageId, type.rawValue, "pending", "processing"
            )
            request.fetchLimit = 1

            do {
                return try context.fetch(request).first != nil
            } catch {
                Log.error("Failed to check for pending action", category: .sync, error: error)
                return false  // Assume no pending action on error
            }
        }
    }

    /// Cancels a pending action for a specific message and type.
    public func cancelPendingAction(forMessageId messageId: String, type: PendingAction.ActionType) async {
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
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
            do {
                guard let action = try context.existingObject(with: objectID) as? PendingAction else {
                    Log.warning("Abandoned action not found for retry", category: .sync)
                    return
                }
                action.setValue("pending", forKey: "status")
                action.setValue(Int16(0), forKey: "retryCount")
                try context.save()
                Log.info("Abandoned action reset for retry", category: .sync)
            } catch {
                Log.error("Failed to retry abandoned action", category: .sync, error: error)
            }
        }

        // Trigger processing of pending actions
        await processAllPendingActions()
    }

    /// Retries all abandoned actions by resetting their status and retry count.
    public func retryAllAbandonedActions() async {
        let context = coreDataStack.newBackgroundContext()
        await context.perform {
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
            } catch {
                Log.error("Failed to retry all abandoned actions", category: .sync, error: error)
            }
        }

        // Trigger processing of pending actions
        await processAllPendingActions()
    }

    /// Dismisses (deletes) an abandoned action permanently.
    public func dismissAbandonedAction(objectID: NSManagedObjectID) async {
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
        }
    }
}
